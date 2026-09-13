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
    @StateObject private var appSettings = AppSettings.shared

    var body: some View {
        Group {
            if showSplash {
                SplashScreenView { showSplash = false; loadActiveSource() }
            } else if credentials != nil || m3uPlaylistURL != nil {
                // FIX DEFINITIVO ANIMAZIONE TAB BAR: l'esatta animazione a
                // "blob liquido" vista in Files (Sfoglia/Condivisi/Recenti)
                // e in iMessage NON e' riproducibile con le API pubbliche
                // GlassEffectContainer/glassEffectID (verificato: quelle
                // producono solo interpolazioni geometriche, non la vera
                // fisica del vetro). Quell'effetto arriva da un framework
                // privato esclusivo di UITabBar/UISegmentedControl. L'unico
                // modo per ottenerlo davvero e' usare il TabView nativo di
                // SwiftUI: ricompilando per iOS 26 adotta automaticamente
                // Liquid Glass reale, zero codice custom necessario. Ho
                // quindi eliminato l'intera GlassTabBar fatta a mano stanotte:
                // era un tentativo, per quanto accurato, di ricostruire con
                // strumenti pubblici un effetto riservato ai componenti di
                // sistema.
                TabView(selection: $selectedTab) {
                    liveTab
                        .tabItem { Label("Live", systemImage: "tv") }
                        .tag(0)
                    filmTab
                        .tabItem { Label("Film", systemImage: "film") }
                        .tag(1)
                    serieTab
                        .tabItem { Label("Serie", systemImage: "rectangle.stack.fill") }
                        .tag(2)
                    SourcesView()
                        .tabItem { Label("Sorgenti", systemImage: "square.stack.3d.up") }
                        .tag(3)
                    PersonalVPNView()
                        .tabItem { Label("VPN", systemImage: "lock.shield") }
                        .tag(4)
                }
                .background(Color.black.ignoresSafeArea())
                .sheet(isPresented: $overlayState.showSearch) { GlobalSearchView() }
                .sheet(isPresented: $overlayState.showSettings) { SettingsView() }
                .onChange(of: sourceManager.activeSourceId) { _, _ in loadActiveSource() }
                .task {
                    vpnManager.handleAppBecameActive()
                }
            } else {
                LoginView(
                    onLogin: { creds in
                        credentials = creds
                        sourceManager.add(MediaSourceConfig(name: "Sorgente principale", type: .xtream, host: creds.host, username: creds.username, password: creds.password))
                    },
                    onM3ULoaded: { url in
                        m3uPlaylistURL = url
                        sourceManager.add(MediaSourceConfig(name: "Playlist M3U", type: .m3u8, host: url.absoluteString))
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
        .environmentObject(appSettings)
    }

    @ViewBuilder private var liveTab: some View {
        if let credentials { ChannelGridView(credentials: credentials, kind: .live) }
        else if let m3uPlaylistURL { M3UChannelsView(playlistURL: m3uPlaylistURL, kind: .live) }
    }
    @ViewBuilder private var filmTab: some View {
        if let credentials { ChannelGridView(credentials: credentials, kind: .movie) }
        else if let m3uPlaylistURL { M3UChannelsView(playlistURL: m3uPlaylistURL, kind: .movie) }
    }
    @ViewBuilder private var serieTab: some View {
        if let credentials { ChannelGridView(credentials: credentials, kind: .series) }
        else if let m3uPlaylistURL { M3UChannelsView(playlistURL: m3uPlaylistURL, kind: .series) }
    }

    private func loadActiveSource() {
        guard let active = sourceManager.activeSource else { return }
        switch active.type {
        case .xtream:
            if let username = active.username, let password = active.password {
                credentials = XtreamCredentials(host: active.host, username: username, password: password)
                m3uPlaylistURL = nil
            }
        case .m3u8:
            if let url = URL(string: active.host) {
                m3uPlaylistURL = url
                credentials = nil
            }
        case .plex, .jellyfin, .emby:
            break
        }
    }
}
