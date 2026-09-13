import SwiftUI

struct ContentView: View {
    @State private var showSplash = true
    @State private var credentials: XtreamCredentials?
    @State private var m3uPlaylistURL: URL?
    @State private var selectedTab = 0

    @StateObject private var sourceManager = SourceManager()
    @StateObject private var lockManager = ParentalLockManager()
    @StateObject private var contentManagement = ContentManagementService()
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var m3uStore = M3UPlaylistStore()
    @StateObject private var overlayState = NavigationOverlayState()
    @StateObject private var vpnManager = PersonalVPNManager()

    /// Canale condiviso tra SettingsView e ChannelGridView.
    ///
    /// SettingsView emette una richiesta di refresh mirata sulla sezione
    /// selezionata; soltanto la griglia della sorgente e del tipo contenuto
    /// corrispondente la riceve e ricarica il catalogo.
    @StateObject private var refreshCoordinator = CatalogRefreshCoordinator()

    var body: some View {
        Group {
            if showSplash {
                SplashScreenView {
                    showSplash = false
                    loadActiveSource()
                }
            } else if credentials != nil || m3uPlaylistURL != nil {
                TabView(selection: $selectedTab) {
                    liveTab
                        .tabItem {
                            Label("Live", systemImage: "tv")
                        }
                        .tag(0)

                    filmTab
                        .tabItem {
                            Label("Film", systemImage: "film")
                        }
                        .tag(1)

                    serieTab
                        .tabItem {
                            Label(
                                "Serie",
                                systemImage: "rectangle.stack.fill"
                            )
                        }
                        .tag(2)

                    SourcesView()
                        .tabItem {
                            Label(
                                "Sorgenti",
                                systemImage: "square.stack.3d.up"
                            )
                        }
                        .tag(3)

                    PersonalVPNView()
                        .tabItem {
                            Label("VPN", systemImage: "lock.shield")
                        }
                        .tag(4)
                }
                .background(Color.black.ignoresSafeArea())
                .sheet(isPresented: $overlayState.showSearch) {
                    GlobalSearchView()
                }
                .sheet(isPresented: $overlayState.showSettings) {
                    SettingsView()
                }
                .onChange(of: sourceManager.activeSourceId) { _, _ in
                    loadActiveSource()
                }
                .task {
                    vpnManager.handleAppBecameActive()
                }
            } else {
                LoginView(
                    onLogin: { creds in
                        credentials = creds

                        sourceManager.add(
                            MediaSourceConfig(
                                name: "Sorgente principale",
                                type: .xtream,
                                host: creds.host,
                                username: creds.username,
                                password: creds.password
                            )
                        )
                    },
                    onM3ULoaded: { url in
                        m3uPlaylistURL = url

                        sourceManager.add(
                            MediaSourceConfig(
                                name: "Playlist M3U",
                                type: .m3u8,
                                host: url.absoluteString
                            )
                        )
                    }
                )
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
        .environmentObject(refreshCoordinator)
    }

    @ViewBuilder
    private var liveTab: some View {
        if let credentials {
            ChannelGridView(
                credentials: credentials,
                kind: .live
            )
        } else if let m3uPlaylistURL {
            M3UChannelsView(
                playlistURL: m3uPlaylistURL,
                kind: .live
            )
        }
    }

    @ViewBuilder
    private var filmTab: some View {
        if let credentials {
            ChannelGridView(
                credentials: credentials,
                kind: .movie
            )
        } else if let m3uPlaylistURL {
            M3UChannelsView(
                playlistURL: m3uPlaylistURL,
                kind: .movie
            )
        }
    }

    @ViewBuilder
    private var serieTab: some View {
        if let credentials {
            ChannelGridView(
                credentials: credentials,
                kind: .series
            )
        } else if let m3uPlaylistURL {
            M3UChannelsView(
                playlistURL: m3uPlaylistURL,
                kind: .series
            )
        }
    }

    /// Ripristina lo stato visualizzato quando l’utente cambia sorgente.
    ///
    /// Per Xtream abilita le tre griglie ChannelGridView e disabilita M3U;
    /// per M3U fa l’opposto. Questo evita che una vecchia sorgente resti
    /// attiva in memoria e che contenuti di provider diversi vengano
    /// accidentalmente mescolati nella UI.
    private func loadActiveSource() {
        guard let active = sourceManager.activeSource else {
            credentials = nil
            m3uPlaylistURL = nil
            return
        }

        switch active.type {
        case .xtream:
            guard
                let username = active.username,
                let password = active.password
            else {
                credentials = nil
                m3uPlaylistURL = nil
                return
            }

            credentials = XtreamCredentials(
                host: active.host,
                username: username,
                password: password
            )

            m3uPlaylistURL = nil

        case .m3u8:
            credentials = nil
            m3uPlaylistURL = URL(string: active.host)

        case .plex, .jellyfin, .emby:
            credentials = nil
            m3uPlaylistURL = nil
        }
    }
}
