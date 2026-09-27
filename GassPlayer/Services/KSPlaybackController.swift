import Foundation
import AVFoundation
import MediaPlayer
import KSPlayer

/// Bridge SwiftUI-friendly per KSPlayerLayer, l'unico motore di
/// riproduzione dell'app. Configura esplicitamente AVFoundation come
/// motore primario e KSMEPlayer/FFmpeg come fallback universale.
///
/// `subtitleDelay` e `subtitleDisable` NON esistono nella versione di
/// KSPlayer compilata dal progetto: nessun riferimento a tali API è
/// presente in questo file.

enum VideoGravityMode: String, CaseIterable, Identifiable {
    case fit
    case fill
    case stretch

    var id: String { rawValue }

    var contentMode: UIView.ContentMode {
        switch self {
        case .fit: return .scaleAspectFit
        case .fill: return .scaleAspectFill
        case .stretch: return .scaleToFill
        }
    }

    var systemImage: String {
        switch self {
        case .fit: return "rectangle.arrowtriangle.2.inward"
        case .fill: return "arrow.up.left.and.arrow.down.right.rectangle"
        case .stretch: return "rectangle.expand.vertical"
        }
    }

    var label: String {
        switch self {
        case .fit: return "Adatta"
        case .fill: return "Riempi"
        case .stretch: return "Stira"
        }
    }

    var next: VideoGravityMode {
        let all = Self.allCases
        let idx = all.firstIndex(of: self) ?? 0
        return all[(idx + 1) % all.count]
    }
}

enum PanoramaMode: String, CaseIterable, Identifiable {
    case plane
    case vr
    case vrBox

    var id: String { rawValue }

    var displayMode: DisplayEnum {
        switch self {
        case .plane: return .plane
        case .vr: return .vr
        case .vrBox: return .vrBox
        }
    }

    var label: String {
        switch self {
        case .plane: return "Normale"
        case .vr: return "Panoramico 360° (VR)"
        case .vrBox: return "Panoramico 360° (VR Box)"
        }
    }

    var systemImage: String {
        switch self {
        case .plane: return "rectangle"
        case .vr: return "globe"
        case .vrBox: return "cube"
        }
    }
}

enum SeekFlagPreset: String, CaseIterable, Identifiable {
    case fast
    case byteAccurate
    case anyFrame
    case frameIndexed

    var id: String { rawValue }

    var flagValue: Int32 {
        switch self {
        case .fast: return 0
        case .byteAccurate: return 2
        case .anyFrame: return 4
        case .frameIndexed: return 8
        }
    }

    var label: String {
        switch self {
        case .fast: return "Rapida (predefinita)"
        case .byteAccurate: return "Accurata per byte"
        case .anyFrame: return "Qualsiasi fotogramma"
        case .frameIndexed: return "Indicizzata per fotogramma"
        }
    }
}

@MainActor
final class KSPlaybackController: NSObject, ObservableObject {

    struct PlaybackPreferences {
        // MARK: Buffer
        var preferredForwardBufferDuration: Double = 5
        var maxBufferDuration: Double = 30

        // MARK: Decodifica
        /// Abilita VideoToolbox nel motore FFmpeg/KSMEPlayer. Il motore
        /// AVFoundation usa comunque l'hardware Apple quando possibile.
        var hardwareDecode: Bool = true
        /// Mantiene il decode hardware fuori dal thread di rendering, così
        /// SwiftUI e i controlli del player restano fluidi durante zapping.
        var asynchronousDecompression: Bool = true
        var syncDecodeVideo: Bool = false
        var syncDecodeAudio: Bool = false
        var lowres: UInt8 = 0
        var videoDisable: Bool = false

        // MARK: Ricerca / sincronizzazione
        var isAccurateSeek: Bool = false
        var seekFlags: Int32 = 0
        var autoDeInterlace: Bool = false
        var videoDelay: Double = 0

        // MARK: Sottotitoli
        var autoSelectEmbedSubtitle: Bool = true
        var isSeekImageSubtitle: Bool = false

