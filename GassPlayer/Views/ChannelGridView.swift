import SwiftUI

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

        init(streams: [XtreamStream], categories: [XtreamCategory]) {
            categoryIDs = Set(categories.map(\.categoryId))

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

    @AppStorage("gassplayer.grid.density")
    private var channelGridDensity = "comfortable"

    @AppStorage("gassplayer.grid.showChannelNumbers")
    private var showChannelNumbers = false

    @State private var selectedCategory: CategorySelection = .all
    @State private var selectedStream: XtreamStream?
    @State private var selectedSeries: XtreamSeriesItem?

    /// `nil` = mai interrogato; `.some(nil)` = interrogato ma nessun
    /// programma disponibile (evita retry continui); `.some(program)` =
    /// programma corrente o prossimo disponibile per il tile.
    @State private var epgByStream: [Int: EPGProgram?] = [:]

    @State private var catalogIndex = CatalogIndex(streams: [], categories: [])
    @State private var indexedSourceIdentity = ""
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
            return allSeries.filter {
                CatalogIndex.normalizedCategoryID($0.categoryId) == categoryID
            }

        case .uncategorized:
            let categoryIDs = Set(categories.map(\.categoryId))

            return allSeries.filter {
                guard let categoryID = CatalogIndex.normalizedCategoryID($0.categoryId) else {
                    return true
                }

                return categoryID == "0" || !categoryIDs.contains(categoryID)
            }
        }
    }

    private var visibleCategories: [XtreamCategory] {
        if kind == .series {
            return categories.filter {
                categoryCount(for: $0.categoryId) > 0
            }
        }

        return categories.filter {
            !(catalogIndex.streamsByCategory[$0.categoryId] ?? []).isEmpty
        }
    }

    private var uncategorizedCount: Int {
        kind == .series ? seriesUncategorizedCount : catalogIndex.uncategorizedStreams.count
    }

    private var seriesUncategorizedCount: Int {
        let categoryIDs = Set(categories.map(\.categoryId))

        return allSeries.lazy.filter {
            guard let categoryID = CatalogIndex.normalizedCategoryID($0.categoryId) else {
                return true
            }

            return categoryID == "0" || !categoryIDs.contains(categoryID)
        }
        .count
    }

    private var itemCount: Int {
        kind == .series ? allSeries.count : allStreams.count
    }

    private var sourceIdentity: String {
        let categoryIdentity = categories
            .map { "\($0.categoryId):\($0.categoryName)" }
            .joined(separator: "|")

        let streamIdentity = allStreams
            .map { "\($0.streamId):\($0.categoryId ?? "")" }
            .joined(separator: "|")

        let seriesIdentity = allSeries
            .map { "\($0.seriesId):\($0.categoryId ?? "")" }
            .joined(separator: "|")

        return [
            kind.rawValue,
            credentials.host.lowercased(),
            credentials.username,
            categoryIdentity,
            streamIdentity,
            seriesIdentity
        ]
        .joined(separator: "§")
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
                categoryChips

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
            .toolbar {
                toolbarContent
            }
            .task(id: sourceIdentity) {
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
                    AdaptivePlayerView(url: url, title: stream.name)
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
                EPGGridView(credentials: credentials, streams: allStreams) { stream in
                    showEPGGuide = false
                    selectedStream = stream
                }
            }
        }
        .onChange(of: kind) { _, _ in
            selectedCategory = .all
            epgByStream = [:]
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
                refreshButton
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
                refreshButton
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

    private var refreshButton: some View {
        Button {
            Task {
                await xtreamCatalog.refresh(credentials: credentials, kind: kind)

                if kind == .live {
                    epgByStream = [:]
                    await loadEPGForVisibleStreams()
                }
            }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .accessibilityLabel("Aggiorna \(kind.displayName)")
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
                        selectedSeries = item
                    }
                }
            }
            .padding(.horizontal, gridHorizontalPadding)
            .padding(.bottom)
            .transaction {
                $0.animation = .snappy(duration: 0.18)
            }
        }
    }

    private var streamsGrid: some View {
        LazyVGrid(columns: columns, spacing: gridRowSpacing) {
            ForEach(Array(displayedStreams.enumerated()), id: \.element.id) { index, stream in
                ChannelTile(
                    stream: stream,
                    kind: kind,
                    channelNumber: shouldShowChannelNumbers ? index + 1 : nil,
                    isCompact: isCompactGrid,
                    artworkSize: artworkSize,
                    moviePosterHeight: moviePosterHeight,
                    isFavorite: contentManagement.isFavorite(id: favoriteID(for: stream)),
                    currentProgram: kind == .live
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
        }
        .padding(.horizontal, gridHorizontalPadding)
        .padding(.bottom)
        .transaction {
            $0.animation = nil
        }
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
        guard kind != .series, indexedSourceIdentity != sourceIdentity else {
            return
        }

        catalogIndex = CatalogIndex(streams: allStreams, categories: categories)

        epgByStream = [:]
        indexedSourceIdentity = sourceIdentity
    }

    private func categoryCount(for categoryID: String) -> Int {
        if kind == .series {
            return allSeries.lazy.filter {
                CatalogIndex.normalizedCategoryID($0.categoryId) == categoryID
            }
            .count
        }

        return catalogIndex.streamsByCategory[categoryID]?.count ?? 0
    }

    private func favoriteID(for stream: XtreamStream) -> String {
        let host = credentials.host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return [host, credentials.username, kind.rawValue, String(stream.streamId)]
            .joined(separator: "|")
    }

    /// Carica il programma "in onda ora" (o il prossimo, in assenza di uno
    /// corrente) per i canali attualmente visibili. I canali per cui il
    /// provider non ha restituito alcun programma vengono comunque
    /// registrati con valore `nil` esplicito, per evitare di rieseguire la
    /// stessa richiesta EPG ad ogni cambio di categoria o ricostruzione
    /// della view.
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

            await withTaskGroup(of: (Int, EPGProgram?).self) { group in
                for stream in batch {
                    group.addTask { [epgTileLookahead] in
                        let programs = try? await epg.shortEPG(
                            streamId: stream.streamId,
                            limit: epgTileLookahead
                        )

                        let now = Date()

                        let current = programs?.first {
                            $0.start <= now && $0.end > now
                        }

                        let next = programs?.first {
                            $0.start > now
                        }

                        return (stream.streamId, current ?? next)
                    }
                }

                for await (streamID, program) in group {
                    guard !Task.isCancelled else { return }

                    epgByStream[streamID] = program
                }
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

private struct ChannelTile: View {
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

private struct SeriesTile: View {
    let series: XtreamSeriesItem
    let artworkWidth: CGFloat
    let artworkHeight: CGFloat
    let onTap: () -> Void

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
