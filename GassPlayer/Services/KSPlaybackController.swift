import Foundation
import AVFoundation
import MediaPlayer
import KSPlayer

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

/// Bridge SwiftUI-friendly per KSPlayerLayer.
///
/// Motore primario: FFmpeg (`KSMEPlayer`) -> compatibile con praticamente
/// ogni contenitore/codec (MP4, MKV, AVI, TS, FLV, WMV, MOV, WebM, MPEG-4
/// ASP, VC-1, ...). Fallback: `KSAVPlayer` (AVFoundation nativo).
///
/// AGGIORNAMENTO 2026-09-28c — "il provider non serve il contenuto":
/// il player prima mostrava il messaggio del SECONDO motore (AVFoundation,
/// generico: "risorsa non disponibile") che mascherava la causa reale, e
/// non provava mai formati/UA alternativi. Cause corrette:
///
/// 1. Connessione rimasta aperta: `pause()` NON chiude il socket. Ogni
///    reload/zapping/fallback lasciava viva la connessione precedente e i
///    provider con 1-2 connessioni rifiutavano la nuova (HTTP 458/509/
///    884, o 5xx). Ora ogni layer scartato viene fermato e distrutto
///    (`teardown`) PRIMA di aprire il successivo e alla chiusura della vista.
/// 2. `container_extension` errata/obsoleta nel catalogo (404/5xx su
///    quel formato): in caso di errore si sonda il provider
///    (`StreamDiagnostics`) e si prova mp4/mkv/avi/m3u8/ts/... finche' uno
///    viene servito davvero.
/// 3. User-Agent `GassPlayer/1.0` respinto da alcuni backend: default VLC
///    + ladder di UA, con memorizzazione dell'UA che funziona per host.
/// 4. Errori di rete/provider presentati come errori di formato: ora il
///    messaggio finale e' il risultato della diagnosi HTTP reale (403,
///    404, limite connessioni, 5xx del backend, timeout, ...).
///
/// In piu': ripresa automatica della posizione per film/episodi.
@MainActor
final class KSPlaybackController: NSObject, ObservableObject {

    /// Preferenze di riproduzione avanzate regolabili dall'utente
    /// (`AdvancedSettingsView`, raggiungibile dal menu "…"). Sono lo
    /// stato di verita' riapplicato ad ogni nuovo `KSPlayerLayer`.
    struct PlaybackPreferences {
        var preferredForwardBufferDuration: Double = 3
        var maxBufferDuration: Double = 30
        /// `KSOptions.hardwareDecode`: VideoToolbox vs software puro. Con
        /// FFmpeg come motore primario controlla solo se FFmpeg delega la
        /// decodifica video a VideoToolbox (H.264/H.265). Dopo un errore
        /// il controller passa da solo a `false` (fallback software).
        var hardwareDecode: Bool = true
        var isAccurateSeek: Bool = false
        var autoDeInterlace: Bool = false
        /// Secondi. Positivo = video ritardato rispetto all'audio.
        var videoDelay: Double = 0
        var videoGravity: VideoGravityMode = .fit

        /// Valori di fabbrica: quelli sopra, indipendentemente da cosa è
        /// salvato in `UserDefaults`. Usato da "Ripristina impostazioni
        /// predefinite del player" in Impostazioni → Riproduzione.
        static let factoryDefault = PlaybackPreferences()

        /// Preferenze da usare per OGNI player appena aperto: quelle
        /// impostate in Impostazioni → Riproduzione (o modificate
        /// dall'ultima volta nel pannello avanzato del player stesso),
        /// con fallback ai valori di fabbrica se non ancora salvate.
        static func loadFromDefaults() -> PlaybackPreferences {
            PlayerEngineDefaultsStore.load()
        }
    }