        // MARK: Rendering
        var videoGravity: VideoGravityMode = .fit
        var panoramaMode: PanoramaMode = .plane
        var autoRotate: Bool = true

        // MARK: Comportamento
        var videoAdaptable: Bool = true
        var isLoopPlay: Bool = false
        var isSecondOpen: Bool = true
        var isSeekedAutoPlay: Bool = true
        var startPlayTime: TimeInterval = 0
        var startPlayRate: Float = 1.0

        // MARK: Rete
        var userAgent: String? = "GassPlayer/1.0"
        var referer: String?
        var customHTTPHeaders: [String: String] = [:]
        var httpCacheEnabled: Bool = false
        var allowInsecureTLS: Bool = false
        var probesize: Int64?
        var maxAnalyzeDuration: Int64?

        // MARK: Filtri e opzioni FFmpeg
        var videoFilters: [String] = []
        var audioFilters: [String] = []
        var formatContextOptions: [String: String] = [:]
        var decoderOptions: [String: String] = [:]
        var avOptions: [String: String] = [:]
    }

    private static let builtInProbesize: Int64 = 10_000_000
    private static let builtInMaxAnalyzeDuration: Int64 = 10_000_000
    private static let maxOpenAttempts = 3
    private static let fallbackUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// Configurazione globale indispensabile: senza `secondPlayerType`, un
    /// flusso rifiutato da AVFoundation non arriva mai a KSMEPlayer. Il
    /// primo motore è nativo Apple (hardware/Metal quando supportato); il
    /// secondo usa FFmpeg e applica `KSOptions.hardwareDecode` per usare
    /// VideoToolbox quando il codec e il profilo lo consentono.
    private static let configurePlayerEngines: Void = {
        KSOptions.firstPlayerType = KSAVPlayer.self
        KSOptions.secondPlayerType = KSMEPlayer.self
    }()

    private static func selfReferer(for url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return "\(scheme)://\(host)/"
    }

    private static let genericFormatContextOptions: [String: String] = [
        "err_detect": "ignore_err",
        "avoid_negative_ts": "make_zero",
        "correct_ts_overflow": "1",
        "seek2any": "1"
    ]

    private static func networkFormatContextOptions(for url: URL, relaxTLSVerification: Bool) -> [String: String] {
        switch url.scheme?.lowercased() {
        case "http", "https":
            var options = [
                "reconnect": "1",
                "reconnect_at_eof": "1",
                "reconnect_streamed": "1",
                "reconnect_delay_max": "5",
                "rw_timeout": "15000000",
                "multiple_requests": "1",
                "http_persistent": "1"
            ]
            if relaxTLSVerification, url.scheme?.lowercased() == "https" {
                options["tls_verify"] = "0"
            }
            return options
        case "rtsp", "rtsps":
            var options = [
                "rtsp_transport": "tcp",
                "rtsp_flags": "prefer_tcp",
                "stimeout": "10000000"
            ]
            if relaxTLSVerification, url.scheme?.lowercased() == "rtsps" {
                options["tls_verify"] = "0"
            }
            return options
        default:
            return [:]
        }
    }

    @Published var state: KSPlayerState = .initialized
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var lastError: String?
    @Published var bufferingProgress: Int = 0
    @Published var isPipActive = false {
        didSet { layer.isPipActive = isPipActive }
    }

    @Published private(set) var layer: KSPlayerLayer
    @Published private(set) var preferences = PlaybackPreferences()

    private(set) var currentURL: URL
    private var title: String
    private var watchdogTask: Task<Void, Never>?
    private var hasEverStartedPlaying = false
    private var openAttemptCount = 0
    private var lastPublishedTime: TimeInterval = -1

    var isPlaying: Bool { state.isPlaying }
    var isBuffering: Bool { state == .preparing || state == .buffering }

