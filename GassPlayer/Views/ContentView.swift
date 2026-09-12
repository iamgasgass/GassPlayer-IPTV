import SwiftUI

/// VOD e Serie ora funzionano anche per playlist M3U, non solo Xtream:
/// ogni tab passa lo stesso `kind` a `ChannelGridView` (Xtream) o
/// `M3UChannelsView` (M3U), e lo store condiviso `M3UPlaylistStore`
/// evita di riparsare la playlist ad ogni cambio tab.
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

    private let tabs = [
        GlassTabItem(title: "Live", systemImage: "tv"),
        GlassTabItem(title: "Film", systemImage: "film"),
        GlassTabItem(title: "Serie", systemImage: "rectangle.stack.fill"),
        GlassTabItem(title: "Cerca", systemImage: "magnifyingglass"),
        GlassTabItem(title: "Sorgenti", systemImage: "square.stack.3d.up"),
        GlassTabItem(title: "VPN", systemImage: "lock.shield"),
        GlassTabItem(title: "Impostazioni", systemImage: "gearshape")
    ]

    var body: some View {
        Group {
            if showSplash {
                SplashScreenView { showSplash = false }
            } else if credentials != nil || m3uPlaylistURL != nil {
                ZStack(alignment: .bottom) {
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
                        case 3: GlobalSearchView()
                        case 4: SourcesView()
                        case 5: ProviderVPNView(credentials: credentials)
                        default: SettingsView()
                        }
                    }
                    GlassTabBar(items: tabs, selection: $selectedTab)
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
    }
}
