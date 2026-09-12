import SwiftUI

struct ContentView: View {
    @State private var credentials: XtreamCredentials?
    @State private var m3uPlaylistURL: URL?
    @State private var selectedTab = 0
    @StateObject private var sourceManager = SourceManager()
    @StateObject private var lockManager = ParentalLockManager()
    @StateObject private var contentManagement = ContentManagementService()

    private let tabs = [
        GlassTabItem(title: "Live", systemImage: "tv"),
        GlassTabItem(title: "VOD", systemImage: "film"),
        GlassTabItem(title: "Cerca", systemImage: "magnifyingglass"),
        GlassTabItem(title: "Sorgenti", systemImage: "square.stack.3d.up"),
        GlassTabItem(title: "VPN", systemImage: "lock.shield"),
        GlassTabItem(title: "Impostazioni", systemImage: "gearshape")
    ]

    var body: some View {
        Group {
            if credentials != nil || m3uPlaylistURL != nil {
                ZStack(alignment: .bottom) {
                    Group {
                        switch selectedTab {
                        case 0:
                            if let credentials { ChannelsView(credentials: credentials) }
                            else if let m3uPlaylistURL { M3UChannelsView(playlistURL: m3uPlaylistURL) }
                        case 1:
                            if let credentials { ChannelsView(credentials: credentials) }
                            else { Text("VOD non disponibile per playlist M3U pure.") }
                        case 2: GlobalSearchView()
                        case 3: SourcesView()
                        case 4: ProviderVPNView(credentials: credentials)
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
        .environmentObject(sourceManager)
        .environmentObject(lockManager)
        .environmentObject(contentManagement)
    }
}