    var supportsPictureInPicture: Bool {
        if #available(iOS 14.0, tvOS 14.0, *) {
            return layer.player.pipController != nil
        }
        return false
    }

    init(url: URL, title: String) {
        _ = Self.configurePlayerEngines
        self.currentURL = url
        self.title = title
        self.layer = Self.buildLayer(for: url, preferences: PlaybackPreferences())
        super.init()
        layer.delegate = self
        startWatchdog()
    }

    private static func buildLayer(
        for url: URL,
        preferences: PlaybackPreferences,
        userAgentOverride: String? = nil,
        refererOverride: String? = nil,
        relaxTLSVerification: Bool = false
    ) -> KSPlayerLayer {
        _ = configurePlayerEngines

        let options = KSOptions()
        options.preferredForwardBufferDuration = preferences.preferredForwardBufferDuration
        options.maxBufferDuration = preferences.maxBufferDuration

        // VideoToolbox/KSMEPlayer: questo è il punto effettivo in cui la
        // preferenza hardware viene trasferita a KSPlayer. Il valore va
        // impostato PRIMA di costruire KSPlayerLayer, perché la pipeline
        // di decode viene creata durante l'apertura del media.
        options.hardwareDecode = preferences.hardwareDecode
        options.asynchronousDecompression = preferences.asynchronousDecompression
        options.syncDecodeVideo = preferences.syncDecodeVideo
        options.syncDecodeAudio = preferences.syncDecodeAudio
        options.lowres = preferences.lowres
        options.videoDisable = preferences.videoDisable

        options.isAccurateSeek = preferences.isAccurateSeek
        options.seekFlags = preferences.seekFlags
        options.autoDeInterlace = preferences.autoDeInterlace
        options.videoDelay = preferences.videoDelay

        options.autoSelectEmbedSubtitle = preferences.autoSelectEmbedSubtitle
        options.isSeekImageSubtitle = preferences.isSeekImageSubtitle

        options.display = preferences.panoramaMode.displayMode
        options.autoRotate = preferences.autoRotate

        options.videoAdaptable = preferences.videoAdaptable
        options.isLoopPlay = preferences.isLoopPlay
        options.isSecondOpen = preferences.isSecondOpen
        options.isSeekedAutoPlay = preferences.isSeekedAutoPlay
        options.startPlayTime = preferences.startPlayTime
        options.startPlayRate = preferences.startPlayRate

        options.userAgent = userAgentOverride ?? preferences.userAgent
        options.referer = refererOverride ?? preferences.referer
        if !preferences.customHTTPHeaders.isEmpty {
            options.appendHeader(preferences.customHTTPHeaders)
        }

        options.cache = preferences.httpCacheEnabled
        options.probesize = preferences.probesize ?? builtInProbesize
        options.maxAnalyzeDuration = preferences.maxAnalyzeDuration ?? builtInMaxAnalyzeDuration
        options.videoFilters = preferences.videoFilters
        options.audioFilters = preferences.audioFilters

        var effectiveFormatContextOptions = genericFormatContextOptions
        effectiveFormatContextOptions.merge(
            networkFormatContextOptions(
                for: url,
                relaxTLSVerification: relaxTLSVerification || preferences.allowInsecureTLS
            )
        ) { _, new in new }
        effectiveFormatContextOptions.merge(preferences.formatContextOptions) { _, new in new }
        options.formatContextOptions.merge(effectiveFormatContextOptions.mapValues { $0 as Any }) { _, new in new }

        if !preferences.decoderOptions.isEmpty {
            options.decoderOptions.merge(preferences.decoderOptions.mapValues { $0 as Any }) { _, new in new }
        }
        if !preferences.avOptions.isEmpty {
            options.avOptions.merge(preferences.avOptions.mapValues { $0 as Any }) { _, new in new }
        }

        options.registerRemoteControll = true
        options.canStartPictureInPictureAutomaticallyFromInline = true

        let layer = KSPlayerLayer(url: url, isAutoPlay: true, options: options, delegate: nil)
        layer.player.contentMode = preferences.videoGravity.contentMode
        return layer
    }

    func load(url: URL, title: String) {
        layer.delegate = nil
        layer.pause()

        self.currentURL = url
        self.title = title
        lastError = nil
        currentTime = 0
        duration = 0
        lastPublishedTime = -1
        hasEverStartedPlaying = false
        bufferingProgress = 0
        openAttemptCount = 0
        state = .initialized

        let newLayer = Self.buildLayer(for: url, preferences: preferences)
        layer = newLayer
        layer.delegate = self
        layer.play()
        startWatchdog()
    }

    func reload() {
        load(url: currentURL, title: title)
    }

    private func retryWithFallbackSettings(attempt: Int) {
        layer.delegate = nil
        layer.pause()

        currentTime = 0
        duration = 0
        lastPublishedTime = -1
        hasEverStartedPlaying = false
        bufferingProgress = 0
        state = .initialized

        let referer = preferences.referer ?? Self.selfReferer(for: currentURL)
        let newLayer: KSPlayerLayer

        if attempt <= 1 {
            newLayer = Self.buildLayer(
                for: currentURL,
                preferences: preferences,
                userAgentOverride: Self.fallbackUserAgent,
                refererOverride: referer,
                relaxTLSVerification: true
            )
        } else {
            // Fallback finale: software FFmpeg esplicito. Non modifichiamo
            // `preferences.hardwareDecode`, così il prossimo canale tenta di
            // nuovo hardware come richiesto dall'utente.
            var fallbackPreferences = preferences
            fallbackPreferences.hardwareDecode = false
            fallbackPreferences.asynchronousDecompression = false
            fallbackPreferences.isSecondOpen = false
            fallbackPreferences.probesize = max(preferences.probesize ?? Self.builtInProbesize, 50_000_000)
            fallbackPreferences.maxAnalyzeDuration = max(preferences.maxAnalyzeDuration ?? Self.builtInMaxAnalyzeDuration, 30_000_000)
            newLayer = Self.buildLayer(
                for: currentURL,
                preferences: fallbackPreferences,
                userAgentOverride: Self.fallbackUserAgent,
                refererOverride: referer,
                relaxTLSVerification: true
            )
        }

        layer = newLayer
        layer.delegate = self
        layer.play()
        startWatchdog()
    }

    private func handleOpenFailure(message: String) {
        guard openAttemptCount < Self.maxOpenAttempts - 1 else {
            lastError = message
            return
        }

        openAttemptCount += 1
        DebugLogger.logAsync(
            .warning,
            "KSPlaybackController: apertura fallita (\(message)); retry \(openAttemptCount + 1)/\(Self.maxOpenAttempts)"
        )
        retryWithFallbackSettings(attempt: openAttemptCount)
    }

    func togglePlayPause() {
        if isPlaying {
            layer.pause()
        } else {
            layer.play()
        }
    }

    func seek(to time: TimeInterval) {
        layer.seek(time: time, autoPlay: true) { _ in }
    }

    func skip(by interval: TimeInterval) {
        guard duration > 0 else { return }
        let target = max(0, min(layer.player.currentPlaybackTime + interval, duration))
        seek(to: target)
    }

    func setPlaybackRate(_ rate: Float) {
        layer.player.playbackRate = rate
    }

    func resetAttempts() {
        lastError = nil
        hasEverStartedPlaying = false
        openAttemptCount = 0
        layer.play()
        startWatchdog()
    }

    var audioTracks: [MediaPlayerTrack] { layer.player.tracks(mediaType: .audio) }
    var subtitleTracks: [MediaPlayerTrack] { layer.player.tracks(mediaType: .subtitle) }
    var videoTracks: [MediaPlayerTrack] { layer.player.tracks(mediaType: .video) }

    func select(track: MediaPlayerTrack) {
        layer.player.select(track: track)
    }

    // MARK: - Buffer (live)

    func setPreferredForwardBufferDuration(_ value: Double) {
        preferences.preferredForwardBufferDuration = value
        layer.options.preferredForwardBufferDuration = value
    }

    func setMaxBufferDuration(_ value: Double) {
        preferences.maxBufferDuration = value
        layer.options.maxBufferDuration = value
    }

    // MARK: - Ricerca e rendering (live)

    func setVideoDelay(_ value: Double) {
        preferences.videoDelay = value
        layer.options.videoDelay = value
    }

    func setAccurateSeek(_ enabled: Bool) {
        preferences.isAccurateSeek = enabled
        layer.options.isAccurateSeek = enabled
    }

    func setSeekFlags(_ preset: SeekFlagPreset) {
        preferences.seekFlags = preset.flagValue
        layer.options.seekFlags = preset.flagValue
    }

    func setSeekedAutoPlay(_ enabled: Bool) {
        preferences.isSeekedAutoPlay = enabled
        layer.options.isSeekedAutoPlay = enabled
    }

    func setVideoGravity(_ mode: VideoGravityMode) {
        preferences.videoGravity = mode
        layer.player.contentMode = mode.contentMode
    }

    func setAutoRotate(_ enabled: Bool) {
        preferences.autoRotate = enabled
        layer.options.autoRotate = enabled
    }

    func setVideoAdaptable(_ enabled: Bool) {
        preferences.videoAdaptable = enabled
        layer.options.videoAdaptable = enabled
    }

    func setLoopPlay(_ enabled: Bool) {
        preferences.isLoopPlay = enabled
        layer.options.isLoopPlay = enabled
    }

    // MARK: - Decodifica (rebuild obbligatorio)

    /// Applica in modo reale la scelta hardware/software: il layer viene
    /// ricreato perché KSPlayer costruisce decoder e sessione VideoToolbox
    /// solo in fase di apertura. Modificare la proprietà sul layer attuale
    /// non sarebbe sufficiente e produrrebbe un toggle UI non funzionante.
    func setHardwareDecode(_ enabled: Bool) {
        guard preferences.hardwareDecode != enabled else { return }
        preferences.hardwareDecode = enabled
        reload()
    }

    func setAutoDeInterlace(_ enabled: Bool) {
        preferences.autoDeInterlace = enabled
        reload()
    }

    func setAsynchronousDecompression(_ enabled: Bool) {
        preferences.asynchronousDecompression = enabled
        reload()
    }

    func setSyncDecodeVideo(_ enabled: Bool) {
        preferences.syncDecodeVideo = enabled
        reload()
    }

    func setSyncDecodeAudio(_ enabled: Bool) {
        preferences.syncDecodeAudio = enabled
        reload()
    }

    func setLowres(_ value: UInt8) {
        preferences.lowres = value
        reload()
    }

    func setVideoDisabled(_ disabled: Bool) {
        preferences.videoDisable = disabled
        reload()
    }

    func setPanoramaMode(_ mode: PanoramaMode) {
        preferences.panoramaMode = mode
        reload()
    }

    func setSecondOpen(_ enabled: Bool) {
        preferences.isSecondOpen = enabled
        reload()
    }

    func setStartPlayTime(_ value: TimeInterval) {
        preferences.startPlayTime = value
    }

    func setStartPlayRate(_ value: Float) {
        preferences.startPlayRate = value
    }

    // MARK: - Sottotitoli (rebuild)

    func setAutoSelectEmbedSubtitle(_ enabled: Bool) {
        preferences.autoSelectEmbedSubtitle = enabled
        reload()
    }

    func setSeekImageSubtitle(_ enabled: Bool) {
        preferences.isSeekImageSubtitle = enabled
        reload()
    }

    // MARK: - Rete (rebuild)

    func setUserAgent(_ value: String?) {
        preferences.userAgent = value
        reload()
    }

    func setReferer(_ value: String?) {
        preferences.referer = value
        reload()
    }

    func setCustomHeader(key: String, value: String) {
        guard !key.isEmpty else { return }
        preferences.customHTTPHeaders[key] = value
        reload()
    }

    func removeCustomHeader(key: String) {
        preferences.customHTTPHeaders.removeValue(forKey: key)
        reload()
    }

    func setHTTPCacheEnabled(_ enabled: Bool) {
        preferences.httpCacheEnabled = enabled
        reload()
    }

    func setAllowInsecureTLS(_ enabled: Bool) {
        preferences.allowInsecureTLS = enabled
        reload()
    }

    func setProbesize(_ value: Int64?) {
        preferences.probesize = value
        reload()
    }

    func setMaxAnalyzeDuration(_ value: Int64?) {
        preferences.maxAnalyzeDuration = value
        reload()
    }

    // MARK: - Filtri FFmpeg (rebuild)

    func addVideoFilter(_ filter: String) {
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        preferences.videoFilters.append(trimmed)
        reload()
    }

    func removeVideoFilter(at index: Int) {
        guard preferences.videoFilters.indices.contains(index) else { return }
        preferences.videoFilters.remove(at: index)
        reload()
    }

    func clearVideoFilters() {
        guard !preferences.videoFilters.isEmpty else { return }
        preferences.videoFilters.removeAll()
        reload()
    }

    func addAudioFilter(_ filter: String) {
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        preferences.audioFilters.append(trimmed)
        reload()
    }

    func removeAudioFilter(at index: Int) {
        guard preferences.audioFilters.indices.contains(index) else { return }
        preferences.audioFilters.remove(at: index)
        reload()
    }

    func clearAudioFilters() {
        guard !preferences.audioFilters.isEmpty else { return }
        preferences.audioFilters.removeAll()
        reload()
    }

    // MARK: - Opzioni FFmpeg grezze (rebuild)

    func setFormatContextOption(key: String, value: String) {
        guard !key.isEmpty else { return }
        preferences.formatContextOptions[key] = value
        reload()
    }

    func removeFormatContextOption(key: String) {
        preferences.formatContextOptions.removeValue(forKey: key)
        reload()
    }

    func setDecoderOption(key: String, value: String) {
        guard !key.isEmpty else { return }
        preferences.decoderOptions[key] = value
        reload()
    }

    func removeDecoderOption(key: String) {
        preferences.decoderOptions.removeValue(forKey: key)
        reload()
    }

    func setAVOption(key: String, value: String) {
        guard !key.isEmpty else { return }
        preferences.avOptions[key] = value
        reload()
    }

    func removeAVOption(key: String) {
        preferences.avOptions.removeValue(forKey: key)
        reload()
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard !self.hasEverStartedPlaying, self.lastError == nil else { return }
            DebugLogger.logAsync(.warning, "KSPlaybackController: nessuna riproduzione avviata dopo 7s (stato=\(self.state)), forzo ciclo pausa->play")
            self.layer.pause()
            self.layer.play()
        }
    }

    deinit {
        watchdogTask?.cancel()
    }
}

