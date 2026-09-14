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
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedPlayable: SelectedPlayable?
    @State private var selectedSeries: SelectedSeriesResult?

    var body: some View {
        NavigationStack {
            List(results) { result in
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
        guard text.count >= 2 else { results = []; return }
        isSearching = true
        let service = GlobalSearchService(configs: sourceManager.sources)
        let newResults = await service.search(text)
        guard !Task.isCancelled else { return }
        results = newResults
        isSearching = false
    }
}
