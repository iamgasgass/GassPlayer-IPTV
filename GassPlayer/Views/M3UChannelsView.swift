import SwiftUI

struct M3UChannelsView: View {
    let playlistURL: URL
    let kind: XtreamStreamKind
    @EnvironmentObject var store: M3UPlaylistStore
    @EnvironmentObject var contentManagement: ContentManagementService

    var body: some View {
        NavigationStack {
            Group {
                if store.isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Caricamento playlist...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage = store.errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                        Text(errorMessage).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Riprova") { Task { await store.reload(url: playlistURL) } }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.totalCount(for: kind) == 0 {
                    VStack(spacing: 8) {
                        Image(systemName: kind.systemImage).font(.largeTitle).foregroundStyle(.secondary)
                        Text("Nessun contenuto \(kind.displayName) trovato in questa playlist.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(store.groups(for: kind), id: \.self) { group in
                                NavigationLink {
                                    M3UGroupChannelsView(
                                        groupTitle: group,
                                        channels: store.channels(for: kind, group: group),
                                        sourceKey: playlistURL.absoluteString
                                    )
                                } label: {
                                    HStack(spacing: 10) {
                                        GroupIconView(
                                            logoURL: store.groupIcon(for: kind, group: group),
                                            fallbackSystemImage: kind.systemImage
                                        )
                                        Text(group)
                                        Spacer()
                                        Text("\(store.channels(for: kind, group: group).count)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } header: {
                            Text("\(kind.displayName) · \(store.totalCount(for: kind)) contenuti")
                        }
                    }
                }
            }
            .navigationTitle(kind.displayName)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { GlassSearchButton() }
                ToolbarItem(placement: .navigationBarTrailing) { GlassSettingsButton() }
            }
            .task(id: playlistURL) { await store.loadIfNeeded(url: playlistURL) }
        }
    }
}

private struct GroupIconView: View {
    let logoURL: String?
    let fallbackSystemImage: String

    var body: some View {
        Group {
            if let logoURL, let url = URL(string: logoURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit()
                    default: Image(systemName: fallbackSystemImage).foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: fallbackSystemImage).foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct M3UGroupChannelsView: View {
    let groupTitle: String
    let channels: [M3UChannel]
    let sourceKey: String
    @EnvironmentObject var contentManagement: ContentManagementService
    @State private var selectedChannel: M3UChannel?

    var body: some View {
        List(channels) { channel in
            HStack(spacing: 12) {
                Button {
                    selectedChannel = channel
                } label: {
                    HStack(spacing: 12) {
                        AsyncImage(url: URL(string: channel.logoURL ?? "")) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFit()
                            default:
                                Image(systemName: channel.kind.systemImage).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        Text(channel.title)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    contentManagement.toggleFavorite(id: "\(sourceKey)-\(channel.id)", title: channel.title, kind: channel.kind.rawValue)
                } label: {
                    Image(systemName: contentManagement.isFavorite(id: "\(sourceKey)-\(channel.id)") ? "star.fill" : "star")
                        .foregroundStyle(.yellow)
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(groupTitle)
        .fullScreenCover(item: $selectedChannel) { channel in
            PlayerView(url: channel.streamURL, title: channel.title)
        }
    }
}
