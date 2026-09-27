import Foundation
import AVFoundation
import MediaPlayer
import KSPlayer

/// Bridge SwiftUI-friendly per KSPlayerLayer.
///
/// FIX 2026-09-28 (compatibilità "TUTTI I FORMATI" + errore
/// `mpeg4 (Advanced Simple Profile) yuv420p 720x304`):
///
/// Il problema riportato NON è un bug di rete o di buffering: è un
/// problema di *scelta del motore di decodifica*. `KSAVPlayer` (basato
/// su `AVFoundation`/`VideoToolbox`, il motore nativo Apple "Metal") non
/// supporta affatto il profilo MPEG-4 ASP (Xvid-style) — Apple supporta
/// solo H.264/H.265/(alcuni) MPEG-4 Simple Profile via hardware. Con le
/// impostazioni precedenti, `KSAVPlayer` veniva provato per primo
/// (default di libreria), falliva su questo codec, e il fallback verso
/// `KSMEPlayer` (FFmpeg) non compensava perché la decodifica *hardware*
/// (`VideoToolbox`) veniva comunque tentata anche dentro FFmpeg
/// (`hardwareDecode = true`), fallendo di nuovo per lo stesso motivo:
/// VideoToolbox non ha un decoder hardware per MPEG-4 ASP su nessun
/// dispositivo Apple. Il flusso non ha mai raggiunto il decoder
/// **software** FFmpeg (libavcodec), che invece supporta letteralmente
/// qualsiasi codec/contenitore esistente (mpeg4, h263, vc1, wmv, vp6,
/// flv1, rv40, ecc.).
///
/// Soluzione implementata:
/// 1) `KSMEPlayer` (motore FFmpeg) diventa il player PRIMARIO globale
///    (`KSOptions.firstPlayerType`). `KSAVPlayer` (motore nativo,
///    accelerazione hardware "Metal"/VideoToolbox) diventa il
///    FALLBACK secondario (`KSOptions.secondPlayerType`), usato solo se
///    FFmpeg stesso non riesce ad aprire il contenitore (praticamente
///    mai, dato che FFmpeg decodifica tutto).
/// 2) Fallback automatico hardware -> software SENZA intervento
///    dell'utente: se la pipeline va in errore con `hardwareDecode`
///    attivo, il controller disattiva la decodifica hardware e ricarica
///    UNA volta in automatico prima di mostrare qualsiasi errore. Questo
///    risolve esattamente il caso "Codec: mpeg4 (Advanced Simple
///    Profile), yuv420p, 720x304": il primo tentativo (hardware) fallisce
///    silenziosamente e il secondo tentativo (software, FFmpeg puro)
///    riesce, perché libavcodec ha un decoder mpeg4/xvid nativo che non
///    dipende da alcun chip di accelerazione.
/// 3) Tuning di latenza: buffer di partenza minimi, decodifica
///    multi-thread per il fallback software, flag FFmpeg "low delay"
///    per non introdurre ritardo di analisi/bufferizzazione aggiuntivo,
///    così anche il motore software resta fluido e senza percepibile
///    ritardo all'avvio o allo zapping.
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
        var preferredForwardBufferDuration: Double = 2
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
    /// se anche il tentativo software fallisce, il formato/contenitore è
    /// realmente non apribile (file corrotto, URL morto) e l'errore
    /// viene mostrato normalmente.
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
        // Log una sola volta per confermare in debug quale pipeline è attiva.
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
    /// all'avvio e allo zapping.
    private static func buildLayer(for url: URL, preferences: PlaybackPreferences) -> KSPlayerLayer {
        let options = KSOptions()

        // --- Buffering: minimo indispensabile, non un secondo di più ---
        // Un buffer di partenza ridotto significa che il primo fotogramma
        // arriva prima. `maxBufferDuration` resta più ampio per assorbire
        // reti IPTV instabili senza reintrodurre latenza percepita
        // all'avvio (si riempie in background dopo che si è già in play).
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
        // scelta manuale), usa tutti i core disponibili (fino a 4) per
        // evitare che il software decode diventi il collo di bottiglia
        // su risoluzioni elevate.
        options.videoSoftDecodeThreadCount = min(ProcessInfo.processInfo.activeProcessorCount, 4)

        // --- Riduzione latenza a livello FFmpeg (demux/decode) ---
        // `nobuffer`: non accumulare pacchetti extra prima di restituirli
        // al decoder. `low_delay`: disattiva l'analisi che introduce
        // ritardo strutturale nei codec che la supportano (utile su MPEG
        // e H.264/H.265 in streaming live).
        options.formatContextOptions["fflags"] = "nobuffer"
        options.formatContextOptions["flags"] = "low_delay"
        // Analisi iniziale del flusso più rapida: individua i codec senza
        // scansionare secondi di dati prima di iniziare a decodificare.
        options.formatContextOptions["analyzeduration"] = 500_000 // microsecondi
        options.formatContextOptions["probesize"] = 500_000 // byte
        // Riconnessione automatica sui flussi HTTP/HLS IPTV che cadono
        // per un istante: evita che un singolo timeout diventi un errore
        // fatale mostrato all'utente.
        options.formatContextOptions["reconnect"] = 1
        options.formatContextOptions["reconnect_streamed"] = 1
        options.formatContextOptions["reconnect_delay_max"] = 2

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

    /// FIX PRINCIPALE per l'errore "Codec: mpeg4 (Advanced Simple
    /// Profile), yuv420p, 720x304" e qualunque altro codec che
    /// VideoToolbox non sa decodificare in hardware: se il flusso va in
    /// errore mentre `hardwareDecode` è attivo, NON mostriamo subito
    /// l'errore all'utente. Disattiviamo la decodifica hardware (forzando
    /// FFmpeg a decodificare in software, via libavcodec, che supporta
    /// il codec) e ricarichiamo lo stesso URL UNA sola volta. Solo se
    /// anche il tentativo software fallisce, l'errore viene propagato
    /// davvero: a quel punto il problema non è più il codec ma il file/
    /// URL stesso.
    func player(layer: KSPlayerLayer, finish error: Error?) {
        guard let error else { return }
        DebugLogger.logAsync(.error, "KSPlaybackController: riproduzione terminata con errore: \(error.localizedDescription)")

        if preferences.hardwareDecode, !didAttemptSoftwareFallback {
            didAttemptSoftwareFallback = true
            DebugLogger.logAsync(.warning, "KSPlaybackController: errore con decodifica hardware, ritento in software (FFmpeg) prima di arrendermi")
            preferences.hardwareDecode = false
            reload()
            return
        }

        lastError = "Impossibile riprodurre il flusso. Il server potrebbe non essere raggiungibile o il formato non è supportato nemmeno in decodifica software."
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {
        DebugLogger.logAsync(.info, "KSPlaybackController: buffer #\(bufferedCount) pronto in \(consumeTime)s")
    }
}
