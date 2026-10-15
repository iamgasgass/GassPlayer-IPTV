import SwiftUI
import UIKit
import AVFoundation
import KSPlayer

// MARK: - Timeline del player con parte bufferizzata e anteprime
//
// - La traccia mostra tre livelli: trascorso (bianco), già scaricato
//   (bianco traslucido) e restante: ci si sposta avanti/indietro sapendo
//   quale parte è già pronta.
// - Durante il trascinamento la posizione si sposta SOLO a schermo (prima
//   ogni movimento del dito lanciava una seek sul flusso): la seek parte una
//   volta, al rilascio.
// - Per Film / Serie TV, sopra il pallino compare l'anteprima del punto
//   scelto: card con angoli continui da 16 pt e filo chiaro (come le card di
//   "Continua a guardare") e il tempo in una capsula Liquid Glass.

/// Miniature della timeline.
/// - mp4 / m4v / mov: `AVAssetImageGenerator` su richiesta (fotogramma chiave
///   più vicino, con lo stesso User-Agent del player), in cache a blocchi di 5 s;
/// - altri contenitori (mkv, avi, ts…): `ThumbnailController` di KSPlayer
///   (FFmpeg), 48 miniature distribuite sulla durata e generate in background
///   qualche secondo dopo l'avvio, mostrate man mano che arrivano.
/// HLS (m3u8) e Live TV non hanno anteprime: resta solo il tempo.
@MainActor
final class PlayerThumbnailProvider: ObservableObject, ThumbnailControllerDelegate {
    @Published private(set) var image: UIImage?

    private var sourceKey: String?
    private var generator: AVAssetImageGenerator?
    private var thumbnailController: ThumbnailController?
    private var ffThumbnails: [FFThumbnail] = []
    private var ffTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var lastUserRequest = Date.distantPast
    private var cache: [Int: UIImage] = [:]

    private static let bucket: TimeInterval = 5
    private static let ffmpegThumbnailCount = 48
    /// Griglia preparata in background per i file mp4/mov: lo scrubbing trova
    /// subito un fotogramma vicino, poi arriva quello esatto.
    private static let prefetchCount = 40
    private static let prefetchDelayNanoseconds: UInt64 = 2_500_000_000
    private static let ffmpegDelayNanoseconds: UInt64 = 2_500_000_000
    private static let avFoundationExtensions: Set<String> = ["mp4", "m4v", "mov", "3gp"]

    var isAvailable: Bool { generator != nil || !ffThumbnails.isEmpty }

    func prepare(url: URL, userAgent: String, duration: TimeInterval) {
        let key = url.absoluteString
        guard key != sourceKey else { return }
        reset()
        sourceKey = key

        let ext = url.pathExtension.lowercased()
        if ext == "m3u8" || ext == "m3u" { return }

        if Self.avFoundationExtensions.contains(ext) {
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": userAgent]])
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 180)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 4, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 4, preferredTimescale: 600)
            self.generator = generator
            startPrefetch(generator: generator, duration: duration, key: key)
            return
        }

        // FFmpeg: dopo qualche secondo di riproduzione, per non togliere banda all'avvio.
        let controller = ThumbnailController(thumbnailCount: Self.ffmpegThumbnailCount)
        controller.delegate = self
        thumbnailController = controller
        ffTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.ffmpegDelayNanoseconds)
            guard !Task.isCancelled else { return }
            let thumbnails = (try? await controller.generateThumbnail(for: url, thumbWidth: 240)) ?? []
            guard !Task.isCancelled, let self, self.sourceKey == key, !thumbnails.isEmpty else { return }
            self.ffThumbnails = thumbnails.sorted { $0.time < $1.time }
        }
    }

    nonisolated func didUpdate(thumbnails: [FFThumbnail], forFile file: URL, withProgress: Int) {
        let snapshot = thumbnails
        let key = file.absoluteString
        Task { @MainActor [weak self] in
            guard let self, self.sourceKey == key else { return }
            self.ffThumbnails = snapshot.sorted { $0.time < $1.time }
        }
    }

    /// Griglia di fotogrammi in background (si ferma mentre l'utente trascina).
    private func startPrefetch(generator: AVAssetImageGenerator, duration: TimeInterval, key: String) {
        guard duration > 0 else { return }
        prefetchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.prefetchDelayNanoseconds)
            let step = max(duration / Double(Self.prefetchCount), Self.bucket)
            var position = step / 2
            while position < duration, !Task.isCancelled {
                while let self, Date().timeIntervalSince(self.lastUserRequest) < 0.6, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }
                guard let self, self.sourceKey == key, !Task.isCancelled else { return }
                let bucket = Int(position / Self.bucket)
                if self.cache[bucket] == nil {
                    let target = CMTime(seconds: Double(bucket) * Self.bucket + Self.bucket / 2, preferredTimescale: 600)
                    if let result = try? await generator.image(at: target), self.sourceKey == key {
                        self.cache[bucket] = UIImage(cgImage: result.image)
                    }
                }
                position += step
            }
        }
    }

    /// Anteprima del punto `time` (chiamata a ogni movimento del dito).
    func request(at time: TimeInterval) {
        let bucket = Int(max(0, time) / Self.bucket)

        if let cached = cache[bucket] {
            image = cached
            return
        }

        if !ffThumbnails.isEmpty {
            image = ffThumbnails.min { abs($0.time - time) < abs($1.time - time) }?.image
            return
        }

        guard let generator else { return }
        lastUserRequest = Date()
        // Subito il fotogramma pronto più vicino, poi quello esatto.
        if let nearest = cache.min(by: { abs($0.key - bucket) < abs($1.key - bucket) })?.value {
            image = nearest
        }
        requestTask?.cancel()
        requestTask = Task { [weak self] in
            // Attesa minima: durante uno scorrimento veloce si chiede solo l'ultimo punto.
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard !Task.isCancelled else { return }
            let target = CMTime(seconds: Double(bucket) * Self.bucket + Self.bucket / 2, preferredTimescale: 600)
            guard let result = try? await generator.image(at: target) else { return }
            let image = UIImage(cgImage: result.image)
            guard let self else { return }
            self.cache[bucket] = image
            if !Task.isCancelled { self.image = image }
        }
    }

    func reset() {
        ffTask?.cancel()
        requestTask?.cancel()
        prefetchTask?.cancel()
        lastUserRequest = .distantPast
        generator?.cancelAllCGImageGeneration()
        generator = nil
        thumbnailController?.delegate = nil
        thumbnailController = nil
        ffThumbnails = []
        cache = [:]
        image = nil
        sourceKey = nil
    }
}

