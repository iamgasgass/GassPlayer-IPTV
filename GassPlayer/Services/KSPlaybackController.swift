import Foundation
import AVFoundation
import MediaPlayer
import KSPlayer

/// Bridge SwiftUI-friendly per KSPlayerLayer, ora l'UNICO motore di
/// riproduzione dell'app (AVPlayer nativo + FFmpeg via KSMEPlayer, con
/// switch automatico gestito da KSPlayerLayer.finish(player:error:), che
/// ritenta con KSOptions.secondPlayerType su qualunque errore prima di
/// arrendersi — a patto che `secondPlayerType` sia stato impostato
/// esplicitamente, cosa che questo file ora fa in
/// `configureEngineFallback`, vedi lì per i dettagli).
///
/// FIX 2026-09-25 (zapping canale/episodio "senza uscire e riaprire il
/// player"): in precedenza ogni pressione di precedente/successivo
/// forzava, lato chiamante (`ChannelGridView`/`SeriesEpisodesView`), un
/// `.id(stream.id)` sulla vista del player: necessario perché
/// `KSPlaybackController` veniva creato una sola volta in `init` e non
/// aveva alcun modo di caricare un URL diverso in seguito — l'unico modo
/// per "cambiare canale" era distruggere e ricreare l'intera
/// `PlayerView` (e quindi anche il `KSPlayerContainerView`/`UIView`
/// sottostante). Il risultato era funzionalmente corretto ma percepito
/// come "chiusura e riapertura" del player: un breve nero, reset dei
/// controlli, nuova `fullScreenCover` dal punto di vista di UIKit.
///
/// `layer` è ora `@Published` (non più `let`): `load(url:title:)` crea un
/// nuovo `KSPlayerLayer` per il nuovo URL e lo assegna a questa stessa
/// istanza di `KSPlaybackController`, che resta viva per tutta la sessione
/// di visione. `PlayerView` (che possiede il controller come
/// `@StateObject`) non viene mai ricreata: `KSPlayerContainerView`
/// (vedi PlayerView.swift) osserva il cambio di `layer` e si limita a
/// staccare la vecchia `UIView` del player e agganciare la nuova nello
/// stesso container già presente a schermo — nessuna nuova
/// presentazione, nessun reset di stato (blocco schermo, timer di
/// spegnimento, ecc.), transizione fluida.
///
/// FIX 2026-09-28 (crash di compilazione "value of type 'KSOptions' has
/// no member 'videoSoftDecodeThreadCount'"): `videoSoftDecodeThreadCount`
/// esiste solo in alcuni fork/versioni più recenti di KSPlayer, NON nella
/// build effettivamente risolta da questo progetto (stesso identico
/// problema già visto con `subtitleDisable`, vedi sotto). È stata
/// sostituita con `KSOptions.decoderOptions["threads"]`: proprietà
/// **sempre presente** in ogni versione di KSPlayer perché è un semplice
/// dizionario `[String: Any]` che il motore passa pari pari alle
/// AVOptions del decoder FFmpeg sottostante — lo stesso identico
/// risultato pratico (limitare/parallelizzare i thread di decodifica
/// software), ma senza dipendere da un'API che nella tua build non
/// esiste. Aggiunte anche `formatContextOptions` per la riconnessione
/// automatica dei flussi di rete (fondamentale per IPTV/Xtream), vedi
/// `buildLayer` per i dettagli — nessuna funzionalità perduta, solo
/// implementata con l'API realmente disponibile.
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
    /// primo avvio sia ad ogni cambio canale/episodio: senza questo,
    /// zappare canale avrebbe azzerato silenziosamente tutte le
    /// preferenze scelte dall'utente per la sessione corrente.
    struct PlaybackPreferences {
        var preferredForwardBufferDuration: Double = 5
        var maxBufferDuration: Double = 30
        /// `KSOptions.hardwareDecode`: decodifica hardware (VideoToolbox)
        /// vs software (FFmpeg puro). Utile per aggirare flussi H.264/
        /// H.265 malformati che il decoder hardware rifiuta ma FFmpeg in
        /// software riesce comunque a decodificare.
        ///
        /// NOTA COMPATIBILITÀ FORMATI: per codec che VideoToolbox non
        /// supporta affatto su iOS (es. MPEG-4 Part 2 "Advanced Simple
        /// Profile", H.263, MPEG-1/2, VP8/VP9, ecc.) questo toggle è
        /// irrilevante lato utente — KSMEPlayer (il motore FFmpeg, vedi
        /// `configureEngineFallback`) individua da solo l'assenza di un
        /// decoder hardware per quel codec e usa comunque la pipeline
        /// software, indipendentemente dal valore qui impostato. Il
        /// toggle ha effetto reale solo sui codec che HANNO un percorso
        /// hardware (H.264/HEVC) e che si vuole forzare in software per
        /// aggirare flussi malformati.
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
        /// `VideoGravityMode`). A differenza di decodifica/
        /// de-interlacciamento, questa si applica al volo (proprietà
        /// della vista di rendering, non della pipeline FFmpeg) e viene
        /// comunque riportata qui perché deve sopravvivere allo zapping
        /// canale/episodio (`load(url:title:)` ricrea il layer da zero).
        var videoGravity: VideoGravityMode = .fit
        // FIX 2026-09-27 (crash di compilazione "value of type 'KSOptions'
        // has no member 'subtitleDisable'"): la build del KSPlayer
        // effettivamente compilata con il progetto NON espone
        // `KSOptions.subtitleDisable` (proprietà assente/rinominata in
        // questa versione del pacchetto). La feature "disattiva
        // sottotitoli a livello di decodifica" è stata quindi rimossa
        // per intero — proprietà nelle preferenze, assegnazione a
        // `options` in `buildLayer` e setter pubblico — invece di
        // lasciare in giro codice morto che punta a un'API inesistente.
        // Chi vuole nascondere i sottotitoli può comunque farlo dal
        // menu "Audio e sottotitoli" deselezionando la traccia attiva
        // (`select(track:)` più sotto): nessuna funzionalità visibile
        // all'utente viene persa, solo la scorciatoia a livello
        // FFmpeg che richiedeva un rebuild della pipeline.
        /// `KSOptions.autoSelectEmbedSubtitle`: seleziona automaticamente la
        /// prima traccia sottotitoli incorporata nel flusso quando presente
        /// (default `true` in KSPlayer). Se disattivato, nessun sottotitolo
        /// parte finché non lo si sceglie esplicitamente da "Audio e
        /// sottotitoli".
        var autoSelectEmbedSubtitle: Bool = true
        /// `KSOptions.videoDisable`: disattiva la decodifica video e
        /// riproduce solo l'audio. Pensato per i canali radio delle
        /// playlist Xtream/M3U (spesso un flusso video nero/statico
        /// abbinato all'audio): decodificare comunque il video sprecherebbe
        /// CPU/GPU e batteria senza alcun beneficio per l'utente.
        var videoDisable: Bool = false
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

    /// OTTIMIZZAZIONE FLUIDITÀ: KSPlayer invoca il delegate di avanzamento
    /// molto più spesso di quanto la UI necessiti per apparire fluida
    /// (spesso più volte al secondo). Senza throttling, ogni singolo tick
    /// pubblica una modifica su `currentTime` che rivaluta l'intera
    /// `PlayerView.body` — pulsanti Liquid Glass inclusi — molte più volte
    /// al secondo di quanto un occhio umano possa percepire, sprecando CPU/
    /// GPU e potendo introdurre micro-scatti. Pubblichiamo un aggiornamento
    /// solo se la variazione percepita è reale (>= 200ms) o se la durata
    /// totale è cambiata (es. aggiornamento del DVR live).
    private var lastPublishedTime: TimeInterval = -1

    var isPlaying: Bool { state.isPlaying }
    var isBuffering: Bool { state == .preparing || state == .buffering }

    var supportsPictureInPicture: Bool {
        if #available(iOS 14.0, tvOS 14.0, *) {
            return layer.player.pipController != nil
        }
        return false
    }

    /// FIX CRITICO COMPATIBILITÀ FORMATI: KSPlayer prova `firstPlayerType`
    /// (`KSAVPlayer`, il motore nativo AVFoundation — veloce ma limitato ai
    /// formati che Apple supporta: H.264/HEVC, HLS, MP4/MOV, non MKV, non
    /// molti codec audio/video usati dai flussi Xtream/IPTV — e in
    /// particolare NON MPEG-4 Part 2 "Advanced Simple Profile", codec
    /// dell'esempio yuv420p/720x304 tipico dei flussi IPTV più datati) e,
    /// SOLO SE `KSOptions.secondPlayerType` è stato impostato
    /// esplicitamente, ripiega in automatico su `KSMEPlayer` (il motore
    /// FFmpeg puro, che demuxa/decodifica letteralmente ogni formato che
    /// l'app dichiara di supportare — MKV, AVI, TS/M2TS, MPEG-4 ASP,
    /// H.263, MPEG-1/2, VP6/7/8/9, tutti i codec audio FFmpeg, ecc.).
    /// Questa riga NON è un dettaglio opzionale: è il passo di
    /// inizializzazione che la documentazione ufficiale di KSPlayer elenca
    /// per primo in OGNI esempio d'uso, e senza di essa `secondPlayerType`
    /// resta `nil` — nessun fallback, nessun secondo tentativo, un flusso
    /// che AVPlayer rifiuta fallisce e basta, indipendentemente da quanto
    /// FFmpeg/KSMEPlayer sarebbe stato in grado di decodificarlo.
    /// `static let` eseguito una sola volta, prima che qualunque
    /// `KSPlayerLayer` venga creato.
    private static let configureEngineFallback: Void = {
        KSOptions.firstPlayerType = KSAVPlayer.self
        KSOptions.secondPlayerType = KSMEPlayer.self
    }()

    init(url: URL, title: String) {
        _ = Self.configureEngineFallback
        self.currentURL = url
        self.title = title
        self.layer = Self.buildLayer(for: url, preferences: PlaybackPreferences())
        super.init()
        layer.delegate = self
        startWatchdog()
    }

    /// Costruisce un nuovo `KSPlayerLayer` con le opzioni derivate dalle
    /// `PlaybackPreferences` correnti. Metodo `static` (non di istanza)
    /// perché deve poter essere chiamato anche dall'`init`, prima che
    /// `super.init()` completi (Swift non permette di chiamare metodi di
    /// istanza su `self` prima di quel punto).
    private static func buildLayer(for url: URL, preferences: PlaybackPreferences) -> KSPlayerLayer {
        _ = configureEngineFallback

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
        // RIMOSSO: `options.subtitleDisable = preferences.subtitleDisable`.
        // `KSOptions` (versione compilata con questo progetto) non ha il
        // membro `subtitleDisable`: era la causa dell'errore di build
        // "value of type 'KSOptions' has no member 'subtitleDisable'".
        options.autoSelectEmbedSubtitle = preferences.autoSelectEmbedSubtitle
        options.videoDisable = preferences.videoDisable
        // Correttezza sempre attiva (non richiede un'impostazione utente):
        // rispetta la rotazione video incorporata nel flusso (metadati
        // "rotate", comuni su registrazioni da smartphone ridistribuite via
        // IPTV) e permette il cambio automatico di bitrate su sorgenti
        // adattive (HLS multi-stream), esattamente come da documentazione
        // ufficiale KSPlayer.
        options.autoRotate = true
        options.videoAdaptable = true

        // FIX 2026-09-28 (crash di compilazione "value of type 'KSOptions'
        // has no member 'videoSoftDecodeThreadCount'"): quella proprietà
        // non esiste nella build di KSPlayer usata da questo progetto
        // (esiste solo in alcuni fork più recenti). L'equivalente
        // universale — presente in QUALSIASI versione di KSPlayer perché
        // è un semplice dizionario passato pari pari alle AVOptions del
        // decoder FFmpeg — è `decoderOptions["threads"]`. Usiamo
        // `activeProcessorCount - 1` per lasciare un core libero alla UI/
        // rendering, con un minimo di 2 thread per non penalizzare la
        // decodifica software di flussi pesanti (MPEG-4 ASP, H.263,
        // MPEG-2, VP8/9, ecc. — tutti i codec che KSMEPlayer decodifica
        // esclusivamente via FFmpeg, senza alcun percorso hardware
        // disponibile su iOS).
        let coreCount = ProcessInfo.processInfo.activeProcessorCount
        let softDecodeThreadCount = max(2, coreCount - 1)
        options.decoderOptions["threads"] = "\(softDecodeThreadCount)"

        // COMPATIBILITÀ FLUSSI DI RETE (IPTV/Xtream): FFmpeg non ritenta
        // automaticamente la connessione se il server droppa momentaneamente
        // lo stream (comune su liste IPTV instabili). Queste opzioni,
        // passate al demuxer via `formatContextOptions` (dizionario sempre
        // presente in KSOptions, analogo a `decoderOptions` ma per il
        // contesto di formato/rete invece che per il singolo decoder),
        // abilitano la riconnessione automatica lato FFmpeg senza dover
        // rifare da zero `load(url:)` lato Swift.
        options.formatContextOptions["reconnect"] = 1
        options.formatContextOptions["reconnect_streamed"] = 1
        options.formatContextOptions["reconnect_delay_max"] = 5

        let layer = KSPlayerLayer(url: url, isAutoPlay: true, options: options, delegate: nil)
        layer.player.contentMode = preferences.videoGravity.contentMode
        return layer
    }

    /// FEATURE MANCANTE aggiunta (precedente/successivo "in-place"): carica
    /// un nuovo URL SENZA che `PlayerView` venga mai distrutta/ricreata.
    /// Il vecchio layer viene fermato e scollegato (evita che il suo
    /// delegate continui a pubblicare eventi di un flusso che non è più
    /// quello mostrato), un nuovo `KSPlayerLayer` viene creato per il
    /// nuovo URL riapplicando le preferenze correnti, e tutto lo stato di
    /// avanzamento/errore viene azzerato per il nuovo contenuto.
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
        state = .initialized

        let newLayer = Self.buildLayer(for: url, preferences: preferences)
        layer = newLayer
        layer.delegate = self
        // BUG FIX ("il flusso non parte automaticamente" dopo prec/succ):
        // `isAutoPlay: true` passato a `KSPlayerLayer.init` in
        // `buildLayer` presuppone che la vista del player sia già
        // agganciata a una window quando l'auto-play interno scatta.
        // Qui invece il layer viene creato PRIMA che
        // `KSPlayerContainerView.updateUIView` (SwiftUI, prossimo ciclo
        // di render) stacchi la vecchia UIView e agganci quella nuova:
        // in quella finestra temporale l'auto-play interno può non
        // avere effetto. Chiamare `play()` esplicitamente qui è
        // ridondante se l'auto-play interno ha già funzionato (play() su
        // un player già in play è un no-op sicuro) ma GARANTISCE
        // l'avvio quando non ha funzionato — nessuna dipendenza dal
        // timing di SwiftUI.
        layer.play()
        startWatchdog()
    }

    /// Ricarica lo stream corrente (stesso URL) con le `preferences`
    /// aggiornate: necessario per le impostazioni che agiscono a livello
    /// di decodifica (hardware/software, de-interlacciamento), che
    /// KSPlayer legge solo alla creazione della pipeline e non possono
    /// essere cambiate "a caldo" su un flusso già in riproduzione.
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
        // BUG FIX: su flussi live (duration == 0) il vecchio codice calcolava
        // un limite superiore pari a `.greatestFiniteMagnitude`, producendo
        // un seek non valido/indefinito verso un tempo che lo stream non ha
        // mai avuto. Senza una durata nota, lo skip è semplicemente un
        // no-op: la UI (PlayerView) non mostra nemmeno i pulsanti di skip
        // in questo caso, ma la protezione resta anche qui a livello di
        // controller per qualunque altro chiamante futuro.
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
    //
    // Le impostazioni "live" si applicano immediatamente sul flusso in
    // riproduzione, scrivendo direttamente su `layer.options` (letto in
    // continuo dal motore di rendering/seek). Le impostazioni di
    // decodifica richiedono invece che la pipeline FFmpeg/AVPlayer venga
    // ricreata da zero per avere effetto: per queste, `reload()` è
    // l'unico modo corretto di applicarle davvero, non un dettaglio
    // implementativo rimandabile.

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

    /// A differenza di `setHardwareDecode`/`setAutoDeInterlace`, non
    /// richiede `reload()`: `contentMode` è letto ad ogni frame renderizzato
    /// dalla vista del player (sia motore AVPlayer sia FFmpeg), quindi il
    /// cambiamento è visibile all'istante sul fotogramma corrente.
    func setVideoGravity(_ mode: VideoGravityMode) {
        preferences.videoGravity = mode
        layer.player.contentMode = mode.contentMode
    }

    func setHardwareDecode(_ enabled: Bool) {
        preferences.hardwareDecode = enabled
        reload()
    }

    func setAutoDeInterlace(_ enabled: Bool) {
        preferences.autoDeInterlace = enabled
        reload()
    }

    // RIMOSSO: `setSubtitleDisable(_:)`. Dipendeva esclusivamente da
    // `KSOptions.subtitleDisable`, membro non presente nella build di
    // KSPlayer usata da questo progetto. Se il tuo `AdvancedSettingsView`
    // ha un toggle collegato a questo metodo o a `preferences.subtitleDisable`,
    // va rimosso anche lì (condividi il file e te lo aggiorno).

    func setAutoSelectEmbedSubtitle(_ enabled: Bool) {
        preferences.autoSelectEmbedSubtitle = enabled
        reload()
    }

    func setVideoDisable(_ enabled: Bool) {
        preferences.videoDisable = enabled
        reload()
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            // OTTIMIZZAZIONE "rapido e fluido": ridotto da 12s a 7s.
            // 12s di schermo nero prima che il watchdog ritenti sono
            // percepiti dall'utente come "il player si è bloccato",
            // esattamente il contrario di "cambio canale rapido e
            // fluido" richiesto. 7s è comunque abbastanza da non
            // scambiare per errore un server IPTV lento a rispondere
            // per un flusso morto.
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
            lastError = "Impossibile riprodurre il flusso. Il server potrebbe non essere raggiungibile o il formato non e' supportato."
            watchdogTask?.cancel()
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
            lastError = error.localizedDescription
        }
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {
        DebugLogger.logAsync(.info, "KSPlaybackController: buffer #\(bufferedCount) pronto in \(consumeTime)s")
    }
}