    /// Persistenza delle preferenze del motore su `UserDefaults`, condivisa
    /// tra il pannello "Impostazioni" (voci aggiuntive in Riproduzione) e il
    /// pannello avanzato dentro al player stesso: modificarne una in un
    /// posto si riflette subito nell'altro, ed entrambi determinano le
    /// preferenze di un nuovo player appena aperto.
    enum PlayerEngineDefaultsStore {
        private enum Key {
            static let forwardBuffer = "gassplayer.player.preferredForwardBufferDuration"
            static let maxBuffer = "gassplayer.player.maxBufferDuration"
            static let hardwareDecode = "gassplayer.player.hardwareDecode"
            static let accurateSeek = "gassplayer.player.isAccurateSeek"
            static let autoDeInterlace = "gassplayer.player.autoDeInterlace"
            static let videoGravity = "gassplayer.player.videoGravity"
        }

        static func load() -> PlaybackPreferences {
            let d = UserDefaults.standard
            let fallback = PlaybackPreferences.factoryDefault
            var prefs = fallback

            if let v = d.object(forKey: Key.forwardBuffer) as? Double { prefs.preferredForwardBufferDuration = v }
            if let v = d.object(forKey: Key.maxBuffer) as? Double { prefs.maxBufferDuration = v }
            if let v = d.object(forKey: Key.hardwareDecode) as? Bool { prefs.hardwareDecode = v }
            if let v = d.object(forKey: Key.accurateSeek) as? Bool { prefs.isAccurateSeek = v }
            if let v = d.object(forKey: Key.autoDeInterlace) as? Bool { prefs.autoDeInterlace = v }
            if let raw = d.string(forKey: Key.videoGravity), let mode = VideoGravityMode(rawValue: raw) { prefs.videoGravity = mode }
            // videoDelay NON viene ricordato tra una riproduzione e l'altra
            // (è specifico del singolo file/fonte: un valore salvato per
            // sbaglio da un contenuto disallineato romperebbe tutti gli altri).

            return prefs
        }

        static func save(_ prefs: PlaybackPreferences) {
            let d = UserDefaults.standard
            d.set(prefs.preferredForwardBufferDuration, forKey: Key.forwardBuffer)
            d.set(prefs.maxBufferDuration, forKey: Key.maxBuffer)
            d.set(prefs.hardwareDecode, forKey: Key.hardwareDecode)
            d.set(prefs.isAccurateSeek, forKey: Key.accurateSeek)
            d.set(prefs.autoDeInterlace, forKey: Key.autoDeInterlace)
            d.set(prefs.videoGravity.rawValue, forKey: Key.videoGravity)
        }

        /// Cancella tutte le chiavi: la prossima lettura torna ai valori di
        /// fabbrica. Usato dal tasto di reset in Impostazioni.
        static func resetToFactoryDefaults() {
            let d = UserDefaults.standard
            [Key.forwardBuffer, Key.maxBuffer, Key.hardwareDecode, Key.accurateSeek, Key.autoDeInterlace, Key.videoGravity]
                .forEach { d.removeObject(forKey: $0) }
        }
    }

    @Published var state: KSPlayerState = .initialized
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var lastError: String?
    @Published var bufferingProgress: Int = 0
    /// Testo mostrato sotto lo spinner mentre il controller diagnostica il
    /// provider o prova un formato/profilo alternativo.
    @Published private(set) var recoveryStatus: String?
    @Published private(set) var isRecovering = false
    /// Posizione da cui si potrebbe riprendere (film/episodi), in attesa
    /// della scelta dell'utente nell'alert "Riprendi la visione?". Finche'
    /// non risponde, il layer resta fermo a 0 senza avviare la riproduzione.
    @Published private(set) var pendingResume: TimeInterval?
    @Published var isPipActive = false {
        didSet { layer.isPipActive = isPipActive }
    }

    @Published private(set) var layer: KSPlayerLayer
    @Published private(set) var preferences = PlaybackPreferences()

    /// URL richiesto dal chiamante (non cambia durante il recupero).
    private(set) var currentURL: URL
    private(set) var isStopped = false

    /// URL/UA effettivamente in uso (possono differire da `currentURL`
    /// dopo un recupero riuscito su un formato alternativo).
    private var activeURL: URL
    private var activeUserAgent: String
    private var title: String

