import SwiftUI
import UIKit
import ImageIO

/// Cache in memoria delle immagini già scaricate e ridimensionate.
/// `NSCache` è thread-safe e si svuota da sola sotto pressione di memoria.
final class PosterImageCache: @unchecked Sendable {
    static let shared = PosterImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 800
        cache.totalCostLimit = 150 * 1024 * 1024
    }

    static func key(url: URL, maxPixel: Int) -> String {
        "\(maxPixel)|\(url.absoluteString)"
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: UIImage, for key: String) {
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}

enum PosterImageLoader {
    /// Scarica l'immagine (sfruttando anche `URLCache` di sistema), la
    /// ridimensiona alla dimensione realmente mostrata e la mette in cache.
    static func load(url: URL, maxPixel: Int) async -> UIImage? {
        let key = PosterImageCache.key(url: url, maxPixel: maxPixel)

        if let cached = PosterImageCache.shared.image(for: key) {
            return cached
        }

        guard let (data, response) = try? await URLSession.shared.data(from: url) else {
            return nil
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return nil
        }

        guard !Task.isCancelled else { return nil }

        let image = await Task.detached(priority: .utility) {
            downsample(data: data, maxPixel: maxPixel)
        }.value

        if let image {
            PosterImageCache.shared.insert(image, for: key)
        }

        return image
    }

    private static func downsample(data: Data, maxPixel: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary

        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}

/// Immagine di locandina/logo letta SOLO dall'URL fornito da Xtream
/// (`stream_icon` / `cover`), usata nelle griglie Live TV, VOD e Serie TV.
///
/// Perché non c'è più sfarfallio durante lo scroll:
/// - nessuna richiesta TMDB nelle celle (prima ogni cella mostrava
///   l'icona Xtream, poi la sostituiva con il poster TMDB: due immagini
///   che si scambiavano a ogni riciclo della cella);
/// - se l'immagine è già in cache viene mostrata dal PRIMO frame della
///   cella (lo `@State` nasce già valorizzato), senza passare dal
///   placeholder come invece fa `AsyncImage` a ogni ricreazione;
/// - nessuna animazione implicita sul cambio placeholder → immagine.
struct CachedPosterImage: View {
    let urlString: String?
    let size: CGSize
    let contentMode: ContentMode
    let cornerRadius: CGFloat
    let placeholderSymbol: String

    @State private var image: UIImage?

    private var url: URL? {
        guard let urlString, !urlString.isEmpty else { return nil }
        return URL(string: urlString)
    }

    /// Lato massimo in pixel: dimensione mostrata × scala schermo tipica.
    private var maxPixel: Int {
        Int((max(size.width, size.height) * 3).rounded())
    }

    private var cacheKey: String? {
        url.map { PosterImageCache.key(url: $0, maxPixel: maxPixel) }
    }

    init(
        urlString: String?,
        size: CGSize,
        contentMode: ContentMode,
        cornerRadius: CGFloat = 12,
        placeholderSymbol: String
    ) {
        self.urlString = urlString
        self.size = size
        self.contentMode = contentMode
        self.cornerRadius = cornerRadius
        self.placeholderSymbol = placeholderSymbol

        var initial: UIImage?

        if let urlString, !urlString.isEmpty, let url = URL(string: urlString) {
            let pixel = Int((max(size.width, size.height) * 3).rounded())
            initial = PosterImageCache.shared.image(
                for: PosterImageCache.key(url: url, maxPixel: pixel)
            )
        }

        _image = State(initialValue: initial)
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .transaction { $0.animation = nil }
        .task(id: cacheKey) {
            guard let url else {
                image = nil
                return
            }

            if let cacheKey, let cached = PosterImageCache.shared.image(for: cacheKey) {
                image = cached
                return
            }

            image = nil
            image = await PosterImageLoader.load(url: url, maxPixel: maxPixel)
        }
    }

    private var placeholder: some View {
        Color.secondary.opacity(0.12)
            .overlay {
                Image(systemName: placeholderSymbol)
                    .foregroundStyle(.secondary)
            }
    }
}
