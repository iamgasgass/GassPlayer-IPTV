import SwiftUI

struct ChannelGridView: View {
    private enum CategorySelection: Hashable {
        case all
        case category(String)
        case uncategorized
    }

    let credentials: XtreamCredentials
    let kind: XtreamStreamKind

    @EnvironmentObject private var contentManagement: ContentManagementService
    @State private var categories: [XtreamCategory] = []
    @State private var allStreams: [XtreamStream] = []
    @State private var filteredStreams: [XtreamStream] = []
    @State private var seriesItems: [XtreamSeriesItem] = []
    @State private var selectedCategory: CategorySelection = .all
    @State private var selectedStream: XtreamStream?
    @State private var selectedSeries: XtreamSeriesItem?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var epgByStream: [Int: EPGProgram] = [:]

    private var repository: CachedXtreamRepository { CachedXtreamRepository(credentials: credentials) }
    private var service: XtreamAPIService { XtreamAPIService(credentials: credentials) }
    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                categoryChips

                if let errorMessage {
                    ContentUnavailableView(
                        "Impossibile caricare i contenuti",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                    .padding(.vertical, 24)
                } else if kind == .series {
                    seriesGrid
                } else if filteredStreams.isEmpty, !isLoading {
                    ContentUnavailableView(
                        "Nessun contenuto in questa sezione",
                        systemImage: kind.systemImage,
                        description: Text("Prova a scegliere un'altra categoria o aggiorna la sorgente.")
                    )
                    .padding(.vertical, 24)
                } else {
                    streamsGrid
                }
            }
            .navigationTitle(kind.displayName)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { Task { await refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Aggiorna catalogo")
                }
            }
            .overlay {
                if isLoading {
                    ProgressView("Caricamento catalogo…")
                        .padding(16)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .task(id: kind) { await loadInitialContent(forceRefresh: false) }
            .fullScreenCover(item: $selectedStream) { stream in
                if let url = service.streamURL(for: stream, kind: kind) {
                    AdaptivePlayerView(url: url, title: stream.name)
                } else {
                    ContentUnavailableView("URL non valido", systemImage: "exclamationmark.triangle")
                }
            }
            .navigationDestination(item: $selectedSeries) { series in
                SeriesEpisodesView(credentials: credentials, seriesId: series.seriesId, seriesName: series.name)
            }
        }
    }

    private var seriesGrid: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(seriesItems) { series in
                SeriesTile(series: series) { selectedSeries = series }
            }
        }
        .padding()
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: seriesItems.count)
    }

    private var streamsGrid: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(filteredStreams) { stream in
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
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: filteredStreams.count)
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if kind != .series {
                    categoryButton(title: "Tutti", icon: "square.grid.2x2", count: allStreams.count, selection: .all)
                    if uncategorizedStreamsCount > 0 {
                        categoryButton(title: "Senza categoria", icon: "tray", count: uncategorizedStreamsCount, selection: .uncategorized)
                    }
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

    private var visibleCategories: [XtreamCategory] {
        guard kind != .series else { return categories }
        return categories.filter { categoryCount(for: $0.categoryId) > 0 }
    }

    private func categoryButton(title: String, icon: String, count: Int, selection: CategorySelection) -> some View {
        Button {
            selectedCategory = selection
            applyFilter()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption)
                Text(title).lineLimit(1)
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected(selection) ? Color.white : Color.primary)
        .background(isSelected(selection) ? Color.accentColor : Color.clear, in: Capsule())
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.white.opacity(isSelected(selection) ? 0.20 : 0.12), lineWidth: 0.5)
        }
        .accessibilityLabel("\(title), \(count) contenuti")
    }

    private func isSelected(_ selection: CategorySelection) -> Bool {
        selectedCategory == selection
    }

    private var uncategorizedStreamsCount: Int {
        allStreams.filter(isUncategorized).count
    }

    private func categoryCount(for categoryID: String) -> Int {
        allStreams.lazy.filter { normalizedCategoryID($0.categoryId) == categoryID }.count
    }

    private func isUncategorized(_ stream: XtreamStream) -> Bool {
        guard let categoryID = normalizedCategoryID(stream.categoryId) else { return true }
        return categoryID == "0" || !Set(categories.map(\.categoryId)).contains(categoryID)
    }

    private func normalizedCategoryID(_ categoryID: String?) -> String? {
        guard let categoryID else { return nil }
        let normalized = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func applyFilter() {
        switch selectedCategory {
        case .all:
            filteredStreams = allStreams
        case .category(let categoryID):
            filteredStreams = allStreams.filter { normalizedCategoryID($0.categoryId) == categoryID }
        case .uncategorized:
            filteredStreams = allStreams.filter(isUncategorized)
        }

        if kind == .live {
            Task { await loadEPGForVisibleStreams() }
        }
    }

    private func loadInitialContent(forceRefresh: Bool) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            categories = try await repository.categories(kind: kind, forceRefresh: forceRefresh)

            if kind == .series {
                selectedCategory = .all
                if let firstCategory = categories.first {
                    seriesItems = try await service.fetchSeriesList(categoryId: firstCategory.categoryId)
                } else {
                    seriesItems = try await service.fetchSeriesList()
                }
                return
            }

            allStreams = try await repository.allStreams(kind: kind, forceRefresh: forceRefresh)
            selectedCategory = .all
            applyFilter()

            if kind == .live {
                await loadEPGForVisibleStreams()
            }
        } catch let error as XtreamError {
            allStreams = []
            filteredStreams = []
            errorMessage = error.errorDescription
        } catch {
            allStreams = []
            filteredStreams = []
            errorMessage = "Errore imprevisto: \(error.localizedDescription)"
        }
    }

    private func refresh() async {
        await repository.invalidate(kind: kind)
        await loadInitialContent(forceRefresh: true)
    }

    private func loadEPGForVisibleStreams() async {
        let visibleStreams = Array(filteredStreams.prefix(24))
        guard !visibleStreams.isEmpty else { return }

        let epgService = EPGService(credentials: credentials)
        let batches = stride(from: 0, to: visibleStreams.count, by: 4).map {
            Array(visibleStreams[$0..<min($0 + 4, visibleStreams.count)])
        }

        for batch in batches {
            await withTaskGroup(of: (Int, EPGProgram?).self) { group in
                for stream in batch {
                    group.addTask {
                        let programs = try? await epgService.shortEPG(streamId: stream.streamId, limit: 2)
                        return (stream.streamId, programs?.first)
                    }
                }
                for await (streamID, program) in group {
                    if let program { epgByStream[streamID] = program }
                }
            }
        }
    }

    private func favoriteID(for stream: XtreamStream) -> String {
        let normalizedHost = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(normalizedHost)|\(credentials.username)|\(kind.rawValue)|\(stream.streamId)"
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
                            case .success(let image):
                                image.resizable().scaledToFit()
                            default:
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(.ultraThinMaterial)
                                    .overlay(Image(systemName: "tv").foregroundStyle(.secondary))
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
    }
}