    private var watchdogTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var hasEverStartedPlaying = false
    private var didAttemptSoftwareFallback = false
    private var recoveryRounds = 0
    private var triedKeys = Set<String>()
    private var loadGeneration = 0
    private var lastPositionSave = Date.distantPast
    private weak var tornDownLayer: KSPlayerLayer?

    private static let maxRecoveryRounds = 3

    // MARK: - Motore globale

    private static var didConfigureGlobalPlayerEngine = false

    /// `firstPlayerType = KSMEPlayer` (FFmpeg): demuxa/decodifica ogni
    /// formato. `secondPlayerType = KSAVPlayer`: ultima risorsa nativa
    /// Apple (utile soprattutto per HLS).
    private static func configureGlobalPlayerEngineIfNeeded() {
        guard !didConfigureGlobalPlayerEngine else { return }
        didConfigureGlobalPlayerEngine = true
        KSOptions.firstPlayerType = KSMEPlayer.self
        KSOptions.secondPlayerType = KSAVPlayer.self
        DebugLogger.logAsync(.info, "KSPlaybackController: motore primario = KSMEPlayer (FFmpeg), fallback = KSAVPlayer")
    }

    var isPlaying: Bool { state.isPlaying }
    var isBuffering: Bool { state == .preparing || state == .buffering || isRecovering }

