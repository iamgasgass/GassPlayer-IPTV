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
/// AGGIORNAMENTO 2026-09-27 — ESPOSIZIONE COMPLETA DELLE CAPACITÀ DI
/// KSPlayer/FFmpeg: `PlaybackPreferences` copre l'intera superficie
/// pubblica e documentata di `KSOptions` (buffer, decodifica hardware/
/// software, sincronizzazione A/V, ricerca accurata/flags, de‑interlacciamento,
/// sottotitoli incorporati/immagine, filtri FFmpeg audio/video, opzioni
/// grezze del format-context/decoder/avOptions, intestazioni HTTP
/// personalizzate, cache HTTP, probing di rete, riproduzione in loop,
/// tempo/velocità di partenza, adattamento automatico del bitrate e
/// rendering panoramico 360°/VR) CONFERMATA presente in questa versione
/// della libreria (vedi nota "FIX BUILD" più sotto).
///
/// AGGIORNAMENTO 2026-09-27 (bis) — DEFAULT "AVFORMAT" GIÀ EFFICACI DI
/// SERIE (compatibilità con TUTTI i formati/protocolli mancanti): oltre
/// alla riconnessione automatica e al trasporto RTSP via TCP già attivi,
/// `PlaybackPreferences` ora include SEMPRE, senza alcuna configurazione
/// manuale:
/// - whitelist dei protocolli avformat estesa a HLS/DASH, RTSP, tutte le
///   varianti RTMP (rtmp/rtmpt/rtmps/rtmpe/rtmpte/rtmpts), MMS/MMSH/MMST,
///   UDP/RTP multicast, file locali e concat/subfile per playlist m3u
///   composte ("protocol_whitelist", "allowed_extensions");
/// - correzione automatica di timestamp mancanti e scarto dei pacchetti
///   corrotti ("fflags": "+genpts+discardcorrupt"), essenziale sui
///   multiplex IPTV non standard;
/// - threading automatico del decoder FFmpeg su tutti i core disponibili
///   ("threads": "auto" in `decoderOptions`), per qualunque codec
///   software (H.264/H.265/MPEG-2/VP9/AV1/...);
/// - probing e analisi estesi (10 MB / 10s, `builtInProbesize`/
///   `builtInMaxAnalyzeDuration`) applicati automaticamente quando
///   l'utente non ha impostato un override esplicito, per rilevare
///   correttamente tutte le tracce anche su flussi che le annunciano
///   in ritardo o in modo non standard.
/// Queste chiavi/valori sono i default DI FABBRICA delle rispettive
/// proprietà — l'utente può comunque sovrascriverle o rimuoverle dal
/// pannello "Impostazioni avanzate" (`setFormatContextOption`,
/// `removeFormatContextOption`, `setProbesize(nil)`, ecc.).
///
/// AGGIORNAMENTO 2026-09-27 (ter) — FIX BUILD: `subtitleDelay` e
/// `subtitleDisable` NON esistono più su `KSOptions` in questa versione
/// della libreria (la gestione del ritardo/disattivazione sottotitoli è
/// stata spostata dal team di KSPlayer in un modello interno separato non
/// esposto pubblicamente in modo stabile — vedi kingslay/KSPlayer#508) e
/// restano quindi assenti sia da `PlaybackPreferences` sia da
/// `buildLayer`. Tutte le altre proprietà `KSOptions` usate in questo
/// file (incluse `probesize`/`maxAnalyzeDuration`, che NON hanno generato
/// errori di build) sono confermate valide per questa libreria.
///
/// FIX 2026-09-25 (zapping canale/episodio "senza uscire e riaprire il
/// player"): `layer` è `@Published` (non `let`): `load(url:title:)` crea
/// un nuovo `KSPlayerLayer` per il nuovo URL e lo assegna a questa stessa
/// istanza di `KSPlaybackController`, che resta viva per tutta la sessione
/// di visione. `PlayerView` (che possiede il controller come
/// `@StateObject`) non viene mai ricreata: `KSPlayerContainerView`
/// osserva il cambio di `layer` e si limita a staccare la vecchia `UIView`
/// del player e agganciare la nuova nello stesso container già presente a
/// schermo — nessuna nuova presentazione, nessun reset di stato.

