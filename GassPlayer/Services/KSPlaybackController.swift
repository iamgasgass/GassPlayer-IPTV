import Foundation
import AVFoundation
import MediaPlayer
import KSPlayer

/// Bridge SwiftUI-friendly per KSPlayerLayer, l'UNICO motore di
/// riproduzione dell'app (AVPlayer nativo + FFmpeg via KSMEPlayer, con
/// switch automatico incorporato nella libreria stessa — vedi
/// KSPlayerLayer.finish(player:error:), che ritenta con
/// KSOptions.secondPlayerType su qualunque errore prima di arrendersi).
///
/// TIPI DI CONTENITORE (avformat) SUPPORTATI — 2026-09-27:
/// FFmpeg/avformat (il motore usato da KSMEPlayer) rileva il contenitore
/// dal CONTENUTO del flusso (probing), non dall'estensione dell'URL:
/// nessun codice aggiuntivo è necessario per "abilitare" un formato,
/// perché tutti i demuxer sono già registrati globalmente dentro il
/// binario FFmpeg compilato con KSPlayer. Sono quindi già leggibili senza
/// alcuna configurazione: MP4/MOV/M4V/QuickTime, Matroska/MKV, WebM, AVI,
/// FLV, MPEG-TS/M2TS/MTS (DVB, IPTV, registrazioni), MPEG-PS/VOB/MPG,
/// ASF/WMV, OGG/OGV, 3GP/3G2, NUT, MXF, RM/RMVB (se il build FFmpeg
/// includiva i demuxer RealMedia). Il supporto CODEC (quali flussi audio/
/// video dentro quei contenitori si sanno DECODIFICARE — H.264, HEVC,
/// AV1, VP8/9, MPEG-2, VC-1, AAC, AC-3/E-AC-3, DTS, Opus, FLAC, ...)
/// dipende invece dalla configurazione di compilazione di FFmpeg dentro
/// il pacchetto KSPlayer stesso (flag `--enable-decoder=...`), NON da
/// questi due file Swift: non esiste alcuna proprietà di `KSOptions` che
/// possa "aggiungere" un decoder assente dal binario compilato.
///
/// Ciò che QUESTO file può davvero fare — e che ora fa — per "leggere
/// tutti i tipi di film" è rendere il PARSING del contenitore più
/// tollerante U N I V E R S A L M E N T E, indipendentemente da quale
/// contenitore/demuxer venga rilevato, usando SOLO opzioni generiche di
/// `AVFormatContext` (documentate in `libavformat/options_table.h`, non
/// legate a un demuxer/protocollo specifico, quindi mai a rischio del
/// bug "opzione non consumata" diagnosticato nei turni precedenti):
///
/// - `err_detect = ignore_err`: non abortisce l'apertura/lettura per
///   pacchetti leggermente corrotti (comune su registrazioni TS/IPTV),
///   valido per QUALUNQUE demuxer.
/// - `avoid_negative_ts = make_zero`: normalizza automaticamente i
///   timestamp negativi che alcuni contenitori (MOV/MP4 con edit list,
///   MKV rimuxati) possono presentare, evitando artefatti di
///   sincronizzazione o rifiuti di apertura.
/// - `correct_ts_overflow = 1`: corregge automaticamente l'overflow dei
///   timestamp su flussi molto lunghi (film > ~26h di PTS a 90kHz, o
///   flussi live accumulati), valido per qualunque contenitore.
/// - `seek2any = 1`: consente il seek su QUALSIASI fotogramma (non solo
///   keyframe) per tutti i demuxer che lo supportano, rendendo il seek
///   utilizzabile anche su contenitori con GOP molto lunghi.
///
/// Queste 4 opzioni sono ora SEMPRE attive (vedi `buildLayer`), in
/// aggiunta — non in sostituzione — ai default di rete sensibili al
/// protocollo e al retry automatico già presenti.
///
/// ANALISI MANIACALE 2026-09-27 (ter) — "avformat: can't open input"
/// PERSISTENTE su alcuni film VOD: `handleOpenFailure` esegue una
/// SEQUENZA di fino a 2 tentativi di fallback automatici e silenziosi
/// (l'utente vede l'errore solo se anche l'ultimo tentativo fallisce):
/// 1) impostazioni utente inalterate; 2) User-Agent browser + Referer
/// auto-derivato dal dominio; 3) come sopra, più decodifica forzata in
/// software, apertura "completa" invece di rapida, e probing/analisi
/// ulteriormente estesi (50 MB / 30s).
///
/// FIX MANIACALE 2026-09-27 (bis) — le opzioni di rete (`reconnect*`,
/// `rtsp_transport`) sono calcolate IN BASE ALLO SCHEMA DELL'URL
/// (`networkFormatContextOptions`): applicarle globalmente a qualunque
/// protocollo lasciava chiavi RTSP "non consumate" su URL http(s) di
/// file VOD gestiti esclusivamente dal motore FFmpeg, causando l'errore
/// generico "can't open input". Ogni chiave è applicata solo al
/// protocollo che la può davvero consumare — le 4 opzioni generiche di
/// `AVFormatContext` elencate sopra sono invece SEMPRE sicure ovunque,
/// perché non appartengono a un singolo demuxer/protocollo.
///
/// FIX 2026-09-27 (precedente) — `subtitleDelay`/`subtitleDisable` NON
/// esistono su `KSOptions` in questa versione della libreria e restano
/// rimossi (vedi kingslay/KSPlayer#508).
///
/// FIX 2026-09-25 (zapping canale/episodio "senza uscire e riaprire il
/// player"): `layer` è `@Published` (non `let`): `load(url:title:)` crea
/// un nuovo `KSPlayerLayer` per il nuovo URL e lo assegna a questa stessa
/// istanza di `KSPlaybackController`, che resta viva per tutta la sessione
/// di visione. `KSPlayerContainerView` osserva il cambio di `layer` e si
/// limita a staccare la vecchia `UIView` del player e agganciare la
/// nuova nello stesso container già presente a schermo.

