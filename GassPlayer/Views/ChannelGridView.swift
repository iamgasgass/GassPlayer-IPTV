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

    let credentials: XtreamCredentials
    let kind: XtreamStreamKind

    @EnvironmentObject private var contentManagement: ContentManagementService
    @EnvironmentObject private var xtreamCatalog: XtreamCatalogStore

    @State private var selectedCategory: CategorySelection = .all
    @State private var selectedStream: XtreamStream?
    @State private var selectedSeries: XtreamSeriesItem?
    @State private var epgByStream: [Int: EPGProgram] = [:]
    @State private var catalogIndex = CatalogIndex(streams: [], categories: [])
    @State private var indexedSourceIdentity = ""

    private var service: XtreamAPIService {
        XtreamAPIService(credentials: credentials)
    }

    private let columns = [
        GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 14)
    ]

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
            return allSeries.filter { CatalogIndex.normalizedCategoryID($0.categoryId) == categoryID }
        case .uncategorized:
            let categoryIDs = Set(categories.map(\.categoryId))
            return allSeries.filter {
                guard let categoryID = CatalogIndex.normalizedCategoryID($0.categoryId) else { return true }
                return categoryID == "0" || !categoryIDs.contains(categoryID)
            }
        }
    }

    private var visibleCategories: [XtreamCategory] {
        if kind == .series {
            return categories.filter { categoryCount(for: $0.categoryId) > 0 }
        }
        return categories.filter { !(catalogIndex.streamsByCategory[$0.categoryId] ?? []).isEmpty }
    }

    private var uncategorizedCount: Int {
        kind == .series ? seriesUncategorizedCount : catalogIndex.uncategorizedStreams.count
    }

    private var seriesUncategorizedCount: Int {
        let categoryIDs = Set(categories.map(\.categoryId))
        return allSeries.lazy.filter {
            guard let categoryID = CatalogIndex.normalizedCategoryID($0.categoryId) else { return true }
            return categoryID == "0" || !categoryIDs.contains(categoryID)
        }.count
    }

    private var itemCount: Int {
        kind == .series ? allSeries.count : allStreams.count
    }

    private var sourceIdentity: String {
        "\(kind.rawValue)|\(categories.map(\.categoryId).joined(separator: ","))|\(allStreams.count)"
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task {
                            await xtreamCatalog.refresh(credentials: credentials, kind: kind)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Aggiorna \(kind.displayName)")
                }
            }
            .task(id: sourceIdentity) {
                rebuildIndexIfNeeded()
                guard kind == .live else { return }
                await loadEPGForVisibleStreams()
            }
            .onChange(of: selectedCategory) { _, _ in
                guard kind == .live else { return }
                Task { await loadEPGForVisibleStreams() }
            }
            .fullScreenCover(item: $selectedStream) { stream in
                if let url = service.streamURL(for: stream, kind: kind) {
                    AdaptivePlayerView(url: url, title: stream.name)
                } else {
                    ContentUnavailableView("URL dello stream non valido", systemImage: "exclamationmark.triangle")
                }
            }
            .navigationDestination(item: $selectedSeries) { series in
                SeriesEpisodesView(credentials: credentials, seriesId: series.seriesId, seriesName: series.name)
            }
        }
        .onChange(of: kind) { _, _ in
            selectedCategory = .all
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
                description: Text(selectedCategory == .all ? "La sorgente non ha restituito contenuti." : "Prova una categoria diversa o aggiorna la sorgente.")
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
                description: Text(selectedCategory == .all ? "La sorgente non ha restituito serie." : "Questa categoria non contiene serie.")
            )
            .padding(.vertical, 32)
        } else {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(displayedSeries) { item in
                    SeriesTile(series: item) { selectedSeries = item }
                }
            }
            .padding()
            .transaction { $0.animation = .snappy(duration: 0.18) }
        }
    }

    private var streamsGrid: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(displayedStreams) { stream in
                ChannelTile(
                    stream: stream,
                    kind: kind,
                    isFavorite: contentManagement.isFavorite(id: favoriteID(for: stream)),
                    currentProgram: kind == .live ? epgByStream[stream.streamId] : nil,
                    onTap: { selectedStream = stream },
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
        .padding()
        .transaction { $0.animation = nil }
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
                categoryButton(title: "Tutti", icon: "square.grid.2x2", count: itemCount, selection: .all)

                if uncategorizedCount > 0 {
                    categoryButton(title: "Senza categoria", icon: "tray", count: uncategorizedCount, selection: .uncategorized)
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

    private func categoryButton(title: String, icon: String, count: Int, selection: CategorySelection) -> some View {
        let isSelected = selectedCategory == selection
        return Button {
            guard selectedCategory != selection else { return }
            withAnimation(.snappy(duration: 0.16, extraBounce: 0.04)) {
                selectedCategory = selection
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption)
                Text(title).lineLimit(1)
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
            Capsule().strokeBorder(Color.white.opacity(isSelected ? 0.22 : 0.12), lineWidth: 0.5)
        }
        .accessibilityLabel("\(title), \(count) contenuti")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func rebuildIndexIfNeeded() {
        guard kind != .series, indexedSourceIdentity != sourceIdentity else { return }
        catalogIndex = CatalogIndex(streams: allStreams, categories: categories)
        indexedSourceIdentity = sourceIdentity
    }

    private func categoryCount(for categoryID: String) -> Int {
        if kind == .series {
            return allSeries.lazy.filter { CatalogIndex.normalizedCategoryID($0.categoryId) == categoryID }.count
        }
        return catalogIndex.streamsByCategory[categoryID]?.count ?? 0
    }

    private func favoriteID(for stream: XtreamStream) -> String {
        let host = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(host)|\(credentials.username)|\(kind.rawValue)|\(stream.streamId)"
    }

    private func loadEPGForVisibleStreams() async {
        let streams = Array(displayedStreams.prefix(24))
        guard !streams.isEmpty else { return }

        let epg = EPGService(credentials: credentials)
        let batches = stride(from: 0, to: streams.count, by: 4).map {
            Array(streams[$0..<min($0 + 4, streams.count)])
        }

        for batch in batches {
            await withTaskGroup(of: (Int, EPGProgram?).self) { group in
                for stream in batch where epgByStream[stream.streamId] == nil {
                    group.addTask {
                        let result = try? await epg.shortEPG(streamId: stream.streamId, limit: 2)
                        return (stream.streamId, result?.first)
                    }
                }

                for await (streamID, program) in group {
                    if let program { epgByStream[streamID] = program }
                }
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
}

private struct ChannelTile: View {
    let stream: XtreamStream
    let kind: XtreamStreamKind
    let isFavorite: Bool
    let currentProgram: EPGProgram?
    let onTap: () -> Void
    let onFavoriteToggle: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    if kind == .movie {
                        TMDBEnrichedPoster(title: stream.name, isSeries: false, fallbackIconURL: stream.streamIcon, width: 100, height: 150)
                    } else {
                        AsyncImage(url: URL(string: stream.streamIcon ?? "")) { phase in
                            switch phase {
                            case .success(let image): image.resizable().scaledToFit()
                            default:
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(.ultraThinMaterial)
                                    .overlay { Image(systemName: "tv").foregroundStyle(.secondary) }
                            }
                        }
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    Button(action: onFavoriteToggle) {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.caption)
                            .padding(7)
                            .foregroundStyle(.yellow)
                    }
                    .buttonStyle(.plain)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(4)
                    .accessibilityLabel(isFavorite ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti")
                }

                Text(stream.name)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                if let currentProgram {
                    Text(currentProgram.title)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(stream.name)
    }
}

private struct SeriesTile: View {
    let series: XtreamSeriesItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                TMDBEnrichedPoster(title: series.name, isSeries: true, fallbackIconURL: series.cover, width: 100, height: 140)
                Text(series.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(series.name)
    }
}