/// Modalità di adattamento del video al riquadro dello schermo.
/// Mappa 1:1 su `UIView.ContentMode`, letto/scritto da
/// `MediaPlayerProtocol.contentMode` in KSPlayer: si applica in tempo
/// reale sulla vista di rendering corrente (AVPlayerLayer o vista
/// Metal/OpenGL di KSMEPlayer), quindi funziona identicamente
/// indipendentemente da quale motore stia decodificando il flusso.
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

/// Modalità di rendering panoramico/360°, mappata su `KSOptions.DisplayEnum`
/// (una delle capacità distintive di KSPlayer: "360° panorama video").
/// `.plane` è la riproduzione normale piatta; `.vr` e `.vrBox` proiettano
/// il fotogramma su una sfera Metal per contenuti equirettangolari a 360°,
/// rispettivamente in modalità singola e "a scatola" (side-by-side per
/// visori). Richiede la ricostruzione del layer perché KSPlayer istanzia
/// il renderer panoramico solo in fase di apertura del flusso.
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

/// Preset comuni per `KSOptions.seekFlags` (flag FFmpeg `AVSEEK_FLAG_*`
/// passati direttamente ad `av_seek_frame`). Esposti come preset invece
/// che come bitmask grezza per restare utilizzabili dall'interfaccia,
/// pur mantenendo il valore `Int32` letterale richiesto da KSOptions.
enum SeekFlagPreset: String, CaseIterable, Identifiable {
    /// Nessun flag: ricerca rapida al keyframe più vicino (default FFmpeg).
    case fast
    /// `AVSEEK_FLAG_BYTE` (2): ricerca basata su offset di byte, utile per
    /// flussi senza timestamp affidabili.
    case byteAccurate
    /// `AVSEEK_FLAG_ANY` (4): consente di posizionarsi su fotogrammi non
    /// keyframe, più preciso su flussi con GOP molto lunghi.
    case anyFrame
    /// `AVSEEK_FLAG_FRAME` (8): ricerca basata su indice di fotogramma.
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
    /// (`AdvancedSettingsView`, raggiungibile dal menu "…"). Coprono
    /// l'intera superficie pubblica di `KSOptions`/FFmpeg confermata
    /// presente nella versione di KSPlayer installata in questo progetto,
    /// e sono lo stato di verità riapplicato ad ogni nuovo
    /// `KSPlayerLayer`, sia al primo avvio sia ad ogni cambio
    /// canale/episodio: senza questo, zappare canale avrebbe azzerato
    /// silenziosamente tutte le preferenze scelte per la sessione corrente.
    struct PlaybackPreferences {
        // MARK: Buffer
        /// `KSOptions.preferredForwardBufferDuration`: buffer minimo (s)
        /// prima di iniziare/riprendere la riproduzione.
        var preferredForwardBufferDuration: Double = 5
        /// `KSOptions.maxBufferDuration`: buffer massimo (s) prima che il
        /// caricamento venga sospeso.
        var maxBufferDuration: Double = 30

        // MARK: Decodifica (FFmpeg / VideoToolbox)
        /// `KSOptions.hardwareDecode`: VideoToolbox vs software (FFmpeg
        /// puro), utile per aggirare flussi H.264/H.265 malformati.
        var hardwareDecode: Bool = true
        /// `KSOptions.asynchronousDecompression`: decompressione hardware
        /// asincrona, riduce gli stalli su decoder hardware lenti.
        var asynchronousDecompression: Bool = true
        /// `KSOptions.syncDecodeVideo` / `syncDecodeAudio`: decodifica
        /// sincrona invece che su thread dedicati — utile in diagnosi per
        /// isolare artefatti dovuti a race condition nella pipeline.
        var syncDecodeVideo: Bool = false
        var syncDecodeAudio: Bool = false
        /// `KSOptions.lowres`: riduce la risoluzione di decodifica FFmpeg
        /// (0 = piena risoluzione, 1 = metà, 2 = un quarto). Utile su
        /// dispositivi poco potenti o per scrub/preview veloci.
        var lowres: UInt8 = 0
        /// `KSOptions.videoDisable`: disabilita completamente la traccia
        /// video — modalità "solo audio" per stream radio IPTV.
        var videoDisable: Bool = false

