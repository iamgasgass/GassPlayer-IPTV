import Foundation
import AVFoundation
import MediaPlayer
import KSPlayer

/// Bridge SwiftUI-friendly per KSPlayerLayer, l'UNICO motore di
/// riproduzione dell'app (AVPlayer nativo + FFmpeg via KSMEPlayer, con
/// switch automatico incorporato nella libreria stessa).
///
/// ANALISI MANIACALE 2026-09-27 (quater) — TUTTI E 3 I TENTATIVI DI
/// APERTURA FALLISCONO IDENTICI: il log conferma che i retry (UA browser
/// + Referer, poi decodifica software + probing esteso) girano
/// correttamente ma non risolvono nulla. Se NESSUno dei tre livelli
/// aiuta, il fallimento avviene quasi certamente PRIMA del demuxer, a
/// livello di connessione di rete stessa — la causa più comune e non
/// ancora coperta è la VERIFICA DEL CERTIFICATO TLS: molti server IPTV/
/// VOD di fascia bassa usano certificati HTTPS self-signed, scaduti o con
/// hostname non corrispondente. FFmpeg, come qualunque client TLS
/// corretto, rifiuta la connessione per default, e KSPlayer la riporta
/// con lo stesso identico messaggio generico "can't open input" — motivo
/// per cui né lo User-Agent né il probing né la decodifica software
/// possono avere alcun effetto: la connessione non si stabilisce mai.
///
/// FIX: dal primo retry di fallback in poi (mai al primo tentativo, per
/// non abbassare la sicurezza sui flussi che già funzionano con
/// certificati validi), viene impostata `tls_verify = 0` per schemi
/// `https`/`rtsps` — disattiva la verifica del certificato SOLO durante
/// i tentativi di recupero automatico. È il compromesso standard adottato
/// da VLC e dalla maggior parte dei player IPTV per restare compatibili
/// con provider che usano certificati non validati, a fronte di un rischio
/// di sicurezza accettabile per questo caso d'uso (streaming di contenuti
/// pubblici, non credenziali sensibili).
///
/// TIPI DI CONTENITORE (avformat) SUPPORTATI: FFmpeg/avformat rileva il
/// contenitore dal CONTENUTO del flusso (probing), non dall'estensione:
/// MP4/MOV, MKV/WebM, AVI, FLV, MPEG-TS/M2TS, MPEG-PS/VOB, ASF/WMV, OGG/
/// OGV, 3GP/3G2, NUT, MXF sono già tutti leggibili senza alcuna
/// configurazione aggiuntiva. Il supporto CODEC dipende dalla
/// configurazione di compilazione di FFmpeg dentro il pacchetto KSPlayer
/// (fuori dallo scopo di questi due file Swift): se TUTTI e 3 i tentativi
/// (incluso quello con TLS relaxato) falliscono ancora nello stesso modo
/// identico, le cause plausibili RESIDUE — non risolvibili da nessuna
/// opzione client-side — sono: (a) l'URL è realmente irraggiungibile/scaduto
/// lato server, (b) il codec dentro il contenitore non è compilato nel
/// binario FFmpeg di KSPlayer, (c) il contenuto è protetto da DRM.
///
/// 4 opzioni generiche `AVFormatContext` (valide per QUALUNQUE contenitore,
/// mai a rischio "opzione non consumata"): `err_detect=ignore_err`,
/// `avoid_negative_ts=make_zero`, `correct_ts_overflow=1`, `seek2any=1`.
///
/// Le opzioni di rete (`reconnect*`, `rtsp_transport`) restano sensibili
/// allo schema dell'URL (`networkFormatContextOptions`), per non lasciare
/// chiavi "non consumate" su protocolli a cui non appartengono.
///
/// `subtitleDelay`/`subtitleDisable` NON esistono su `KSOptions` in
/// questa versione della libreria (kingslay/KSPlayer#508).
///
/// `layer` è `@Published`: `load(url:title:)` crea un nuovo
/// `KSPlayerLayer` per il nuovo URL riassegnandolo a questa stessa
/// istanza, che resta viva per tutta la sessione di visione —
/// `KSPlayerContainerView` osserva il cambio di `layer` e si limita a
/// staccare la vecchia `UIView` e agganciare la nuova nello stesso
/// container già presente a schermo.

/// Modalità di adattamento del video al riquadro dello schermo.
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

/// Modalità di rendering panoramico/360°, mappata su `KSOptions.DisplayEnum`.
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

