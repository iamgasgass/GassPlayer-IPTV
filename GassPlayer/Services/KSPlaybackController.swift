import Foundation
import AVFoundation
import MediaPlayer
import KSPlayer

/// Bridge SwiftUI-friendly per KSPlayerLayer, ora l'UNICO motore di
/// riproduzione dell'app (AVPlayer nativo + FFmpeg via KSMEPlayer, con
/// switch automatico incorporato nella libreria stessa — vedi
/// KSPlayerLayer.finish(player:error:), che ritenta con
/// KSOptions.secondPlayerType su qualunque errore prima di arrendersi).
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
        var hardwareDecode: Bool = true
        /// `KSOptions.isAccurateSeek`: seek fotogramma-esatto (più lento)
        /// invece del seek "al keyframe più vicino" (più rapido, default).
        var isAccurateSeek: Bool = false
        /// `KSOptions.autoDeInterlace`: rileva e corregge automaticamente
        /// l'interlacciamento, comune su molti canali SD delle
        /// playlist IPTV.
        var autoDeInterlace: Bool = false
        /// `KSOptions.subtitleDisable`: disattiva completamente il
        /// demuxing dei sottotitoli incorporati (non solo la loro
        /// visualizzazione), a beneficio delle prestazioni su flussi che
        /// ne includono molte tracce inutilizzate.
        var subtitleDisabled: Bool = false
        /// `KSOptions.videoDelay` (secondi): sincronizzazione audio/video
        /// manuale. Positivo = video ritardato rispetto all'audio.
        var videoDelay: Double = 0
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

    init(url: URL, title: String) {
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
        let options = KSOptions()
        options.preferredForwardBufferDuration = preferences.preferredForwardBufferDuration
        options.maxBufferDuration = preferences.maxBufferDuration
        options.registerRemoteControll = true
        options.canStartPictureInPictureAutomaticallyFromInline = true
        options.userAgent = "GassPlayer/1.0"
        options.hardwareDecode = preferences.hardwareDecode
        options.isAccurateSeek = preferences.isAccurateSeek
        options.autoDeInterlace = preferences.autoDeInterlace
        options.subtitleDisable = preferences.subtitleDisabled
        options.videoDelay = preferences.videoDelay
        return KSPlayerLayer(url: url, isAutoPlay: true, options: options, delegate: nil)
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
        startWatchdog()
    }

    /// Ricarica lo stream corrente (stesso URL) con le `preferences`
    /// aggiornate: necessario per le impostazioni che agiscono a livello
    /// di decodifica (hardware/software, de-interlacciamento, sottotitoli
    /// disattivati), che KSPlayer legge solo alla creazione della
    /// pipeline e non possono essere cambiate "a caldo" su un flusso già
    /// in riproduzione.
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

    func setHardwareDecode(_ enabled: Bool) {
        preferences.hardwareDecode = enabled
        reload()
    }

    func setAutoDeInterlace(_ enabled: Bool) {
        preferences.autoDeInterlace = enabled
        reload()
    }

    func setSubtitleDisabled(_ disabled: Bool) {
        preferences.subtitleDisabled = disabled
        reload()
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard !self.hasEverStartedPlaying, self.lastError == nil else { return }
            DebugLogger.logAsync(.warning, "KSPlaybackController: nessuna riproduzione avviata dopo 12s (stato=\(self.state)), forzo ciclo pausa->play")
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
