import SwiftUI

struct ChannelsView: View {
    private enum CategorySelection: Hashable {
        case all
        case category(String)
        case uncategorized
    }

    let credentials: XtreamCredentials
    var kind: XtreamStreamKind = .live

    @EnvironmentObject private var contentManagement: ContentManagementService
    @State private var categories: [XtreamCategory] = []
    @State private var allStreams: [XtreamStream] = []
    @State private var streams: [XtreamStream] = []
    @State private var seriesItems: [XtreamSeriesItem] = []
    @State private var selectedCategory: CategorySelection = .all
    @State private var selectedStream: XtreamStream?
    @State private var selectedSeries: XtreamSeriesItem?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var showUnplayableAlert = false

    private var repository: CachedXtreamRepository { CachedXtreamRepository(credentials: credentials) }
    private var service: XtreamAPIService { XtreamAPIService(credentials: credentials) }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Categorie") {
                    if kind != .series {
                        categoryButton("Tutti (\(allStreams.count))", selection: .all)
                        if uncategorizedCount > 0 {
                            categoryButton("Senza categoria (\(uncategorizedCount))", selection: .uncategorized)
                        }
                    }

                    ForEach(visibleCategories) { category in
                        categoryButton(
                            "\(category.categoryName) (\(categoryCount(for: category.categoryId)))",
                            selection: .category(category.categoryId)
                        )
                    }
                }

                Section("Contenuti") {
                    if isLoading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if kind == .series {
                        ForEach(seriesItems) { series in
                            Button(series.name) { selectedSeries = series }
                        }
                    } else if streams.isEmpty {
                        ContentUnavailableView(
                            "Nessun contenuto",
                            systemImage: kind.systemImage,
                            description: Text("Non ci sono elementi nella categoria selezionata.")
                        )
                    } else {
                        ForEach(streams) { stream in
                            HStack(spacing: 12) {
                                Button { selectStream(stream) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(stream.name).foregroundStyle(.primary)
                                        if kind == .movie, let extensionName = stream.containerExtension, !extensionName.isEmpty {
                                            Text(extensionName.uppercased())
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                Button {
                                    contentManagement.toggleFavorite(
                                        id: favoriteID(for: stream),
                                        title: stream.name,
                                        kind: kind.rawValue
                                    )
                                } label: {
                                    Image(systemName: contentManagement.isFavorite(id: favoriteID(for: stream)) ? "star.fill" : "star")
                                        .foregroundStyle(.yellow)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Preferito: \(stream.name)")
                            }
                        }
                    }
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
            .task(id: kind) { await loadInitialContent(forceRefresh: false) }
            .fullScreenCover(item: $selectedStream) { stream in
                if let url = service.streamURL(for: stream, kind: kind) {
                    AdaptivePlayerView(url: url, title: stream.name)
                }
            }
            .navigationDestination(item: $selectedSeries) { series in
                SeriesEpisodesView(credentials: credentials, seriesId: series.seriesId, seriesName: series.name)
            }
            .alert("Impossibile riprodurre", isPresented: $showUnplayableAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Non è stato possibile costruire un URL di streaming valido per questo contenuto.")
            }
        }
    }

    private var visibleCategories: [XtreamCategory] {
        guard kind != .series else { return categories }
        return categories.filter { categoryCount(for: $0.categoryId) > 0 }
    }

    private func categoryButton(_ title: String, selection: CategorySelection) -> some View {
        Button {
            selectedCategory = selection
            applyFilter()
        } label: {
            HStack {
                Text(title)
                Spacer()
                if selectedCategory == selection {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
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
                if let category = categories.first {
                    seriesItems = try await service.fetchSeriesList(categoryId: category.categoryId)
                } else {
                    seriesItems = try await service.fetchSeriesList()
                }
                return
            }

            allStreams = try await repository.allStreams(kind: kind, forceRefresh: forceRefresh)
            selectedCategory = .all
            applyFilter()
        } catch let error as XtreamError {
            allStreams = []
            streams = []
            errorMessage = error.errorDescription
        } catch {
            allStreams = []
            streams = []
            errorMessage = "Errore imprevisto: \(error.localizedDescription)"
        }
    }

    private func applyFilter() {
        switch selectedCategory {
        case .all:
            streams = allStreams
        case .category(let categoryID):
            streams = allStreams.filter { normalizedCategoryID($0.categoryId) == categoryID }
        case .uncategorized:
            streams = allStreams.filter(isUncategorized)
        }
    }

    private func refresh() async {
        await repository.invalidate(kind: kind)
        await loadInitialContent(forceRefresh: true)
    }

    private func selectStream(_ stream: XtreamStream) {
        guard service.streamURL(for: stream, kind: kind) != nil else {
            showUnplayableAlert = true
            return
        }
        selectedStream = stream
    }

    private func normalizedCategoryID(_ categoryID: String?) -> String? {
        guard let categoryID else { return nil }
        let normalized = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func isUncategorized(_ stream: XtreamStream) -> Bool {
        guard let categoryID = normalizedCategoryID(stream.categoryId) else { return true }
        return categoryID == "0" || !Set(categories.map(\.categoryId)).contains(categoryID)
    }

    private var uncategorizedCount: Int {
        allStreams.filter(isUncategorized).count
    }

    private func categoryCount(for categoryID: String) -> Int {
        allStreams.lazy.filter { normalizedCategoryID($0.categoryId) == categoryID }.count
    }

    private func favoriteID(for stream: XtreamStream) -> String {
        let normalizedHost = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(normalizedHost)|\(credentials.username)|\(kind.rawValue)|\(stream.streamId)"
    }
}
