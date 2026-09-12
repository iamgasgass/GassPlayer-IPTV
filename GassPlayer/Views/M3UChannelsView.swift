import SwiftUI

struct M3UChannelsView: View {
    let playlistURL: URL
    @State private var channels: [M3UChannel] = []
    @State private var selectedChannel: M3UChannel?
    @State private var groups: [String] = []
    @State private var selectedGroup: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Gruppi") {
                    ForEach(groups, id: \.self) { group in
                        Button(group) { selectedGroup = group }
                    }
                }
                Section("Canali") {
                    ForEach(filteredChannels) { channel in
                        Button(channel.title) { selectedChannel = channel }
                    }
                }
            }
            .navigationTitle("Playlist M3U")
            .task { await loadPlaylist() }
            .fullScreenCover(item: $selectedChannel) { channel in
                PlayerView(url: channel.streamURL, title: channel.title)
            }
        }
    }

    private var filteredChannels: [M3UChannel] {
        guard let selectedGroup else { return channels }
        return channels.filter { $0.groupTitle == selectedGroup }
    }

    private func loadPlaylist() async {
        let service = M3UPlaylistService()
        if let loaded = try? await service.load(from: playlistURL) {
            channels = loaded
            groups = Array(Set(loaded.compactMap { $0.groupTitle })).sorted()
        }
    }
}
