import Foundation
import AVFoundation
import MediaPlayer
import KSPlayer

/// Bridge SwiftUI-friendly per KSPlayerLayer.
///
/// FIX 2026-09-28a (compatibilità "TUTTI I FORMATI" + errore
/// `mpeg4 (Advanced Simple Profile) yuv420p 720x304`):
/// FFmpeg (`KSMEPlayer`) diventa il motore PRIMARIO globale, con
/// fallback automatico hardware -> software su qualsiasi errore prima
/// di arrendersi (vedi `configureGlobalPlayerEngineIfNeeded()` e
/// `player(layer:finish:)`).
///
/// FIX 2026-09-28b ("risorsa non disponibile" identico su hardware E
/// software): il log mostrava lo STESSO errore, ISTANTANEO, su entrambi
/// i tentativi — segno che il problema non era il decoder ma la nostra
/// stessa configurazione FFmpeg, che impediva l'apertura del flusso
/// ancora prima di arrivare al decoder. Due cause individuate e
/// corrette:
///
/// 1) `avOptions` in KSPlayer sono le opzioni di **AVFoundation/
///    AVURLAsset**, usate SOLO dal motore nativo `KSAVPlayer`: non
///    hanno alcun effetto (e possono confondere l'engine) sul motore
///    FFmpeg `KSMEPlayer`, che è il nostro primario. Le opzioni FFmpeg
///    reali (avformat/protocollo: `reconnect`, `timeout`, ecc.) vanno
///    invece in `formatContextOptions`, che è la vera controparte
///    dell'`AVDictionary` passata a `avformat_open_input`. Le chiavi di
///    riconnessione sono state spostate lì.
/// 2) `probesize`/`maxAnalyzeDuration` erano stati ridotti in modo
///    troppo aggressivo (500KB / 1s) per "guadagnare" qualche
///    millisecondo di latenza. Molti file AVI/MP4 di IPTV/VOD (incluso
///    verosimilmente questo film) hanno metadata di stream non
///    immediatamente all'inizio del file: con un probe troppo piccolo,
///    FFmpeg può fallire silenziosamente l'apertura del contenitore
///    PRIMA ancora di sapere quali codec sono coinvolti — da cui
///    l'errore generico e identico su entrambi i motori. Questi limiti
///    sono stati rimossi (si lascia FFmpeg usare i suoi default
///    robusti): la compatibilità totale ha priorità sui millisecondi.
///
/// Inoltre l'errore ora viene SEMPRE mostrato con il testo reale
/// riportato dal motore (non più un messaggio generico "formato non
/// supportato" quando il problema è di rete/risorsa): questo evita di
/// confondere un URL non raggiungibile con un problema di codec.
enum VideoGravityMode: String, CaseIterable, Identifiable {
    /// Il video intero è visibile, con eventuali barre nere ai lati:
    /// nessun ritaglio, nessuna deformazione. Default.
    case fit
    /// Il video riempie tutto il riquadro ritagliando le parti che
    /// eccedono: nessuna barra nera, nessuna deformazione, ma parte
    /// dell'immagine (di solito i bordi) non è visibile.
    case fill
    /// Il video viene stirato per riempire esattamente il riquadro:
    /// nessuna barra nera, nessun ritaglio, ma l'immagine viene
    /// deformata se le proporzioni non corrispondono.
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

@MainActor
final class KSPlaybackController: NSObject, ObservableObject {

