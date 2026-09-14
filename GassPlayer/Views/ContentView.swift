import SwiftUI

/// Identificatori delle destinazioni principali della tab bar.
/// Non usare `private`: HomeView è in un file differente dello stesso target
/// e deve poter ricevere il binding selezionato da ContentView.
enum MainTab: Hashable {
    case home
    case liveTV
    case vod
    case series
}

struct ContentView: View {
    @State private var showSplash = true
    @State private var credentials: XtreamCredentials?
    @State private var m3uPlaylistURL: URL?
    @State private var selectedTab: MainTab = .home

    @StateObject private var sourceManager = SourceManager()
    @StateObject private var lockManager = ParentalLockManager()
    @StateObject private var contentManagement = ContentManagementService()
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var m3uStore = M3UPlaylistStore()
    @StateObject private var overlayState = NavigationOverlayState()
    @StateObject private var vpnManager = PersonalVPNManager()
    @StateObject private var xtreamCatalog = XtreamCatalogStore()

    var body: some View {
        Group {
            if showSplash {
                SplashScreenView {
                    loadActiveSource()
                    showSplash = false
                }
            } else {
                mainTabs
            }
        }
        .preferredColorScheme(themeManager.theme.colorScheme)
        .environmentObject(sourceManager)
        .environmentObject(lockManager)
        .environmentObject(contentManagement)
        .environmentObject(themeManager)
        .environmentObject(m3uStore)
        .environmentObject(overlayState)
        .environmentObject(vpnManager)
        .environmentObject(xtreamCatalog)
    }

    private var mainTabs: some View {
        TabView(selection: $selectedTab) {
            HomeView(
                selectedTab: $selectedTab,
                hasActiveSource: hasActivePlayableSource
            )
            .tabItem {
                Label("Home", systemImage: "house.fill")
            }
            .tag(MainTab.home)

            liveTVTab
                .tabItem {
                    Label("Live TV", systemImage: "tv.fill")
                }
                .tag(MainTab.liveTV)

            vodTab
                .tabItem {
                    Label("VOD", systemImage: "film.fill")
                }
                .tag(MainTab.vod)

            seriesTab
                .tabItem {
                    Label("Serie TV", systemImage: "rectangle.stack.fill")
                }
                .tag(MainTab.series)
        }
        .sheet(isPresented: $overlayState.showSearch) {
            GlobalSearchView()
        }
        .sheet(isPresented: $overlayState.showSettings) {
            SettingsView()
        }
        .onChange(of: sourceManager.activeSourceId) { _, _ in
            loadActiveSource()
        }
        .task(id: xtreamSourceTaskID) {
            guard let credentials else {
                return
            }

            await xtreamCatalog.loadIfNeeded(credentials: credentials)
            vpnManager.handleAppBecameActive()
        }
    }

    @ViewBuilder
    private var liveTVTab: some View {
        if let credentials {
            ChannelGridView(credentials: credentials, kind: .live)
        } else if let m3uPlaylistURL {
            M3UChannelsView(playlistURL: m3uPlaylistURL, kind: .live)
        } else {
            EmptyLibraryView(
                kind: .live,
                title: "Nessun canale Live TV",
                message: "Aggiungi una sorgente dalle Impostazioni per visualizzare i canali in diretta."
            )
        }
    }

    @ViewBuilder
    private var vodTab: some View {
        if let credentials {
            ChannelGridView(credentials: credentials, kind: .movie)
        } else if let m3uPlaylistURL {
            M3UChannelsView(playlistURL: m3uPlaylistURL, kind: .movie)
        } else {
            EmptyLibraryView(
                kind: .movie,
                title: "Nessun film disponibile",
                message: "Aggiungi una sorgente dalle Impostazioni per visualizzare qui il catalogo VOD."
            )
        }
    }

    @ViewBuilder
    private var seriesTab: some View {
        if let credentials {
            ChannelGridView(credentials: credentials, kind: .series)
        } else if let m3uPlaylistURL {
            M3UChannelsView(playlistURL: m3uPlaylistURL, kind: .series)
        } else {
            EmptyLibraryView(
                kind: .series,
                title: "Nessuna serie disponibile",
                message: "Aggiungi una sorgente dalle Impostazioni per visualizzare qui le serie TV."
            )
        }
    }

    private var hasActivePlayableSource: Bool {
        credentials != nil || m3uPlaylistURL != nil
    }

    private var xtreamSourceTaskID: String {
        guard let credentials else {
            return "no-xtream-source"
        }

        return [
            sourceManager.activeSourceId?.uuidString ?? "none",
            normalizedHost(credentials.host),
            credentials.username
        ]
        .joined(separator: "|")
    }

    /// Carica nella UI esclusivamente la sorgente attiva e abilitata.
    /// Non effettua chiamate di rete: il catalogo Xtream viene caricato dal
    /// task identificato dal fingerprint della sorgente.
    private func loadActiveSource() {
        guard let activeSource = sourceManager.activeSource,
              activeSource.isEnabled else {
            credentials = nil
            m3uPlaylistURL = nil
            selectedTab = .home
            xtreamCatalog.reset()
            return
        }

        switch activeSource.type {
        case .xtream:
            guard
                let username = activeSource.username?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !username.isEmpty,
                let password = activeSource.password,
                !password.isEmpty
            else {
                credentials = nil
                m3uPlaylistURL = nil
                selectedTab = .home
                xtreamCatalog.reset()
                return
            }

            let nextCredentials = XtreamCredentials(
                host: activeSource.host,
                username: username,
                password: password
            )

            if shouldResetCatalog(current: credentials, next: nextCredentials) {
                xtreamCatalog.reset()
            }

            credentials = nextCredentials
            m3uPlaylistURL = nil

        case .m3u8:
            credentials = nil
            m3uPlaylistURL = validHTTPURL(from: activeSource.host)
            xtreamCatalog.reset()

            if m3uPlaylistURL == nil {
                selectedTab = .home
            }

        case .plex, .jellyfin, .emby:
            // Questi tipi restano memorizzabili in SourcesView, ma finché
            // non viene implementato il relativo adapter non vengono trattati
            // come sorgenti riproducibili dalla tab bar.
            credentials = nil
            m3uPlaylistURL = nil
            selectedTab = .home
            xtreamCatalog.reset()
        }
    }

    private func validHTTPURL(from rawValue: String) -> URL? {
        let normalizedValue = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard
            let url = URL(string: normalizedValue),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host != nil
        else {
            return nil
        }

        return url
    }

    private func shouldResetCatalog(
        current: XtreamCredentials?,
        next: XtreamCredentials
    ) -> Bool {
        guard let current else {
            return true
        }

        return normalizedHost(current.host) != normalizedHost(next.host)
            || current.username != next.username
    }

    private func normalizedHost(_ host: String) -> String {
        host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }
}
