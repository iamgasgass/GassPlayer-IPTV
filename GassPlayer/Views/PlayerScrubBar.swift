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

    /// Blocchi da 5 s, più larghi sui contenuti lunghi (durata / 240): meno
    /// letture e più miniature già pronte mentre il dito si muove.
    private static let minimumBucket: TimeInterval = 5
    private static let maxBuckets: Double = 240
    private var bucketSize: TimeInterval = 5
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
        bucketSize = max(Self.minimumBucket, duration / Self.maxBuckets)

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
        let bucketSize = self.bucketSize
        prefetchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.prefetchDelayNanoseconds)
            let step = max(duration / Double(Self.prefetchCount), bucketSize)
            var grid: [Int] = stride(from: step / 2, to: duration, by: step).map { Int($0 / bucketSize) }
            while !grid.isEmpty, !Task.isCancelled {
                // La richiesta esatta dell'utente ha la precedenza.
                while let self, self.requestInFlight, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 40_000_000)
                }
                guard let self, self.sourceKey == key, self.generator === generator, !Task.isCancelled else { return }
                // Sempre il punto della griglia più vicino al dito: le miniature utili arrivano per prime.
                let focus = self.wantedTime.map { Int($0 / bucketSize) } ?? grid[0]
                guard let index = grid.indices.min(by: { abs(grid[$0] - focus) < abs(grid[$1] - focus) }) else { return }
                let bucket = grid.remove(at: index)
                if self.cache[bucket] == nil, !self.failedBuckets.contains(bucket) {
                    if let result = try? await generator.image(at: self.frameTime(for: bucket)), self.sourceKey == key {
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
        let bucket = Int(max(0, time) / bucketSize)
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

    // MARK: Anteprima in tempo reale

    /// Player nascosto dell'anteprima: si sposta mentre si trascina e si vede
    /// SOLO dentro la card (il video principale dietro resta fermo).
    let previewEngine = PlayerScrubPreviewEngine()

    /// Mostra subito un fotogramma (quello a schermo all'inizio del trascinamento).
    func showLive(_ cgImage: CGImage) {
        image = Self.scaledThumbnail(cgImage)
    }

    private static func scaledThumbnail(_ cgImage: CGImage) -> UIImage {
        let source = UIImage(cgImage: cgImage)
        let width: CGFloat = 360
        let scale = width / max(source.size.width, 1)
        let size = CGSize(width: width, height: max(1, (source.size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
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
        // La prossima anteprima riparte dal fotogramma a schermo, non dall'ultima di questa volta.
        image = nil
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
        let bucket = Int(time / bucketSize)
        if let exact = cache[bucket] {
            image = exact
        } else if let nearest = cache.min(by: { abs($0.key - bucket) < abs($1.key - bucket) })?.value {
            image = nearest
        }
    }

    /// Genera il fotogramma dell'ultimo punto richiesto, uno alla volta.
    private func pump() {
        guard !requestInFlight, let generator, let time = wantedTime, let key = sourceKey else { return }
        let bucket = Int(time / bucketSize)
        guard cache[bucket] == nil, !failedBuckets.contains(bucket) else { return }
        requestInFlight = true
        let target = frameTime(for: bucket)
        requestTask = Task { [weak self] in
            let result = try? await generator.image(at: target)
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

    private func frameTime(for bucket: Int) -> CMTime {
        CMTime(seconds: Double(bucket) * bucketSize + bucketSize / 2, preferredTimescale: 600)
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
        bucketSize = Self.minimumBucket
        requestInFlight = false
        wantedTime = nil
        image = nil
        sourceKey = nil
        sourceURL = nil
        previewEngine.teardown()
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
    var currentFrame: (@MainActor () async -> CGImage?)? = nil

    @State private var scrubTime: TimeInterval?
    @State private var isEditing = false
    /// Rete di sicurezza: se il sistema non segnala il rilascio, lo scrubbing
    /// si chiude comunque dopo un breve periodo senza movimenti.
    @State private var releaseWatchdog: Task<Void, Never>?
    /// Ultimo rilascio: lo `Slider` di sistema a volte invia un ultimo valore
    /// subito DOPO il rilascio; prima riapriva l'anteprima (che restava a
    /// schermo) e dopo qualche secondo faceva ripartire il video da un altro
    /// punto. Quei valori ora vengono ignorati.
    @State private var lastRelease = Date.distantPast
    /// Punto lasciato in sospeso dalla rete di sicurezza: se poi arriva il
    /// rilascio vero, la ricerca parte da lì.
    @State private var orphanTarget: TimeInterval?

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
                    if !isEditing {
                        // Valore arrivato a ridosso del rilascio: già applicato, si ignora.
                        guard !justReleased else { return }
                        beginScrub()
                    }
                    scrubTime = time
                    if let source = thumbnailSource {
                        // Tempo reale: si sposta SOLO il player nascosto dell'anteprima.
                        thumbnails.previewEngine.scrub(url: source.url, userAgent: source.userAgent, to: time)
                    }
                    armReleaseWatchdog()
                }
            ),
            in: 0...max(duration, 1),
            onEditingChanged: { editing in
                if editing {
                    // Su iOS 26 lo Slider può segnalare un nuovo "inizio" subito dopo il
                    // rilascio senza mai chiuderlo: riapriva l'anteprima, che restava a
                    // schermo, e dopo qualche secondo il video ripartiva da un altro punto.
                    if !isEditing, !justReleased { beginScrub() }
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
            thumbnails.previewEngine.endSession()
            onScrubbingChanged(false)
        }
    }

    // MARK: Inizio / fine trascinamento

    private func beginScrub() {
        orphanTarget = nil
        isEditing = true
        scrubTime = currentTime
        if let source = thumbnailSource, duration > 0 {
            // Subito il fotogramma a schermo; intanto il player nascosto dell'anteprima
            // (aperto solo da qui, al primo trascinamento) va sul punto scelto.
            thumbnails.previewEngine.beginSession()
            if let currentFrame {
                Task { @MainActor in
                    if let frame = await currentFrame(), isEditing { thumbnails.showLive(frame) }
                }
            }
            thumbnails.previewEngine.scrub(url: source.url, userAgent: source.userAgent, to: currentTime)
        }
        onScrubbingChanged(true)
        armReleaseWatchdog()
    }

    /// Rilascio: seek al punto scelto, anteprima e tempo spariscono subito e
    /// riparte il timer che nasconde i controlli (`onScrubbingChanged(false)`).
    private func finishScrub() {
        releaseWatchdog?.cancel()
        releaseWatchdog = nil
        guard isEditing else {
            if let orphan = orphanTarget {
                orphanTarget = nil
                onSeek(orphan)
            }
            return
        }
        orphanTarget = nil
        let target = scrubTime
        lastRelease = Date()
        isEditing = false
        scrubTime = nil
        thumbnails.finishRequests()
        thumbnails.previewEngine.endSession()
        if let target { onSeek(target) }
        onScrubbingChanged(false)
    }

    /// Subito dopo un rilascio (1,5 s): segnali e valori dello Slider ignorati.
    private var justReleased: Bool {
        Date().timeIntervalSince(lastRelease) < 1.5
    }

    private func armReleaseWatchdog() {
        releaseWatchdog?.cancel()
        releaseWatchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Metrics.releaseWatchdogNanoseconds)
            guard !Task.isCancelled else { return }
            // Rete di sicurezza: chiude anteprima e tempo SENZA spostare il video
            // (la ricerca vera parte solo dal rilascio).
            closeWithoutSeeking()
        }
    }

    private func closeWithoutSeeking() {
        releaseWatchdog?.cancel()
        releaseWatchdog = nil
        guard isEditing else { return }
        orphanTarget = scrubTime
        isEditing = false
        scrubTime = nil
        thumbnails.finishRequests()
        thumbnails.previewEngine.endSession()
        onScrubbingChanged(false)
    }

    // MARK: Anteprima

    private func preview(time: TimeInterval) -> some View {
        VStack(spacing: Metrics.previewSpacing) {
            if thumbnailSource != nil {
                ZStack {
                    Color.black
                    // Sotto: il fotogramma a schermo all'inizio del trascinamento.
                    if let image = thumbnails.image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                    // Sopra: il player nascosto che segue il dito in tempo reale.
                    PlayerScrubPreviewSurface(engine: thumbnails.previewEngine)
                }
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

// MARK: - Fotogramma attuale per la timeline

extension KSPlaybackController {
    /// Fotogramma che il player sta mostrando adesso (già decodificato,
    /// nessuna rete): prima anteprima istantanea della timeline.
    func timelineCurrentFrame() async -> CGImage? {
        await layer.player.thumbnailImageAtCurrentTime()
    }
}

// MARK: - Player nascosto dell'anteprima (iOS)

/// Secondo player KSPlayer MUTO che legge lo stesso flusso e si sposta
/// mentre si trascina la barra: si vede solo nella card dell'anteprima, il
/// video principale dietro non si muove fino al rilascio. Una ricerca alla
/// volta: finita quella, parte subito l'ultimo punto richiesto. Aperto al
/// primo trascinamento, riusato per i successivi; chiuso (connessione
/// compresa) 30 s dopo l'ultimo trascinamento, cambiando contenuto o
/// uscendo dal player.
@MainActor
final class PlayerScrubPreviewEngine: NSObject, ObservableObject, KSPlayerLayerDelegate {
    /// Vero quando la card mostra un fotogramma del punto scelto.
    @Published private(set) var hasFrame = false

    let container: UIView = {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.clipsToBounds = true
        return view
    }()

    private var layer: KSPlayerLayer?
    private weak var playerView: UIView?
    private var key: String?
    private var seekInFlight = false
    private var pending: TimeInterval?
    private var idleTeardown: Task<Void, Never>?

    func beginSession() {
        idleTeardown?.cancel()
        idleTeardown = nil
        // Mai un fotogramma vecchio: la card mostra il fotogramma a schermo
        // finché il player dell'anteprima non è sul nuovo punto.
        hasFrame = false
    }

    func scrub(url: URL, userAgent: String, to time: TimeInterval) {
        let target = max(0, time)
        if url.absoluteString != key {
            teardown()
            key = url.absoluteString
            start(url: url, userAgent: userAgent, at: target)
            return
        }
        pending = target
        pump()
    }

    func endSession() {
        pending = nil
        layer?.pause()
        idleTeardown?.cancel()
        idleTeardown = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            self?.teardown()
        }
    }

    func teardown() {
        idleTeardown?.cancel()
        idleTeardown = nil
        if let old = layer {
            old.delegate = nil
            old.pause()
            old.player.shutdown()
        }
        layer = nil
        playerView?.removeFromSuperview()
        playerView = nil
        key = nil
        seekInFlight = false
        pending = nil
        hasFrame = false
    }

    private func start(url: URL, userAgent: String, at time: TimeInterval) {
        let options = KSOptions()
        options.userAgent = userAgent
        options.registerRemoteControll = false
        options.canStartPictureInPictureAutomaticallyFromInline = false
        options.isAccurateSeek = false
        if time > 0 { options.startPlayTime = time }
        if url.scheme == "http" || url.scheme == "https" {
            options.formatContextOptions["user_agent"] = userAgent
            options.formatContextOptions["reconnect"] = 1
            options.formatContextOptions["reconnect_streamed"] = 1
            options.formatContextOptions["reconnect_delay_max"] = 2
            options.formatContextOptions["timeout"] = 15_000_000
            options.formatContextOptions["rw_timeout"] = 15_000_000
            // Stessa connessione HTTP per tutte le ricerche dell'anteprima.
            options.formatContextOptions["multiple_requests"] = 1
        }

        let newLayer = KSPlayerLayer(url: url, isAutoPlay: true, options: options, delegate: nil)
        newLayer.delegate = self
        newLayer.player.isMuted = true
        newLayer.player.contentMode = .scaleAspectFill
        layer = newLayer

        if let view = newLayer.player.view {
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
            playerView = view
        }
        newLayer.play()
    }

    private func pump() {
        guard let layer, layer.player.isReadyToPlay, !seekInFlight, let time = pending else { return }
        pending = nil
        seekInFlight = true
        // In riproduzione (muta) il nuovo fotogramma compare subito dopo la ricerca.
        layer.seek(time: time, autoPlay: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.seekInFlight = false
                // Il tempo di disegnare il primo fotogramma dopo la ricerca.
                try? await Task.sleep(nanoseconds: 80_000_000)
                if self.layer != nil, self.key != nil { self.hasFrame = true }
                self.pump()
            }
        }
    }

    // MARK: KSPlayerLayerDelegate

    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        guard layer === self.layer else { return }
        layer.player.isMuted = true
        if state == .readyToPlay || state == .bufferFinished {
            hasFrame = true
            pump()
        }
    }

    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {}

    func player(layer: KSPlayerLayer, finish error: Error?) {
        guard layer === self.layer else { return }
        hasFrame = false
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {}
}

/// Superficie del player dell'anteprima dentro la card: trasparente finché
/// non c'è un fotogramma del punto scelto (sotto resta quello iniziale).
private struct PlayerScrubPreviewSurface: View {
    @ObservedObject var engine: PlayerScrubPreviewEngine

    var body: some View {
        PlayerScrubPreviewContainer(container: engine.container)
            .opacity(engine.hasFrame ? 1 : 0)
            .allowsHitTesting(false)
    }
}

private struct PlayerScrubPreviewContainer: UIViewRepresentable {
    let container: UIView

    func makeUIView(context: Context) -> UIView {
        // Lo stesso contenitore viene riusato a ogni comparsa della card.
        container.removeFromSuperview()
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