    /// Preferenze di riproduzione avanzate regolabili dall'utente
    /// (`AdvancedSettingsView`, raggiungibile dal menu "…"). Sono lo
    /// stato di verità riapplicato ad ogni nuovo `KSPlayerLayer`, sia al
    /// primo avvio sia ad ogni cambio canale/episodio.
    struct PlaybackPreferences {
        var preferredForwardBufferDuration: Double = 3
        var maxBufferDuration: Double = 30
        /// `KSOptions.hardwareDecode`: decodifica hardware
        /// (VideoToolbox, "Metal") vs software (FFmpeg puro,
        /// libavcodec). Con FFmpeg come motore primario, questo flag
        /// controlla solo se FFmpeg stesso delega la decodifica video a
        /// VideoToolbox quando il codec lo consente (H.264/H.265): per
        /// codec non supportati da VideoToolbox (MPEG-4 ASP, H.263,
        /// VC-1, WMV, VP6, FLV1, RealVideo, ecc.) il controller forza
        /// automaticamente `false` dopo il primo fallimento, garantendo
        /// compatibilità totale.
        var hardwareDecode: Bool = true
        /// `KSOptions.isAccurateSeek`: seek fotogramma-esatto (più lento)
        /// invece del seek "al keyframe più vicino" (più rapido, default).
        var isAccurateSeek: Bool = false
        /// `KSOptions.autoDeInterlace`: rileva e corregge automaticamente
        /// l'interlacciamento, comune su molti canali SD delle
        /// playlist IPTV.
        var autoDeInterlace: Bool = false
        /// `KSOptions.videoDelay` (secondi): sincronizzazione audio/video
        /// manuale. Positivo = video ritardato rispetto all'audio.
        var videoDelay: Double = 0
        /// Modalità di adattamento del video al riquadro (vedi
        /// `VideoGravityMode`).
        var videoGravity: VideoGravityMode = .fit
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

    /// FIX FORMATO: quando un flusso va in errore con `hardwareDecode`
    /// ancora attivo, tentiamo UNA sola volta il ricaricamento in
    /// decodifica 100% software (FFmpeg/libavcodec) prima di arrenderci
    /// e mostrare l'errore all'utente. Questo flag evita loop infiniti:
    /// se anche il tentativo software fallisce, mostriamo l'errore reale
    /// (che può essere di rete/risorsa, non necessariamente di codec).
    private var didAttemptSoftwareFallback = false

    /// Configurazione GLOBALE del motore di riproduzione: applicata una
    /// sola volta, vale per ogni `KSOptions`/`KSPlayerLayer` creato da
    /// questo momento in avanti nell'intera app.
    ///
    /// `firstPlayerType = KSMEPlayer.self`: FFmpeg è il motore PRIMARIO.
    /// A differenza di `KSAVPlayer` (che capisce solo i contenitori/
    /// codec che Apple supporta nativamente), `KSMEPlayer` include
    /// libavformat + libavcodec compilati nella libreria e quindi
    /// demuxa/decodifica letteralmente ogni formato esistente (MP4,
    /// MKV, AVI, TS, FLV, WMV, MOV, WebM, ecc. con qualunque codec
    /// audio/video/sottotitolo al loro interno).
    ///
    /// `secondPlayerType = KSAVPlayer.self`: se anche FFmpeg dovesse
    /// fallire ad aprire il contenitore (evento raro: file realmente
    /// corrotto o URL non raggiungibile), si tenta come ultima risorsa
    /// il motore nativo Apple con accelerazione hardware completa.
    private static var didConfigureGlobalPlayerEngine = false

    private static func configureGlobalPlayerEngineIfNeeded() {
        guard !didConfigureGlobalPlayerEngine else { return }
        didConfigureGlobalPlayerEngine = true
        KSOptions.firstPlayerType = KSMEPlayer.self
        KSOptions.secondPlayerType = KSAVPlayer.self
        DebugLogger.logAsync(.info, "KSPlaybackController: motore primario = KSMEPlayer (FFmpeg), fallback = KSAVPlayer (hardware/Metal)")
    }

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
        Self.configureGlobalPlayerEngineIfNeeded()
        self.layer = Self.buildLayer(for: url, preferences: PlaybackPreferences())
        super.init()
        layer.delegate = self
        startWatchdog()
    }

