import SwiftUI

struct GlobalSearchView: View {
    @EnvironmentObject var sourceManager: SourceManager
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false

    var body: some View {
        NavigationStack {
            List(results) { result in
                VStack(alignment: .leading) {
                    Text(result.title).font(.headline)
                    Text(result.sourceName).font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Ricerca globale")
            .searchable(text: $query, prompt: "Cerca in tutte le playlist")
            .onChange(of: query) { _, newValue in Task { await runSearch(newValue) } }
            .overlay { if isSearching { ProgressView() } }
        }
    }

    private func runSearch(_ text: String) async {
        guard text.count >= 2 else { results = []; return }
        isSearching = true
        let service = GlobalSearchService(configs: sourceManager.sources)
        results = await service.search(text)
        isSearching = false
    }
}
