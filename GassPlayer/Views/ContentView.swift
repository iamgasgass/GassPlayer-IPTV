import SwiftUI

struct ContentView: View {
    let activeCredentials: XtreamCredentials?
    let activeSourceID: String?

    @StateObject private var catalog = XtreamCatalogStore()
    @StateObject private var settings = CatalogSettings.shared
    @State private var showSettings = false
    @State private var showSearch = false

    var body: some View {
        TabView {
            ChannelsView(
                streamKind: .live,
                catalog: catalog,
                credentials: activeCredentials
            )
            .tabItem {
                Label("Live", systemImage: "tv")
            }

            ChannelsView(
                streamKind: .movie,
                catalog: catalog,
                credentials: activeCredentials
            )
            .tabItem {
                Label("Film", systemImage: "film")
            }

            ChannelsView(
                streamKind: .series,
                catalog: catalog,
                credentials: activeCredentials
            )
            .tabItem {
                Label("Serie", systemImage: "rectangle.stack")
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showSearch = true
                } label: {
                    Label("Cerca", systemImage: "magnifyingglass")
                }

                Button {
                    showSettings = true
                } label: {
                    Label("Impostazioni", systemImage: "gearshape")
                }
            }
        }
        .task(id: activeSourceID) {
            guard let activeCredentials else {
                catalog.reset()
                return
            }

            await catalog.loadIfNeeded(credentials: activeCredentials)
        }
        .sheet(isPresented: $showSearch) {
            GlobalSearchView(catalog: catalog)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                catalog: catalog,
                settings: settings,
                credentials: activeCredentials
            )
        }
    }
}
