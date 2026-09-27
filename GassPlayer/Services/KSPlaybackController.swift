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
/// ANALISI MANIACALE 2026-09-27 (ter) — "avformat: can't open input"
/// PERSISTENTE su alcuni film VOD: il messaggio è generico e ingloba
/// diverse cause distinte di fallimento di `avformat_open_input`. Un
/// singolo retry automatico può non bastare se la causa reale non è lo
/// User-Agent/Referer ma, ad esempio, un negoziato di decodifica
/// hardware che fallisce prima ancora di leggere il container, o un
/// probing troppo breve su un file con indice/heder posizionato in modo
/// atipico. `handleOpenFailure` ora esegue una SEQUENZA di fino a 2
/// tentativi di fallback automatici e silenziosi (l'utente vede
/// l'errore solo se anche l'ultimo tentativo fallisce):
///
/// 1. Tentativo iniziale: impostazioni scelte dall'utente, inalterate.
/// 2. Fallback #1: User-Agent da browser reale + Referer auto-derivato
///    dal dominio del flusso (aggira hotlink-protection/UA-filtering).
/// 3. Fallback #2: come sopra, PIÙ decodifica forzata in software
///    (bypassa un eventuale fallimento di negoziazione VideoToolbox),
///    apertura "completa" invece di rapida (`isSecondOpen = false`) e
///    probing/analisi ulteriormente estesi (50 MB / 30s) per file con
///    intestazioni o indici collocati in modo non standard.
///
/// Ogni tentativo ricrea il layer da zero con `buildLayer`, SENZA mai
/// modificare le `preferences` scelte dall'utente: i fallback sono
/// esclusivamente transitori e si applicano solo al tentativo di
/// apertura corrente.
///
/// FIX MANIACALE 2026-09-27 (bis) — le opzioni di rete (`reconnect*`,
/// `rtsp_transport`) sono calcolate IN BASE ALLO SCHEMA DELL'URL
/// (`networkFormatContextOptions`): applicarle globalmente a qualunque
/// protocollo lasciava chiavi RTSP "non consumate" su URL http(s) di
/// file VOD gestiti esclusivamente dal motore FFmpeg (MKV/AVI non
/// supportati nativamente da AVPlayer), causando lo stesso errore
/// generico "can't open input". Ogni chiave è applicata solo al
/// protocollo che la può davvero consumare.
///
/// FIX 2026-09-27 (precedente) — `subtitleDelay`/`subtitleDisable` NON
/// esistono su `KSOptions` in questa versione della libreria e restano
/// rimossi (vedi kingslay/KSPlayer#508).
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
        // `KSOptions` in questa versione di KSPlayer e NON sono più
        // presenti qui (vedi kingslay/KSPlayer#508).
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
        /// `KSOptions.userAgent`: intestazione User-Agent HTTP usata al
        /// PRIMO tentativo di apertura. Se il primo tentativo fallisce,
        /// `handleOpenFailure` ritenta automaticamente con
        /// `fallbackUserAgent` SENZA modificare questo valore.
        var userAgent: String? = "GassPlayer/1.0"
        /// `KSOptions.referer`: intestazione Referer HTTP. Se `nil` al
        /// momento di un RETRY di fallback, viene derivato automaticamente
        /// dal dominio dell'URL (vedi `selfReferer`); il primo tentativo
        /// invece non forza alcun Referer se l'utente non ne ha impostato
        /// uno esplicito, per non alterare il comportamento su flussi che
        /// già funzionano.
        var referer: String?
        /// Intestazioni HTTP personalizzate aggiuntive, applicate tramite
        /// `KSOptions.appendHeader(_:)` — utile per playlist IPTV che
        /// richiedono token/cookie/Origin specifici.
        var customHTTPHeaders: [String: String] = [:]
        /// `KSOptions.cache`: cache HTTP lato FFmpeg (solo protocollo
        /// http/https).
        var httpCacheEnabled: Bool = false
        /// `KSOptions.probesize` (byte): override esplicito del probing
        /// FFmpeg. `nil` = usa il default robusto sempre attivo
        /// (`builtInProbesize`, 10 MB), pensato per rilevare correttamente
        /// tutte le tracce anche su file VOD/MKV con indici non standard.
        var probesize: Int64?
        /// `KSOptions.maxAnalyzeDuration` (µs): override esplicito della
        /// durata di analisi. `nil` = usa il default robusto sempre
        /// attivo (`builtInMaxAnalyzeDuration`, 10s).
        var maxAnalyzeDuration: Int64?

        // MARK: Filtri FFmpeg
        /// `KSOptions.videoFilters`: catena di filtri video FFmpeg
        /// (sintassi `libavfilter`, es. `"hflip"`, `"eq=contrast=1.2"`).
        var videoFilters: [String] = []
        /// `KSOptions.audioFilters`: catena di filtri audio FFmpeg (es.
        /// `"volume=2.0"`, `"aecho=0.8:0.9:1000:0.3"`).
        var audioFilters: [String] = []

        // MARK: Opzioni FFmpeg grezze AGGIUNTIVE (potere assoluto)
        //
        // Parte VUOTO: i default di rete non sono iniettati qui in modo
        // globale (causava il bug "avformat: can't open input" sui VOD),
        // ma calcolati DINAMICAMENTE in base al protocollo dell'URL da
        // `KSPlaybackController.networkFormatContextOptions(for:)` e
        // uniti a queste eventuali chiavi scelte dall'utente, che hanno
        // sempre la precedenza in caso di conflitto sulla stessa chiave.
        /// `KSOptions.formatContextOptions`: opzioni AGGIUNTIVE passate
        /// direttamente ad `AVFormatContext` (es. `"analyzeduration": "0"`).
        var formatContextOptions: [String: String] = [:]
        /// `KSOptions.decoderOptions`: opzioni passate al decoder FFmpeg
        /// selezionato (es. `"threads": "4"`).
        var decoderOptions: [String: String] = [:]
        /// `KSOptions.avOptions`: opzioni FFmpeg generiche di libreria.
        var avOptions: [String: String] = [:]
    }

    /// Default probing/analisi robusti, sempre attivi (proprietà TIPIZZATE
    /// di `KSOptions`, non chiavi del dizionario grezzo: non soffrono del
    /// problema delle "opzioni non consumate", quindi possono restare
    /// sempre attivi senza alcun rischio).
    private static let builtInProbesize: Int64 = 10_000_000
    private static let builtInMaxAnalyzeDuration: Int64 = 10_000_000

    /// Numero massimo di tentativi di apertura totali (1 iniziale + 2 di
    /// fallback) prima di mostrare finalmente l'errore all'utente.
    private static let maxOpenAttempts = 3

    /// User-Agent di fallback usato SOLO nei retry automatici dopo un
    /// fallimento di apertura: uno user-agent da browser desktop reale,
    /// per aggirare i filtri di alcuni server/CDN VOD che negano
    /// l'accesso a richieste con user-agent non riconosciuti (tipicamente
    /// il default FFmpeg "Lavf/..." o user-agent applicativi generici).
    private static let fallbackUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// Deriva un Referer plausibile dal dominio dell'URL stesso (es.
    /// `https://cdn.esempio.com/film.mkv` → `https://cdn.esempio.com/`),
    /// usato SOLO nei retry di fallback quando l'utente non ha impostato
    /// un Referer esplicito: molte protezioni "hotlink" richiedono che il
    /// Referer coincida (anche solo per dominio) con l'host del file
    /// stesso, non con l'app che lo richiede.
    private static func selfReferer(for url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return "\(scheme)://\(host)/"
    }

    /// Calcola le opzioni `AVFormatContext`/protocollo di rete pertinenti
    /// ESCLUSIVAMENTE allo schema dell'URL corrente. Applicare
    /// `rtsp_transport`/`rtsp_flags` a QUALUNQUE URL lasciava quelle
    /// chiavi "non consumate" su protocolli non RTSP (http/https di file
    /// VOD, file locali, RTMP, ...), condizione che alcuni demuxer FFmpeg
    /// rifiutano con errore di apertura invece di ignorare
    /// silenziosamente. Ogni chiave è quindi applicata SOLO quando il
    /// protocollo la può realmente consumare.
    private static func networkFormatContextOptions(for url: URL) -> [String: String] {
        switch url.scheme?.lowercased() {
        case "http", "https":
            return [
                // Riconnessione automatica su drop di rete/HTTP: essenziale
                // per IPTV live e per download VOD interrotti a metà.
                "reconnect": "1",
                "reconnect_at_eof": "1",
                "reconnect_streamed": "1",
                "reconnect_delay_max": "5",
                // Timeout generico di lettura/scrittura I/O (15s, µs).
                "rw_timeout": "15000000",
                // Riutilizza la connessione HTTP keep-alive tra richieste
                // successive (segmenti HLS, seek), riducendo la latenza.
                "multiple_requests": "1",
                "http_persistent": "1",
            ]
        case "rtsp", "rtsps":
            return [
                // RTSP forzato su TCP: evita la perdita di pacchetti UDP
                // tipica delle reti IPTV/mobile dietro NAT.
                "rtsp_transport": "tcp",
                "rtsp_flags": "prefer_tcp",
                "stimeout": "10000000",
            ]
        default:
            // rtmp/rtmps/rtmpt/mms/mmsh/mmst/udp/rtp/file/altro: nessuna
            // opzione di protocollo estranea — evita esattamente la
            // classe di bug diagnosticata sopra.
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

    /// Numero di tentativi di apertura già eseguiti per l'URL corrente
    /// (0 = nessun fallimento ancora avvenuto). Azzerato ad ogni
    /// `load(url:title:)`/`resetAttempts()`. Guida la sequenza di
    /// fallback automatici in `handleOpenFailure`/`retryWithFallbackSettings`.
    private var openAttemptCount = 0

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
    /// di `PlaybackPreferences` confermata presente in `KSOptions`, con i
    /// default di rete calcolati IN BASE AL PROTOCOLLO dell'URL corrente
    /// e i default di probing/analisi sempre attivi. `userAgentOverride`/
    /// `refererOverride` sono usati ESCLUSIVAMENTE dai retry di fallback
    /// (`retryWithFallbackSettings`) e non toccano mai `preferences`.
    /// Metodo `static` perché deve poter essere chiamato anche dall'`init`,
    /// prima che `super.init()` completi.
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

        // Sottotitoli (autoSelectEmbedSubtitle/isSeekImageSubtitle
        // confermati esistenti su questa versione di KSOptions)
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

        // Rete: userAgentOverride/refererOverride hanno sempre la
        // precedenza (usati solo dai retry di fallback); altrimenti si
        // usano i valori scelti dall'utente in `preferences`.
        options.userAgent = userAgentOverride ?? preferences.userAgent
        options.referer = refererOverride ?? preferences.referer
        if !preferences.customHTTPHeaders.isEmpty {
            options.appendHeader(preferences.customHTTPHeaders)
        }
        options.cache = preferences.httpCacheEnabled
        // Probing/analisi: proprietà tipizzate, sempre sicure. Se
        // l'utente non ha impostato un override esplicito, usa il
        // default robusto (10 MB / 10s) pensato per rilevare
        // correttamente tutte le tracce anche su file VOD/MKV con indici
        // non standard.
        options.probesize = preferences.probesize ?? builtInProbesize
        options.maxAnalyzeDuration = preferences.maxAnalyzeDuration ?? builtInMaxAnalyzeDuration

        // Filtri FFmpeg
        options.videoFilters = preferences.videoFilters
        options.audioFilters = preferences.audioFilters

        // Opzioni FFmpeg grezze: la base è SOLO ciò che il protocollo
        // dell'URL corrente può realmente consumare (fix del bug VOD),
        // le personalizzazioni dell'utente si sommano e vincono chiave
        // per chiave in caso di conflitto.
        var effectiveFormatContextOptions = networkFormatContextOptions(for: url)
        effectiveFormatContextOptions.merge(preferences.formatContextOptions) { _, new in new }
        if !effectiveFormatContextOptions.isEmpty {
            options.formatContextOptions.merge(effectiveFormatContextOptions.mapValues { $0 as Any }) { _, new in new }
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
    /// `preferences` correnti, e tutto lo stato di avanzamento/errore
    /// (incluso il contatore dei tentativi di fallback) viene azzerato
    /// per il nuovo contenuto.
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

    /// Eseguito automaticamente e SILENZIOSAMENTE (nessun errore mostrato
    /// all'utente) ad ogni fallimento di apertura per l'URL corrente,
    /// finché non si raggiunge `maxOpenAttempts`. Ricrea il layer con lo
    /// stesso URL ma con impostazioni progressivamente più permissive,
    /// SENZA mai alterare le `preferences` scelte dall'utente:
    ///
    /// - Tentativo 1 (primo fallback): User-Agent da browser reale e
    ///   Referer auto-derivato dal dominio del flusso — aggira
    ///   hotlink-protection/UA-filtering, la causa più comune.
    /// - Tentativo 2 (secondo fallback): come sopra, PIÙ decodifica
    ///   forzata in software, apertura "completa" invece che rapida, e
    ///   probing/analisi ulteriormente estesi (50 MB / 30s) — copre
    ///   fallimenti di negoziazione hardware o container con indici
    ///   collocati in modo atipico.
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

    /// Punto unico di gestione di un fallimento di apertura/riproduzione,
    /// invocato sia da `player(layer:state:)` (stato `.error`) sia da
    /// `player(layer:finish:)`. Se non è stato ancora raggiunto
    /// `maxOpenAttempts`, esegue silenziosamente il prossimo tentativo di
    /// fallback; altrimenti mostra finalmente l'errore all'utente.
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
