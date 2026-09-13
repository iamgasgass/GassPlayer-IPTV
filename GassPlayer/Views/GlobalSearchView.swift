import SwiftUI

struct GlobalSearchView: View {
    enum Result: Identifiable {
        case live(XtreamStream)
        case movie(XtreamStream)
        case series(XtreamSeriesItem)

        var id: String {
            switch self {
            case .live(let item): return "live-\(item.streamId)"
            case .movie(let item): return "movie-\(item.streamId)"
            case .series(let item): return "series-\(item.seriesId)"
            }
        }

        var title: String {
            switch self {
            case .live(let item), .movie(let item): return item.name
            case .series(let item): return item.name
            }
        }

        var kind: String {
            switch self {
            case .live: return "Canale"
            case .movie: return "Film"
            case .series: return "Serie"
            }
        }

        var artworkURL: URL? {
            switch self {
            case .live(let item), .movie(let item): return URL(string: item.streamIcon ?? "")
            case .series(let item): return URL(string: item.cover ?? "")
            }
        }
    }

    @ObservedObject var catalog: XtreamCatalogStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [Result] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return [] }
        let live = catalog.liveStreams.filter { $0.name.localizedCaseInsensitiveContains(text) }.prefix(40).map(Result.live)
        let movies = catalog.vodStreams.filter { $0.name.localizedCaseInsensitiveContains(text) }.prefix(40).map(Result.movie)
        let series = catalog.seriesItems.filter { $0.name.localizedCaseInsensitiveContains(text) }.prefix(40).map(Result.series)
        return live + movies + series
    }

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
                    ContentUnavailableView(
                        "Cerca nel catalogo",
                        systemImage: "magnifyingglass",
                        description: Text("Inserisci almeno due caratteri.")
                    )
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(results) { result in
                        HStack(spacing: 12) {
                            AsyncImage(url: result.artworkURL) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Color.secondary.opacity(0.15)
                            }
                            .frame(width: 54, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.title).foregroundStyle(.primary)
                                Text(result.kind).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Ricerca globale")
            .searchable(text: $query, prompt: "Canali, film e serie")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Chiudi") { dismiss() }
                }
            }
        }
    }
}
