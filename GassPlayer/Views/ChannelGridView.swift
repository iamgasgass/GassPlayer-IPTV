import SwiftUI
import UIKit
import ImageIO

/// FIX/OTTIMIZZAZIONE 2026-09-20 (velocità di caricamento/ricaricamento):
///
/// 1) `CatalogIndex` ora precalcola anche il raggruppamento delle Serie TV
/// per categoria (`seriesByCategory`, `uncategorizedSeries`) e una mappa
/// `categoryCounts` unica per il `kind` corrente. Prima, per le Serie TV,
/// `categoryCount(for:)` eseguiva `allSeries.lazy.filter { ... }.count`
/// — una scansione COMPLETA del catalogo serie PER OGNI categoria — e
/// questo veniva rifatto ad ogni singola valutazione di `body` (cambio
/// categoria, refresh, persino toggle non correlati), con complessità
/// O(categorie × serie). Con cataloghi ampi era il principale
/// responsabile della lentezza percepita. Ora è un'unica passata O(n)
/// eseguita solo quando la sorgente cambia davvero (`rebuildIndexIfNeeded`),
/// e le letture a runtime sono lookup O(1) su dizionario.
/// 2) L'aggiornamento dell'EPG nei tile (`loadEPGForVisibleStreams`) ora
/// applica gli esiti di un intero batch concorrente in un'unica scrittura
/// su `epgByStream`, invece di una scrittura per canale: da un massimo di
/// 24 re-render (uno per canale) si passa a un massimo di 6 (uno per
/// batch, con `epgTileConcurrency` invariata), rendendo il popolamento
/// dei tile percepibilmente più fluido senza cambiare timing di rete o
/// numero di richieste concorrenti verso il provider.
/// 3) La griglia canali evita l'allocazione di `Array(displayedStreams.enumerated())`
/// quando i numeri di canale sono disattivati (caso predefinito),
/// risparmiando una copia O(n) ad ogni render per cataloghi ampi.
///
/// Tutta la logica di importazione/filtro/visualizzazione (categorie,
/// "senza categoria", comportamento EPG nei tile, limiti EPG) resta
/// invariata: questi sono ottimizzazioni pure, non modifiche funzionali.
///
/// FIX 2026-09-24 (menu "…" al posto del pulsante Ricarica isolato):
///
/// Il pulsante di ricarica in toolbar (icona "arrow.clockwise") era
/// visibile solo per Live TV (`kind == .live`): VOD e Serie TV non
/// avevano alcun modo di ricaricare la propria sezione dalla toolbar.
/// Il pulsante è stato sostituito da un menu "…" (`libraryMenu`),
/// presente in ogni sezione (Live TV, VOD, Serie TV), che raggruppa sotto
/// l'header "Libreria" tre funzioni:
/// - "Densità griglia": stesso menu a tendina Compatta/Comoda già
///   presente in `SettingsView` → sezione Libreria.
/// - "UI Gruppi": scelta fra due implementazioni della vista gruppi,
///   entrambe già esistenti e non alterate nella loro logica —
///   "Scorrevole" (i chip orizzontali già presenti in questo file) ed
///   "Espansibile" (il menu a tendina Liquid Glass in alto a sinistra,
///   portato identico da `ChannelGridView2.swift`).
/// - "Ricarica <sezione>": la stessa identica azione del vecchio
///   `refreshButton`, ora disponibile in Live TV, VOD e Serie TV.
///
/// FIX 2026-09-24 (titolo sezione grande, comportamento nativo in
/// "Scorrevole" + fix "titolo bloccato piccolo" dopo lo switch):
///
/// In modalità "Espansibile" il `ToolbarItem(.principal)` che ospita la
/// pillola del gruppo occupa lo spazio del titolo di navigazione,
/// impedendo al titolo di sistema di comparire "grande": per questa
/// modalità resta quindi un `Text` manuale (`sectionTitleHeader`, stesso
/// font `.largeTitle` del titolo di sistema) sempre visibile in testa al
/// contenuto, con `.navigationBarTitleDisplayMode(.inline)`.
///
/// In modalità "Scorrevole" si usa invece il comportamento NATIVO del
/// titolo di sistema (`.large`): grande in testa al contenuto, piccolo in
/// toolbar solo scrollando.
///
/// BUG "titolo resta piccolo dopo lo switch Espansibile → Scorrevole"
/// (ANALISI APPROFONDITA, secondo tentativo):
///
/// Il primo fix (`.id(groupUIStyle)` sul contenuto ScrollView, DENTRO il
/// `NavigationStack`) non risolveva il problema perché `NavigationStack`
/// mantiene un singolo `UINavigationController` persistente che sopravvive
/// ai cambi di identità del proprio CONTENUTO interno: SwiftUI aggiorna
/// solo la vista ospitata dentro lo stesso `UIHostingController`/
/// `UINavigationController`, ma il `UINavigationItem` sottostante — dove
/// UIKit conserva la cache di layout del titolo grande, incluso lo stato
/// "collassato" ereditato da "Espansibile" — resta la STESSA istanza. Il
/// cambio di `id` sul solo contenuto interno non tocca quella cache.
///
/// La correzione reale è applicare `.id(groupUIStyle)` all'INTERO
/// `NavigationStack` (non al suo contenuto): questo forza SwiftUI a
/// distruggere e ricreare da zero anche il `UINavigationController`
/// sottostante — e con esso il suo `UINavigationItem` e ogni cache di
/// layout del titolo — ogni volta che "UI Gruppi" cambia. Il titolo
/// grande compare quindi correttamente subito dopo lo switch, senza
/// alcuna transizione "bloccata" a metà.
///
/// Effetto collaterale accettato e coerente: passare da una modalità
/// all'altra resetta il filtro categoria a "Tutti" e la cache EPG dei
/// tile (`epgByStream`), che viene semplicemente ricaricata dal
/// `.task(id: sourceIdentity)` — nessuna richiesta di rete duplicata né
/// comportamento errato, solo un normale primo caricamento (idempotente:
/// `loadIfNeeded`/`rebuildIndexIfNeeded` non rifanno nulla se i dati sono
/// già pronti).
///
/// FIX 2026-09-25 (pulsanti precedente/successivo nel player):
///
/// `PlayerView` espone ora `onPrevious`/`onNext` opzionali per scorrere
/// canali/film senza chiudere il player. Qui vengono calcolati con
/// `adjacentStream(to:offset:)` sulla stessa lista attualmente filtrata
/// (`displayedStreams`: stesso gruppo/categoria selezionato) e collegati
/// al `fullScreenCover`. Fondamentale l'`.id(stream.id)` esplicito sulla
/// vista presentata: senza di esso, cambiare `selectedStream` mentre il
/// player è già aperto NON ricreerebbe `PlayerView` (SwiftUI riusa la
/// stessa identità di vista quando cambiano solo i parametri, non la sua
/// posizione nell'albero), lasciando la `@StateObject
/// KSPlaybackController` — e quindi il flusso in riproduzione — quella
/// del canale precedente nonostante titolo e controlli mostrino già il
/// nuovo canale.
/// FIX 2026-10-01 (griglia 100% Xtream, scroll senza sfarfallii):
///
/// 1) SORGENTE DATI: le tile di Live TV, VOD e Serie TV leggono ORA
/// esclusivamente dal catalogo Xtream (nome, categoria, `stream_icon` /
/// `cover`). Prima, con una API key TMDB impostata, ogni tile VOD/Serie
/// lanciava una ricerca TMDB per titolo (`TMDBEnrichedPoster`) e, a
/// risposta arrivata, SOSTITUIVA l'immagine Xtream con il poster TMDB:
/// la cella cambiava contenuto a scroll in corso (placeholder → poster
/// Xtream → poster TMDB) ed era la causa principale dello sfarfallio, oltre
/// che di poster sbagliati per i titoli omonimi/parziali. TMDB resta usato
/// solo nelle schede dettaglio (film/serie), dove ora il matching è di
/// precisione (anno, titolo originale, id Xtream, cast). In griglia resta
/// soltanto il BADGE del voto TMDB (`GridTMDBRatingBadge`, stessa resa della
/// vecchia `TMDBEnrichedPoster`), che non modifica mai il poster.
/// 2) IMMAGINI: `AsyncImage` riparte da "placeholder" ogni volta che una
/// cella della `LazyVGrid` viene riciclata, anche se l'immagine è già in
/// cache di rete: il flash placeholder → immagine è lo sfarfallio visibile.
/// `CachedPosterImage` legge in modo SINCRONO una cache in memoria
/// (`NSCache`) già nell'`init`, quindi una cella che rientra in vista mostra
/// subito l'immagine al primo frame; i download sono ridimensionati
/// (ImageIO) fuori dal main thread e annullati quando la cella esce dallo
/// schermo.
/// 2b) ICONE/POSTER MANCANTI: `CachedPosterImage` risolve gli URL del
/// catalogo (percorsi relativi, `//host`, `\\/`, spazi) e `PosterDownloader`
/// ritenta gli errori transitori, prova http se https fallisce e accetta i
/// certificati dei server immagini dei provider.
/// 3) Le tile usano `.equatable()` (la conformità `Equatable` da sola non
/// viene sfruttata da SwiftUI per via delle closure) e `.animation(nil,
/// value:)` non mappa più l'intero elenco di serie ad ogni render.
/// Misure del riferimento per la modalità "Poster" di VOD/Serie TV: stessa
/// spaziatura delle card di "Continua a guardare" (testo sotto la card a
/// 5 pt, rientrato di 12 pt, angoli 16 pt).
private enum LargePosterStyle {
    static let cornerRadius: CGFloat = 16
    static let titleSpacing: CGFloat = 5
    static let titleInset: CGFloat = 12
    static let titleFont: Font = .system(size: 13.5)
}