struct PlayerScrubBar: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let bufferedTime: TimeInterval
    /// Flusso da cui leggere le miniature; `nil` = nessuna anteprima (Live TV).
    let thumbnailSource: (url: URL, userAgent: String)?
    @ObservedObject var thumbnails: PlayerThumbnailProvider
    let onScrubbingChanged: (Bool) -> Void
    let onSeek: (TimeInterval) -> Void

    @State private var scrubTime: TimeInterval?
    @State private var isEditing = false

    private enum Metrics {
        static let bufferedTrackHeight: CGFloat = 4
        static let previewWidth: CGFloat = 176
        static let previewHeight: CGFloat = 99
        static let previewCornerRadius: CGFloat = 16
        static let previewSpacing: CGFloat = 6
        static let previewGap: CGFloat = 10
    }

    var body: some View {
        // Lo stesso `Slider` nativo bianco di prima (Liquid Glass su iOS 26):
        // dietro la traccia la parte già scaricata, sopra l'anteprima.
        Slider(
            value: Binding(
                get: { scrubTime ?? currentTime },
                set: { time in
                    if isEditing {
                        scrubTime = time
                        if thumbnailSource != nil { thumbnails.request(at: time) }
                    } else {
                        onSeek(time)
                    }
                }
            ),
            in: 0...max(duration, 1),
            onEditingChanged: { editing in
                isEditing = editing
                if editing {
                    scrubTime = currentTime
                    if thumbnailSource != nil { thumbnails.request(at: currentTime) }
                    onScrubbingChanged(true)
                } else {
                    if let scrubTime { onSeek(scrubTime) }
                    scrubTime = nil
                    onScrubbingChanged(false)
                }
            }
        )
        .tint(.white)
        .background {
            GeometryReader { proxy in
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(
                        width: proxy.size.width * fraction(max(bufferedTime, currentTime)),
                        height: Metrics.bufferedTrackHeight
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        // Anteprima SOPRA la barra: il fondo della card resta a `previewGap`
        // dal bordo superiore dello slider, centrata sul punto scelto.
        .overlay {
            GeometryReader { proxy in
                if isEditing, let scrubTime {
                    preview(time: scrubTime)
                        .fixedSize()
                        .offset(
                            x: previewX(progress: fraction(scrubTime), width: proxy.size.width),
                            y: -(proxy.size.height + Metrics.previewGap)
                        )
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
                        .transition(.opacity)
                }
            }
            .allowsHitTesting(false)
        }
        .zIndex(1)
        .animation(.easeOut(duration: 0.15), value: isEditing)
        .task(id: thumbnailSource?.url.absoluteString) {
            guard let source = thumbnailSource, duration > 0 else { return }
            thumbnails.prepare(url: source.url, userAgent: source.userAgent, duration: duration)
        }
    }

    // MARK: Anteprima

    private func preview(time: TimeInterval) -> some View {
        VStack(spacing: Metrics.previewSpacing) {
            if thumbnailSource != nil, let image = thumbnails.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Metrics.previewWidth, height: Metrics.previewHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.previewCornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Metrics.previewCornerRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.7)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            }

            Text(Self.formatted(time))
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .modifier(PlayerGlassCapsuleBackground())
        }
        .frame(width: Metrics.previewWidth)
    }

    private func previewX(progress: Double, width: CGFloat) -> CGFloat {
        let center = width * progress
        let half = Metrics.previewWidth / 2
        return min(max(center - half, 0), max(width - Metrics.previewWidth, 0))
    }

    // MARK: Calcoli

    private func fraction(_ time: TimeInterval) -> Double {
        guard duration > 0, time.isFinite else { return 0 }
        return min(max(time / duration, 0), 1)
    }

    private func timeAt(_ x: CGFloat, width: CGFloat) -> TimeInterval {
        let ratio = min(max(Double(x / width), 0), 1)
        return ratio * duration
    }

    static func formatted(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// Capsula Liquid Glass del tempo nell'anteprima: vetro nativo su iOS 26,
/// materiale sottile con filo di bordo prima (come `ClearGlassCapsule`).
private struct PlayerGlassCapsuleBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
                }
        }
    }
}