        // MARK: Ricerca / sincronizzazione A/V
        /// `KSOptions.isAccurateSeek`: seek fotogramma-esatto invece del
        /// keyframe più vicino.
        var isAccurateSeek: Bool = false
        /// `KSOptions.seekFlags`: flag FFmpeg passati a `av_seek_frame`.
        var seekFlags: Int32 = 0
        /// `KSOptions.autoDeInterlace`: rilevamento/correzione automatica
        /// dell'interlacciamento (comune su canali SD IPTV).
        var autoDeInterlace: Bool = false
        /// `KSOptions.videoDelay` (s): sincronizzazione video manuale,
        /// positivo = video ritardato rispetto all'audio.
        var videoDelay: Double = 0

        // MARK: Sottotitoli (testo, immagine, Closed Captions)
        //
        // NOTA: `subtitleDisable` e `subtitleDelay` sono stati rimossi da
        // `KSOptions` in questa versione di KSPlayer (spostati in un
        // modello di sottotitoli interno non esposto pubblicamente) e
        // NON sono più presenti qui: il tentativo di scriverli su
        // `KSOptions` causava l'errore di build "has no member
        // 'subtitleDelay'/'subtitleDisable'".
        /// `KSOptions.autoSelectEmbedSubtitle`: selezione automatica della
        /// prima traccia sottotitoli incorporata nel flusso.
        var autoSelectEmbedSubtitle: Bool = true
        /// `KSOptions.isSeekImageSubtitle`: mantiene visibile l'ultimo
        /// sottotitolo immagine (es. PGS/DVB) durante il seek.
        var isSeekImageSubtitle: Bool = false

        // MARK: Rendering
        /// Modalità di adattamento del video al riquadro. Si applica al
        /// volo (proprietà della vista, non della pipeline FFmpeg) ma è
        /// comunque persistita qui perché deve sopravvivere allo zapping.
        var videoGravity: VideoGravityMode = .fit
        /// `KSOptions.display`: modalità piatta/VR/VR box per contenuti
        /// panoramici 360°.
        var panoramaMode: PanoramaMode = .plane
        /// `KSOptions.autoRotate`: applica automaticamente la rotazione
        /// indicata nei metadati del flusso.
        var autoRotate: Bool = true

        // MARK: Adattamento qualità / comportamento riproduzione
        /// `KSOptions.videoAdaptable`: switch automatico tra bitrate
        /// multipli su playlist HLS/DASH multi-variante in base alla rete.
        var videoAdaptable: Bool = true
        /// `KSOptions.isLoopPlay`: riproduzione in loop automatico a fine
        /// flusso (contenuti brevi/VOD).
        var isLoopPlay: Bool = false
        /// `KSOptions.isSecondOpen`: apertura rapida ("secondo open") del
        /// flusso per un avvio percepito più veloce.
        var isSecondOpen: Bool = true
        /// `KSOptions.isSeekedAutoPlay`: riprende automaticamente la
        /// riproduzione dopo un seek manuale.
        var isSeekedAutoPlay: Bool = true
        /// `KSOptions.startPlayTime` (s): posizione di partenza, applicata
        /// solo al successivo `load(url:title:)` (es. riprendi da dove
        /// avevi interrotto).
        var startPlayTime: TimeInterval = 0
        /// `KSOptions.startPlayRate`: velocità di riproduzione iniziale.
        var startPlayRate: Float = 1.0

        // MARK: Rete
        /// `KSOptions.userAgent`: intestazione User-Agent HTTP.
        var userAgent: String? = "GassPlayer/1.0"
        /// `KSOptions.referer`: intestazione Referer HTTP.
        var referer: String?
        /// Intestazioni HTTP personalizzate aggiuntive, applicate tramite
        /// `KSOptions.appendHeader(_:)` — utile per playlist IPTV che
        /// richiedono token/cookie/Origin specifici.
        var customHTTPHeaders: [String: String] = [:]
        /// `KSOptions.cache`: cache HTTP lato FFmpeg (solo protocollo
        /// http/https).
        var httpCacheEnabled: Bool = false
        /// `KSOptions.probesize` (byte): override del probing FFmpeg.
        /// `nil` = usa il default robusto già attivo di serie
        /// (`builtInProbesize`, 10 MB) pensato per rilevare correttamente
        /// tutte le tracce anche su multiplex IPTV mal formati/con
        /// formati "mancanti" annunciati in ritardo.
        var probesize: Int64?
        /// `KSOptions.maxAnalyzeDuration` (µs): override della durata di
        /// analisi FFmpeg. `nil` = usa il default robusto già attivo di
        /// serie (`builtInMaxAnalyzeDuration`, 10 s).
        var maxAnalyzeDuration: Int64?

