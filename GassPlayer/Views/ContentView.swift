import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var accountStore: AccountStore
    @StateObject private var catalog = XtreamCatalogStore()
    @StateObject private var settings = CatalogSettings.shared
    @State private var showSettings = false
    @State private var showSearch = false

    var body: some View {
        TabView {
            ChannelsView(streamKind: .live, catalog: catalog)
                .tabItem { Label("Live", systemImage: "tv") }

            ChannelsView(streamKind: .movie, catalog: catalog)
                .tabItem { Label("Film", systemImage: "film") }

            ChannelsView(streamKind: .series, catalog: catalog)
                .tabItem { Label("Serie", systemImage: "rectangle.stack") }
        }
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