extension KSPlaybackController: KSPlayerLayerDelegate {
    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        // Gli eventi di un layer appena sostituito non devono più
        // modificare lo stato della UI o avviare retry sul nuovo stream.
        guard layer === self.layer else { return }

        self.state = state
        switch state {
        case .bufferFinished, .buffering:
            hasEverStartedPlaying = true
            watchdogTask?.cancel()
        case .readyToPlay:
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] = title.isEmpty ? "GassPlayer" : title
        case .error:
            watchdogTask?.cancel()
            handleOpenFailure(message: "Impossibile riprodurre il flusso. Il server potrebbe non essere raggiungibile o il formato non e' supportato.")
        default:
            break
        }
    }

    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        guard layer === self.layer else { return }
        let durationChanged = totalTime != duration
        guard durationChanged || abs(currentTime - lastPublishedTime) >= 0.2 else { return }
        lastPublishedTime = currentTime
        self.currentTime = currentTime
        self.duration = totalTime
    }

    func player(layer: KSPlayerLayer, finish error: Error?) {
        guard layer === self.layer else { return }
        if let error {
            DebugLogger.logAsync(.error, "KSPlaybackController: riproduzione terminata con errore: \(error.localizedDescription)")
            handleOpenFailure(message: error.localizedDescription)
        }
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {
        guard layer === self.layer else { return }
        DebugLogger.logAsync(.info, "KSPlaybackController: buffer #\(bufferedCount) pronto in \(consumeTime)s")
    }
}
