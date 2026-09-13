import SwiftUI

// MARK: - Root integration
// Merge CatalogRootIntegration into the view that owns AccountStore.

struct CatalogRootIntegration<Content: View>: View {
    @EnvironmentObject private var accountStore: AccountStore
    @StateObject private var catalog = XtreamCatalogStore()
    @StateObject private var settings = CatalogSettings.shared
    @State private var showSettings = false
    @State private var showSearch = false

    let content: (XtreamCatalogStore) -> Content

    var body: some View {
        content(catalog)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showSearch = true } label: {
                        Label("Cerca", systemImage: "magnifyingglass")
                    }
                    Button { showSettings = true } label: {
                        Label("Impostazioni", systemImage: "gearshape")
                    }
                }
            }
            .task(id: accountStore.activeAccount?.id) {
                guard let credentials = accountStore.activeAccount?.xtreamCredentials else {
                    catalog.reset()
                    return
                }
                await catalog.loadIfNeeded(credentials: credentials)
            }
            .sheet(isPresented: $showSearch) {
                GlobalSearchView(catalog: catalog)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(catalog: catalog, settings: settings)
            }
    }
}

// MARK: - Grid integration helpers

extension XtreamCatalogStore {
    func visibleStreams(kind: XtreamStreamKind, categoryID: String?, query: String) -> [XtreamStream] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return streams(for: kind).filter { item in
            let categoryMatches = categoryID == nil || item.categoryId == categoryID
            let textMatches = normalized.isEmpty || item.name.localizedCaseInsensitiveContains(normalized)
            return categoryMatches && textMatches
        }
    }
}

struct CatalogLoadOverlay: View {
    let state: XtreamCatalogStore.LoadState
    let isEmpty: Bool

    var body: some View {
        switch state {
        case .loadingFromDisk:
            ProgressView("Caricamento cache…").padding()
        case .loadingFromNetwork where isEmpty:
            ProgressView("Aggiornamento playlist…").padding()
        case .failed(let message) where isEmpty:
            ContentUnavailableView(
                "Catalogo non disponibile",
                systemImage: "wifi.exclamationmark",
                description: Text(message)
            )
        default:
            EmptyView()
        }
    }
}

// MARK: - Search

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

        var subtitle: String {
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
                    ContentUnavailableView("Cerca nel catalogo", systemImage: "magnifyingglass", description: Text("Inserisci almeno due caratteri."))
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(results) { result in
                        HStack(spacing: 12) {
                            AsyncImage(url: result.artworkURL) { image in image.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.15) }
                                .frame(width: 54, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.title).foregroundStyle(.primary)
                                Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Ricerca globale")
            .searchable(text: $query, prompt: "Canali, film e serie")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Chiudi") { dismiss() } } }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var catalog: XtreamCatalogStore
    @ObservedObject var settings: CatalogSettings
    @EnvironmentObject private var accountStore: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var refreshing = false
    @State private var clearing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Catalogo e sincronizzazione") {
                    Picker("Aggiornamento automatico", selection: $settings.refreshInterval) {
                        ForEach(CatalogSettings.RefreshInterval.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Aggiorna all’apertura", isOn: $settings.refreshOnLaunch)
                    if let date = settings.lastRefreshDate {
                        LabeledContent("Ultimo aggiornamento") {
                            Text(date, format: .dateTime.day().month().year().hour().minute()).foregroundStyle(.secondary)
                        }
                    }
                    Button { Task { await refresh() } } label: { Label("Aggiorna ora", systemImage: "arrow.clockwise") }
                        .disabled(refreshing || accountStore.activeAccount?.xtreamCredentials == nil)
                    Button(role: .destructive) { Task { await clearCache() } } label: { Label("Cancella cache catalogo", systemImage: "trash") }
                        .disabled(clearing)
                }
                Section("Riproduzione") {
                    Toggle("Mostra programma corrente", isOn: $settings.showEPGInChannelTiles)
                    Toggle("Precarica dettagli delle serie", isOn: $settings.preloadSeries)
                }
            }
            .navigationTitle("Impostazioni")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fine") { dismiss() } } }
        }
    }

    private func refresh() async {
        guard let credentials = accountStore.activeAccount?.xtreamCredentials else { return }
        refreshing = true
        await catalog.refresh(credentials: credentials)
        refreshing = false
    }

    private func clearCache() async {
        clearing = true
        await catalog.clearPersistedCache(credentials: accountStore.activeAccount?.xtreamCredentials)
        clearing = false
    }
}