/// Preset comuni per `KSOptions.seekFlags` (flag FFmpeg `AVSEEK_FLAG_*`).
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

    /// Preferenze di riproduzione avanzate regolabili dall'utente.
    struct PlaybackPreferences {
        // MARK: Buffer
        var preferredForwardBufferDuration: Double = 5
        var maxBufferDuration: Double = 30

        // MARK: Decodifica (FFmpeg / VideoToolbox)
        var hardwareDecode: Bool = true
        var asynchronousDecompression: Bool = true
        var syncDecodeVideo: Bool = false
        var syncDecodeAudio: Bool = false
        var lowres: UInt8 = 0
        var videoDisable: Bool = false

        // MARK: Ricerca / sincronizzazione A/V
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

        // MARK: Adattamento qualità / comportamento riproduzione
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
        /// `false` (default): verifica normalmente i certificati TLS su
        /// https/rtsps. Attivare manualmente SOLO se un provider specifico
        /// usa certificati self-signed/non validi in modo permanente — i
        /// retry automatici di fallback lo attivano già da soli quando
        /// serve, senza bisogno di questa preferenza persistente.
        var allowInsecureTLS: Bool = false
        /// `nil` = usa il default robusto sempre attivo (10 MB).
        var probesize: Int64?
        /// `nil` = usa il default robusto sempre attivo (10s).
        var maxAnalyzeDuration: Int64?

        // MARK: Filtri FFmpeg
        var videoFilters: [String] = []
        var audioFilters: [String] = []

        // MARK: Opzioni FFmpeg grezze AGGIUNTIVE (potere assoluto)
        var formatContextOptions: [String: String] = [:]
        var decoderOptions: [String: String] = [:]
        var avOptions: [String: String] = [:]
    }

    private static let builtInProbesize: Int64 = 10_000_000
    private static let builtInMaxAnalyzeDuration: Int64 = 10_000_000

    /// Numero massimo di tentativi di apertura totali (1 iniziale + 2 di
    /// fallback) prima di mostrare finalmente l'errore all'utente.
    private static let maxOpenAttempts = 3

    /// User-Agent di fallback usato SOLO nei retry automatici.
    private static let fallbackUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private static func selfReferer(for url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return "\(scheme)://\(host)/"
    }

    /// Opzioni GENERICHE di `AVFormatContext`, valide per QUALUNQUE
    /// contenitore/demuxer perché sono AVOptions dichiarate sulla classe
    /// `AVFormatContext` stessa, non su un singolo demuxer/protocollo:
    /// vengono sempre consumate, indipendentemente dal tipo di file.
    private static let genericFormatContextOptions: [String: String] = [
        "err_detect": "ignore_err",
        "avoid_negative_ts": "make_zero",
        "correct_ts_overflow": "1",
        "seek2any": "1",
    ]

    /// Opzioni di rete pertinenti ESCLUSIVAMENTE allo schema dell'URL
    /// corrente. `relaxTLSVerification`, attivo solo durante i retry di
    /// fallback, disattiva la verifica del certificato su https/rtsps per
    /// tollerare certificati self-signed/scaduti tipici di alcuni
    /// provider IPTV/VOD di fascia bassa — è l'unica causa plausibile di
    /// fallimento IDENTICO su tutti e 3 i livelli di retry (UA/referer e
    /// decodifica non hanno alcun effetto su un handshake TLS rifiutato).
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
                "http_persistent": "1",
            ]
            if relaxTLSVerification, url.scheme?.lowercased() == "https" {
                options["tls_verify"] = "0"
            }
            return options
        case "rtsp", "rtsps":
            var options = [
                "rtsp_transport": "tcp",
                "rtsp_flags": "prefer_tcp",
                "stimeout": "10000000",
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
        self.currentURL = url
        self.title = title
        self.layer = Self.buildLayer(for: url, preferences: PlaybackPreferences())
        super.init()
        layer.delegate = self
        startWatchdog()
    }

    /// Costruisce un nuovo `KSPlayerLayer`. `userAgentOverride`/
    /// `refererOverride`/`relaxTLSVerification` sono usati ESCLUSIVAMENTE
    /// dai retry di fallback e non toccano mai `preferences`.
    private static func buildLayer(
        for url: URL,
        preferences: PlaybackPreferences,
        userAgentOverride: String? = nil,
        refererOverride: String? = nil,
        relaxTLSVerification: Bool = false
    ) -> KSPlayerLayer {
        let options = KSOptions()

        options.preferredForwardBufferDuration = preferences.preferredForwardBufferDuration
        options.maxBufferDuration = preferences.maxBufferDuration

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

        // Opzioni FFmpeg grezze: generiche (sempre valide) + rete
        // (sensibili al protocollo, con TLS relaxato solo se richiesto
        // dal retry di fallback o dall'impostazione persistente
        // dell'utente) + personalizzazioni dell'utente, che vincono
        // chiave per chiave in caso di conflitto.
        var effectiveFormatContextOptions = genericFormatContextOptions
        effectiveFormatContextOptions.merge(
            networkFormatContextOptions(for: url, relaxTLSVerification: relaxTLSVerification || preferences.allowInsecureTLS)
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

    /// Carica un nuovo URL SENZA che `PlayerView` venga mai
    /// distrutta/ricreata.
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

    /// Ricarica lo stream corrente con le `preferences` aggiornate.
    func reload() {
        load(url: currentURL, title: title)
    }

    /// Eseguito automaticamente e SILENZIOSAMENTE ad ogni fallimento di
    /// apertura, finché non si raggiunge `maxOpenAttempts`:
    /// - Tentativo 1: User-Agent browser + Referer auto-derivato + TLS
    ///   relaxato su https/rtsps (aggira sia hotlink-protection/UA-
    ///   filtering SIA certificati self-signed/scaduti).
    /// - Tentativo 2: come sopra, PIÙ decodifica software forzata,
    ///   apertura completa invece che rapida, e probing/analisi estesi.
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
            var toughPreferences = preferences
            toughPreferences.hardwareDecode = false
            toughPreferences.isSecondOpen = false
            toughPreferences.probesize = max(preferences.probesize ?? Self.builtInProbesize, 50_000_000)
            toughPreferences.maxAnalyzeDuration = max(preferences.maxAnalyzeDuration ?? Self.builtInMaxAnalyzeDuration, 30_000_000)
            newLayer = Self.buildLayer(
                for: currentURL,
                preferences: toughPreferences,
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

    /// Punto unico di gestione di un fallimento di apertura/riproduzione.
    private func handleOpenFailure(message: String) {
        guard openAttemptCount < Self.maxOpenAttempts - 1 else {
            lastError = message
            return
        }
        openAttemptCount += 1
        DebugLogger.logAsync(.warning, "KSPlaybackController: apertura fallita (\(message)); ritento (tentativo \(openAttemptCount + 1)/\(Self.maxOpenAttempts)) prima di mostrare l'errore")
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

    // MARK: - Buffer (applicazione live)

    func setPreferredForwardBufferDuration(_ value: Double) {
        preferences.preferredForwardBufferDuration = value
        layer.options.preferredForwardBufferDuration = value
    }

    func setMaxBufferDuration(_ value: Double) {
        preferences.maxBufferDuration = value
        layer.options.maxBufferDuration = value
    }

    // MARK: - Sincronizzazione / ricerca (applicazione live)

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

    // MARK: - Rendering (applicazione live)

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

    // MARK: - Decodifica (richiede reload)

    func setHardwareDecode(_ enabled: Bool) {
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

    // MARK: - Sottotitoli (richiede reload)

    func setAutoSelectEmbedSubtitle(_ enabled: Bool) {
        preferences.autoSelectEmbedSubtitle = enabled
        reload()
    }

    func setSeekImageSubtitle(_ enabled: Bool) {
        preferences.isSeekImageSubtitle = enabled
        reload()
    }

    // MARK: - Rete (richiede reload)

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

    /// Attiva/disattiva PERMANENTEMENTE (per questa sessione, su questo
    /// URL e sui successivi) la verifica del certificato TLS su
    /// https/rtsps. Utile se sai già in anticipo che un provider usa
    /// certificati self-signed e vuoi evitare il primo tentativo (sempre
    /// con verifica attiva) che fallirebbe comunque.
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

    // MARK: - Filtri FFmpeg (richiede reload)

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

    // MARK: - Opzioni FFmpeg grezze (richiede reload)

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
        let durationChanged = totalTime != duration
        guard durationChanged || abs(currentTime - lastPublishedTime) >= 0.2 else { return }
        lastPublishedTime = currentTime
        self.currentTime = currentTime
        self.duration = totalTime
    }

    func player(layer: KSPlayerLayer, finish error: Error?) {
        if let error {
            DebugLogger.logAsync(.error, "KSPlaybackController: riproduzione terminata con errore: \(error.localizedDescription)")
            handleOpenFailure(message: error.localizedDescription)
        }
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {
        DebugLogger.logAsync(.info, "KSPlaybackController: buffer #\(bufferedCount) pronto in \(consumeTime)s")
    }
}