    /// Costruisce un nuovo `KSPlayerLayer` con le opzioni derivate dalle
    /// `PlaybackPreferences` correnti, ottimizzato per: (1) compatibilità
    /// massima di formato/codec via FFmpeg, (2) latenza minima
    /// all'avvio e allo zapping, SENZA sacrificare la capacità di
    /// FFmpeg di analizzare correttamente il contenitore.
    private static func buildLayer(for url: URL, preferences: PlaybackPreferences) -> KSPlayerLayer {
        let options = KSOptions()

        // --- Buffering ---
        options.preferredForwardBufferDuration = preferences.preferredForwardBufferDuration
        options.maxBufferDuration = preferences.maxBufferDuration
        options.registerRemoteControll = true
        options.canStartPictureInPictureAutomaticallyFromInline = true
        options.userAgent = "GassPlayer/1.0"

        // --- Decodifica ---
        options.hardwareDecode = preferences.hardwareDecode
        options.isAccurateSeek = preferences.isAccurateSeek
        options.autoDeInterlace = preferences.autoDeInterlace
        options.videoDelay = preferences.videoDelay
        // Decompressione asincrona: il rendering non aspetta la CPU/GPU
        // in modo bloccante, riducendo micro-scatti percepiti.
        options.asynchronousDecompression = true

        // Se si finisce in decodifica software (fallback automatico o
        // scelta manuale), usa più thread FFmpeg per il decoder video
        // (chiave libavcodec "threads"), evitando che il software decode
        // diventi il collo di bottiglia su risoluzioni elevate.
        let threadCount = min(ProcessInfo.processInfo.activeProcessorCount, 4)
        options.decoderOptions["threads"] = "\(threadCount)"

        // NON tocchiamo `probesize`/`maxAnalyzeDuration`: forzarli a
        // valori piccoli per "guadagnare latenza" ha causato in
        // precedenza il fallimento di apertura di contenitori AVI/MP4
        // con metadata non lineare (l'errore "risorsa non disponibile"
        // riprodotto identico su hardware E software). Si lasciano i
        // default della libreria, che sanno già bilanciare velocità e
        // correttezza dell'analisi del contenitore.

        // --- Opzioni FFmpeg reali (avformat/protocollo), NON opzioni
        // AVFoundation: vanno in `formatContextOptions`, la vera
        // controparte dell'AVDictionary passata a
        // `avformat_open_input`. `avOptions` in KSPlayer è invece
        // riservato alle opzioni di AVURLAsset usate solo dal motore
        // nativo KSAVPlayer: metterci opzioni FFmpeg lì non ha alcun
        // effetto sul motore primario e va evitato.
        if url.scheme == "http" || url.scheme == "https" {
            // Riconnessione automatica sui flussi HTTP/HLS IPTV che
            // cadono per un istante: evita che un singolo timeout
            // diventi un errore fatale mostrato all'utente.
            options.formatContextOptions["reconnect"] = 1
            options.formatContextOptions["reconnect_streamed"] = 1
            options.formatContextOptions["reconnect_delay_max"] = 2
            // Timeout di connessione/lettura (microsecondi): evita che
            // un server IPTV lento a rispondere blocchi indefinitamente
            // l'apertura del flusso senza mai restituire un errore.
            options.formatContextOptions["timeout"] = 15_000_000
            options.formatContextOptions["rw_timeout"] = 15_000_000
        }
        // Molte playlist HLS di IPTV referenziano sotto-manifest/segmenti
        // su protocolli diversi (http/https/crypto per gli stream
        // cifrati AES-128): senza whitelist esplicita FFmpeg può
        // rifiutare l'apertura con "Protocol not found" su alcuni CDN.
        options.formatContextOptions["protocol_whitelist"] = "file,http,https,tcp,tls,crypto,hls,applehttp"

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
        hasEverStartedPlaying = false
        bufferingProgress = 0
        didAttemptSoftwareFallback = false
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
        didAttemptSoftwareFallback = false
        layer.play()
        startWatchdog()
    }