/// Larghezza del contenitore della griglia (vedi `gridContainerWidth`).
private struct ChannelGridWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ChannelGridView: View {
    private enum CategorySelection: Hashable {
        case all
        case category(String)
        case uncategorized
    }

    /// Indice precalcolato del catalogo per il `kind` corrente. Costruito
    /// una sola volta per ogni cambio reale di sorgente/catalogo
    /// (`rebuildIndexIfNeeded`), non ad ogni render: tutte le query usate
    /// dalla UI (conteggi per categoria, contenuti "senza categoria",
    /// elenco per categoria selezionata) diventano lookup O(1)/O(categorie)
    /// invece di scansioni ripetute del catalogo intero.
    private struct CatalogIndex {
        let categoryIDs: Set<String>
        let streamsByCategory: [String: [XtreamStream]]
        let uncategorizedStreams: [XtreamStream]
        let seriesByCategory: [String: [XtreamSeriesItem]]
        let uncategorizedSeries: [XtreamSeriesItem]
        let categoryCounts: [String: Int]
        let uncategorizedCount: Int

        init(kind: XtreamStreamKind, streams: [XtreamStream], series: [XtreamSeriesItem], categories: [XtreamCategory]) {
            categoryIDs = Set(categories.map(\.categoryId))

            if kind == .series {
                var grouped: [String: [XtreamSeriesItem]] = [:]
                var uncategorized: [XtreamSeriesItem] = []
                grouped.reserveCapacity(categories.count)

                for item in series {
                    guard let categoryID = Self.normalizedCategoryID(item.categoryId),
                          categoryID != "0",
                          categoryIDs.contains(categoryID) else {
                        uncategorized.append(item)
                        continue
                    }

                    grouped[categoryID, default: []].append(item)
                }

                seriesByCategory = grouped
                uncategorizedSeries = uncategorized
                streamsByCategory = [:]
                uncategorizedStreams = []
                categoryCounts = grouped.mapValues(\.count)
                uncategorizedCount = uncategorized.count
            } else {
                var grouped: [String: [XtreamStream]] = [:]
                var uncategorized: [XtreamStream] = []
                grouped.reserveCapacity(categories.count)

                for stream in streams {
                    guard let categoryID = Self.normalizedCategoryID(stream.categoryId),
                          categoryID != "0",
                          categoryIDs.contains(categoryID) else {
                        uncategorized.append(stream)
                        continue
                    }

                    grouped[categoryID, default: []].append(stream)
                }

                streamsByCategory = grouped
                uncategorizedStreams = uncategorized
                seriesByCategory = [:]
                uncategorizedSeries = []
                categoryCounts = grouped.mapValues(\.count)
                uncategorizedCount = uncategorized.count
            }
        }

        static func normalizedCategoryID(_ categoryID: String?) -> String? {
            guard let categoryID else { return nil }

            let normalized = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)

