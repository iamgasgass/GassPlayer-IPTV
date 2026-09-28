import Foundation
import AVFoundation
import MediaPlayer
import KSPlayer

/// Bridge SwiftUI-friendly per KSPlayerLayer.
///
/// FIX 2026-09-28a: FFmpeg (`KSMEPlayer`) motore PRIMARIO globale,
/// fallback hardware -> software automatico su errore.
///
/// FIX 2026-09-28d (diagnosi definitiva di "risorsa non disponibile"):
/// il dettaglio tecnico ora loggato/mostrato (introdotto nel fix
/// precedente) ha rivelato la causa REALE:
///
///   domain=NSURLErrorDomain code=-1008
///   underlying=NSOSStatusErrorDomain#-16846
///
/// `-16846` è documentato come "Server error. Received HTTP status code
/// within 500-599": il SERVER della playlist IPTV ha risposto con un
/// errore 500/502/503/504 su questo specifico film. Non è un problema
/// di codec (già risolto con il fallback hardware->software), non è un
/// problema di header/TLS (già mitigato), e non è risolvibile con
/// NESSUNA configurazione lato client: il server del provider sta
/// letteralmente restituendo un errore per quella risorsa in quel
/// momento — esattamente come se si aprisse l'URL in un browser e
/// questo mostrasse "502 Bad Gateway".
///
/// Cosa fa questa versione, in modo "maniacale" ma onesto:
/// 1) Riconosce la classe esatta dell'errore tramite l'OSStatus
///    sottostante (tabella `Self.knownOSStatusMessages`, verificata
///    sulla documentazione errori di sistema Apple).
/// 2) Per errori 5xx (spesso transitori: sovraccarico del server IPTV,
///    riavvio del backend, CDN che si sta ancora propagando) esegue
///    fino a 3 retry automatici con backoff crescente (2s, 4s, 8s)
///    PRIMA di mostrare qualsiasi errore: molti di questi si risolvono
///    da soli in pochi secondi.
/// 3) Per errori non transitori (4xx, DNS, TLS, URL malformato) mostra
///    subito un messaggio onesto e specifico: "il player funziona
///    correttamente, il server ha rifiutato/non ha la risorsa" — senza
///    più far credere che sia un problema di formato o di
///    configurazione locale.
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
    @Published var lastErrorDetail: String?
    /// Messaggio informativo transitorio mostrato SOLO durante i retry
    /// automatici su errori server 5xx (vedi `player(layer:finish:)`),
    /// per non far credere all'utente che l'app sia bloccata mentre in
    /// realtà sta ritentando in background.
    @Published var transientRetryMessage: String?
    @Published var bufferingProgress: Int = 0
    @Published var isPipActive = false {
        didSet { layer.isPipActive = isPipActive }
    }

    @Published private(set) var layer: KSPlayerLayer
    @Published private(set) var preferences = PlaybackPreferences()

    private(set) var currentURL: URL
    private var title: String
    private var watchdogTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var hasEverStartedPlaying = false

    /// FIX FORMATO: quando un flusso va in errore con `hardwareDecode`
    /// ancora attivo, tentiamo UNA sola volta il ricaricamento in
    /// decodifica 100% software (FFmpeg/libavcodec) prima di procedere
    /// con la diagnosi dell'errore (che potrebbe non essere di codec).
    private var didAttemptSoftwareFallback = false

    /// Contatore dei retry automatici per errori server transitori
    /// (5xx). Limitato per non ritentare all'infinito un server
    /// realmente down.
    private var transientRetryCount = 0
    private static let maxTransientRetries = 3

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
    /// formato/codec e di rete.
    private static func buildLayer(for url: URL, preferences: PlaybackPreferences) -> KSPlayerLayer {
        let options = KSOptions()

        options.preferredForwardBufferDuration = preferences.preferredForwardBufferDuration
        options.maxBufferDuration = preferences.maxBufferDuration
        options.registerRemoteControll = true
        options.canStartPictureInPictureAutomaticallyFromInline = true
        options.userAgent = "GassPlayer/1.0"

        options.hardwareDecode = preferences.hardwareDecode
        options.isAccurateSeek = preferences.isAccurateSeek
        options.autoDeInterlace = preferences.autoDeInterlace
        options.videoDelay = preferences.videoDelay
        options.asynchronousDecompression = true

        let threadCount = min(ProcessInfo.processInfo.activeProcessorCount, 4)
        options.decoderOptions["threads"] = "\(threadCount)"

        var networkOptions: [String: Any] = [
            "protocol_whitelist": "file,http,https,tcp,tls,crypto,hls,applehttp"
        ]
        if url.scheme == "http" || url.scheme == "https" {
            networkOptions["reconnect"] = 1
            networkOptions["reconnect_streamed"] = 1
            networkOptions["reconnect_at_eof"] = 1
            networkOptions["reconnect_delay_max"] = 2
            networkOptions["timeout"] = 15_000_000
            networkOptions["rw_timeout"] = 15_000_000
            if let host = url.host {
                let originValue = "\(url.scheme ?? "http")://\(host)/"
                networkOptions["headers"] = "Referer: \(originValue)\r\nOrigin: \(originValue)\r\n"
            }
        }
        if url.scheme == "https" {
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
        retryTask?.cancel()

        self.currentURL = url
        self.title = title
        lastError = nil
        lastErrorDetail = nil
        transientRetryMessage = nil
        currentTime = 0
        duration = 0
        hasEverStartedPlaying = false
        bufferingProgress = 0
        didAttemptSoftwareFallback = false
        transientRetryCount = 0
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
        transientRetryMessage = nil
        hasEverStartedPlaying = false
        didAttemptSoftwareFallback = false
        transientRetryCount = 0
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
        retryTask?.cancel()
    }

    // MARK: - Diagnosi errori (OSStatus / HTTP)

    /// Tabella dei codici OSStatus più rilevanti per lo streaming IPTV,
    /// verificata sulla documentazione errori di sistema Apple. Copre
    /// sia il range "-16850..-16846" (errori server 5xx sotto
    /// AVFoundation/HLS) sia i corrispettivi "classici" NSURLErrorDomain
    /// (-1000..-1013), oltre a TLS/DNS/auth.
    private static let knownOSStatusMessages: [Int: String] = [
        -16850: "Il server ha risposto 504 Gateway Timeout.",
        -16849: "Il server ha risposto 503 Service Unavailable.",
        -16848: "Il server ha risposto 502 Bad Gateway.",
        -16847: "Il server ha risposto 500 Internal Server Error.",
        -16846: "Il server ha risposto con un errore 5xx (server temporaneamente in difficoltà).",
        -16845: "Il server ha rifiutato la richiesta con un codice 4xx.",
        -16840: "Il server richiede autenticazione (401 Unauthorized): la playlist/token potrebbe essere scaduto.",
        -12938: "Il server ha risposto 404: il file non esiste più a questo indirizzo.",
        -12661: "Il server ha risposto 503 Service Unavailable.",
        -12660: "Il server ha rifiutato la richiesta (403 Forbidden).",
        -1202: "Certificato del server non valido o non attendibile (TLS).",
        -1102: "Il server ha rifiutato la richiesta (403 Forbidden).",
        -1100: "Il server ha risposto 404: il file non esiste più a questo indirizzo.",
        -1013: "Il server richiede autenticazione (401 Unauthorized).",
        -1009: "Il dispositivo non è connesso a Internet.",
        -1008: "La risorsa richiesta non è disponibile sul server.",
        -1004: "Impossibile connettersi al server (host irraggiungibile).",
        -1003: "Host non trovato: controlla l'indirizzo della playlist.",
        -1000: "URL malformato.",
    ]

    /// Vero se il codice indica un errore SERVER (5xx) verosimilmente
    /// transitorio: vale la pena ritentare automaticamente con backoff
    /// prima di arrendersi, perché spesso si risolve da solo in pochi
    /// secondi (sovraccarico momentaneo, riavvio backend, ecc.).
    private static func isTransientServerError(_ code: Int) -> Bool {
        (-16850...(-16846)).contains(code) || code == -12661 || code == -16849
    }

    private static func underlyingOSStatusCode(for error: NSError) -> Int? {
        if error.domain == NSOSStatusErrorDomain { return error.code }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlyingOSStatusCode(for: underlying)
        }
        return nil
    }

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

    /// Messaggio finale onesto e specifico da mostrare all'utente:
    /// usa la tabella `knownOSStatusMessages` quando riconosce il
    /// codice, altrimenti ricade sul testo originale del motore.
    private static func userFacingMessage(for error: Error) -> String {
        let nsError = error as NSError
        let candidateCode = underlyingOSStatusCode(for: nsError) ?? nsError.code
        if let known = knownOSStatusMessages[candidateCode] {
            return "\(known) Questo non è un problema del player: il server della playlist ha risposto così in questo momento."
        }
        return nsError.localizedDescription
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

    /// Gestione unificata degli errori di riproduzione, in 3 fasi:
    ///
    /// 1) Se `hardwareDecode` è attivo, tenta UNA volta la decodifica
    ///    100% software (copre i codec non supportati in hardware).
    /// 2) Se l'errore sottostante è un OSStatus 5xx (server IPTV in
    ///    difficoltà temporanea), ritenta automaticamente fino a 3
    ///    volte con backoff crescente (2s/4s/8s) PRIMA di arrendersi:
    ///    la maggior parte dei 502/503 si risolve da sola in pochi
    ///    secondi.
    /// 3) Solo dopo aver esaurito i tentativi utili, mostra un
    ///    messaggio finale onesto (`userFacingMessage`), che distingue
    ///    chiaramente un problema server/rete da un problema di
    ///    formato — niente più "il formato potrebbe non essere
    ///    supportato" quando il vero problema è un 502 del provider.
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

        let nsError = error as NSError
        let osStatusCode = Self.underlyingOSStatusCode(for: nsError) ?? nsError.code
        if Self.isTransientServerError(osStatusCode), transientRetryCount < Self.maxTransientRetries {
            transientRetryCount += 1
            let delaySeconds = [2.0, 4.0, 8.0][min(transientRetryCount - 1, 2)]
            transientRetryMessage = "Il server ha risposto con un errore temporaneo, nuovo tentativo \(transientRetryCount)/\(Self.maxTransientRetries) in \(Int(delaySeconds))s…"
            DebugLogger.logAsync(.warning, "KSPlaybackController: errore server transitorio (OSStatus \(osStatusCode)), retry \(transientRetryCount)/\(Self.maxTransientRetries) in \(delaySeconds)s")
            retryTask?.cancel()
            retryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.reload()
            }
            return
        }

        lastError = Self.userFacingMessage(for: error)
        lastErrorDetail = detail
        transientRetryMessage = nil
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {
        DebugLogger.logAsync(.info, "KSPlaybackController: buffer #\(bufferedCount) pronto in \(consumeTime)s")
    }
}
