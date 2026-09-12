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

    private let tabs = [
        GlassTabItem(title: "Live", systemImage: "tv"),
        GlassTabItem(title: "Film", systemImage: "film"),
        GlassTabItem(title: "Serie", systemImage: "rectangle.stack.fill"),
        GlassTabItem(title: "Sorgenti", systemImage: "square.stack.3d.up"),
        GlassTabItem(title: "VPN", systemImage: "lock.shield")
    ]

    var body: some View {
        Group {
            if showSplash {
                SplashScreenView { showSplash = false; loadActiveSource() }
            } else if credentials != nil || m3uPlaylistURL != nil {
                ZStack(alignment: .bottom) {
                    Color.black.ignoresSafeArea()

                    Group {
                        switch selectedTab {
                        case 0:
                            if let credentials { ChannelGridView(credentials: credentials, kind: .live) }
                            else if let m3uPlaylistURL { M3UChannelsView(playlistURL: m3uPlaylistURL, kind: .live) }
                        case 1:
                            if let credentials { ChannelGridView(credentials: credentials, kind: .movie) }
                            else if let m3uPlaylistURL { M3UChannelsView(playlistURL: m3uPlaylistURL, kind: .movie) }
                        case 2:
                            if let credentials { ChannelGridView(credentials: credentials, kind: .series) }
                            else if let m3uPlaylistURL { M3UChannelsView(playlistURL: m3uPlaylistURL, kind: .series) }
                        case 3: SourcesView()
                        default: ProviderVPNView(credentials: credentials)
                        }
                    }
                    GlassTabBar(items: tabs, selection: $selectedTab)
                }
                .sheet(isPresented: $overlayState.showSearch) { GlobalSearchView() }
                .sheet(isPresented: $overlayState.showSettings) { SettingsView() }
                .onChange(of: sourceManager.activeSourceId) { _, _ in loadActiveSource() }
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