            return normalized.isEmpty ? nil : normalized
        }
    }

    private enum GridMetrics {
        // "Comoda" e "Compatta": ripristinate ESATTAMENTE come nella
        // versione precedente (Live TV, VOD e Serie TV).
        static let comfortableColumnMinimum: CGFloat = 110
        static let comfortableColumnMaximum: CGFloat = 140
        static let comfortableColumnSpacing: CGFloat = 14
        static let comfortableRowSpacing: CGFloat = 16
        static let comfortableHorizontalPadding: CGFloat = 16

        static let compactColumnMinimum: CGFloat = 84
        static let compactColumnMaximum: CGFloat = 110
        static let compactColumnSpacing: CGFloat = 10
        static let compactRowSpacing: CGFloat = 10
        static let compactHorizontalPadding: CGFloat = 10

        static let comfortableArtworkSize: CGFloat = 100
        static let compactArtworkSize: CGFloat = 84

        static let comfortableMoviePosterHeight: CGFloat = 150
        static let compactMoviePosterHeight: CGFloat = 126

        static let comfortableSeriesPosterHeight: CGFloat = 140
        static let compactSeriesPosterHeight: CGFloat = 118

        // "Poster" per VOD e Serie TV (menu "…" → "Densità griglia"): misure
        // della schermata di riferimento (393 pt): 2 colonne da 175,5 pt,
        // locandine 2:3 alte ~265 pt, 10 pt fra le card, margine laterale
        // 16 pt, 18 pt fra le righe. Su schermi larghi aumentano le colonne
        // mantenendo margini e spazi identici.
        static let posterReferenceWidth: CGFloat = 175.5
        static let posterAspectRatio: CGFloat = 1.51
        static let posterColumnSpacing: CGFloat = 10
        static let posterRowSpacing: CGFloat = 18
        static let posterHorizontalPadding: CGFloat = 16
    }

    let credentials: XtreamCredentials
    let kind: XtreamStreamKind

    @EnvironmentObject private var contentManagement: ContentManagementService
    @EnvironmentObject private var xtreamCatalog: XtreamCatalogStore
    @EnvironmentObject private var recentlyWatched: RecentlyWatchedStore

    @AppStorage("gassplayer.grid.density")
    private var channelGridDensity = "comfortable"

    @AppStorage("gassplayer.grid.showChannelNumbers")
    private var showChannelNumbers = false

    /// Stile dell'interfaccia dei gruppi/categorie, scelto dal menu "…" →
    /// "UI Gruppi": "scorrevole" (chip orizzontali, comportamento storico
    /// di questa vista) oppure "espansibile" (pillola Liquid Glass in
    /// alto a sinistra con menu a tendina, portata da `ChannelGridView2`).
    /// Condiviso da Live TV, VOD e Serie TV.
    @AppStorage("gassplayer.grid.groupUIStyle")
    private var groupUIStyle = "scorrevole"

    @State private var selectedCategory: CategorySelection = .all
    @State private var selectedStream: XtreamStream?
    @State private var selectedSeries: XtreamSeriesItem?
    /// Film selezionato per la nuova scheda dettaglio (hero + valutazioni +
    /// cast): a differenza di `selectedStream` (Live TV, riproduzione
    /// diretta) il tap su una locandina VOD apre prima questa scheda, che
    /// avvia la riproduzione vera e propria solo al tocco di "Riproduci il
    /// film".
    @State private var selectedMovieForDetail: XtreamStream?

    /// `nil` = mai interrogato; `.some(nil)` = interrogato ma nessun
    /// programma disponibile (evita retry continui); `.some(program)` =
    /// programma corrente o prossimo disponibile per il tile.
    @State private var epgByStream: [Int: EPGProgram?] = [:]

    @State private var catalogIndex = CatalogIndex(kind: .live, streams: [], series: [], categories: [])
    @State private var indexedSourceIdentity: SourceIdentity?
    @State private var showEPGGuide = false

    private let epgTileBatchLimit = 24
    private let epgTileConcurrency = 4
    private let epgTileLookahead = 8

    private var service: XtreamAPIService {
        XtreamAPIService(credentials: credentials)
    }

    /// Identità della sorgente per le tile `Equatable`: gli `streamId`
    /// possono coincidere fra sorgenti diverse, e senza questa chiave una
    /// tile riusata dopo il cambio sorgente conserverebbe le closure
    /// (`onTap`) della sorgente precedente.
    private var tileSourceKey: String {
        "\(credentials.host.lowercased())|\(credentials.username)"
    }

    /// Host del provider, usato per risolvere le icone con percorso
    /// relativo (`/images/x.png`) restituite da alcuni pannelli Xtream.
    private var imageBaseHost: String {
        credentials.host
    }

    private var isCompactGrid: Bool {
        channelGridDensity == "compact"
    }

    /// "Poster": solo VOD e Serie TV, scelta dal menu "…". In Live TV un
    /// eventuale valore "poster" condiviso vale come "Comoda".
    private var isPosterGrid: Bool {
        kind != .live && channelGridDensity == "poster"
    }

    /// Locandine grandi con testo sotto la card: solo la modalità "Poster".
    private var usesLargePosters: Bool {
        isPosterGrid
    }

    /// Larghezza misurata del contenitore della griglia (0 finché non è
    /// stata misurata): serve alla modalità "Poster" per calcolare colonne
    /// e larghezza delle locandine.
    @State private var gridContainerWidth: CGFloat = 0

    private var largePosterColumnCount: Int {
        guard gridContainerWidth > 0 else { return 2 }

        let usable = gridContainerWidth - 2 * GridMetrics.posterHorizontalPadding
        let pitch = GridMetrics.posterReferenceWidth + GridMetrics.posterColumnSpacing
        let count = Int(((usable + GridMetrics.posterColumnSpacing) / pitch).rounded())

        return max(2, count)
    }

    /// Larghezza della locandina "Poster": ricavata dalla larghezza reale
    /// così margini e spazi restano esattamente 16 / 10 pt.
    private var largePosterWidth: CGFloat {
        guard gridContainerWidth > 0 else { return GridMetrics.posterReferenceWidth }

        let count = CGFloat(largePosterColumnCount)
        let usable = gridContainerWidth
            - 2 * GridMetrics.posterHorizontalPadding
            - (count - 1) * GridMetrics.posterColumnSpacing

        return max(1, (usable / count).rounded(.down))
    }

    private var largePosterHeight: CGFloat {
        (largePosterWidth * GridMetrics.posterAspectRatio).rounded()
    }

    /// Larghezza esatta occupata dalle colonne fisse della modalità "Poster".
    private var largePosterGridWidth: CGFloat {
        let count = CGFloat(largePosterColumnCount)
        return count * largePosterWidth + (count - 1) * GridMetrics.posterColumnSpacing
    }

    private var columns: [GridItem] {
        if usesLargePosters {
            return Array(
                repeating: GridItem(
                    .fixed(largePosterWidth),
                    spacing: GridMetrics.posterColumnSpacing,
                    alignment: .topLeading
                ),
                count: largePosterColumnCount
            )
        }

        if isCompactGrid {
            return [
                GridItem(
                    .adaptive(
                        minimum: GridMetrics.compactColumnMinimum,
                        maximum: GridMetrics.compactColumnMaximum
                    ),
                    spacing: GridMetrics.compactColumnSpacing
                )
            ]
        }

        return [
            GridItem(
                .adaptive(
                    minimum: GridMetrics.comfortableColumnMinimum,
                    maximum: GridMetrics.comfortableColumnMaximum
                ),
                spacing: GridMetrics.comfortableColumnSpacing
            )
        ]
    }

    private var gridRowSpacing: CGFloat {
        if usesLargePosters { return GridMetrics.posterRowSpacing }
        return isCompactGrid ? GridMetrics.compactRowSpacing : GridMetrics.comfortableRowSpacing
    }

    private var gridHorizontalPadding: CGFloat {
        if usesLargePosters { return GridMetrics.posterHorizontalPadding }
        return isCompactGrid ? GridMetrics.compactHorizontalPadding : GridMetrics.comfortableHorizontalPadding
    }

    private var artworkSize: CGFloat {
        if usesLargePosters { return largePosterWidth }
        return isCompactGrid ? GridMetrics.compactArtworkSize : GridMetrics.comfortableArtworkSize
    }

    private var moviePosterHeight: CGFloat {
        if usesLargePosters { return largePosterHeight }
        return isCompactGrid ? GridMetrics.compactMoviePosterHeight : GridMetrics.comfortableMoviePosterHeight
    }

    private var seriesPosterHeight: CGFloat {
        if usesLargePosters { return largePosterHeight }
        return isCompactGrid ? GridMetrics.compactSeriesPosterHeight : GridMetrics.comfortableSeriesPosterHeight
    }

    /// Griglia "Poster": larghezza esatta delle colonne fisse e
    /// allineamento a sinistra; negli altri casi nessun effetto.
    @ViewBuilder
    private func largePosterAlignment<Grid: View>(_ grid: Grid) -> some View {
        if usesLargePosters {
            grid
                .frame(width: largePosterGridWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            grid
        }
    }

    private var categories: [XtreamCategory] {
        xtreamCatalog.categories(for: kind)
    }

    private var allStreams: [XtreamStream] {
        xtreamCatalog.streams(for: kind)
    }

    private var allSeries: [XtreamSeriesItem] {
        xtreamCatalog.seriesItems
    }

    private var displayedStreams: [XtreamStream] {
        switch selectedCategory {
        case .all:
            return allStreams

        case .category(let categoryID):
            return catalogIndex.streamsByCategory[categoryID] ?? []

        case .uncategorized:
            return catalogIndex.uncategorizedStreams
        }
    }

    private var displayedSeries: [XtreamSeriesItem] {
        switch selectedCategory {
        case .all:
            return allSeries

        case .category(let categoryID):
            return catalogIndex.seriesByCategory[categoryID] ?? []

        case .uncategorized:
            return catalogIndex.uncategorizedSeries
        }
    }

    /// Categorie con almeno un contenuto, calcolate con un lookup O(1) sulla
    /// mappa `categoryCounts` precalcolata in `CatalogIndex`, valida sia per
    /// canali/film sia per le Serie TV in base al `kind` corrente della vista.
    private var visibleCategories: [XtreamCategory] {
        categories.filter { (catalogIndex.categoryCounts[$0.categoryId] ?? 0) > 0 }
    }

    private var uncategorizedCount: Int {
        catalogIndex.uncategorizedCount
    }

    private var itemCount: Int {
        kind == .series ? allSeries.count : allStreams.count
    }

    /// Identità "leggera" della sorgente dati correntemente mostrata, usata
    /// come `id` di `.task` per decidere quando ricostruire l'indice delle
    /// categorie e ricaricare l'EPG. Deve essere economica da calcolare: la
    /// vecchia implementazione univa in un'unica stringa id e categoria di
    /// OGNI stream e OGNI serie ad ogni singola valutazione di `body`
    /// (quindi anche durante lo scroll, per via di `.onAppear` sui tile e
    /// degli aggiornamenti di `epgByStream`), il che con cataloghi ampi
    /// — Serie TV in particolare — produceva scatti percepibili. Contare
    /// gli elementi e riusare `lastRefreshDate` (aggiornato solo quando il
    /// catalogo cambia davvero) individua gli stessi cambiamenti in O(1).
    private struct SourceIdentity: Equatable {
        let kind: XtreamStreamKind
        let host: String
        let username: String
        let lastRefreshDate: Date?
        let categoryCount: Int
        let streamCount: Int
        let seriesCount: Int
    }

    private var sourceIdentity: SourceIdentity {
        SourceIdentity(
            kind: kind,
            host: credentials.host.lowercased(),
            username: credentials.username,
            lastRefreshDate: xtreamCatalog.lastRefreshDate,
            categoryCount: categories.count,
            streamCount: allStreams.count,
            seriesCount: kind == .series ? allSeries.count : 0
        )
    }

    private var isInitialLoadPending: Bool {
        guard itemCount == 0 else { return false }

        switch xtreamCatalog.state {
        case .idle, .loading:
            return true

        default:
            return false
        }
    }

    private var shouldShowChannelNumbers: Bool {
        kind == .live && showChannelNumbers
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // Il titolo grande manuale serve solo in "Espansibile": in
                // "Scorrevole" il titolo grande di sistema (nativo) copre
                // già esattamente lo stesso comportamento richiesto.
                if groupUIStyle == "espansibile" {
                    sectionTitleHeader
                }

                if groupUIStyle == "scorrevole" {
                    categoryChips
                }

                // "Continua a guardare" come in `HomeView` (con l'immagine
                // della scheda dettaglio), ma solo con i contenuti di
                // questa sezione: film in VOD, serie in Serie TV.
                if kind != .live && !isInitialLoadPending {
                    ContinueWatchingSection(
                        kindFilter: kind.rawValue,
                        horizontalInset: 16,
                        topPadding: 8,
                        bottomPadding: 16
                    )
                }

                if isInitialLoadPending {
                    loadingView
                } else if case .failed(let message) = xtreamCatalog.state, itemCount == 0 {
                    ContentUnavailableView(
                        "Impossibile caricare il catalogo",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                    .padding(.vertical, 32)
                } else {
                    content
                        .frame(maxWidth: .infinity)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(key: ChannelGridWidthKey.self, value: proxy.size.width)
                            }
                        }
                }
            }
            .onPreferenceChange(ChannelGridWidthKey.self) { width in
                if abs(width - gridContainerWidth) > 0.5 { gridContainerWidth = width }
            }
            .navigationTitle(kind.displayName)
            // "Espansibile": la pillola del gruppo occupa lo slot del
            // titolo (`.principal`), quindi il titolo di sistema resta
            // forzato su `.inline` (il titolo grande manuale sopra lo
            // sostituisce). "Scorrevole": nessun `.principal` occupa quel
            // slot, quindi si usa `.large` per il comportamento nativo
            // (titolo grande finché non si scrolla, poi piccolo in
            // toolbar).
            .navigationBarTitleDisplayMode(groupUIStyle == "espansibile" ? .inline : .large)
            .toolbar {
                toolbarContent
            }
            .task(id: sourceIdentity) {
                // Se il catalogo e' stato svuotato (es. "Svuota cache
                // catalogo" nelle Impostazioni) mentre questa vista era
                // gia' presente, `sourceIdentity` puo' restare invariato
                // (la sorgente attiva non cambia) e nessun'altra vista
                // richiede piu' un caricamento: senza questa chiamata la
                // schermata resta bloccata su "Caricamento playlist…" pur
                // non effettuando piu' alcuna richiesta di rete.
                // `loadIfNeeded` e' innocuo da richiamare qui: se il
                // catalogo e' gia' caricato per questa sorgente torna
                // immediatamente senza rifare alcuna richiesta.
                await xtreamCatalog.loadIfNeeded(credentials: credentials)

                rebuildIndexIfNeeded()

                guard kind == .live else { return }

                await loadEPGForVisibleStreams()
            }
            .onChange(of: selectedCategory) { _, _ in
                guard kind == .live else { return }

                Task {
                    await loadEPGForVisibleStreams()
                }
            }
            .fullScreenCover(item: $selectedStream) { stream in
                if let url = service.streamURL(for: stream, kind: kind) {
                    AdaptivePlayerView(
                        url: url,
                        title: stream.name,
                        onPrevious: adjacentStream(to: stream, offset: -1).map { target in
                            { selectedStream = target }
                        },
                        onNext: adjacentStream(to: stream, offset: 1).map { target in
                            { selectedStream = target }
                        }
                    )
                    // FIX (zapping "senza uscire e riaprire il player"):
                    // `PlayerView` ora resta la STESSA istanza per tutta la
                    // sessione di visione — il controller al suo interno
                    // carica il nuovo URL in-place quando `selectedStream`
                    // cambia (vedi `.onChange(of: url)` in PlayerView).
                    // Nessun `.id(stream.id)`: forzarlo ricreerebbe l'intera
                    // vista (e il relativo `KSPlayerContainerView`) ad ogni
                    // canale, esattamente il "chiudi e riapri" che questo
                    // fix elimina.
                    //
                    // `.task(id: stream.id)` al posto di `.onAppear`: con la
                    // vista che non viene più ricreata ad ogni canale,
                    // `.onAppear` scatterebbe una sola volta per l'intera
                    // sessione di zapping (la vista "appare" una volta
                    // sola). `.task(id:)` invece si riavvia automaticamente
                    // ad ogni cambio di `stream.id`, incluso il primo,
                    // registrando correttamente ogni canale zappato nei
                    // "visti di recente".
                    .task(id: stream.id) {
                        recentlyWatched.record(
                            id: favoriteID(for: stream),
                            title: stream.name,
                            kind: kind.rawValue,
                            streamURL: url
                        )
                    }
                } else {
                    ContentUnavailableView(
                        "URL dello stream non valido",
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }
            .fullScreenCover(item: $selectedSeries) { series in
                SeriesEpisodesView(
                    credentials: credentials,
                    seriesId: series.seriesId,
                    seriesName: series.name,
                    fallbackCoverURLString: series.cover
                )
            }
            .fullScreenCover(item: $selectedMovieForDetail) { stream in
                MovieDetailView(credentials: credentials, stream: stream)
            }
            .fullScreenCover(isPresented: $showEPGGuide) {
                // EPGGridView legge i canali live direttamente da
                // `XtreamCatalogStore` tramite `@EnvironmentObject`, non da
                // un array congelato al momento dell'apertura: se il
                // catalogo si aggiorna anche DOPO l'apertura della guida,
                // la vista si ridisegna da sola con i dati corretti. Per
                // questo e' fondamentale propagare esplicitamente
                // `xtreamCatalog` anche qui, perche' il fullScreenCover
                // crea un nuovo ramo di gerarchia di presentazione.
                EPGGridView(credentials: credentials, kind: .live) { stream in
                    showEPGGuide = false
                    selectedStream = stream
                }
                .environmentObject(xtreamCatalog)
            }
            .onChange(of: kind) { _, _ in
                selectedCategory = .all
                epgByStream = [:]
            }
        }
        // FIX (root cause reale) — applicare `.id()` al CONTENUTO dentro
        // `NavigationStack` non basta: `NavigationStack` mantiene un
        // singolo `UINavigationController` persistente e il suo
        // `UINavigationItem` (dove UIKit conserva la cache di layout del
        // titolo grande) resta la STESSA istanza anche se il contenuto
        // ospitato cambia identità. Il titolo grande restava quindi
        // "bloccato" piccolo dopo lo switch Espansibile → Scorrevole.
        // Applicando `.id(groupUIStyle)` all'INTERO `NavigationStack` si
        // forza SwiftUI a distruggere e ricreare anche il
        // `UINavigationController` sottostante — e con esso il suo
        // `UINavigationItem` e ogni cache di layout — ogni volta che "UI
        // Gruppi" cambia: il titolo grande compare ora correttamente
        // subito dopo lo switch.
        .id(groupUIStyle)
    }

    /// Titolo grande della sezione (Live TV / VOD / Serie TV), usato
    /// SOLO in modalità "Espansibile" (font `.largeTitle`, grassetto),
    /// come prima vista del contenuto. Necessario perché in questa
    /// modalità il `ToolbarItem(.principal)` occupa lo spazio del titolo
    /// di navigazione impedendo al titolo di sistema di comparire grande.
    /// In "Scorrevole" questo `Text` non viene mostrato: il titolo grande
    /// nativo di sistema (`.navigationBarTitleDisplayMode(.large)`) copre
    /// già lo stesso identico comportamento richiesto.
    private var sectionTitleHeader: some View {
        Text(kind.displayName)
            .font(.largeTitle.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 8)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if groupUIStyle == "espansibile" {
            ToolbarItem(placement: .principal) {
                groupMenu
            }
        }

        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .navigationBarTrailing) {
                GlassSearchButton()
            }

            ToolbarSpacer(.fixed, placement: .navigationBarTrailing)

            ToolbarItem(placement: .navigationBarTrailing) {
                GlassSettingsButton()
            }

            if kind == .live {
                ToolbarSpacer(.fixed, placement: .navigationBarTrailing)

                ToolbarItem(placement: .navigationBarTrailing) {
                    epgGuideButton
                }
            }

            ToolbarSpacer(.fixed, placement: .navigationBarTrailing)

            ToolbarItem(placement: .navigationBarTrailing) {
                libraryMenu
            }
        } else {
            ToolbarItem(placement: .navigationBarTrailing) {
                GlassSearchButton()
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                GlassSettingsButton()
            }

            if kind == .live {
                ToolbarItem(placement: .navigationBarTrailing) {
                    epgGuideButton
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                libraryMenu
            }
        }
    }

    private var epgGuideButton: some View {
        GlassIconButton(
            systemImage: "tv.badge.wifi",
            size: 34,
            isInSystemToolbar: true,
            accessibilityLabel: "Apri guida TV"
        ) {
            showEPGGuide = true
        }
    }

    /// Selezione mostrata dal selettore densità: la modalità "Poster" esiste
    /// solo per VOD/Serie TV, quindi in Live TV (stessa chiave condivisa)
    /// vale come "Comoda", che è ciò che Live mostra davvero.
    private var densityPickerSelection: Binding<String> {
        Binding(
            get: {
                (kind == .live && channelGridDensity == "poster") ? "comfortable" : channelGridDensity
            },
            set: { channelGridDensity = $0 }
        )
    }

    /// Menu "…" con le opzioni di libreria per questa sezione (Live TV,
    /// VOD o Serie TV): densità griglia, stile dell'interfaccia dei
    /// gruppi e ricarica del catalogo. Sostituisce il precedente pulsante
    /// di ricarica isolato in toolbar (icona "arrow.clockwise", visibile
    /// solo per Live TV): "Ricarica" è ora disponibile in ogni sezione.
    private var libraryMenu: some View {
        Menu {
            Section("Libreria") {
                Menu {
                    Picker("Densità griglia", selection: densityPickerSelection) {
                        Text("Compatta").tag("compact")
                        Text("Comoda").tag("comfortable")
                        // Solo VOD e Serie TV: locandine grandi come nel
                        // riferimento (vedi `GridMetrics.poster*`).
                        if kind != .live {
                            Text("Poster").tag("poster")
                        }
                    }
                } label: {
                    Label("Densità griglia", systemImage: "square.grid.3x3")
                }

                Menu {
                    Picker("UI Gruppi", selection: $groupUIStyle) {
                        Text("Scorrevole").tag("scorrevole")
                        Text("Espansibile").tag("espansibile")
                    }
                } label: {
                    Label("UI Gruppi", systemImage: "rectangle.grid.1x2")
                }

                Button {
                    Task { await refreshCatalog() }
                } label: {
                    Label("Ricarica \(kind.displayName)", systemImage: "arrow.clockwise")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("Altre opzioni")
        .accessibilityHint("Densità griglia, stile dei gruppi e ricarica di \(kind.displayName)")
    }

    /// Selettore "Gruppo" con la stessa identica UI Liquid Glass del
    /// selettore "Gruppo playlist" di `EPGGridView` (pillola nativa
    /// `.glassEffect(.regular.interactive(), in: Capsule())` su iOS 26+,
    /// fallback `.ultraThinMaterial` + bordo sulle versioni precedenti):
    /// stesso `Menu` + `Picker(.inline)`, stessa tipografia e stesso
    /// padding della pillola, così Live TV, VOD e Serie TV condividono
    /// esattamente lo stesso selettore di gruppo della guida EPG. Portato
    /// identico da `ChannelGridView2.swift`, attivo solo quando "UI
    /// Gruppi" è impostato su "Espansibile" dal menu "…".
    private var groupMenu: some View {
        Menu {
            Picker("Gruppo", selection: $selectedCategory) {
                Label("Tutti", systemImage: "square.grid.2x2")
                    .tag(CategorySelection.all)

                if uncategorizedCount > 0 {
                    Label("Senza categoria (\(uncategorizedCount))", systemImage: "tray")
                        .tag(CategorySelection.uncategorized)
                }

                if !visibleCategories.isEmpty {
                    Divider()
                    ForEach(visibleCategories) { category in
                        Label(
                            "\(category.categoryName) (\(categoryCount(for: category.categoryId)))",
                            systemImage: Self.categoryIcon(for: category.categoryName)
                        )
                        .tag(CategorySelection.category(category.categoryId))
                    }
                }
            }
            .pickerStyle(.inline)
        } label: {
            groupPillLabel(name: currentGroupName, icon: currentGroupIcon)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Gruppo: \(currentGroupName)")
        .accessibilityHint("Tocca per scegliere il gruppo da visualizzare")
    }

    private var currentGroupName: String {
        switch selectedCategory {
        case .all:
            return "Tutti"

        case .uncategorized:
            return "Senza categoria"

        case .category(let categoryID):
            return categories.first(where: { $0.categoryId == categoryID })?.categoryName ?? "Tutti"
        }
    }

    private var currentGroupIcon: String {
        switch selectedCategory {
        case .all:
            return "square.grid.2x2"

        case .uncategorized:
            return "tray"

        case .category(let categoryID):
            guard let name = categories.first(where: { $0.categoryId == categoryID })?.categoryName else {
                return "square.grid.2x2"
            }

            return Self.categoryIcon(for: name)
        }
    }

    /// Identica, carattere per carattere, alla pillola di `EPGGridView`
    /// (`groupPillLabel`): stesso layout, stessa tipografia, stesso
    /// `.glassEffect` nativo Liquid Glass.
    @ViewBuilder
    private func groupPillLabel(name: String, icon: String) -> some View {
        let pill = HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))

            Text(name)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(minWidth: 116, maxWidth: 238, minHeight: 44)
        .contentShape(Capsule())

        if #available(iOS 26.0, *) {
            pill.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            pill
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6)
                }
        }
    }

    /// Ricarica il catalogo per la sezione corrente (Live TV, VOD o Serie
    /// TV). Stessa identica logica del precedente `refreshButton`, ora
    /// richiamata dalla voce "Ricarica" del menu "…" in ogni sezione.
    private func refreshCatalog() async {
        await xtreamCatalog.refresh(credentials: credentials, kind: kind)

        if kind == .live {
            epgByStream = [:]
            await loadEPGForVisibleStreams()
        }
    }

    @ViewBuilder
    private var content: some View {
        if kind == .series {
            seriesGrid
        } else if displayedStreams.isEmpty {
            ContentUnavailableView(
                "Nessun contenuto in questa sezione",
                systemImage: kind.systemImage,
                description: Text(
                    selectedCategory == .all
                        ? "La sorgente non ha restituito contenuti."
                        : "Prova una categoria diversa o aggiorna la sorgente."
                )
            )
            .padding(.vertical, 32)
        } else {
            streamsGrid
        }
    }

    @ViewBuilder
    private var seriesGrid: some View {
        if displayedSeries.isEmpty {
            ContentUnavailableView(
                "Nessuna serie in questa sezione",
                systemImage: "rectangle.stack.fill",
                description: Text(
                    selectedCategory == .all
                        ? "La sorgente non ha restituito serie."
                        : "Questa categoria non contiene serie."
                )
            )
            .padding(.vertical, 32)
        } else {
            // FIX GLITCH SCROLL SERIE TV:
            // In precedenza questa griglia applicava una `.transaction`
            // con animazione `.snappy(duration: 0.18)` su TUTTA la
            // LazyVGrid. Con cataloghi ampi (Serie TV in particolare),
            // ogni volta che una `SeriesTile` veniva riciclata/inserita
            // durante lo scroll (tramite `.onAppear` per il prefetch, o
            // per il caricamento asincrono del poster in
            // `TMDBEnrichedPoster`), SwiftUI applicava quella curva di
            // animazione anche al layout della cella, producendo
            // pop-in/scatti visibili sui poster ("animazione glitched").
            // `streamsGrid`, poco sotto, aveva già `animation = nil` per
            // lo stesso identico motivo: questa incoerenza non era stata
            // portata sulla sezione Serie TV. Ora il comportamento è
            // allineato: nessuna animazione implicita sulla transazione
            // di layout della griglia durante lo scroll.
            largePosterAlignment(LazyVGrid(columns: columns, spacing: gridRowSpacing) {
                ForEach(displayedSeries) { item in
                    SeriesTile(
                        series: item,
                        sourceKey: tileSourceKey,
                        imageBaseHost: imageBaseHost,
                        artworkWidth: artworkSize,
                        artworkHeight: seriesPosterHeight,
                        isLargePoster: usesLargePosters
                    ) {
                        selectedSeries = item
                    }
                    .equatable()
                    .id(item.seriesId)
                    .onAppear {
                        prefetchSeriesInfoIfNeeded(item)
                    }
                }
            })
            .padding(.horizontal, gridHorizontalPadding)
            .padding(.bottom)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            // Blocca esplicitamente qualunque animazione implicita che
            // potrebbe propagarsi dal cambio di categoria (chip) o dal
            // refresh del catalogo verso il layout dei poster durante lo
            // scroll: solo il conteggio/ordine degli elementi mostrati fa
            // scattare un ridisegno "silenzioso", senza curve animate.
            .animation(nil, value: selectedCategory)
        }
    }

    /// Griglia canali/film. Quando i numeri di canale sono disattivati
    /// (impostazione predefinita) evitiamo del tutto l'allocazione di
    /// `Array(displayedStreams.enumerated())`, che con cataloghi ampi
    /// veniva ricreata ad ogni render solo per calcolare un indice mai
    /// utilizzato dalla UI.
    @ViewBuilder
    private var streamsGrid: some View {
        if shouldShowChannelNumbers {
            largePosterAlignment(LazyVGrid(columns: columns, spacing: gridRowSpacing) {
                ForEach(Array(displayedStreams.enumerated()), id: \.element.id) { index, stream in
                    channelTile(for: stream, channelNumber: index + 1)
                }
            })
            .padding(.horizontal, gridHorizontalPadding)
            .padding(.bottom)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        } else {
            largePosterAlignment(LazyVGrid(columns: columns, spacing: gridRowSpacing) {
                ForEach(displayedStreams) { stream in
                    channelTile(for: stream, channelNumber: nil)
                }
            })
            .padding(.horizontal, gridHorizontalPadding)
            .padding(.bottom)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }

    @ViewBuilder
    private func channelTile(for stream: XtreamStream, channelNumber: Int?) -> some View {
        ChannelTile(
            stream: stream,
            kind: kind,
            sourceKey: tileSourceKey,
            imageBaseHost: imageBaseHost,
            channelNumber: channelNumber,
            // "Compatta"/"Comoda": stile originale (Live TV, VOD, Serie TV).
            isCompact: isCompactGrid,
            isLargePoster: usesLargePosters,
            artworkSize: artworkSize,
            moviePosterHeight: moviePosterHeight,
            isFavorite: contentManagement.isFavorite(id: favoriteID(for: stream)),
            currentProgram: (kind == .live && CatalogSettings.shared.showEPGInChannelTiles)
                ? (epgByStream[stream.streamId] ?? nil)
                : nil,
            onTap: {
                if kind == .movie {
                    selectedMovieForDetail = stream
                } else {
                    selectedStream = stream
                }
            },
            onFavoriteToggle: {
                contentManagement.toggleFavorite(
                    id: favoriteID(for: stream),
                    title: stream.name,
                    kind: kind.rawValue
                )
            }
        )
        .equatable()
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()

            Text("Caricamento playlist…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 48)
    }

    /// Vista gruppi "Scorrevole": chip orizzontali, comportamento storico
    /// di questa vista (invariato). Mostrata quando "UI Gruppi" è
    /// impostato su "Scorrevole" dal menu "…".
    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // `LazyHStack`: con centinaia di gruppi solo i chip visibili
            // creano il proprio vetro Liquid Glass (render molto più leggero).
            LazyHStack(spacing: 8) {
                categoryButton(
                    title: "Tutti",
                    icon: "square.grid.2x2",
                    count: itemCount,
                    selection: .all
                )

                if uncategorizedCount > 0 {
                    categoryButton(
                        title: "Senza categoria",
                        icon: "tray",
                        count: uncategorizedCount,
                        selection: .uncategorized
                    )
                }

                ForEach(visibleCategories) { category in
                    categoryButton(
                        title: category.categoryName,
                        icon: Self.categoryIcon(for: category.categoryName),
                        count: categoryCount(for: category.categoryId),
                        selection: .category(category.categoryId)
                    )
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func categoryButton(
        title: String,
        icon: String,
        count: Int,
        selection: CategorySelection
    ) -> some View {
        let isSelected = selectedCategory == selection

        return Button {
            guard selectedCategory != selection else { return }

            // L'animazione dei chip resta, ma ora è isolata al bottone
            // stesso (colore/capsule) tramite `withAnimation` locale: non
            // è più una `.transaction` che si propaga fino ai poster
            // della griglia sottostante, evitando che il cambio categoria
            // produca artefatti visivi sulle celle Serie TV.
            withAnimation(.snappy(duration: 0.16, extraBounce: 0.04)) {
                selectedCategory = selection
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)

                Text(title)
                    .lineLimit(1)

                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isSelected ? Color.white.opacity(0.78) : Color.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        // Stesso Liquid Glass del tasto "X" delle schede dettaglio
        // (vedi `NativeOrLegacyGlassChip`).
        .modifier(NativeOrLegacyGlassChip(isSelected: isSelected))
        .accessibilityLabel("\(title), \(count) contenuti")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Ricostruisce l'indice del catalogo (raggruppamento per categoria +
    /// conteggi) solo quando la sorgente è realmente cambiata. Ora copre
    /// anche il `kind == .series` (prima veniva saltato del tutto per le
    /// serie, che pagavano quindi filtri O(n) ad ogni render).
    private func rebuildIndexIfNeeded() {
        guard indexedSourceIdentity != sourceIdentity else {
            return
        }

        catalogIndex = CatalogIndex(kind: kind, streams: allStreams, series: allSeries, categories: categories)

        if kind == .live {
            epgByStream = [:]
        }

        indexedSourceIdentity = sourceIdentity
    }

    /// Lookup O(1) sulla mappa di conteggi precalcolata in `CatalogIndex`,
    /// valida sia per canali/film sia per Serie TV in base al `kind`
    /// corrente della vista.
    private func categoryCount(for categoryID: String) -> Int {
        catalogIndex.categoryCounts[categoryID] ?? 0
    }

    /// FEATURE MANCANTE aggiunta: calcola il canale/contenuto adiacente
    /// (precedente/successivo) rispetto a quello attualmente in
    /// riproduzione, all'interno della lista attualmente filtrata
    /// (`displayedStreams`: stessa categoria/gruppo selezionato). Restituisce
    /// `nil` ai bordi della lista (primo/ultimo elemento), così i pulsanti
    /// corrispondenti in `PlayerView` si nascondono automaticamente invece
    /// di restare visibili ma inattivi.
    private func adjacentStream(to stream: XtreamStream, offset: Int) -> XtreamStream? {
        guard let currentIndex = displayedStreams.firstIndex(where: { $0.id == stream.id }) else {
            return nil
        }

        let targetIndex = currentIndex + offset
        guard displayedStreams.indices.contains(targetIndex) else { return nil }

        return displayedStreams[targetIndex]
    }

    private func favoriteID(for stream: XtreamStream) -> String {
        credentials.favoriteID(kind: kind, streamId: stream.streamId)
    }

    /// Precarica in background stagioni/episodi di una serie non appena la
    /// sua card diventa visibile, così quando l'utente la apre davvero i
    /// dati sono già in cache (`CachedXtreamRepository.seriesInfo`) e
    /// `SeriesEpisodesView` non deve attendere la rete. Attivo solo se
    /// l'utente ha abilitato "Precarica dettagli serie" in Impostazioni →
    /// Catalogo: è una vera ottimizzazione di rete, non un semplice toggle
    /// decorativo.
    private func prefetchSeriesInfoIfNeeded(_ item: XtreamSeriesItem) {
        guard CatalogSettings.shared.preloadSeries else { return }

        Task {
            _ = try? await CachedXtreamRepository(credentials: credentials)
                .seriesInfo(seriesId: item.seriesId)
        }
    }

    /// Carica il programma "in onda ora" (o il prossimo, in assenza di uno
    /// corrente) per i canali attualmente visibili. I canali per cui il
    /// provider non ha restituito alcun programma vengono comunque
    /// registrati con valore `nil` esplicito, per evitare di rieseguire la
    /// stessa richiesta EPG ad ogni cambio di categoria o ricostruzione
    /// della view.
    ///
    /// OTTIMIZZAZIONE: gli esiti di ciascun batch concorrente vengono ora
    /// raccolti in un dizionario locale e applicati a `epgByStream` con
    /// un'unica scrittura per batch, invece che una scrittura per singolo
    /// canale. Questo riduce il numero di re-render dell'intera vista da
    /// fino a `missingStreams.count` a fino a `missingStreams.count /
    /// epgTileConcurrency`, senza alterare il numero di richieste di rete
    /// concorrenti né i tempi di attesa verso il provider.
    private func loadEPGForVisibleStreams() async {
        let streams = Array(displayedStreams.prefix(epgTileBatchLimit))

        guard !streams.isEmpty else { return }

        let missingStreams = streams.filter {
            epgByStream[$0.streamId] == nil
        }

        guard !missingStreams.isEmpty else { return }

        let epg = EPGService(credentials: credentials)

        for batchStart in stride(
            from: 0,
            to: missingStreams.count,
            by: epgTileConcurrency
        ) {
            guard !Task.isCancelled else { return }

            let batchEnd = min(batchStart + epgTileConcurrency, missingStreams.count)
            let batch = Array(missingStreams[batchStart..<batchEnd])

            var batchResults: [Int: EPGProgram?] = [:]
            batchResults.reserveCapacity(batch.count)

            await withTaskGroup(of: (Int, EPGProgram?).self) { group in
                for stream in batch {
                    group.addTask { [epgTileLookahead] in
                        let programs = try? await epg.shortEPG(streamId: stream.streamId, limit: epgTileLookahead)

                        let now = Date()
                        let current = programs?.first { $0.start <= now && $0.end > now }
                        let next = programs?.first { $0.start > now }

                        return (stream.streamId, current ?? next)
                    }
                }

                for await (streamID, program) in group {
                    batchResults[streamID] = program
                }
            }

            guard !Task.isCancelled else { return }

            // Unica scrittura di stato per l'intero batch: un solo
            // re-render della vista invece di uno per canale.
            for (streamID, program) in batchResults {
                epgByStream[streamID] = program
            }
        }
    }

    private static func categoryIcon(for name: String) -> String {
        let normalized = name.lowercased()

        if normalized.contains("sport") {
            return "sportscourt"
        }

        if normalized.contains("kids") || normalized.contains("cartoon") || normalized.contains("bambini") {
            return "gamecontroller"
        }

        if normalized.contains("news") || normalized.contains("notizie") {
            return "newspaper"
        }

        if normalized.contains("music") || normalized.contains("musica") {
            return "music.note"
        }

        if normalized.contains("cinema") || normalized.contains("film") || normalized.contains("movie") {
            return "film"
        }

        if normalized.contains("document") {
            return "video"
        }

        if normalized.contains("relig") {
            return "building.columns"
        }

        if normalized.contains("adult") || normalized.contains("+18") || normalized.contains("xxx") {
            return "eye.slash"
        }

        return "tv"
    }
}

private struct ChannelTile: View, Equatable {
    let stream: XtreamStream
    let kind: XtreamStreamKind
    let sourceKey: String
    let imageBaseHost: String
    let channelNumber: Int?
    let isCompact: Bool
    let isLargePoster: Bool
    let artworkSize: CGFloat
    let moviePosterHeight: CGFloat
    let isFavorite: Bool
    let currentProgram: EPGProgram?
    let onTap: () -> Void
    let onFavoriteToggle: () -> Void

    // `Equatable` sintetizzato ignorando le closure: permette a SwiftUI di
    // saltare il re-render della cella quando i dati effettivi non sono
    // cambiati durante il riciclo della LazyVGrid in scroll, riducendo
    // ridiff/animazioni implicite indesiderate sul poster.
    static func == (lhs: ChannelTile, rhs: ChannelTile) -> Bool {
        lhs.stream.id == rhs.stream.id &&
        lhs.kind == rhs.kind &&
        lhs.sourceKey == rhs.sourceKey &&
        lhs.imageBaseHost == rhs.imageBaseHost &&
        lhs.channelNumber == rhs.channelNumber &&
        lhs.isCompact == rhs.isCompact &&
        lhs.isLargePoster == rhs.isLargePoster &&
        lhs.artworkSize == rhs.artworkSize &&
        lhs.moviePosterHeight == rhs.moviePosterHeight &&
        lhs.isFavorite == rhs.isFavorite &&
        lhs.currentProgram?.title == rhs.currentProgram?.title
    }

    private var titleFont: Font {
        isCompact ? .caption2 : .caption
    }

    private var programFont: Font {
        .system(size: isCompact ? 8 : 9)
    }

    private var tileSpacing: CGFloat {
        isCompact ? 4 : 6
    }

    private var cornerRadius: CGFloat {
        isCompact ? 10 : 12
    }

    private var favoriteIconPadding: CGFloat {
        isCompact ? 5 : 7
    }

    var body: some View {
        if isLargePoster {
            largePosterBody
        } else {
            standardBody
        }
    }

    /// "Comoda" di VOD/Serie TV: testo SOTTO la card, allineato a sinistra
    /// e rientrato di 12 pt, a 5 pt dal poster (stesse misure del
    /// riferimento e di "Continua a guardare").
    private var largePosterBody: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: LargePosterStyle.titleSpacing) {
                artwork

                Text(stream.name)
                    .font(LargePosterStyle.titleFont)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, LargePosterStyle.titleInset)
                    .frame(width: artworkSize, alignment: .leading)
            }
            .frame(width: artworkSize, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var standardBody: some View {
        Button(action: onTap) {
            VStack(spacing: tileSpacing) {
                artwork

                Text(stream.name)
                    .font(titleFont)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                if let currentProgram {
                    Text(currentProgram.title)
                        .font(programFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var artwork: some View {
        ZStack(alignment: .topTrailing) {
            // Solo dati Xtream (`stream_icon`): nessuna sostituzione con
            // immagini di altre fonti mentre si scorre.
            if kind == .movie {
                CachedPosterImage(
                    urlString: stream.streamIcon,
                    baseHost: imageBaseHost,
                    width: artworkSize,
                    height: moviePosterHeight,
                    cornerRadius: isLargePoster ? LargePosterStyle.cornerRadius : 12,
                    placeholderSymbol: "film"
                )
                // Voto TMDB in alto a destra (solo badge, poster Xtream).
                .overlay(alignment: .topTrailing) {
                    GridTMDBRatingBadge(title: stream.name, isSeries: false)
                }
            } else {
                CachedPosterImage(
                    urlString: stream.streamIcon,
                    baseHost: imageBaseHost,
                    width: artworkSize,
                    height: artworkSize,
                    cornerRadius: cornerRadius,
                    placeholderSymbol: "tv"
                )
            }

            // Nei film il voto occupa l'angolo in alto a destra (come nel
            // riferimento): la stella dei preferiti passa in alto a sinistra.
            favoriteButton
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: kind == .movie ? .topLeading : .topTrailing
                )

            if let channelNumber {
                channelNumberBadge(channelNumber)
            }
        }
        .frame(
            width: artworkSize,
            height: kind == .movie ? moviePosterHeight : artworkSize
        )
    }

    private var favoriteButton: some View {
        Button(action: onFavoriteToggle) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(isCompact ? .caption2 : .caption)
                .padding(favoriteIconPadding)
                .foregroundStyle(.yellow)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: Circle())
        .padding(isCompact ? 3 : 4)
        .accessibilityLabel(isFavorite ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti")
    }

    private func channelNumberBadge(_ channelNumber: Int) -> some View {
        Text("\(channelNumber)")
            .font(.system(size: isCompact ? 9 : 10, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.primary)
            .padding(.horizontal, isCompact ? 5 : 6)
            .padding(.vertical, isCompact ? 2 : 3)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
            }
            .padding(isCompact ? 3 : 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .accessibilityLabel("Canale \(channelNumber)")
    }

    private var accessibilityLabel: String {
        guard let channelNumber else {
            return stream.name
        }

        return "Canale \(channelNumber), \(stream.name)"
    }
}

private struct SeriesTile: View, Equatable {
    let series: XtreamSeriesItem
    let sourceKey: String
    let imageBaseHost: String
    let artworkWidth: CGFloat
    let artworkHeight: CGFloat
    let isLargePoster: Bool
    let onTap: () -> Void

    // Come per `ChannelTile`: `Equatable` sintetizzato sui soli dati
    // rilevanti per il rendering, ignorando la closure `onTap`. Questo è
    // il fix chiave lato-cella per il glitch dei poster in Serie TV:
    // durante lo scroll rapido, `LazyVGrid` continua a riciclare/ricreare
    // istanze di `SeriesTile` per righe che rientrano nella viewport.
    // Senza `Equatable`, SwiftUI non ha modo di sapere che una cella
    // riciclata rappresenta esattamente la stessa serie con le stesse
    // dimensioni, quindi la ridiffa e la ridisegna da capo — che con la
    // transazione animata precedentemente attiva sulla griglia produceva
    // l'animazione "glitched" segnalata. Con `Equatable` + transazione
    // senza animazione, la cella viene semplicemente riusata senza alcun
    // ridisegno/animazione spuria.
    static func == (lhs: SeriesTile, rhs: SeriesTile) -> Bool {
        lhs.series.seriesId == rhs.series.seriesId &&
        lhs.sourceKey == rhs.sourceKey &&
        lhs.imageBaseHost == rhs.imageBaseHost &&
        lhs.series.name == rhs.series.name &&
        lhs.series.cover == rhs.series.cover &&
        lhs.artworkWidth == rhs.artworkWidth &&
        lhs.artworkHeight == rhs.artworkHeight &&
        lhs.isLargePoster == rhs.isLargePoster
    }

    var body: some View {
        Button(action: onTap) {
            VStack(
                alignment: isLargePoster ? .leading : .center,
                spacing: isLargePoster ? LargePosterStyle.titleSpacing : 4
            ) {
                // Solo dati Xtream (`cover`): nessun poster TMDB in griglia.
                CachedPosterImage(
                    urlString: series.cover,
                    baseHost: imageBaseHost,
                    width: artworkWidth,
                    height: artworkHeight,
                    cornerRadius: isLargePoster ? LargePosterStyle.cornerRadius : 12,
                    placeholderSymbol: "rectangle.stack.fill"
                )
                // Voto TMDB in alto a destra (solo badge, poster Xtream).
                .overlay(alignment: .topTrailing) {
                    GridTMDBRatingBadge(title: series.name, isSeries: true)
                }

                if isLargePoster {
                    // "Poster": testo sotto la card, a sinistra, rientrato.
                    Text(series.name)
                        .font(LargePosterStyle.titleFont)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, LargePosterStyle.titleInset)
                        .frame(width: artworkWidth, alignment: .leading)
                } else {
                    Text(series.name)
                        .font(.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: isLargePoster ? artworkWidth : nil, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(series.name)
    }
}


// MARK: - Voto TMDB sul poster (solo badge)

/// Badge del voto TMDB sulle locandine VOD/Serie TV della griglia: stessa
/// implementazione (ricerca per titolo su `TMDBService.shared`, badge in
/// alto a destra bianco su fondo scuro) della vecchia `TMDBEnrichedPoster`
/// con `badgeStyle: .topTrailing`. A differenza di allora NON tocca il
/// poster: l'immagine resta sempre quella Xtream, quindi la comparsa del
/// voto non può far "saltare" la cella durante lo scroll. Il voto già
/// ottenuto viene riletto in modo sincrono all'`init` (cella riciclata =
/// badge subito presente, nessun pop-in).
private struct GridTMDBRatingBadge: View {
    let title: String
    let isSeries: Bool

    @State private var rating: Double?
    @State private var didAttemptLookup = false

    private static let known: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 5000
        return cache
    }()

    init(title: String, isSeries: Bool) {
        self.title = title
        self.isSeries = isSeries

        if let cached = Self.known.object(forKey: Self.key(title: title, isSeries: isSeries)) {
            _rating = State(initialValue: cached.doubleValue > 0 ? cached.doubleValue : nil)
            _didAttemptLookup = State(initialValue: true)
        }
    }

    private static func key(title: String, isSeries: Bool) -> NSString {
        "\(isSeries ? "tv" : "movie")::\(title)" as NSString
    }

    var body: some View {
        Group {
            if let rating, rating > 0 {
                Text(String(format: "%.1f", rating))
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(5)
            }
        }
        .transaction { $0.animation = nil }
        .task {
            guard !didAttemptLookup, TMDBService.hasAPIKey else { return }
            didAttemptLookup = true

            let result = try? await TMDBService.shared.lookup(title: title, isSeries: isSeries)

            // Task annullato (cella uscita dallo schermo): non memorizzare
            // un falso "nessun voto", sarà riprovato al prossimo ingresso.
            guard !Task.isCancelled else {
                didAttemptLookup = false
                return
            }

            let value = result?.voteAverage ?? 0
            Self.known.setObject(NSNumber(value: value), forKey: Self.key(title: title, isSeries: isSeries))
            rating = value > 0 ? value : nil
        }
    }
}

// MARK: - Immagini poster/icone Xtream senza sfarfallio

/// Cache in memoria + risoluzione robusta degli URL delle immagini del
/// catalogo Xtream. La lettura dalla cache è sincrona (`NSCache` è
/// thread-safe), così una cella riciclata mostra l'immagine al primo frame.
enum PosterImageStore {
    static let memory: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 800
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()

    /// Lato massimo in pixel dell'immagine decodificata.
    static let maxPixelSize: CGFloat = 480

    /// Caratteri che NON vanno ri-codificati: `%` incluso, per non
    /// codificare due volte URL già percent-encoded.
    private static let urlSafe: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "!#$&'()*+,/:;=?@[]%-._~")
        return set
    }()

    /// Trasforma il valore grezzo di `stream_icon` / `cover` in un URL
    /// scaricabile. I pannelli Xtream restituiscono spesso valori che
    /// `URL(string:)` o `AsyncImage` non sanno usare così come sono:
    /// - percorsi relativi al server (`/images/x.png`, `images/x.png`);
    /// - URL "protocol-relative" (`//cdn.host/x.png`);
    /// - slash escapati (`http:\/\/host\/x.png`) e backslash di Windows;
    /// - spazi o caratteri non ASCII non codificati (nome file con spazi);
    /// - segnaposto testuali (`null`, `none`, `n/a`, `0`).
    static func url(from raw: String?, baseHost: String) -> URL? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))),
              !text.isEmpty else {
            return nil
        }

        if ["null", "none", "n/a", "nil", "0", "false", "undefined"].contains(text.lowercased()) {
            return nil
        }

        text = text.replacingOccurrences(of: "\\/", with: "/")
        if !text.contains("://") {
            text = text.replacingOccurrences(of: "\\", with: "/")
        }

        let base = URLComponents(string: baseHost.trimmingCharacters(in: .whitespacesAndNewlines))

        if text.hasPrefix("//") {
            text = "\(base?.scheme ?? "http"):\(text)"
        } else if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            // Relativo al server del provider.
            guard let scheme = base?.scheme, let host = base?.host else { return nil }

            var origin = "\(scheme)://\(host)"
            if let port = base?.port { origin += ":\(port)" }

            text = origin + (text.hasPrefix("/") ? "" : "/") + text
        }

        let url = URL(string: text)
            ?? text.addingPercentEncoding(withAllowedCharacters: urlSafe).flatMap(URL.init(string:))

        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }

        return url
    }

    /// Chiave di cache: l'URL stesso per la dimensione standard (tile della
    /// griglia), URL + frammento per le dimensioni maggiori (es. card
    /// "Continua a guardare"), così la stessa immagine può convivere a due
    /// risoluzioni senza che la versione piccola venga mostrata ingrandita.
    static func key(_ url: URL, maxPixel: CGFloat) -> URL {
        guard maxPixel != maxPixelSize else { return url }
        return URL(string: url.absoluteString + "#px\(Int(maxPixel))") ?? url
    }

    static func cachedImage(for url: URL, maxPixel: CGFloat = PosterImageStore.maxPixelSize) -> UIImage? {
        memory.object(forKey: key(url, maxPixel: maxPixel) as NSURL)
    }

    static func store(_ image: UIImage, for url: URL, maxPixel: CGFloat = PosterImageStore.maxPixelSize) {
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        memory.setObject(image, forKey: key(url, maxPixel: maxPixel) as NSURL, cost: cost)
    }
}

/// Accetta i certificati non validi (self-signed, scaduti, host diverso)
/// SOLO per il download delle icone del catalogo: i server immagini dei
/// provider IPTV li hanno spesso, e `AsyncImage` in quel caso falliva in
/// silenzio lasciando la cella senza poster.
final class PosterSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// Download delle immagini con: deduplica delle richieste identiche (molti
/// canali condividono la stessa icona), annullamento quando nessuna cella
/// attende più il risultato, nuovi tentativi per errori transitori
/// (timeout, 429/5xx dovuti alle troppe richieste parallele), fallback
/// https → http e breve "pausa" sugli URL falliti (mai un fallimento
/// permanente: la cella riprova al prossimo ingresso in vista).
actor PosterDownloader {
    static let shared = PosterDownloader()

    private struct Entry {
        let token: UUID
        let task: Task<UIImage?, Never>
        var waiters: Int
    }

    private var entries: [URL: Entry] = [:]
    private var failures: [URL: Date] = [:]
    private let failureCooldown: TimeInterval = 15

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = [
            "Accept": "image/webp,image/png,image/jpeg,image/*;q=0.8,*/*;q=0.5",
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        ]
        configuration.urlCache = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 300 * 1024 * 1024
        )
        return URLSession(configuration: configuration, delegate: PosterSessionDelegate(), delegateQueue: nil)
    }()

    func image(for sourceURL: URL, maxPixel: CGFloat = PosterImageStore.maxPixelSize) async -> UIImage? {
        if let cached = PosterImageStore.cachedImage(for: sourceURL, maxPixel: maxPixel) { return cached }

        // `url` è la chiave di deduplicazione/cooldown (URL + dimensione);
        // `sourceURL` è l'indirizzo reale da scaricare.
        let url = PosterImageStore.key(sourceURL, maxPixel: maxPixel)

        if let failedAt = failures[url], Date().timeIntervalSince(failedAt) < failureCooldown {
            return nil
        }

        let token: UUID
        let task: Task<UIImage?, Never>

        if var existing = entries[url] {
            existing.waiters += 1
            entries[url] = existing
            token = existing.token
            task = existing.task
        } else {
            token = UUID()
            task = Task.detached(priority: .utility) { [session] in
                await Self.fetch(sourceURL, session: session, maxPixel: maxPixel)
            }
            entries[url] = Entry(token: token, task: task, waiters: 1)
        }

        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.release(url, token: token) }
        }

        // Il chiamante è stato annullato (cella uscita dallo schermo):
        // `release` ha già aggiornato i contatori.
        if Task.isCancelled { return nil }

        if entries[url]?.token == token { entries[url] = nil }

        if let image {
            PosterImageStore.store(image, for: sourceURL, maxPixel: maxPixel)
            failures[url] = nil
        } else {
            failures[url] = Date()
        }

        return image
    }

    private func release(_ url: URL, token: UUID) {
        guard var entry = entries[url], entry.token == token else { return }

        entry.waiters -= 1

        if entry.waiters <= 0 {
            entry.task.cancel()
            entries[url] = nil
        } else {
            entries[url] = entry
        }
    }

    private static func fetch(_ url: URL, session: URLSession, maxPixel: CGFloat) async -> UIImage? {
        var candidates = [url]

        // Molti server immagini dei provider espongono solo http: se https
        // fallisce si prova la stessa risorsa in chiaro (ATS già aperto).
        if url.scheme?.lowercased() == "https",
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = "http"
            if let fallback = components.url { candidates.append(fallback) }
        }

        for candidate in candidates {
            for attempt in 0..<3 {
                if Task.isCancelled { return nil }

                switch await download(candidate, session: session, maxPixel: maxPixel) {
                case .image(let image):
                    return image

                case .permanentFailure:
                    break

                case .transientFailure:
                    if attempt < 2 {
                        try? await Task.sleep(nanoseconds: UInt64(400_000_000) << UInt64(attempt))
                        continue
                    }
                }

                break
            }
        }

        return nil
    }

    private enum DownloadOutcome {
        case image(UIImage)
        case transientFailure
        case permanentFailure
    }

    private static func download(_ url: URL, session: URLSession, maxPixel: CGFloat) async -> DownloadOutcome {
        do {
            let (data, response) = try await session.data(from: url)

            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                // Troppe richieste / errori del server: ritentabili.
                return [408, 425, 429, 500, 502, 503, 504, 509, 512, 520, 521, 522, 524].contains(http.statusCode)
                    ? .transientFailure
                    : .permanentFailure
            }

            guard !data.isEmpty, let image = decode(data, maxPixel: maxPixel) else { return .permanentFailure }

            return .image(image)
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                return .permanentFailure

            case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                 .dnsLookupFailed, .cannotFindHost, .resourceUnavailable:
                return .transientFailure

            default:
                return .permanentFailure
            }
        } catch {
            return .permanentFailure
        }
    }

    /// Decodifica ridimensionata con ImageIO (leggera, fuori dal main
    /// thread); se ImageIO non la riconosce ripiega su `UIImage(data:)`.
    private static func decode(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary

        if let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) {
            let thumbnailOptions = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ] as CFDictionary

            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) {
                return UIImage(cgImage: cgImage)
            }
        }

        return UIImage(data: data)
    }
}