        // MARK: Filtri FFmpeg
        /// `KSOptions.videoFilters`: catena di filtri video FFmpeg
        /// (sintassi `libavfilter`, es. `"hflip"`, `"eq=contrast=1.2"`).
        var videoFilters: [String] = []
        /// `KSOptions.audioFilters`: catena di filtri audio FFmpeg (es.
        /// `"volume=2.0"`, `"aecho=0.8:0.9:1000:0.3"`).
        var audioFilters: [String] = []

        // MARK: Opzioni FFmpeg grezze — default "avformat" già attivi
        //
        // Popolate di fabbrica con l'intero set di parametri
        // `AVFormatContext`/protocollo/decoder che rende KSPlayer
        // compatibile "di serie", senza alcuna configurazione manuale,
        // con letteralmente ogni protocollo/formato che avformat sa
        // aprire — non solo HTTP/HLS semplice ma anche RTSP live, tutte
        // le varianti RTMP, MMS/MMSH/MMST, UDP/RTP multicast e playlist
        // concat/subfile. Essendo semplici chiavi di dizionario passate a
        // FFmpeg via `AVDictionary`, una chiave non pertinente al
        // protocollo del flusso corrente (es. "rtsp_transport" su una
        // URL http://) viene semplicemente ignorata da FFmpeg — non causa
        // mai un errore di apertura né di compilazione.
        //
        // - "reconnect"/"reconnect_at_eof"/"reconnect_streamed" (1): fa
        //   ritentare automaticamente la connessione HTTP/HLS quando il
        //   server IPTV la chiude o si raggiunge un EOF anomalo.
        // - "reconnect_delay_max" (5): attesa massima (s) tra i tentativi
        //   di riconnessione.
        // - "rw_timeout" (15000000 µs = 15s): timeout generico di
        //   lettura/scrittura I/O.
        // - "multiple_requests" (1) / "http_persistent" (1): riusa la
        //   stessa connessione HTTP (keep-alive) tra le richieste
        //   successive, riducendo la latenza di zapping.
        // - "rtsp_transport" ("tcp") / "rtsp_flags" ("prefer_tcp"): forza
        //   il trasporto RTSP su TCP invece di UDP, molto più affidabile
        //   dietro NAT/firewall tipici delle reti IPTV domestiche.
        // - "fflags" ("+genpts+discardcorrupt"): rigenera i timestamp
        //   mancanti/malformati e scarta i pacchetti corrotti invece di
        //   bloccare la decodifica — fondamentale su molti multiplex
        //   IPTV non standard che altrimenti apparirebbero come "formato
        //   non supportato".
        // - "protocol_whitelist": elenco esplicito di TUTTI i protocolli
        //   che avformat deve poter apire (necessario perché demuxer
        //   come HLS/concat aprono sotto-URL con protocolli diversi da
        //   quello iniziale): file, http(s), tcp/tls, rtp, rtsp, tutte le
        //   varianti rtmp, udp, mms(h/t), crypto, httpproxy, data,
        //   concat, subfile, hls, applehttp.
        // - "allowed_extensions" ("ALL"): rimuove ogni restrizione di
        //   estensione file, altrimenti alcuni demuxer (concat) potrebbero
        //   rifiutare URL IPTV con estensioni "atipiche".
        //
        // Si sommano — e in caso di conflitto sovrascrivono chiave per
        // chiave — con qualunque opzione l'utente aggiunga/rimuova dal
        // pannello "Impostazioni avanzate".
        /// `KSOptions.formatContextOptions`: opzioni passate direttamente
        /// ad `AVFormatContext`/ai protocolli sottostanti.
        var formatContextOptions: [String: String] = [
            "reconnect": "1",
            "reconnect_at_eof": "1",
            "reconnect_streamed": "1",
            "reconnect_delay_max": "5",
            "rw_timeout": "15000000",
            "multiple_requests": "1",
            "http_persistent": "1",
            "rtsp_transport": "tcp",
            "rtsp_flags": "prefer_tcp",
            "fflags": "+genpts+discardcorrupt",
            "protocol_whitelist": "file,http,https,tcp,tls,rtp,rtsp,rtmp,rtmpt,rtmps,rtmpe,rtmpte,rtmpts,udp,mmsh,mmst,crypto,httpproxy,data,concat,subfile,hls,applehttp",
            "allowed_extensions": "ALL",
        ]
        /// `KSOptions.decoderOptions`: opzioni passate al decoder FFmpeg
        /// selezionato. Popolato di fabbrica con `"threads": "auto"` per
        /// sfruttare tutti i core disponibili su qualunque codec software
        /// (H.264, H.265, MPEG-2, VP9, AV1, ...) senza configurazione
        /// manuale.
        var decoderOptions: [String: String] = [
            "threads": "auto",
        ]
        /// `KSOptions.avOptions`: opzioni FFmpeg generiche di libreria.
        var avOptions: [String: String] = [:]
    }

