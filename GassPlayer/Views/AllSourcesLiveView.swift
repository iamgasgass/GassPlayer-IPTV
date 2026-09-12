import SwiftUI

struct AllSourcesLiveView: View {
    let sources: [MediaSourceConfig]
    let kind: XtreamStreamKind

    @State private var groups: [AggregatedChannelGroup] = []
    @State private var isLoading = true
    @State private var selectedStream: PlayableStream?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Caricamento di tutte le liste...").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if groups.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up.slash").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Nessuna sorgente Xtream abilitata trovata.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(groups) { group in
                            Section {
                                if let error = group.error {
                                    Label(error, systemImage: "exclamationmark.triangle")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                                ForEach(group.streams) { stream in
                                    Button(stream.name) {
                                        selectedStream = PlayableStream(stream: stream, credentials: group.credentials)
                                    }
                                }
                            } header: {
                                HStack {
                                    Text(group.sourceName)
                                    Spacer()
                                    Text("\(group.streams.count) canali").font(.caption2)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Tutte le liste — \(kind.displayName)")
            .task { await loadAll() }
            .refreshable { await loadAll() }
            .fullScreenCover(item: $selectedStream) { playable in
                if let url = XtreamAPIService(credentials: playable.credentials).streamURL(for: playable.stream, kind: kind) {
                    PlayerView(url: url, title: playable.stream.name)
                } else {
                    Text("URL dello stream non valido.")
                }
            }
        }
    }

    private func loadAll() async {
        isLoading = true
        let service = AggregatedSourceService()
        groups = await service.fetchLiveChannels(from: sources, kind: kind)
        isLoading = false
    }
}

private struct PlayableStream: Identifiable {
    let stream: XtreamStream
    let credentials: XtreamCredentials
    var id: Int { stream.streamId }
}
