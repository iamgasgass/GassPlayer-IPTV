import SwiftUI

struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Ora usa CachedXtreamRepository (cache + retry automatico con backoff)
/// invece di chiamare XtreamAPIService direttamente: categorie e canali
/// già caricati in questa sessione non vengono ri-scaricati ad ogni tap,
/// e un fallimento di rete temporaneo viene ritentato da solo prima di
/// mostrare un errore all'utente.
struct ChannelsView: View {
    let credentials: XtreamCredentials
    @EnvironmentObject var contentManagement: ContentManagementService
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @State private var categories: [XtreamCategory] = []
    @State private var streams: [XtreamStream] = []
    @State private var selectedStream: XtreamStream?
    @State private var playerTarget: IdentifiableURL?
    @State private var isLoadingStream = false
    @State private var loadError: String?

    private var repository: CachedXtreamRepository { CachedXtreamRepository(credentials: credentials) }
    private var api: XtreamAPIService { XtreamAPIService(credentials: credentials) }

    var body: some View {
        NavigationStack {
            List {
                if !networkMonitor.isConnected {
                    Section {
                        Label("Nessuna connessione di rete", systemImage: "wifi.slash")
                            .foregroundStyle(.red)
                    }
                } else if networkMonitor.shouldPreferLowerQuality {
                    Section {
                        Label("Rete cellulare o risparmio dati attivo: qualità limitata automaticamente", systemImage: "antenna.radiowaves.left.and.right.slash")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }

                Section("Categorie") {
                    ForEach(categories) { category in
                        Button(category.categoryName) { Task { await loadStreams(for: category) } }
                    }
                }
                Section("Canali") {
                    ForEach(streams) { stream in
                        HStack {
                            Button(stream.name) { Task { await openStream(stream) } }
                            Spacer()
                            if isLoadingStream && selectedStream?.id == stream.id {
                                ProgressView()
                            }
                            Button {
                                contentManagement.toggleFavorite(id: "\(credentials.host)-\(stream.streamId)", title: stream.name, kind: "live")
                            } label: {
                                Image(systemName: contentManagement.isFavorite(id: "\(credentials.host)-\(stream.streamId)") ? "star.fill" : "star")
                                    .foregroundStyle(.yellow)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let loadError {
                    Section { Text(loadError).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Live TV")
            .task { await loadCategories() }
            .refreshable { await loadCategories(forceRefresh: true) }
            .fullScreenCover(item: $playerTarget) { target in
                PlayerView(url: target.url, title: selectedStream?.name ?? "")
            }
        }
    }

    private func loadCategories(forceRefresh: Bool = false) async {
        if forceRefresh { await CacheService.shared.invalidate(prefix: credentials.host) }
        categories = (try? await repository.categories(kind: .live)) ?? []
    }

    private func loadStreams(for category: XtreamCategory) async {
        streams = (try? await repository.streams(kind: .live, categoryId: category.categoryId)) ?? []
    }

    private func openStream(_ stream: XtreamStream) async {
        selectedStream = stream
        isLoadingStream = true
        loadError = nil
        if let url = await api.resolvedStreamURL(for: stream.streamId, kind: .live) {
            playerTarget = IdentifiableURL(url: url)
        } else {
            loadError = "Impossibile risolvere l'URL dello stream per \(stream.name)."
        }
        isLoadingStream = false
    }
}