/// Modalità di adattamento del video al riquadro dello schermo.
/// Mappa 1:1 su `UIView.ContentMode`, letto/scritto da
/// `MediaPlayerProtocol.contentMode` in KSPlayer.
enum VideoGravityMode: String, CaseIterable, Identifiable {
    /// Il video intero è visibile, con eventuali barre nere ai lati.
    case fit
    /// Il video riempie tutto il riquadro ritagliando le parti che eccedono.
    case fill
    /// Il video viene stirato per riempire esattamente il riquadro.
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

    /// Preferenze di riproduzione avanzate regolabili dall'utente
    /// (`AdvancedSettingsView`, raggiungibile dal menu "…").
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

        // MARK: Sottotitoli (testo, immagine, Closed Captions)
        // NOTA: `subtitleDisable`/`subtitleDelay` non esistono su
        // `KSOptions` in questa versione (vedi kingslay/KSPlayer#508).
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
        /// `nil` = usa il default robusto sempre attivo (10 MB).
        var probesize: Int64?
        /// `nil` = usa il default robusto sempre attivo (10s).
        var maxAnalyzeDuration: Int64?

        // MARK: Filtri FFmpeg
        var videoFilters: [String] = []
        var audioFilters: [String] = []

        // MARK: Opzioni FFmpeg grezze AGGIUNTIVE (potere assoluto)
        //
        // Si sommano — vincendo chiave per chiave in caso di conflitto —
        // sia ai default di rete sensibili al protocollo
        // (`networkFormatContextOptions`) sia alle 4 opzioni generiche di
        // `AVFormatContext` sempre attive (`genericFormatContextOptions`)
        // descritte nella nota "TIPI DI CONTENITORE" in testa al file.
        var formatContextOptions: [String: String] = [:]
        var decoderOptions: [String: String] = [:]
        var avOptions: [String: String] = [:]
    }

    /// Default probing/analisi robusti, sempre attivi (proprietà TIPIZZATE
    /// di `KSOptions`, non chiavi del dizionario grezzo: nessun rischio
    /// di "opzione non consumata").
    private static let builtInProbesize: Int64 = 10_000_000
    private static let builtInMaxAnalyzeDuration: Int64 = 10_000_000

    /// Numero massimo di tentativi di apertura totali (1 iniziale + 2 di
    /// fallback) prima di mostrare finalmente l'errore all'utente.
    private static let maxOpenAttempts = 3

    /// User-Agent di fallback usato SOLO nei retry automatici dopo un
    /// fallimento di apertura.
    private static let fallbackUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// Deriva un Referer plausibile dal dominio dell'URL stesso, usato
    /// SOLO nei retry di fallback quando l'utente non ne ha impostato uno.
    private static func selfReferer(for url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return "\(scheme)://\(host)/"
    }

    /// Opzioni GENERICHE di `AVFormatContext`, valide per QUALUNQUE
    /// contenitore/demuxer (MP4, MKV, AVI, TS, FLV, WebM, ASF, VOB, OGV,
    /// 3GP, ...) perché sono AVOptions dichiarate direttamente sulla
    /// classe `AVFormatContext` in FFmpeg, non su un singolo demuxer o
    /// protocollo: a differenza di `rtsp_transport`/`reconnect` (validi
    /// solo per specifici protocolli, vedi `networkFormatContextOptions`),
    /// queste 4 chiavi vengono SEMPRE consumate, indipendentemente dal
    /// tipo di file aperto, quindi possono restare attive senza alcun
    /// rischio della classe di bug "opzione non consumata" diagnosticata
    /// nei turni precedenti. Vedi nota "TIPI DI CONTENITORE" in testa al
    /// file per il dettaglio di cosa fa ciascuna chiave.
    private static let genericFormatContextOptions: [String: String] = [
        "err_detect": "ignore_err",
        "avoid_negative_ts": "make_zero",
        "correct_ts_overflow": "1",
        "seek2any": "1",
    ]

    /// Calcola le opzioni `AVFormatContext`/protocollo di rete pertinenti
    /// ESCLUSIVAMENTE allo schema dell'URL corrente (fix del bug VOD: le
    /// chiavi RTSP-specifiche applicate a URL http/https venivano lasciate
    /// "non consumate" da alcuni demuxer, causando "can't open input").
    private static func networkFormatContextOptions(for url: URL) -> [String: String] {
        switch url.scheme?.lowercased() {
        case "http", "https":
            return [
                "reconnect": "1",
                "reconnect_at_eof": "1",
                "reconnect_streamed": "1",
                "reconnect_delay_max": "5",
                "rw_timeout": "15000000",
                "multiple_requests": "1",
                "http_persistent": "1",
            ]
        case "rtsp", "rtsps":
            return [
                "rtsp_transport": "tcp",
                "rtsp_flags": "prefer_tcp",
                "stimeout": "10000000",
            ]
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

    /// Numero di tentativi di apertura già eseguiti per l'URL corrente.
    /// Azzerato ad ogni `load(url:title:)`/`resetAttempts()`.
    private var openAttemptCount = 0

    /// Pubblichiamo un aggiornamento di `currentTime` solo se la
    /// variazione percepita è reale (>= 200ms) o se la durata totale è
    /// cambiata, per non rivalutare l'intera UI molte volte al secondo.
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

    /// Costruisce un nuovo `KSPlayerLayer` applicando l'intera superficie
    /// di `PlaybackPreferences`, i default di rete sensibili al protocollo,
    /// le 4 opzioni generiche `AVFormatContext` sempre attive (compatibili
    /// con QUALUNQUE tipo di contenitore) e i default di probing/analisi.
    /// `userAgentOverride`/`refererOverride` sono usati ESCLUSIVAMENTE dai
    /// retry di fallback e non toccano mai `preferences`.
    private static func buildLayer(
        for url: URL,
        preferences: PlaybackPreferences,
        userAgentOverride: String? = nil,
        refererOverride: String? = nil
    ) -> KSPlayerLayer {
        let options = KSOptions()

        // Buffer
        options.preferredForwardBufferDuration = preferences.preferredForwardBufferDuration
        options.maxBufferDuration = preferences.maxBufferDuration

        // Decodifica
        options.hardwareDecode = preferences.hardwareDecode
        options.asynchronousDecompression = preferences.asynchronousDecompression
        options.syncDecodeVideo = preferences.syncDecodeVideo
        options.syncDecodeAudio = preferences.syncDecodeAudio
        options.lowres = preferences.lowres
        options.videoDisable = preferences.videoDisable

        // Ricerca / sincronizzazione
        options.isAccurateSeek = preferences.isAccurateSeek
        options.seekFlags = preferences.seekFlags
        options.autoDeInterlace = preferences.autoDeInterlace
        options.videoDelay = preferences.videoDelay

        // Sottotitoli
        options.autoSelectEmbedSubtitle = preferences.autoSelectEmbedSubtitle
        options.isSeekImageSubtitle = preferences.isSeekImageSubtitle

        // Rendering / panorama
        options.display = preferences.panoramaMode.displayMode
        options.autoRotate = preferences.autoRotate

        // Adattamento / comportamento riproduzione
        options.videoAdaptable = preferences.videoAdaptable
        options.isLoopPlay = preferences.isLoopPlay
        options.isSecondOpen = preferences.isSecondOpen
        options.isSeekedAutoPlay = preferences.isSeekedAutoPlay
        options.startPlayTime = preferences.startPlayTime
        options.startPlayRate = preferences.startPlayRate

        // Rete
        options.userAgent = userAgentOverride ?? preferences.userAgent
        options.referer = refererOverride ?? preferences.referer
        if !preferences.customHTTPHeaders.isEmpty {
            options.appendHeader(preferences.customHTTPHeaders)
        }
        options.cache = preferences.httpCacheEnabled
        options.probesize = preferences.probesize ?? builtInProbesize
        options.maxAnalyzeDuration = preferences.maxAnalyzeDuration ?? builtInMaxAnalyzeDuration

        // Filtri FFmpeg
        options.videoFilters = preferences.videoFilters
        options.audioFilters = preferences.audioFilters

        // Opzioni FFmpeg grezze: partiamo dalle 4 opzioni generiche
        // AVFormatContext (SEMPRE valide, qualunque contenitore), ci
        // uniamo i default di rete pertinenti SOLO al protocollo
        // dell'URL corrente, infine le personalizzazioni dell'utente
        // vincono chiave per chiave in caso di conflitto.
        var effectiveFormatContextOptions = genericFormatContextOptions
        effectiveFormatContextOptions.merge(networkFormatContextOptions(for: url)) { _, new in new }
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

    /// Ricarica lo stream corrente (stesso URL) con le `preferences`
    /// aggiornate.
    func reload() {
        load(url: currentURL, title: title)
    }

    /// Eseguito automaticamente e SILENZIOSAMENTE ad ogni fallimento di
    /// apertura per l'URL corrente, finché non si raggiunge
    /// `maxOpenAttempts`. Vedi nota "ANALISI MANIACALE" in testa al file
    /// per il dettaglio della sequenza a 2 livelli.
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
                refererOverride: referer
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
                refererOverride: referer
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
