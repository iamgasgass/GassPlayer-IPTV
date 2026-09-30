import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Pipeline unica per tutte le immagini del catalogo.
///
/// Obiettivi:
/// - cache RAM + URLCache su disco;
/// - deduplicazione delle richieste concorrenti per la stessa URL;
/// - downsampling prima del rendering, così una locandina 1000+ px non viene
///   decodificata alla risoluzione originale dentro una LazyVGrid;
/// - nessuna animazione di ingresso: l'immagine sostituisce semplicemente il
///   placeholder stabile.
///
/// `URLCache` rende il caricamento persistente tra le schermate e, quando il
/// server lo consente, anche tra avvii dell'app. La cache RAM evita inoltre
/// che lo scroll avanti/indietro riapra continuamente le stesse immagini.
actor RemoteImagePipeline {
    static let shared = RemoteImagePipeline()

    private let session: URLSession
    private let memoryCache: NSCache<NSURL, NSData>
    private var inFlight: [URL: Task<Data, Error>] = [:]

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 256 * 1024 * 1024,
            diskPath: "gassplayer.artwork"
        )
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30

        session = URLSession(configuration: configuration)

        let cache = NSCache<NSURL, NSData>()
        cache.countLimit = 350
        cache.totalCostLimit = 64 * 1024 * 1024
        memoryCache = cache
    }

    func data(for url: URL, maxPixelSize: Int) async throws -> Data {
        if let cached = memoryCache.object(forKey: url as NSURL) {
            return cached as Data
        }

        if let task = inFlight[url] {
            return try await task.value
        }

        let session = session
        let task = Task<Data, Error> {
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad

            let (data, response) = try await session.data(for: request)

            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }

            guard !data.isEmpty else {
                throw URLError(.zeroByteResource)
            }

            return try downsampledImageData(data, maxPixelSize: maxPixelSize)
        }

        inFlight[url] = task

        do {
            let data = try await task.value
            memoryCache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
            inFlight[url] = nil
            return data
        } catch {
            inFlight[url] = nil
            throw error
        }
    }

    func prefetch(_ urls: [URL], maxPixelSize: Int) async {
        let uniqueURLs = Array(Set(urls)).prefix(80)

        for start in stride(from: 0, to: uniqueURLs.count, by: 8) {
            guard !Task.isCancelled else { return }

            let end = min(start + 8, uniqueURLs.count)
            let batch = Array(uniqueURLs[start..<end])

            await withTaskGroup(of: Void.self) { group in
                for url in batch {
                    group.addTask { [self] in
                        _ = try? await self.data(
                            for: url,
                            maxPixelSize: maxPixelSize
                        )
                    }
                }
            }
        }
    }

}

/// Downsampling fuori dal MainActor: il decoder non porta una bitmap enorme
/// nel renderer SwiftUI e riduce sensibilmente picchi di CPU/memoria durante
/// lo scroll.
private func downsampledImageData(_ data: Data, maxPixelSize: Int) throws -> Data {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
        throw URLError(.cannotDecodeContentData)
    }

    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(128, maxPixelSize)
    ]

    guard let image = CGImageSourceCreateThumbnailAtIndex(
        source,
        0,
        options as CFDictionary
    ) else {
        throw URLError(.cannotDecodeContentData)
    }

    let hasAlpha: Bool
    switch image.alphaInfo {
    case .first, .last, .premultipliedFirst, .premultipliedLast:
        hasAlpha = true
    default:
        hasAlpha = false
    }

    let output = NSMutableData()
    let type: CFString = hasAlpha
        ? UTType.png.identifier as CFString
        : UTType.jpeg.identifier as CFString

    guard let destination = CGImageDestinationCreateWithData(
        output,
        type,
        1,
        nil
    ) else {
        throw URLError(.cannotCreateFile)
    }

    var properties: [CFString: Any] = [:]
    if !hasAlpha {
        properties[kCGImageDestinationLossyCompressionQuality] = 0.88
    }

    CGImageDestinationAddImage(destination, image, properties as CFDictionary)

    guard CGImageDestinationFinalize(destination) else {
        throw URLError(.cannotCreateFile)
    }

    return output as Data
}

/// Loader di una singola card. Mantiene il fallback già visibile mentre il
/// poster TMDB viene scaricato: questo elimina il "flash" placeholder -> poster
/// durante lo scroll.
@MainActor
final class CachedRemoteImageLoader: ObservableObject {
    enum Source {
        case none
        case primary
        case fallback
    }

    @Published private(set) var image: UIImage?
    @Published private(set) var source: Source = .none

    private var configurationKey: String?
    private var fallbackURL: URL?

    func load(
        primaryURL: URL?,
        fallbackURL: URL?,
        maxPixelSize: Int
    ) async {
        let key = "\(primaryURL?.absoluteString ?? "-")|\(fallbackURL?.absoluteString ?? "-")|\(maxPixelSize)"
        guard configurationKey != key else { return }

        let oldFallbackURL = self.fallbackURL
        let canKeepCurrentImage =
            image != nil &&
            source == .fallback &&
            oldFallbackURL == fallbackURL

        configurationKey = key
        self.fallbackURL = fallbackURL

        if !canKeepCurrentImage {
            image = nil
            source = .none
        }

        if let primaryURL {
            if let data = try? await RemoteImagePipeline.shared.data(
                for: primaryURL,
                maxPixelSize: maxPixelSize
            ),
            let decoded = UIImage(data: data),
            !Task.isCancelled {
                image = decoded
                source = .primary
                return
            }
        }

        if let fallbackURL {
            if canKeepCurrentImage {
                // Il fallback e' gia' sullo schermo: non lo ricarichiamo.
                return
            }

            if let data = try? await RemoteImagePipeline.shared.data(
                for: fallbackURL,
                maxPixelSize: maxPixelSize
            ),
            let decoded = UIImage(data: data),
            !Task.isCancelled {
                image = decoded
                source = .fallback
                return
            }
        }

        if !Task.isCancelled {
            image = nil
            source = .none
        }
    }
}

struct CachedRemoteImage<Placeholder: View>: View {
    let primaryURL: URL?
    let fallbackURL: URL?
    let width: CGFloat
    let height: CGFloat
    let primaryContentMode: ContentMode
    let fallbackContentMode: ContentMode
    @ViewBuilder let placeholder: () -> Placeholder

    @StateObject private var loader = CachedRemoteImageLoader()

    init(
        primaryURL: URL?,
        fallbackURL: URL?,
        width: CGFloat,
        height: CGFloat,
        primaryContentMode: ContentMode = .fill,
        fallbackContentMode: ContentMode = .fit,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.primaryURL = primaryURL
        self.fallbackURL = fallbackURL
        self.width = width
        self.height = height
        self.primaryContentMode = primaryContentMode
        self.fallbackContentMode = fallbackContentMode
        self.placeholder = placeholder
    }

    private var maxPixelSize: Int {
        max(128, Int(max(width, height) * 3.0))
    }

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(
                        contentMode: loader.source == .primary
                            ? primaryContentMode
                            : fallbackContentMode
                    )
            } else {
                placeholder()
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .transaction { transaction in
            transaction.animation = nil
        }
        .task(id: "\(primaryURL?.absoluteString ?? "-")|\(fallbackURL?.absoluteString ?? "-")") {
            await loader.load(
                primaryURL: primaryURL,
                fallbackURL: fallbackURL,
                maxPixelSize: maxPixelSize
            )
        }
    }
}