    /// Probing esteso (10 MB) applicato quando `preferences.probesize`
    /// è `nil`: rileva correttamente tutte le tracce audio/video/
    /// sottotitoli anche su multiplex IPTV che annunciano le proprie
    /// tracce in ritardo o in modo non standard ("formati mancanti").
    private static let builtInProbesize: Int64 = 10_000_000
    /// Durata massima di analisi estesa (10s, µs) applicata quando
    /// `preferences.maxAnalyzeDuration` è `nil`, allineata al probing
    /// esteso qui sopra.
    private static let builtInMaxAnalyzeDuration: Int64 = 10_000_000

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
    /// molto più spesso di quanto la UI necessiti per apparire fluida.
    /// Pubblichiamo un aggiornamento solo se la variazione percepita è
    /// reale (>= 200ms) o se la durata totale è cambiata (es. DVR live).
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
    /// di `PlaybackPreferences` confermata presente in `KSOptions` per
    /// questa versione della libreria (INCLUSI i default avformat di
    /// riconnessione/timeout/RTSP-TCP/whitelist protocolli/probing
    /// estesi, già attivi di fabbrica in `PlaybackPreferences`) alle
    /// opzioni del nuovo layer. Metodo `static` perché deve poter essere
    /// chiamato anche dall'`init`, prima che `super.init()` completi.
    private static func buildLayer(for url: URL, preferences: PlaybackPreferences) -> KSPlayerLayer {
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

        // Sottotitoli (autoSelectEmbedSubtitle/isSeekImageSubtitle
        // confermati esistenti; subtitleDisable/subtitleDelay NON
        // esistono più su KSOptions in questa versione, vedi nota sopra)
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
        options.userAgent = preferences.userAgent
        options.referer = preferences.referer
        if !preferences.customHTTPHeaders.isEmpty {
            options.appendHeader(preferences.customHTTPHeaders)
        }
        options.cache = preferences.httpCacheEnabled
        // Se l'utente non ha impostato un override esplicito, usa SEMPRE
        // il default robusto "avformat" (10 MB / 10s) invece del default
        // minimale di FFmpeg: compatibilità di serie con multiplex IPTV
        // che annunciano male le proprie tracce ("formati mancanti").
        options.probesize = preferences.probesize ?? builtInProbesize
        options.maxAnalyzeDuration = preferences.maxAnalyzeDuration ?? builtInMaxAnalyzeDuration

        // Filtri FFmpeg
        options.videoFilters = preferences.videoFilters
        options.audioFilters = preferences.audioFilters

        // Opzioni FFmpeg grezze — unite ai default della libreria senza
        // rimpiazzarli. Riconnessione, timeout, RTSP-TCP, whitelist
        // protocolli e threading decoder sono quindi già effettivi qui,
        // ad ogni apertura o ricarica del flusso, anche se l'utente non
        // ha mai aperto il pannello "Impostazioni avanzate".
        if !preferences.formatContextOptions.isEmpty {
            options.formatContextOptions.merge(preferences.formatContextOptions.mapValues { $0 as Any }) { _, new in new }
        }
        if !preferences.decoderOptions.isEmpty {
            options.decoderOptions.merge(preferences.decoderOptions.mapValues { $0 as Any }) { _, new in new }
        }
        if !preferences.avOptions.isEmpty {
            options.avOptions.merge(preferences.avOptions.mapValues { $0 as Any }) { _, new in new }
        }

        // Invariato rispetto alla configurazione precedente
        options.registerRemoteControll = true
        options.canStartPictureInPictureAutomaticallyFromInline = true

        let layer = KSPlayerLayer(url: url, isAutoPlay: true, options: options, delegate: nil)
        layer.player.contentMode = preferences.videoGravity.contentMode
        return layer
    }