    var supportsPictureInPicture: Bool {
        if #available(iOS 14.0, tvOS 14.0, *) {
            return layer.player.pipController != nil
        }
        return false
    }

    /// `true` per Live TV (nessuna durata, URL non film/serie).
    var isLiveContent: Bool {
        PlaybackPositionStore.identity(for: currentURL) == nil && duration <= 0
    }

    // MARK: - Init

    init(url: URL, title: String) {
        var userAgent = PlaybackProfileStore.userAgent(for: url) ?? StreamUserAgents.vlc
        var playURL = url
        // "Continua a guardare": la posizione salvata non viene piu'
        // seminata da sola nel motore. Resta "in sospeso" finche' l'utente
        // non risponde all'alert liquid glass mostrato da PlayerView; fino
        // ad allora il layer parte da 0 e NON riproduce.
        let start = PlaybackPositionStore.position(for: url)

        // Risoluzione recente gia' verificata: parte subito, senza sonde.
        let cached = ResolutionCache.fresh(for: url)
        if let cached {
            playURL = cached.playURL
            userAgent = cached.userAgent
        }
        let needsPreflight = cached == nil && Self.needsPreflight(url)

        self.currentURL = url
        self.activeURL = playURL
        self.activeUserAgent = userAgent
        self.title = title
        Self.configureGlobalPlayerEngineIfNeeded()
        let initialPreferences = PlaybackPreferences.loadFromDefaults()
        self.preferences = initialPreferences
        self.layer = Self.buildLayer(
            for: playURL,
            preferences: initialPreferences,
            userAgent: userAgent,
            startTime: nil,
            autoPlay: !needsPreflight && start == nil
        )
        super.init()
        layer.delegate = self
        pendingResume = start
        triedKeys = [Self.key(playURL, userAgent)]
        if needsPreflight {
            beginPreflight()
        } else {
            startWatchdog()
        }
    }

    // MARK: - Verifica preventiva

    /// Film ed episodi (URL Xtream `movie`/`series`): si verifica PRIMA di
    /// avviare il player cosa serve davvero il provider. La Live non si
    /// sonda (aprirebbe un flusso continuo e i canali raramente falliscono
    /// per il formato).
    private static func needsPreflight(_ url: URL) -> Bool {
        guard url.scheme == "http" || url.scheme == "https" else { return false }
        return PlaybackPositionStore.identity(for: url) != nil
    }

    /// Sceglie come avviare `requested`: cache -> subito; VOD -> verifica
    /// preventiva; altrimenti (Live, URL generici) -> avvio diretto.
    /// L'eventuale posizione salvata e' gestita a parte da `pendingResume`.
    private func launch(requested: URL, startTime: TimeInterval?) {
        let userAgent = PlaybackProfileStore.userAgent(for: requested) ?? StreamUserAgents.vlc
        activeURL = requested
        activeUserAgent = userAgent
        let autoPlay = pendingResume == nil

        if let cached = ResolutionCache.fresh(for: requested) {
            triedKeys = [Self.key(cached.playURL, cached.userAgent)]
            startLayer(url: cached.playURL, userAgent: cached.userAgent, startTime: startTime, autoPlay: autoPlay)
        } else if Self.needsPreflight(requested) {
            beginPreflight()
        } else {
            startLayer(url: requested, userAgent: userAgent, startTime: startTime, autoPlay: autoPlay)
        }
    }

    private func beginPreflight() {
        loadGeneration += 1
        let requested = currentURL
        let userAgent = activeUserAgent
        let generation = loadGeneration

        // Segnaposto / layer precedente: mai attivo durante la verifica
        // (una connessione aperta occuperebbe lo slot del provider).
        teardown(layer)
        watchdogTask?.cancel()
        isRecovering = true
        recoveryStatus = "Verifico il provider…"

        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            let diagnosis = await StreamDiagnostics.diagnose(
                url: requested,
                preferredUserAgent: userAgent,
                useCache: true
            )
            if case .playable = diagnosis {
                // Breve pausa: il provider deve registrare la chiusura della
                // connessione della sonda prima di aprire quella del player.
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            guard let self, !Task.isCancelled, generation == self.loadGeneration, !self.isStopped else { return }
            self.finishPreflight(diagnosis, requested: requested, userAgent: userAgent)
        }
    }

    private func finishPreflight(_ diagnosis: StreamDiagnosis, requested: URL, userAgent: String) {
        isRecovering = false
        recoveryStatus = nil
        // La verifica formati non decide mai se riprendere: decide solo se
        // avviare subito o restare fermi in attesa della risposta
        // dell'utente all'alert (pendingResume, se presente).
        let autoPlay = pendingResume == nil

        switch diagnosis {
        case .playable(let resolution):
            triedKeys = [Self.key(resolution.playURL, resolution.userAgent)]
            startLayer(url: resolution.playURL, userAgent: resolution.userAgent, startTime: nil, autoPlay: autoPlay)

        case .inconclusive(let message):
            // La sonda non basta a decidere: provo comunque col motore video.
            DebugLogger.logAsync(.warning, "KSPlaybackController: verifica inconcludente (\(message)), avvio diretto")
            triedKeys = [Self.key(requested, userAgent)]
            startLayer(url: requested, userAgent: userAgent, startTime: nil, autoPlay: autoPlay)

        case .unplayable(let message):
            DebugLogger.logAsync(.error, "KSPlaybackController: verifica provider fallita: \(message)")
            lastError = message
        }
    }

    // MARK: - Alert "Riprendi la visione?"

    /// L'utente ha scelto di riprendere: cerca la posizione salvata.
    func confirmResume() {
        guard let time = pendingResume else { return }
        pendingResume = nil
        layer.seek(time: time, autoPlay: true) { _ in }
    }

    /// L'utente ha scelto di ricominciare da capo: si scarta la posizione
    /// salvata (niente piu' richiesta ai prossimi avvii di questo contenuto).
    func declineResume() {
        guard pendingResume != nil else { return }
        pendingResume = nil
        PlaybackPositionStore.clear(for: currentURL)
        layer.play()
    }

    // MARK: - Costruzione layer

    /// Costruisce un `KSPlayerLayer` ottimizzato per compatibilita' di
    /// formato e latenza, con l'UA indicato.
    private static func buildLayer(
        for url: URL,
        preferences: PlaybackPreferences,
        userAgent: String,
        startTime: TimeInterval?,
        autoPlay: Bool = true
    ) -> KSPlayerLayer {
        let options = KSOptions()

        // --- Buffering ---
        options.preferredForwardBufferDuration = preferences.preferredForwardBufferDuration
        options.maxBufferDuration = preferences.maxBufferDuration
        options.registerRemoteControll = true
        options.canStartPictureInPictureAutomaticallyFromInline = true
        options.userAgent = userAgent

        // --- Ripresa posizione (film/episodi) ---
        if let startTime, startTime > 0 {
            options.startPlayTime = startTime
        }

        // --- Decodifica ---
        options.hardwareDecode = preferences.hardwareDecode
        options.isAccurateSeek = preferences.isAccurateSeek
        options.autoDeInterlace = preferences.autoDeInterlace
        options.videoDelay = preferences.videoDelay
        options.asynchronousDecompression = true

        let threadCount = min(ProcessInfo.processInfo.activeProcessorCount, 4)
        options.decoderOptions["threads"] = "\(threadCount)"

        // NON si toccano `probesize`/`maxAnalyzeDuration`: valori piccoli
        // rompevano l'apertura di AVI/MP4 con metadata non lineari.

        // --- Opzioni FFmpeg reali (avformat) ---
        if url.scheme == "http" || url.scheme == "https" {
            options.formatContextOptions["user_agent"] = userAgent
            options.formatContextOptions["reconnect"] = 1
            options.formatContextOptions["reconnect_streamed"] = 1
            options.formatContextOptions["reconnect_on_network_error"] = 1
            options.formatContextOptions["reconnect_delay_max"] = 2
            // Tetto al tempo totale di riconnessione: senza, FFmpeg puo'
            // insistere per minuti su un backend morto prima di dare errore.
            options.formatContextOptions["reconnect_delay_total_max"] = 10
            // Microsecondi. I film hanno bisogno di piu' margine (il
            // server deve spesso cercare il file/moov atom prima di rispondere).
            let isVOD = PlaybackPositionStore.identity(for: url) != nil
            let timeout = isVOD ? 30_000_000 : 15_000_000
            options.formatContextOptions["timeout"] = timeout
            options.formatContextOptions["rw_timeout"] = timeout
            if isVOD {
                // Riusa la stessa connessione HTTP per i seek invece di
                // aprirne una nuova ogni volta: seek piu' rapidi e meno
                // slot occupati sul provider.
                options.formatContextOptions["multiple_requests"] = 1
            }
        }
        // Whitelist ampia: sotto-manifest HLS/CDN su protocolli diversi,
        // stream cifrati AES-128, sorgenti M3U con rtmp/rtsp/udp/rtp.
        options.formatContextOptions["protocol_whitelist"] =
            "file,http,https,tcp,tls,crypto,hls,applehttp,udp,rtp,rtsp,rtmp,rtmps,data,httpproxy,subfile,async,cache"

        let layer = KSPlayerLayer(url: url, isAutoPlay: autoPlay, options: options, delegate: nil)
        layer.player.contentMode = preferences.videoGravity.contentMode
        return layer
    }

    /// Ferma e distrugge un layer: `pause()` da solo NON chiude la
    /// connessione HTTP e con provider a 1-2 connessioni la successiva
    /// viene rifiutata. Ordine: pause -> shutdown.
    private func teardown(_ target: KSPlayerLayer) {
        // Idempotente: stop()/load()/recupero possono incrociarsi sullo
        // stesso layer (riferimento debole: nessun rischio di riuso).
        guard tornDownLayer !== target else { return }
        tornDownLayer = target
        target.delegate = nil
        target.pause()
        target.player.shutdown()
    }

    private func startLayer(url: URL, userAgent: String, startTime: TimeInterval?, autoPlay: Bool = true) {
        loadGeneration += 1
        activeURL = url
        activeUserAgent = userAgent
        hasEverStartedPlaying = false
        state = .initialized

        let newLayer = Self.buildLayer(
            for: url,
            preferences: preferences,
            userAgent: userAgent,
            startTime: startTime,
            autoPlay: autoPlay
        )
        layer = newLayer
        newLayer.delegate = self
        if autoPlay {
            newLayer.play()
        }
        startWatchdog()
    }

    private func resetPlaybackState() {
        lastError = nil
        currentTime = 0
        duration = 0
        bufferingProgress = 0
        hasEverStartedPlaying = false
        didAttemptSoftwareFallback = false
        isRecovering = false
        recoveryStatus = nil
        state = .initialized
    }

    private func cancelRecovery() {
        recoveryTask?.cancel()
        recoveryTask = nil
        watchdogTask?.cancel()
    }

    private static func key(_ url: URL, _ userAgent: String) -> String {
        "\(url.absoluteString)|\(userAgent)"
    }

    // MARK: - API pubblica

    /// Carica un nuovo URL SENZA distruggere/ricreare `PlayerView`. Il
    /// vecchio flusso viene chiuso davvero prima di aprire il nuovo.
    func load(url: URL, title: String) {
        persistPosition()
        cancelRecovery()
        teardown(layer)

        currentURL = url
        activeURL = url
        activeUserAgent = PlaybackProfileStore.userAgent(for: url) ?? StreamUserAgents.vlc
        self.title = title
        isStopped = false
        recoveryRounds = 0
        resetPlaybackState()
        triedKeys = [Self.key(url, activeUserAgent)]

        let start = PlaybackPositionStore.position(for: url)
        pendingResume = start
        launch(requested: url, startTime: nil)
    }

    /// Ricarica lo stream in uso con le `preferences` aggiornate,
    /// mantenendo la posizione corrente.
    func reload() {
        let resumeAt = (duration > 0 && currentTime > 5) ? currentTime : nil
        let url = activeURL
        let userAgent = activeUserAgent

        cancelRecovery()
        teardown(layer)
        recoveryRounds = 0
        resetPlaybackState()
        startLayer(
            url: url,
            userAgent: userAgent,
            startTime: resumeAt ?? PlaybackPositionStore.position(for: currentURL)
        )
    }

    /// "Riprova" dell'utente: ripartenza pulita con diagnosi completa se
    /// fallisce ancora.
    func resetAttempts() {
        let resumeAt = resumeTime()

        cancelRecovery()
        teardown(layer)
        recoveryRounds = 0
        resetPlaybackState()
        // Ripartenza pulita: si scarta la risoluzione in cache (potrebbe
        // essere proprio quella che ha smesso di funzionare).
        ResolutionCache.invalidate(for: currentURL)
        launch(requested: currentURL, startTime: resumeAt)
    }

    /// Chiude davvero il flusso (rilascia la connessione col provider) e
    /// salva la posizione. Chiamato alla chiusura della vista.
    func stop() {
        guard !isStopped else { return }
        persistPosition()
        isStopped = true
        cancelRecovery()
        teardown(layer)
        isRecovering = false
        recoveryStatus = nil
        state = .initialized
    }

    /// Se la vista ricompare dopo uno `stop()` (es. swipe di chiusura
    /// annullato) riapre il flusso dalla posizione salvata.
    func resumeIfStopped() {
        guard isStopped else { return }
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

    var audioTracks: [MediaPlayerTrack] { layer.player.tracks(mediaType: .audio) }
    var subtitleTracks: [MediaPlayerTrack] { layer.player.tracks(mediaType: .subtitle) }
    var videoTracks: [MediaPlayerTrack] { layer.player.tracks(mediaType: .video) }

    func select(track: MediaPlayerTrack) {
        layer.player.select(track: track)
    }

    // MARK: - Impostazioni avanzate

    func setPreferredForwardBufferDuration(_ value: Double) {
        preferences.preferredForwardBufferDuration = value
        layer.options.preferredForwardBufferDuration = value
        PlayerEngineDefaultsStore.save(preferences)
    }

    func setMaxBufferDuration(_ value: Double) {
        preferences.maxBufferDuration = value
        layer.options.maxBufferDuration = value
        PlayerEngineDefaultsStore.save(preferences)
    }

    /// Non persistito: è specifico del file/fonte aperta in questo
    /// momento, non una preferenza generale da riapplicare ovunque.
    func setVideoDelay(_ value: Double) {
        preferences.videoDelay = value
        layer.options.videoDelay = value
    }

    func setAccurateSeek(_ enabled: Bool) {
        preferences.isAccurateSeek = enabled
        layer.options.isAccurateSeek = enabled
        PlayerEngineDefaultsStore.save(preferences)
    }

    func setVideoGravity(_ mode: VideoGravityMode) {
        preferences.videoGravity = mode
        layer.player.contentMode = mode.contentMode
        PlayerEngineDefaultsStore.save(preferences)
    }

    /// Scelta MANUALE hardware/software (indipendente dal fallback automatico).
    func setHardwareDecode(_ enabled: Bool) {
        preferences.hardwareDecode = enabled
        PlayerEngineDefaultsStore.save(preferences)
        reload()
    }

    func setAutoDeInterlace(_ enabled: Bool) {
        preferences.autoDeInterlace = enabled
        PlayerEngineDefaultsStore.save(preferences)
        reload()
    }

    // MARK: - Posizione

    private func resumeTime() -> TimeInterval? {
        if duration > 0, currentTime > 15 { return currentTime }
        return PlaybackPositionStore.position(for: currentURL)
    }

    private func persistPosition() {
        lastPositionSave = Date()
        guard duration > 0, hasEverStartedPlaying else { return }
        PlaybackPositionStore.record(time: currentTime, duration: duration, for: currentURL)
    }

    private func markStarted() {
        guard !hasEverStartedPlaying else { return }
        hasEverStartedPlaying = true
        watchdogTask?.cancel()
        recoveryStatus = nil
        recoveryRounds = 0
        triedKeys = [Self.key(activeURL, activeUserAgent)]
        PlaybackProfileStore.remember(userAgent: activeUserAgent, for: currentURL)
        if PlaybackPositionStore.identity(for: currentURL) != nil {
            // Il motore ha davvero riprodotto: la prossima apertura salta la verifica.
            ResolutionCache.store(
                StreamResolution(requestedURL: currentURL, playURL: activeURL, userAgent: activeUserAgent),
                for: currentURL
            )
        }
    }

    // MARK: - Watchdog

    /// Dopo 7s senza avvio forza pausa->play; dopo altri 18s (25s totali)
    /// considera il flusso fallito e avvia la diagnosi del provider.
    private func startWatchdog() {
        watchdogTask?.cancel()
        let generation = loadGeneration
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard let self, !Task.isCancelled, generation == self.loadGeneration else { return }
            guard !self.hasEverStartedPlaying, self.lastError == nil, !self.isRecovering else { return }
            DebugLogger.logAsync(.warning, "KSPlaybackController: nessuna riproduzione dopo 7s (stato=\(self.state)), ciclo pausa->play")
            self.layer.pause()
            self.layer.play()

            try? await Task.sleep(nanoseconds: 18_000_000_000)
            guard !Task.isCancelled, generation == self.loadGeneration else { return }
            guard !self.hasEverStartedPlaying, self.lastError == nil, !self.isRecovering else { return }
            self.handlePlaybackFailure("Timeout: nessun dato valido ricevuto dal provider entro 25 secondi.")
        }
    }

    // MARK: - Recupero errori

    /// Errore del motore: chiude il flusso (libera la connessione),
    /// sonda il provider per capire la causa reale e poi riprova con
    /// un URL/UA/decoder diverso oppure mostra la causa vera.
    private func handlePlaybackFailure(_ description: String) {
        guard !isRecovering, !isStopped else { return }
        DebugLogger.logAsync(.error, "KSPlaybackController: errore riproduzione: \(description)")

        recoveryRounds += 1
        guard recoveryRounds <= Self.maxRecoveryRounds else {
            recoveryStatus = nil
            lastError = description
            return
        }

        let failedMidstream = hasEverStartedPlaying
        isRecovering = true
        recoveryStatus = "Il flusso non parte: controllo cosa risponde il provider…"
        watchdogTask?.cancel()

        // Siamo dentro la callback del layer che ha fallito: si scollega
        // subito il delegate e lo si distrugge al giro successivo, fuori
        // dalla callback (evita rientranze dentro KSPlayer).
        let failedLayer = layer
        failedLayer.delegate = nil

        let generation = loadGeneration
        let requested = currentURL
        let userAgent = activeUserAgent

        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            await Task.yield()
            self?.teardown(failedLayer)
            // Lascia al provider il tempo di rilasciare lo slot connessione.
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            ResolutionCache.invalidate(for: requested)
            let diagnosis = await StreamDiagnostics.diagnose(url: requested, preferredUserAgent: userAgent)
            guard let self, !Task.isCancelled, generation == self.loadGeneration, !self.isStopped else { return }
            self.applyDiagnosis(diagnosis, engineError: description, failedMidstream: failedMidstream)
        }
    }

    private func applyDiagnosis(_ diagnosis: StreamDiagnosis, engineError: String, failedMidstream: Bool) {
        isRecovering = false

        switch diagnosis {
        case .unplayable(let message), .inconclusive(let message):
            DebugLogger.logAsync(.error, "KSPlaybackController: diagnosi provider: \(message)")
            recoveryStatus = nil
            lastError = message

        case .playable(let resolution):
            let key = Self.key(resolution.playURL, resolution.userAgent)

            if !triedKeys.contains(key) || failedMidstream {
                triedKeys.insert(key)
                if resolution.playURL.pathExtension.lowercased() != currentURL.pathExtension.lowercased() {
                    recoveryStatus = "Provo il formato \(resolution.playURL.pathExtension.uppercased())…"
                } else {
                    recoveryStatus = "Riprovo la connessione…"
                }
                DebugLogger.logAsync(.warning, "KSPlaybackController: ritento con \(resolution.playURL.lastPathComponent) (UA: \(resolution.userAgent))")
                startLayer(url: resolution.playURL, userAgent: resolution.userAgent, startTime: resumeTime())

            } else if preferences.hardwareDecode, !didAttemptSoftwareFallback {
                // Il provider serve il file: il problema e' il decoder.
                didAttemptSoftwareFallback = true
                preferences.hardwareDecode = false
                recoveryStatus = "Passo alla decodifica software (FFmpeg)…"
                startLayer(url: activeURL, userAgent: activeUserAgent, startTime: resumeTime())

            } else {
                recoveryStatus = nil
                lastError = "Il provider serve il file correttamente ma il player non riesce a decodificarlo.\n\nDettaglio: \(engineError)\n\nProva «Apri con un altro player»."
            }
        }
    }

    deinit {
        watchdogTask?.cancel()
        recoveryTask?.cancel()
    }
}

extension KSPlaybackController: KSPlayerLayerDelegate {
    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        guard layer === self.layer else { return }
        self.state = state
        switch state {
        case .readyToPlay:
            markStarted()
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] = title.isEmpty ? "GassPlayer" : title
        case .bufferFinished:
            markStarted()
        case .playedToTheEnd:
            // Segna come completato (non cancella): la barra sulla
            // miniatura dell'episodio deve restare piena, non sparire.
            PlaybackPositionStore.markCompleted(for: currentURL, duration: duration)
        case .error:
            watchdogTask?.cancel()
        default:
            break
        }
    }

    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        guard layer === self.layer else { return }
        let durationChanged = totalTime != duration
        guard durationChanged || abs(currentTime - self.currentTime) >= 0.2 else { return }
        self.currentTime = currentTime
        self.duration = totalTime
        if totalTime > 0, Date().timeIntervalSince(lastPositionSave) > 15 {
            persistPosition()
        }
    }

    func player(layer: KSPlayerLayer, finish error: Error?) {
        guard layer === self.layer, let error else { return }
        handlePlaybackFailure(error.localizedDescription)
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {
        DebugLogger.logAsync(.info, "KSPlaybackController: buffer #\(bufferedCount) pronto in \(consumeTime)s")
    }
}
