import SwiftUI

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
/// "Scorrevole"):
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
/// FIX 2026-09-25 (titolo bloccato piccolo dopo lo switch, SENZA
/// instabilizzare il menu "…" — TERZO tentativo, quello corretto):
///
/// Il tentativo precedente applicava `.id(groupUIStyle)` all'INTERO
/// `NavigationStack` per forzare UIKit a ricalcolare lo stato del titolo
/// grande. Risolveva il titolo, ma introduceva una regressione grave: la
/// riga `Picker("UI Gruppi", selection: $groupUIStyle)` sta DENTRO al
/// menu "…" — selezionare "Scorrevole"/"Espansibile" scrive su
/// `groupUIStyle`, e siccome quello stesso valore era anche l'`id()` di
/// TUTTO l'albero, l'intera vista (incluso il menu che si stava ancora
/// chiudendo) veniva distrutta e ricreata a metà interazione: il menu
/// smetteva di rispondere ai tap, e qualunque altro re-render successivo
/// (EPG, refresh catalogo) rischiava di ripetere la stessa ricostruzione,
/// dando la sensazione di "ricarica sempre".
///
/// La correzione corretta usa `LargeTitleRefreshBridge`, un piccolo ponte
/// UIKit (`UIViewControllerRepresentable`) che NON tocca in alcun modo
/// l'albero delle vista SwiftUI: individua il `UINavigationController`
/// più vicino e forza un ciclo nascondi/mostra sulla sua navigation bar
/// — tecnica nota per costringere UIKit a ricalcolare da zero il layout
/// del titolo grande — SOLO quando `groupUIStyle` cambia davvero
/// (tracciato in un `Coordinator`, non ad ogni render). Nessun `@State`
/// viene azzerato, nessuna vista (incluso il menu "…") viene distrutta:
/// il titolo si corregge, il menu resta stabile e reattivo.
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

    private var isCompactGrid: Bool {
        channelGridDensity == "compact"
    }

    private var columns: [GridItem] {
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
        isCompactGrid ? GridMetrics.compactRowSpacing : GridMetrics.comfortableRowSpacing
    }

    private var gridHorizontalPadding: CGFloat {
        isCompactGrid ? GridMetrics.compactHorizontalPadding : GridMetrics.comfortableHorizontalPadding
    }

    private var artworkSize: CGFloat {
        isCompactGrid ? GridMetrics.compactArtworkSize : GridMetrics.comfortableArtworkSize
    }

    private var moviePosterHeight: CGFloat {
        isCompactGrid ? GridMetrics.compactMoviePosterHeight : GridMetrics.comfortableMoviePosterHeight
    }

    private var seriesPosterHeight: CGFloat {
        isCompactGrid ? GridMetrics.compactSeriesPosterHeight : GridMetrics.comfortableSeriesPosterHeight
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
                }
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
            // FIX titolo bloccato piccolo dopo lo switch — ponte UIKit
            // non distruttivo: NON tocca l'albero SwiftUI (a differenza
            // di un `.id()` su `NavigationStack`, che instabilizzava il
            // menu "…"). Vedi commento di testa al file per l'analisi
            // completa.
            .background(LargeTitleRefreshBridge(trigger: groupUIStyle))
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
                    // FIX (zapping "senza uscire e riaprire il player"):
                    // `PlayerView` resta la STESSA istanza per tutta la
                    // sessione di visione — il controller al suo interno
                    // carica il nuovo URL in-place quando `selectedStream`
                    // cambia (vedi `.onChange(of: url)` in PlayerView).
                    // Nessun `.id(stream.id)` qui: forzarlo ricreerebbe
                    // l'intera vista (e il relativo
                    // `KSPlayerContainerView`) ad ogni canale, esattamente
                    // il "chiudi e riapri" che questo fix elimina.
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
                    // `.task(id: stream.id)` al posto di `.onAppear`: con
                    // la vista che non viene più ricreata ad ogni canale,
                    // `.onAppear` scatterebbe una sola volta per l'intera
                    // sessione di zapping (la vista "appare" una volta
                    // sola). `.task(id:)` invece si riavvia
                    // automaticamente ad ogni cambio di `stream.id`,
                    // incluso il primo, registrando correttamente ogni
                    // canale zappato nei "visti di recente".
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
            .navigationDestination(item: $selectedSeries) { series in
                SeriesEpisodesView(
                    credentials: credentials,
                    seriesId: series.seriesId,
                    seriesName: series.name
                )
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

    /// Menu "…" con le opzioni di libreria per questa sezione (Live TV,
    /// VOD o Serie TV): densità griglia, stile dell'interfaccia dei
    /// gruppi e ricarica del catalogo. Sostituisce il precedente pulsante
    /// di ricarica isolato in toolbar (icona "arrow.clockwise", visibile
    /// solo per Live TV): "Ricarica" è ora disponibile in ogni sezione.
    private var libraryMenu: some View {
        Menu {
            Section("Libreria") {
                Menu {
                    Picker("Densità griglia", selection: $channelGridDensity) {
                        Text("Compatta").tag("compact")
                        Text("Comoda").tag("comfortable")
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
            LazyVGrid(columns: columns, spacing: gridRowSpacing) {
                ForEach(displayedSeries) { item in
                    SeriesTile(
                        series: item,
                        artworkWidth: artworkSize,
                        artworkHeight: seriesPosterHeight
                    ) {
                        selectedSeries = item
                    }
                    .id(item.seriesId)
                    .onAppear {
                        prefetchSeriesInfoIfNeeded(item)
                    }
                }
            }
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
            .animation(nil, value: displayedSeries.map(\.seriesId))
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
            LazyVGrid(columns: columns, spacing: gridRowSpacing) {
                ForEach(Array(displayedStreams.enumerated()), id: \.element.id) { index, stream in
                    channelTile(for: stream, channelNumber: index + 1)
                }
            }
            .padding(.horizontal, gridHorizontalPadding)
            .padding(.bottom)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        } else {
            LazyVGrid(columns: columns, spacing: gridRowSpacing) {
                ForEach(displayedStreams) { stream in
                    channelTile(for: stream, channelNumber: nil)
                }
            }
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
            channelNumber: channelNumber,
            isCompact: isCompactGrid,
            artworkSize: artworkSize,
            moviePosterHeight: moviePosterHeight,
            isFavorite: contentManagement.isFavorite(id: favoriteID(for: stream)),
            currentProgram: (kind == .live && CatalogSettings.shared.showEPGInChannelTiles)
                ? (epgByStream[stream.streamId] ?? nil)
                : nil,
            onTap: {
                selectedStream = stream
            },
            onFavoriteToggle: {
                contentManagement.toggleFavorite(
                    id: favoriteID(for: stream),
                    title: stream.name,
                    kind: kind.rawValue
                )
            }
        )
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
            HStack(spacing: 8) {
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
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(isSelected ? Color.accentColor : Color.clear, in: Capsule())
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(
                    Color.white.opacity(isSelected ? 0.22 : 0.12),
                    lineWidth: 0.5
                )
        }
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
        let host = credentials.host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return [host, credentials.username, kind.rawValue, String(stream.streamId)]
            .joined(separator: "|")
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

/// Ponte UIKit invisibile e NON distruttivo per il bug del titolo grande
/// bloccato piccolo dopo un cambio di `navigationBarTitleDisplayMode` a
/// runtime. A differenza di un `.id()` sul `NavigationStack` (che
/// distrugge e ricrea l'intero albero SwiftUI — incluso qualunque `Menu`
/// aperto in quel momento, instabilizzando l'interazione), questa vista
/// non ha alcun contenuto visibile e non modifica in alcun modo lo stato
/// SwiftUI: si limita a individuare il `UINavigationController` più
/// vicino e a forzare un ciclo nascondi/mostra sulla sua navigation bar,
/// tecnica nota per costringere UIKit a ricalcolare da zero il layout del
/// titolo grande. Il `Coordinator` ricorda l'ultimo valore di `trigger`
/// osservato, così l'operazione viene eseguita SOLO quando `trigger`
/// cambia realmente — non ad ogni re-render della vista (es. per
/// aggiornamenti EPG o del catalogo) — evitando qualunque ciclo di
/// "ricarica" indesiderato.
private struct LargeTitleRefreshBridge: UIViewControllerRepresentable {
    let trigger: String

    final class Coordinator {
        var lastTrigger: String?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard context.coordinator.lastTrigger != trigger else { return }
        context.coordinator.lastTrigger = trigger

        DispatchQueue.main.async {
            guard let navigationBar = uiViewController.navigationController?.navigationBar else { return }
            navigationBar.isHidden = true
            navigationBar.isHidden = false
        }
    }
}

private struct ChannelTile: View, Equatable {
    let stream: XtreamStream
    let kind: XtreamStreamKind
    let channelNumber: Int?
    let isCompact: Bool
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
        lhs.channelNumber == rhs.channelNumber &&
        lhs.isCompact == rhs.isCompact &&
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
            if kind == .movie {
                TMDBEnrichedPoster(
                    title: stream.name,
                    isSeries: false,
                    fallbackIconURL: stream.streamIcon,
                    width: artworkSize,
                    height: moviePosterHeight
                )
            } else {
                AsyncImage(url: URL(string: stream.streamIcon ?? "")) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            // Disabilita la transizione di fase implicita
                            // di AsyncImage: senza questo, ogni volta che
                            // la cella viene riciclata durante lo scroll
                            // l'immagine "fade-in" viene rianimata da zero,
                            // producendo lo sfarfallio/glitch percepito.
                            .transaction { $0.animation = nil }

                    default:
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay {
                                Image(systemName: "tv")
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }

            favoriteButton

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
    let artworkWidth: CGFloat
    let artworkHeight: CGFloat
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
        lhs.series.name == rhs.series.name &&
        lhs.series.cover == rhs.series.cover &&
        lhs.artworkWidth == rhs.artworkWidth &&
        lhs.artworkHeight == rhs.artworkHeight
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                TMDBEnrichedPoster(
                    title: series.name,
                    isSeries: true,
                    fallbackIconURL: series.cover,
                    width: artworkWidth,
                    height: artworkHeight
                )
                // Blocca eventuali animazioni implicite generate
                // internamente da `TMDBEnrichedPoster` (es. transizione
                // placeholder → immagine caricata) quando la cella viene
                // riciclata dalla griglia durante lo scroll.
                .transaction { $0.animation = nil }

                Text(series.name)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(series.name)
    }
}