/// Immagine di griglia (poster o logo canale) con comportamento stabile in
/// scroll: placeholder neutro, immagine mostrata subito se già in cache,
/// comparsa SENZA animazione.
struct CachedPosterImage: View {
    let urlString: String?
    let baseHost: String
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let placeholderSymbol: String
    var contentMode: ContentMode = .fit
    var maxPixel: CGFloat = PosterImageStore.maxPixelSize

    private let resolvedURL: URL?

    @State private var image: UIImage?
    @State private var imageURL: URL?

    init(
        urlString: String?,
        baseHost: String,
        width: CGFloat,
        height: CGFloat,
        cornerRadius: CGFloat,
        placeholderSymbol: String,
        contentMode: ContentMode = .fit,
        maxPixel: CGFloat = PosterImageStore.maxPixelSize
    ) {
        self.urlString = urlString
        self.baseHost = baseHost
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.placeholderSymbol = placeholderSymbol
        self.contentMode = contentMode
        self.maxPixel = maxPixel

        let url = PosterImageStore.url(from: urlString, baseHost: baseHost)
        resolvedURL = url

        // Lettura sincrona della cache già all'init: la cella riciclata
        // parte direttamente con l'immagine, senza frame di placeholder.
        if let url, let cached = PosterImageStore.cachedImage(for: url, maxPixel: maxPixel) {
            _image = State(initialValue: cached)
            _imageURL = State(initialValue: url)
        }
    }

    var body: some View {
        ZStack {
            if let image, imageURL == resolvedURL {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Color(uiColor: .secondarySystemFill)
                    .overlay {
                        Image(systemName: placeholderSymbol)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .transaction { $0.animation = nil }
        .task(id: resolvedURL) {
            guard let url = resolvedURL else { return }
            guard imageURL != url || image == nil else { return }

            guard let loaded = await PosterDownloader.shared.image(for: url, maxPixel: maxPixel), !Task.isCancelled else { return }

            var transaction = Transaction()
            transaction.disablesAnimations = true

            withTransaction(transaction) {
                image = loaded
                imageURL = url
            }
        }
    }
}
