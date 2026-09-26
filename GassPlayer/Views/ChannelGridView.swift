import SwiftUI

/// FIX/OTTIMIZZAZIONE 2026-09-20 (velocità di caricamento/ricaricamento):
///
/// 1) `CatalogIndex` ora precalcola anche il raggruppamento delle Serie TV
/// per categoria (`seriesByCategory`, `uncategorizedSeries`) e una mappa
/// `categoryCounts` unica per il `kind` corrente.
/// 2) L'aggiornamento dell'EPG nei tile (`loadEPGForVisibleStreams`) applica
/// gli esiti di un intero batch concorrente in un'unica scrittura su `epgByStream`.
/// 3) La griglia canali evita l'allocazione di `Array(displayedStreams.enumerated())`
/// quando i numeri di canale sono disattivati.
///
/// FIX 2026-09-26 (NUOVA UI DETTAGLIO VOD / SERIE TV FEDELISSIMA):
///
/// Il tap su un film VOD o una serie TV apre la scheda di dettaglio modale a tutto
/// schermo `MediaDetailSheetView` perfettamente identica al design nativo mostrato nei
/// video dimostrativi:
/// - Header con Backdrop / Poster cinematografico a pieno schermo e gradiente sfumato;
/// - Metadati completi (Badge Voto, Anno, Durata / Genere);
/// - Pulsante principale di riproduzione ("Riproduci il film" / "Riproduci Stagione X: Episodio Y");
/// - Barra azioni secondarie (Preferito 'Cuore', Audio/Muto, Scarica, Altre fonti);
/// - Trama/Sinossi espansa ad alta leggibilità;
/// - Sezione 'VALUTAZIONI' orizzontale con punteggi e percentuali (TMDB, Trakt, IMDb, Metacritic, Critiche, Pubblico);
/// - Sezione 'CAST' orizzontale con avatar circolare, nome attore e personaggio;
/// - Sezione 'EPISODI' per le Serie TV con selettore chip Stagioni (Stagione 1, 2, 3...)
///   e schede episodio con thumbnail 16:9, indicatore di progresso, codice SxxExx e sinossi dedicata.
struct ChannelGridView: View {
    private enum CategorySelection: Hashable {
        case all
        case category(String)
        case uncategorized
    }

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

    @AppStorage("gassplayer.grid.groupUIStyle")
    private var groupUIStyle = "scorrevole"

    @State private var selectedCategory: CategorySelection = .all

    // Player per Live TV
    @State private var selectedStream: XtreamStream?

    // Scheda Dettaglio Fedele per VOD e Serie TV
    @State private var detailStream: XtreamStream?
    @State private var detailSeries: XtreamSeriesItem?

    // Riproduzione diretta da dentro la scheda di dettaglio
    @State private var directPlayURL: URL?
    @State private var directPlayTitle: String = ""

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

    private var visibleCategories: [XtreamCategory] {
        categories.filter { (catalogIndex.categoryCounts[$0.categoryId] ?? 0) > 0 }
    }

    private var uncategorizedCount: Int {
        catalogIndex.uncategorizedCount
    }

    private var itemCount: Int {
        kind == .series ? allSeries.count : allStreams.count
    }

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
            .navigationBarTitleDisplayMode(groupUIStyle == "espansibile" ? .inline : .large)
            .toolbar {
                toolbarContent
            }
            .task(id: sourceIdentity) {
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
            // Riproduzione Live TV
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
            // Riproduzione diretta avviata dalla Scheda Dettaglio
            .fullScreenCover(isPresented: Binding(
                get: { directPlayURL != nil },
                set: { if !$0 { directPlayURL = nil } }
            )) {
                if let url = directPlayURL {
                    AdaptivePlayerView(url: url, title: directPlayTitle)
                }
            }
            // SCHEDA DETTAGLIO VOD MOVIE (Fedelissima 100%)
            .sheet(item: $detailStream) { movie in
                MediaDetailSheetView(
                    mediaKind: .movie(stream: movie),
                    credentials: credentials,
                    onPlayDirectStream: { url, title in
                        detailStream = nil
                        directPlayTitle = title
                        directPlayURL = url
                    },
                    onDismiss: {
                        detailStream = nil
                    }
                )
                .presentationDragIndicator(.hidden)
            }
            // SCHEDA DETTAGLIO SERIE TV (Fedelissima 100%)
            .sheet(item: $detailSeries) { series in
                MediaDetailSheetView(
                    mediaKind: .series(seriesItem: series),
                    credentials: credentials,
                    onPlayDirectStream: { url, title in
                        detailSeries = nil
                        directPlayTitle = title
                        directPlayURL = url
                    },
                    onDismiss: {
                        detailSeries = nil
                    }
                )
                .presentationDragIndicator(.hidden)
            }
            .fullScreenCover(isPresented: $showEPGGuide) {
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
            .id(groupUIStyle)
        }
    }

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
            LazyVGrid(columns: columns, spacing: gridRowSpacing) {
                ForEach(displayedSeries) { item in
                    SeriesTile(
                        series: item,
                        artworkWidth: artworkSize,
                        artworkHeight: seriesPosterHeight
                    ) {
                        detailSeries = item
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
            .animation(nil, value: displayedSeries.map(\.seriesId))
        }
    }

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
                if kind == .movie {
                    detailStream = stream
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

    private func categoryCount(for categoryID: String) -> Int {
        catalogIndex.categoryCounts[categoryID] ?? 0
    }

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

    private func prefetchSeriesInfoIfNeeded(_ item: XtreamSeriesItem) {
        guard CatalogSettings.shared.preloadSeries else { return }
        Task {
            _ = try? await CachedXtreamRepository(credentials: credentials)
                .seriesInfo(seriesId: item.seriesId)
        }
    }

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
                        let programs = try? await epg.shortEPG(
                            streamId: stream.streamId,
                            limit: epgTileLookahead
                        )
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

            for (streamID, program) in batchResults {
                epgByStream[streamID] = program
            }
        }
    }

    private static func categoryIcon(for name: String) -> String {
        let normalized = name.lowercased()
        if normalized.contains("sport") { return "sportscourt" }
        if normalized.contains("kids") || normalized.contains("cartoon") || normalized.contains("bambini") { return "gamecontroller" }
        if normalized.contains("news") || normalized.contains("notizie") { return "newspaper" }
        if normalized.contains("music") || normalized.contains("musica") { return "music.note" }
        if normalized.contains("cinema") || normalized.contains("film") || normalized.contains("movie") { return "film" }
        if normalized.contains("document") { return "video" }
        if normalized.contains("relig") { return "building.columns" }
        if normalized.contains("adult") || normalized.contains("+18") || normalized.contains("xxx") { return "eye.slash" }
        return "tv"
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
                    Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
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
}
