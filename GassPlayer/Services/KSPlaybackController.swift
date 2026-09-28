import Foundation
import AVFoundation
import MediaPlayer
import KSPlayer

/// Bridge SwiftUI-friendly per KSPlayerLayer.
///
/// FIX 2026-09-28a: FFmpeg (`KSMEPlayer`) motore PRIMARIO globale,
/// fallback hardware -> software automatico su errore (vedi
/// `configureGlobalPlayerEngineIfNeeded()` e `player(layer:finish:)`).
///
/// FIX 2026-09-28c ("risorsa non disponibile" IDENTICO su hardware E
/// software, ripetuto in più sessioni):
///
/// A questo punto il pattern esclude con certezza un problema di
/// *codec/decodifica*: se fosse un codec che il decoder non capisce,
/// il tentativo software (FFmpeg puro, che decodifica letteralmente
/// tutto) sarebbe riuscito almeno ad APRIRE il contenitore e leggere
/// qualche fotogramma prima di eventualmente fermarsi. Un errore
/// generico e ISTANTANEO, identico in ogni condizione, significa che
/// nessuno dei due motori riesce nemmeno a stabilire la connessione al
/// file. Le cause più comuni con playlist IPTV sono:
///   • il server richiede header HTTP specifici (Referer/Origin) non
///     inviati di default da AVFoundation né da FFmpeg;
///   • il server usa un certificato TLS self-signed/non valido, che
///     entrambi i motori rifiutano per default;
///   • il link della playlist è scaduto/a uso singolo (comune con
///     provider Xtream-Codes: il token nell'URL può invalidarsi dopo un
///     primo utilizzo o dopo pochi minuti).
///
/// Questa versione: (1) aggiunge header e bypass TLS in ENTRAMBI i
/// dizionari di opzioni esposti da KSOptions (`avOptions` e
/// `formatContextOptions`) per massimizzare la compatibilità
/// indipendentemente da quale dei due venga effettivamente onorato
/// dalla versione di KSPlayer vendorizzata nel progetto; (2) cattura e
/// registra il vero `NSError` sottostante (domain/code/userInfo), non
/// solo `localizedDescription`, così un errore di rete non viene più
/// confuso con un errore di formato; (3) espone questo dettaglio anche
/// nel banner di errore mostrato in `PlayerView`, per diagnosi rapida
/// senza dover consultare i log.
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
    /// Dettaglio tecnico dell'ultimo errore (domain/code reali
    /// dell'NSError sottostante), separato da `lastError` (messaggio
    /// leggibile) per poterlo mostrare in piccolo nel banner senza
    /// appesantire il messaggio principale.
    @Published var lastErrorDetail: String?
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
    /// e mostrare l'errore all'utente. Questo flag evita loop infiniti.
    private var didAttemptSoftwareFallback = false

    /// Configurazione GLOBALE del motore di riproduzione: applicata una
    /// sola volta, vale per ogni `KSOptions`/`KSPlayerLayer` creato da
    /// questo momento in avanti nell'intera app.
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
    /// `PlaybackPreferences` correnti, massimizzando la compatibilità di
    /// rete oltre a quella di formato/codec.
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
        options.asynchronousDecompression = true

        let threadCount = min(ProcessInfo.processInfo.activeProcessorCount, 4)
        options.decoderOptions["threads"] = "\(threadCount)"

        // --- Robustezza di RETE (causa più probabile di "risorsa non
        // disponibile" identico su ogni motore/modalità) ---
        //
        // Le chiavi vengono scritte sia in `avOptions` sia in
        // `formatContextOptions`: le versioni di KSPlayer non sono
        // consistenti su quale dizionario venga effettivamente
        // propagato a libavformat, quindi duplicarle è l'unico modo
        // sicuro di garantire che vengano applicate senza dover
        // dipendere dalla versione esatta vendorizzata nel progetto.
        var networkOptions: [String: Any] = [
            // Molte playlist HLS referenziano segmenti/chiavi su
            // protocolli diversi (http/https/crypto per AES-128): senza
            // whitelist esplicita alcuni CDN vengono rifiutati con
            // "Protocol not found".
            "protocol_whitelist": "file,http,https,tcp,tls,crypto,hls,applehttp"
        ]
        if url.scheme == "http" || url.scheme == "https" {
            networkOptions["reconnect"] = 1
            networkOptions["reconnect_streamed"] = 1
            networkOptions["reconnect_at_eof"] = 1
            networkOptions["reconnect_delay_max"] = 2
            // Timeout di connessione/lettura (microsecondi): un server
            // IPTV lento a rispondere deve restituire un errore gestito
            // invece di bloccare indefinitamente l'apertura del flusso.
            networkOptions["timeout"] = 15_000_000
            networkOptions["rw_timeout"] = 15_000_000
            // Molti provider IPTV verificano l'header Referer/Origin e
            // rifiutano richieste "anonime": lo impostiamo sullo stesso
            // host del flusso, il comportamento più compatibile con la
            // maggior parte dei player IPTV (VLC/Kodi fanno lo stesso).
            if let host = url.host {
                let originValue = "\(url.scheme ?? "http")://\(host)/"
                networkOptions["headers"] = "Referer: \(originValue)\r\nOrigin: \(originValue)\r\n"
            }
        }
        if url.scheme == "https" {
            // Molti pannelli IPTV usano certificati self-signed o
            // scaduti sul proprio dominio: senza questo bypass, sia
            // AVFoundation sia FFmpeg rifiutano la connessione TLS con
            // un errore generico indistinguibile da un link morto.
            // Compromesso di sicurezza accettato consapevolmente per
            // massimizzare la compatibilità con provider IPTV reali.
            networkOptions["tls_verify"] = "0"
        }
        for (key, value) in networkOptions {
            options.avOptions[key] = value
            options.formatContextOptions[key] = value
        }

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
        lastErrorDetail = nil
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
        lastErrorDetail = nil
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

    /// Estrae domain/code/userInfo reali dall'errore, scavando anche
    /// nell'`NSUnderlyingErrorKey` se presente (comune quando
    /// AVFoundation avvolge un errore di rete/POSIX più specifico).
    /// Questo è il dettaglio che rende possibile capire SE il problema
    /// è di rete (es. NSURLErrorDomain -1004 "impossibile connettersi
    /// al server", -1202 certificato non valido) o realmente altro,
    /// invece di fermarsi al testo generico "risorsa non disponibile".
    private static func technicalDetail(for error: Error) -> String {
        let nsError = error as NSError
        var parts = ["domain=\(nsError.domain)", "code=\(nsError.code)"]
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying=\(underlying.domain)#\(underlying.code) \(underlying.localizedDescription)")
        }
        if let failureReason = nsError.localizedFailureReason {
            parts.append("reason=\(failureReason)")
        }
        return parts.joined(separator: " · ")
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
    /// 1) Se `hardwareDecode` è attivo, tenta UNA volta la decodifica
    ///    100% software prima di arrendersi (copre i codec che
    ///    VideoToolbox non decodifica in hardware, es. MPEG-4 ASP).
    /// 2) Se l'errore persiste identico anche in software, il problema
    ///    NON è di codec: viene mostrato il messaggio reale più il
    ///    dettaglio tecnico (`technicalDetail`), per distinguere un
    ///    problema di rete/URL da un problema di formato senza dover
    ///    aprire i log.
    func player(layer: KSPlayerLayer, finish error: Error?) {
        guard let error else { return }
        let description = error.localizedDescription
        let detail = Self.technicalDetail(for: error)
        DebugLogger.logAsync(.error, "KSPlaybackController: riproduzione terminata con errore: \(description) [\(detail)]")

        if preferences.hardwareDecode, !didAttemptSoftwareFallback {
            didAttemptSoftwareFallback = true
            DebugLogger.logAsync(.warning, "KSPlaybackController: errore con decodifica hardware, ritento in software (FFmpeg) prima di arrendermi")
            preferences.hardwareDecode = false
            reload()
            return
        }

        lastError = description
        lastErrorDetail = detail
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {
        DebugLogger.logAsync(.info, "KSPlaybackController: buffer #\(bufferedCount) pronto in \(consumeTime)s")
    }
}