    var audioTracks: [MediaPlayerTrack] { layer.player.tracks(mediaType: .audio) }
    var subtitleTracks: [MediaPlayerTrack] { layer.player.tracks(mediaType: .subtitle) }
    var videoTracks: [MediaPlayerTrack] { layer.player.tracks(mediaType: .video) }

    func select(track: MediaPlayerTrack) {
        layer.player.select(track: track)
    }

    // MARK: - Impostazioni avanzate (KSOptions, vedi PlaybackPreferences)

    func setPreferredForwardBufferDuration(_ value: Double) {
        preferences.preferredForwardBufferDuration = value
        layer.options.preferredForwardBufferDuration = value
    }

    func setMaxBufferDuration(_ value: Double) {
        preferences.maxBufferDuration = value
        layer.options.maxBufferDuration = value
    }

    func setVideoDelay(_ value: Double) {
        preferences.videoDelay = value
        layer.options.videoDelay = value
    }

    func setAccurateSeek(_ enabled: Bool) {
        preferences.isAccurateSeek = enabled
        layer.options.isAccurateSeek = enabled
    }

    func setVideoGravity(_ mode: VideoGravityMode) {
        preferences.videoGravity = mode
        layer.player.contentMode = mode.contentMode
    }

    /// Attivazione/disattivazione MANUALE della decodifica hardware
    /// (toggle utente in `AdvancedSettingsView`/menu "…"). Indipendente
    /// dal fallback AUTOMATICO in caso di errore (vedi
    /// `player(layer:finish:)`): qui l'utente sceglie esplicitamente,
    /// quindi resettiamo il flag di fallback per permettere un nuovo
    /// tentativo automatico se necessario.
    func setHardwareDecode(_ enabled: Bool) {
        preferences.hardwareDecode = enabled
        didAttemptSoftwareFallback = false
        reload()
    }

    func setAutoDeInterlace(_ enabled: Bool) {
        preferences.autoDeInterlace = enabled
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
        default:
            break
        }
    }

    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        let durationChanged = totalTime != duration
        guard durationChanged || abs(currentTime - self.currentTime) >= 0.2 else { return }
        self.currentTime = currentTime
        self.duration = totalTime
    }

    /// Gestione unificata degli errori di riproduzione.
    ///
    /// Se il flusso va in errore mentre `hardwareDecode` è attivo,
    /// tentiamo automaticamente UNA volta la decodifica 100% software
    /// (FFmpeg/libavcodec), che copre i codec che VideoToolbox non
    /// decodifica in hardware (es. MPEG-4 Advanced Simple Profile).
    ///
    /// FIX 2026-09-28: mostriamo sempre il messaggio di errore REALE
    /// riportato dal motore (`error.localizedDescription`), non più un
    /// testo generico che ipotizzava sempre "formato non supportato".
    /// Un errore come "risorsa non disponibile" indica quasi sempre un
    /// problema di rete/URL (server irraggiungibile, link scaduto,
    /// playlist non più valida) e va comunicato come tale: continuare a
    /// suggerire "il formato potrebbe non essere supportato" in quel
    /// caso è fuorviante e fa perdere tempo a diagnosticare la causa
    /// vera.
    func player(layer: KSPlayerLayer, finish error: Error?) {
        guard let error else { return }
        let description = error.localizedDescription
        DebugLogger.logAsync(.error, "KSPlaybackController: riproduzione terminata con errore: \(description)")

        if preferences.hardwareDecode, !didAttemptSoftwareFallback {
            didAttemptSoftwareFallback = true
            DebugLogger.logAsync(.warning, "KSPlaybackController: errore con decodifica hardware, ritento in software (FFmpeg) prima di arrendermi")
            preferences.hardwareDecode = false
            reload()
            return
        }

        lastError = description
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {
        DebugLogger.logAsync(.info, "KSPlaybackController: buffer #\(bufferedCount) pronto in \(consumeTime)s")
    }
}
