import SwiftUI

/// Prima il tap su un gruppo si limitava a impostare `selectedGroup`,
/// filtrando i canali nella STESSA lista lunghissima (100+ paesi in
/// playlist come Free-TV/IPTV) — l'utente doveva scorrere oltre tutti i
/// gruppi rimanenti per vedere l'effetto, sembrando "bloccato". Ora il
/// tap naviga davvero a una schermata dedicata (`M3UGroupChannelsView`)
/// con solo i canali di quel gruppo.
struct M3UChannelsView: View {
    let playlistURL: URL
    @State private var channels: [M3UChannel] = []
    @State private var groups: [String] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Caricamento playlist...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                        Text(errorMessage).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Riprova") { Task { await loadPlaylist() } }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(groups, id: \.self) { group in
                                NavigationLink {
                                    M3UGroupChannelsView(groupTitle: group, channels: channelsFor(group))
                                } label: {
                                    HStack {
                                        Text(group)
                                        Spacer()
                                        Text("\(channelsFor(group).count)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } header: {
                            Text("Gruppi (\(groups.count))")
                        }
                    }
                }
            }
            .navigationTitle("Playlist M3U")
            .task { await loadPlaylist() }
        }
    }

    private func channelsFor(_ group: String) -> [M3UChannel] {
        channels.filter { $0.groupTitle == group }
    }

    private func loadPlaylist() async {
        isLoading = true
        errorMessage = nil
        let service = M3UPlaylistService()
        do {
            let loaded = try await service.load(from: playlistURL)
            guard !loaded.isEmpty else {
                errorMessage = "La playlist è stata scaricata ma non contiene canali validi. Controlla che l'URL punti a un file .m3u/.m3u8 valido."
                isLoading = false
                return
            }
            channels = loaded
            groups = Array(Set(loaded.compactMap { $0.groupTitle })).sorted()
            if groups.isEmpty {
                groups = ["Tutti i canali"]
            }
        } catch {
            errorMessage = "Errore nel caricamento della playlist: \(error.localizedDescription)"
        }
        isLoading = false
    }
}

/// Schermata dedicata ai canali di un singolo gruppo, con logo canale
/// (AsyncImage) e navigazione diretta al player.
struct M3UGroupChannelsView: View {
    let groupTitle: String
    let channels: [M3UChannel]
    @State private var selectedChannel: M3UChannel?

    var body: some View {
        List(channels) { channel in
            Button {
                selectedChannel = channel
            } label: {
                HStack(spacing: 12) {
                    AsyncImage(url: URL(string: channel.logoURL ?? "")) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                        default:
                            Image(systemName: "tv").foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    Text(channel.title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
        }
        .navigationTitle(groupTitle)
        .fullScreenCover(item: $selectedChannel) { channel in
            PlayerView(url: channel.streamURL, title: channel.title)
        }
    }
}
