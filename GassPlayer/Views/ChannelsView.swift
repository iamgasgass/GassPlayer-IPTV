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
    @EnvironmentObject private var xtreamCatalog: XtreamCatalogStore

    @State private var selectedCategory: CategorySelection = .all
    @State private var selectedStream: XtreamStream?
    @State private var selectedSeries: XtreamSeriesItem?
    @State private var showUnplayableAlert = false

    private var service: XtreamAPIService {
        XtreamAPIService(credentials: credentials)
    }

    private var categories: [XtreamCategory] {
        xtreamCatalog.categories(for: kind)
    }

    private var allStreams: [XtreamStream] {
        xtreamCatalog.streams(for: kind)
    }

    private var displayedStreams: [XtreamStream] {
        switch selectedCategory {
        case .all:
            return allStreams

        case .category(let categoryID):
            return allStreams.filter {
                normalizedCategoryID($0.categoryId) == categoryID
            }

        case .uncategorized:
            return allStreams.filter(isUncategorized)
        }
    }

    private var visibleCategories: [XtreamCategory] {
        guard kind != .series else { return categories }

        return categories.filter {
            categoryCount(for: $0.categoryId) > 0
        }
    }

    var body: some View {
        NavigationStack {
            List {
                switch xtreamCatalog.state {
                case .failed(let message):
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                default:
                    EmptyView()
                }

                Section("Categorie") {
                    if kind != .series {
                        categoryButton(
                            title: "Tutti",
                            count: allStreams.count,
                            selection: .all
                        )

                        if uncategorizedCount > 0 {
                            categoryButton(
                                title: "Senza categoria",
                                count: uncategorizedCount,
                                selection: .uncategorized
                            )
                        }
                    }

                    ForEach(visibleCategories) { category in
                        categoryButton(
                            title: category.categoryName,
                            count: categoryCount(for: category.categoryId),
                            selection: .category(category.categoryId)
                        )
                    }
                }

                Section("Contenuti") {
                    if case .loading = xtreamCatalog.state,
                       allStreams.isEmpty,
                       kind != .series {
                        HStack {
                            Spacer()
                            ProgressView("Caricamento playlist…")
                            Spacer()
                        }
                    } else if kind == .series {
                        seriesContent
                    } else if displayedStreams.isEmpty {
                        ContentUnavailableView(
                            "Nessun contenuto",
                            systemImage: kind.systemImage,
                            description: Text(
                                "Non ci sono elementi nella categoria selezionata."
                            )
                        )
                    } else {
                        ForEach(displayedStreams) { stream in
                            streamRow(stream)
                        }
                    }
                }
            }
            .navigationTitle(kind.displayName)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task {
                            await xtreamCatalog.refresh(
                                credentials: credentials,
                                kind: kind
                            )
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Aggiorna \(kind.displayName)")
                }
            }
            .fullScreenCover(item: $selectedStream) { stream in
                if let url = service.streamURL(for: stream, kind: kind) {
                    AdaptivePlayerView(url: url, title: stream.name)
                }
            }
            .navigationDestination(item: $selectedSeries) { series in
                SeriesEpisodesView(
                    credentials: credentials,
                    seriesId: series.seriesId,
                    seriesName: series.name
                )
            }
            .alert("Impossibile riprodurre", isPresented: $showUnplayableAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(
                    "Non è stato possibile costruire un URL di streaming valido per questo contenuto."
                )
            }
        }
    }

    @ViewBuilder
    private var seriesContent: some View {
        if xtreamCatalog.seriesItems.isEmpty {
            ContentUnavailableView(
                "Nessuna serie disponibile",
                systemImage: "rectangle.stack.fill"
            )
        } else {
            ForEach(xtreamCatalog.seriesItems) { series in
                Button(series.name) {
                    selectedSeries = series
                }
            }
        }
    }

    private func streamRow(_ stream: XtreamStream) -> some View {
        HStack(spacing: 12) {
            Button {
                selectStream(stream)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(stream.name)
                        .foregroundStyle(.primary)

                    if kind == .movie,
                       let extensionName = stream.containerExtension,
                       !extensionName.isEmpty {
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
                Image(
                    systemName: contentManagement.isFavorite(
                        id: favoriteID(for: stream)
                    )
                    ? "star.fill"
                    : "star"
                )
                .foregroundStyle(.yellow)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preferito: \(stream.name)")
        }
    }

    private func categoryButton(
        title: String,
        count: Int,
        selection: CategorySelection
    ) -> some View {
        Button {
            selectedCategory = selection
        } label: {
            HStack {
                Text(title)

                Spacer()

                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                if selectedCategory == selection {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
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

        let normalized = categoryID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        return normalized.isEmpty ? nil : normalized
    }

    private func isUncategorized(_ stream: XtreamStream) -> Bool {
        guard let categoryID = normalizedCategoryID(stream.categoryId) else {
            return true
        }

        let knownCategoryIDs = Set(categories.map(\.categoryId))
        return categoryID == "0" || !knownCategoryIDs.contains(categoryID)
    }

    private var uncategorizedCount: Int {
        allStreams.filter(isUncategorized).count
    }

    private func categoryCount(for categoryID: String) -> Int {
        allStreams.lazy.filter {
            normalizedCategoryID($0.categoryId) == categoryID
        }.count
    }

    private func favoriteID(for stream: XtreamStream) -> String {
        let host = credentials.host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return "\(host)|\(credentials.username)|\(kind.rawValue)|\(stream.streamId)"
    }
}
