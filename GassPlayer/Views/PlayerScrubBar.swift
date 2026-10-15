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
    private var sourceURL: URL?
    private var generator: AVAssetImageGenerator?
    private var thumbnailController: ThumbnailController?
    private var ffThumbnails: [FFThumbnail] = []
    private var ffTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var lastUserRequest = Date.distantPast
    private var cache: [Int: UIImage] = [:]
    /// Punto richiesto dallo scrubbing in corso (nil = nessuno scrubbing).
    private var wantedTime: TimeInterval?
    /// Una sola generazione alla volta: finita quella, parte subito l'ultimo
    /// punto richiesto (le anteprime continuano ad arrivare mentre si trascina,
    /// invece di essere annullate a ogni movimento del dito).
    private var requestInFlight = false
    private var failedBuckets: Set<Int> = []
    private var avFailures = 0

    private static let bucket: TimeInterval = 5
    private static let ffmpegThumbnailCount = 48
    /// Griglia preparata in background per i file mp4/mov: lo scrubbing trova
    /// subito un fotogramma vicino, poi arriva quello esatto.
    private static let prefetchCount = 40
    /// Tutto parte solo al primo trascinamento (nessuna connessione in più
    /// al server finché non si usa la timeline).
    private static let prefetchDelayNanoseconds: UInt64 = 0
    private static let ffmpegDelayNanoseconds: UInt64 = 0
    /// Dopo questi errori consecutivi senza alcun fotogramma, AVFoundation
    /// lascia il posto a FFmpeg (server senza richieste parziali, codec non
    /// supportati…).
    private static let maxAVFailures = 3
    private static let avFoundationExtensions: Set<String> = ["mp4", "m4v", "mov", "3gp"]

    var isAvailable: Bool { generator != nil || !ffThumbnails.isEmpty }

    func prepare(url: URL, userAgent: String, duration: TimeInterval) {
        let key = url.absoluteString
        guard key != sourceKey else { return }
        reset()
        sourceKey = key
        sourceURL = url

        let ext = url.pathExtension.lowercased()
        if ext == "m3u8" || ext == "m3u" { return }

        if Self.avFoundationExtensions.contains(ext) {
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": userAgent]])
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 360, height: 202)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 4, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 4, preferredTimescale: 600)
            self.generator = generator
            startPrefetch(generator: generator, duration: duration, key: key)
            return
        }

        startFFmpeg(url: url, key: key)
    }

    /// Miniature FFmpeg (KSPlayer), mostrate man mano che arrivano.
    private func startFFmpeg(url: URL, key: String) {
        let controller = ThumbnailController(thumbnailCount: Self.ffmpegThumbnailCount)
        controller.delegate = self
        thumbnailController = controller
        ffTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.ffmpegDelayNanoseconds)
            guard !Task.isCancelled else { return }
            let thumbnails = (try? await controller.generateThumbnail(for: url, thumbWidth: 240)) ?? []
            guard !Task.isCancelled, let self, self.sourceKey == key, !thumbnails.isEmpty else { return }
            self.ffThumbnails = thumbnails.sorted { $0.time < $1.time }
            self.refreshImage()
        }
    }

    nonisolated func didUpdate(thumbnails: [FFThumbnail], forFile file: URL, withProgress: Int) {
        let snapshot = thumbnails
        let key = file.absoluteString
        Task { @MainActor [weak self] in
            guard let self, self.sourceKey == key else { return }
            self.ffThumbnails = snapshot.sorted { $0.time < $1.time }
            self.refreshImage()
        }
    }

    /// Griglia di fotogrammi in background (si ferma mentre l'utente trascina).
    private func startPrefetch(generator: AVAssetImageGenerator, duration: TimeInterval, key: String) {
        guard duration > 0 else { return }
        prefetchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.prefetchDelayNanoseconds)
            let step = max(duration / Double(Self.prefetchCount), Self.bucket)
            var grid: [Int] = stride(from: step / 2, to: duration, by: step).map { Int($0 / Self.bucket) }
            while !grid.isEmpty, !Task.isCancelled {
                // La richiesta esatta dell'utente ha la precedenza.
                while let self, self.requestInFlight, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 40_000_000)
                }
                guard let self, self.sourceKey == key, self.generator === generator, !Task.isCancelled else { return }
                // Sempre il punto della griglia più vicino al dito: le miniature utili arrivano per prime.
                let focus = self.wantedTime.map { Int($0 / Self.bucket) } ?? grid[0]
                guard let index = grid.indices.min(by: { abs(grid[$0] - focus) < abs(grid[$1] - focus) }) else { return }
                let bucket = grid.remove(at: index)
                if self.cache[bucket] == nil, !self.failedBuckets.contains(bucket) {
                    if let result = try? await generator.image(at: Self.time(for: bucket)), self.sourceKey == key {
                        self.store(UIImage(cgImage: result.image), bucket: bucket)
                    }
                }
            }
        }
    }

    /// Prima comparsa istantanea: il fotogramma a schermo entra in cache al
    /// punto di riproduzione attuale (ridotto alle dimensioni delle miniature).
    func seed(currentFrame cgImage: CGImage, at time: TimeInterval) {
        guard sourceKey != nil else { return }
        let bucket = Int(max(0, time) / Self.bucket)
        guard cache[bucket] == nil else { return }
        let source = UIImage(cgImage: cgImage)
        let width: CGFloat = 360
        let scale = width / max(source.size.width, 1)
        let size = CGSize(width: width, height: max(1, (source.size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let thumbnail = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
        store(thumbnail, bucket: bucket)
        if ffThumbnails.isEmpty, wantedTime != nil, image == nil { image = thumbnail }
    }

    /// Anteprima del punto `time` (chiamata a ogni movimento del dito).
    func request(at time: TimeInterval) {
        wantedTime = max(0, time)
        lastUserRequest = Date()
        refreshImage()
        pump()
    }

    /// Fine dello scrubbing: nessun'altra richiesta per il punto lasciato.
    func finishRequests() {
        wantedTime = nil
    }

    /// Mostra subito il fotogramma pronto più vicino al punto richiesto
    /// (quello esatto se c'è).
    private func refreshImage() {
        guard let time = wantedTime else { return }
        if !ffThumbnails.isEmpty {
            if let nearest = ffThumbnails.min(by: { abs($0.time - time) < abs($1.time - time) }) {
                image = nearest.image
            }
            return
        }
        let bucket = Int(time / Self.bucket)
        if let exact = cache[bucket] {
            image = exact
        } else if let nearest = cache.min(by: { abs($0.key - bucket) < abs($1.key - bucket) })?.value {
            image = nearest
        }
    }

    /// Genera il fotogramma dell'ultimo punto richiesto, uno alla volta.
    private func pump() {
        guard !requestInFlight, let generator, let time = wantedTime, let key = sourceKey else { return }
        let bucket = Int(time / Self.bucket)
        guard cache[bucket] == nil, !failedBuckets.contains(bucket) else { return }
        requestInFlight = true
        requestTask = Task { [weak self] in
            let result = try? await generator.image(at: Self.time(for: bucket))
            guard let self, self.sourceKey == key, self.generator === generator else { return }
            self.requestInFlight = false
            if let result {
                self.avFailures = 0
                self.store(UIImage(cgImage: result.image), bucket: bucket)
            } else {
                self.failedBuckets.insert(bucket)
                self.avFailures += 1
                if self.avFailures >= Self.maxAVFailures, self.cache.isEmpty, let url = self.sourceURL {
                    self.switchToFFmpeg(url: url, key: key)
                    return
                }
            }
            self.pump()
        }
    }

    private func store(_ image: UIImage, bucket: Int) {
        cache[bucket] = image
        failedBuckets.remove(bucket)
        refreshImage()
    }

    private func switchToFFmpeg(url: URL, key: String) {
        prefetchTask?.cancel()
        generator?.cancelAllCGImageGeneration()
        generator = nil
        requestInFlight = false
        startFFmpeg(url: url, key: key)
    }

    private static func time(for bucket: Int) -> CMTime {
        CMTime(seconds: Double(bucket) * Self.bucket + Self.bucket / 2, preferredTimescale: 600)
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
        failedBuckets = []
        avFailures = 0
        requestInFlight = false
        wantedTime = nil
        image = nil
        sourceKey = nil
        sourceURL = nil
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
    /// Fotogramma attualmente a schermo (prima anteprima istantanea).
    var currentFrame: (() async -> CGImage?)? = nil

    @State private var scrubTime: TimeInterval?
    @State private var isEditing = false
    /// Rete di sicurezza: se il sistema non segnala il rilascio, lo scrubbing
    /// si chiude comunque dopo un breve periodo senza movimenti.
    @State private var releaseWatchdog: Task<Void, Never>?

    private enum Metrics {
        static let bufferedTrackHeight: CGFloat = 4
        static let previewWidth: CGFloat = 176
        static let previewHeight: CGFloat = 99
        static let previewCornerRadius: CGFloat = 16
        static let previewSpacing: CGFloat = 6
        static let previewGap: CGFloat = 10
        static let releaseWatchdogNanoseconds: UInt64 = 4_000_000_000
    }

    var body: some View {
        // Lo stesso `Slider` nativo bianco di prima (Liquid Glass su iOS 26):
        // dietro la traccia la parte già scaricata, sopra l'anteprima.
        Slider(
            value: Binding(
                get: { scrubTime ?? currentTime },
                set: { time in
                    if !isEditing { beginScrub() }
                    scrubTime = time
                    if thumbnailSource != nil { thumbnails.request(at: time) }
                    armReleaseWatchdog()
                }
            ),
            in: 0...max(duration, 1),
            onEditingChanged: { editing in
                if editing {
                    if !isEditing { beginScrub() }
                } else {
                    finishScrub()
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
                }
            }
            .allowsHitTesting(false)
        }
        .zIndex(1)
        .onDisappear {
            releaseWatchdog?.cancel()
            releaseWatchdog = nil
            guard isEditing else { return }
            isEditing = false
            scrubTime = nil
            thumbnails.finishRequests()
            onScrubbingChanged(false)
        }
    }

    // MARK: Inizio / fine trascinamento

    private func beginScrub() {
        isEditing = true
        scrubTime = currentTime
        // Le anteprime si preparano solo da qui, al primo trascinamento.
        if let source = thumbnailSource, duration > 0 {
            thumbnails.prepare(url: source.url, userAgent: source.userAgent, duration: duration)
            // Subito il fotogramma a schermo, intanto arrivano quelli del punto scelto.
            let playbackTime = currentTime
            if let currentFrame {
                Task { @MainActor in
                    if let frame = await currentFrame() {
                        thumbnails.seed(currentFrame: frame, at: playbackTime)
                    }
                }
            }
            thumbnails.request(at: currentTime)
        }
        onScrubbingChanged(true)
        armReleaseWatchdog()
    }

    /// Rilascio: seek al punto scelto, anteprima e tempo spariscono subito e
    /// riparte il timer che nasconde i controlli (`onScrubbingChanged(false)`).
    private func finishScrub() {
        releaseWatchdog?.cancel()
        releaseWatchdog = nil
        guard isEditing else { return }
        let target = scrubTime
        isEditing = false
        scrubTime = nil
        thumbnails.finishRequests()
        if let target { onSeek(target) }
        onScrubbingChanged(false)
    }

    private func armReleaseWatchdog() {
        releaseWatchdog?.cancel()
        releaseWatchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Metrics.releaseWatchdogNanoseconds)
            guard !Task.isCancelled else { return }
            finishScrub()
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
