import SwiftUI

/// Sheet aperta dal pulsante "Altre fonti" nelle schede dettaglio film/
/// serie: cerca lo stesso titolo su tutte le sorgenti Xtream configurate e
/// abilitate (tranne quella corrente) tramite `GlobalSearchService`, già
/// usato dalla ricerca globale dell'app — nessuna nuova logica di rete,
/// solo un punto d'ingresso mirato "stesso titolo, altra sorgente".
struct AlternateSourcesView: View {
    let title: String
    let kind: XtreamStreamKind
    let excluding: XtreamCredentials
    let onPickMovie: (XtreamCredentials, XtreamStream) -> Void
    let onPickSeries: (XtreamCredentials, Int, String) -> Void

    @EnvironmentObject private var sourceManager: SourceManager
    @Environment(\.dismiss) private var dismiss

    @State private var results: [SearchResult] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Ricerca su altre sorgenti…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    ContentUnavailableView(
                        "Nessuna altra fonte trovata",
                        systemImage: "server.rack",
                        description: Text("\"\(title)\" non è disponibile su altre sorgenti Xtream configurate.")
                    )
                } else {
                    List(results) { result in
                        Button {
                            pick(result)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: result.kind.systemImage)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(result.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(result.sourceName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Altre fonti")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
            .task {
                await load()
            }
        }
    }

    private func load() async {
        let service = GlobalSearchService(configs: sourceManager.sources)
        let all = await service.search(title)

        results = all.filter { result in
            result.kind == kind && result.credentials != excluding
        }

        isLoading = false
    }

    private func pick(_ result: SearchResult) {
        switch result.kind {
        case .movie:
            let stream = XtreamStream(
                streamId: result.streamId,
                name: result.title,
                streamIcon: nil,
                categoryId: nil,
                containerExtension: nil
            )
            onPickMovie(result.credentials, stream)

        case .series:
            onPickSeries(result.credentials, result.streamId, result.title)

        case .live:
            break
        }

        dismiss()
    }
}
