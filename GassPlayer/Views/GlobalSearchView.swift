import SwiftUI

private struct SelectedSeriesResult: Identifiable, Hashable {
    let id = UUID()
    let credentials: XtreamCredentials
    let seriesId: Int
    let name: String

    static func == (lhs: SelectedSeriesResult, rhs: SelectedSeriesResult) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private struct SelectedPlayable: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let title: String

    static func == (lhs: SelectedPlayable, rhs: SelectedPlayable) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct GlobalSearchView: View {
    @EnvironmentObject var sourceManager: SourceManager
    @StateObject private var history = SearchHistoryStore()

    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedPlayable: SelectedPlayable?
    @State private var selectedSeries: SelectedSeriesResult?
    @State private var selectedKindFilter: XtreamStreamKind?

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredResults: [SearchResult] {
        guard let selectedKindFilter else { return results }
        return results.filter { $0.kind == selectedKindFilter }
    }

    var body: some View {
        NavigationStack {
            Group {
                if trimmedQuery.count < 2 {
                    recentSearchesView
                } else {
                    searchResultsView
                }
            }
            .navigationTitle("Ricerca globale")
            .searchable(text: $query, prompt: "Cerca in tutte le playlist")
            .onChange(of: query) { _, newValue in scheduleSearch(newValue) }
            .overlay { if isSearching { ProgressView() } }
            .fullScreenCover(item: $selectedPlayable) { playable in
                AdaptivePlayerView(url: playable.url, title: playable.title)
            }
            .navigationDestination(item: $selectedSeries) { selection in
                SeriesEpisodesView(credentials: selection.credentials, seriesId: selection.seriesId, seriesName: selection.name)
            }
        }
    }

    @ViewBuilder
    private var searchResultsView: some View {
        VStack(spacing: 0) {
            filterChips
            if filteredResults.isEmpty && !isSearching {
                ContentUnavailableView.search(text: query)
            } else {
                List(filteredResults) { result in
                    Button {
                        open(result)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title).font(.headline)
                                Text(result.sourceName).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: result.kind.systemImage)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(title: "Tutti (\(results.count))", isSelected: selectedKindFilter == nil) {
                    selectedKindFilter = nil
                }
                ForEach(XtreamStreamKind.allCases) { kind in
                    let count = results.filter { $0.kind == kind }.count
                    filterChip(title: "\(kind.displayName) (\(count))", isSelected: selectedKindFilter == kind) {
                        selectedKindFilter = kind
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func filterChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
    }

    @ViewBuilder
    private var recentSearchesView: some View {
        if history.items.isEmpty {
            ContentUnavailableView(
                "Cerca nel catalogo",
                systemImage: "magnifyingglass",
                description: Text("Inserisci almeno due caratteri per cercare canali, film e serie in tutte le tue sorgenti.")
            )
        } else {
            List {
                Section {
                    ForEach(history.items, id: \.self) { item in
                        Button {
                            query = item
                        } label: {
                            Label(item, systemImage: "clock.arrow.circlepath")
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { history.remove(item) } label: {
                                Label("Rimuovi", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Ricerche recenti")
                        Spacer()
                        Button("Cancella") { history.clear() }
                            .font(.caption)
                    }
                }
            }
        }
    }

    private func open(_ result: SearchResult) {
        switch result.kind {
        case .live, .movie:
            let service = XtreamAPIService(credentials: result.credentials)
            guard let url = service.streamURL(for: result.streamId, kind: result.kind) else {
                DebugLogger.logAsync(.error, "GlobalSearchView: impossibile costruire l'URL per \(result.title)")
                return
            }
            selectedPlayable = SelectedPlayable(url: url, title: result.title)
        case .series:
            selectedSeries = SelectedSeriesResult(credentials: result.credentials, seriesId: result.streamId, name: result.title)
        }
    }

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await runSearch(text)
        }
    }

    private func runSearch(_ text: String) async {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else {
            results = []
            return
        }
        isSearching = true
        let service = GlobalSearchService(configs: sourceManager.sources)
        let newResults = await service.search(text)
        guard !Task.isCancelled else { return }
        results = newResults
        history.record(text)
        selectedKindFilter = nil
        isSearching = false
    }
}