    /// Carica un nuovo URL SENZA che `PlayerView` venga mai
    /// distrutta/ricreata. Il vecchio layer viene fermato e scollegato, un
    /// nuovo `KSPlayerLayer` viene creato riapplicando integralmente le
    /// `preferences` correnti (incluse le opzioni FFmpeg avanzate e i
    /// default avformat di riconnessione/RTSP-TCP/whitelist/probing), e
    /// tutto lo stato di avanzamento/errore viene azzerato.
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
        // Chiamata esplicita a play() ridondante ma sicura: garantisce
        // l'avvio anche quando l'auto-play interno non ha effetto perché
        // la vista non è ancora agganciata a una window.
        layer.play()
        startWatchdog()
    }

    /// Ricarica lo stream corrente (stesso URL) con le `preferences`
    /// aggiornate: necessario per le impostazioni che agiscono a livello
    /// di apertura/pipeline (decodifica, sottotitoli, rete, filtri, opzioni
    /// FFmpeg grezze, panorama), che KSPlayer legge solo alla creazione
    /// della pipeline e non possono essere cambiate "a caldo".
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
        // Su flussi live (duration == 0) lo skip è un no-op: senza una
        // durata nota non esiste un limite superiore valido per il seek.
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

    // MARK: - Buffer (applicazione live, nessun reload necessario)

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

    /// A differenza di decodifica/de-interlacciamento, non richiede
    /// `reload()`: `contentMode` è letto ad ogni frame renderizzato,
    /// quindi il cambiamento è visibile all'istante sul fotogramma corrente.
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

    // MARK: - Decodifica (richiede reload: la pipeline FFmpeg va ricreata)

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

    /// Applicati solo al successivo `load(url:title:)` (es. "riprendi da
    /// dove avevi interrotto"): non hanno effetto retroattivo su un
    /// flusso già aperto, quindi non richiedono un reload immediato.
    func setStartPlayTime(_ value: TimeInterval) {
        preferences.startPlayTime = value
    }

    func setStartPlayRate(_ value: Float) {
        preferences.startPlayRate = value
    }

    // MARK: - Sottotitoli (richiede reload: il sottosistema si inizializza in apertura)

    func setAutoSelectEmbedSubtitle(_ enabled: Bool) {
        preferences.autoSelectEmbedSubtitle = enabled
        reload()
    }

    func setSeekImageSubtitle(_ enabled: Bool) {
        preferences.isSeekImageSubtitle = enabled
        reload()
    }

    // MARK: - Rete (richiede reload: intestazioni/proxy si applicano all'apertura HTTP)

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

    /// `value == nil` ripristina il default robusto sempre attivo
    /// (`builtInProbesize`, 10 MB), non il default minimale di FFmpeg.
    func setProbesize(_ value: Int64?) {
        preferences.probesize = value
        reload()
    }

    /// `value == nil` ripristina il default robusto sempre attivo
    /// (`builtInMaxAnalyzeDuration`, 10s), non il default minimale di FFmpeg.
    func setMaxAnalyzeDuration(_ value: Int64?) {
        preferences.maxAnalyzeDuration = value
        reload()
    }

    // MARK: - Filtri FFmpeg (richiede reload: i grafi filtro si costruiscono in apertura)

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

    // MARK: - Opzioni FFmpeg grezze (potere assoluto, richiede reload)
    //
    // Queste funzioni restano il punto di ingresso per personalizzare o
    // RIMUOVERE anche i default avformat impostati di fabbrica in
    // `PlaybackPreferences.formatContextOptions`/`decoderOptions` (es. se
    // un server IPTV specifico si comporta meglio con
    // `reconnect_delay_max` diverso, o con `rtsp_transport=udp`):
    // `setFormatContextOption` sovrascrive la singola chiave, mentre
    // `removeFormatContextOption` la elimina anche se era un default di
    // fabbrica, senza toccare le altre.

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
            // 7s di schermo nero prima che il watchdog ritenti: abbastanza
            // per non scambiare per errore un server IPTV lento a
            // rispondere per un flusso morto, ma percepito come "rapido".
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
