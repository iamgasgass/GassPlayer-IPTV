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
                                            fallbackSystemImage: kind.systemImage,
                                            baseHost: playlistURL.absoluteString
                                        )
                                        Text(group)
                                        Spacer()
                                        Text("\(store.channelCount(for: kind, group: group))")
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
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .navigationBarTrailing) { GlassSearchButton() }
                    ToolbarSpacer(.fixed, placement: .navigationBarTrailing)
                    ToolbarItem(placement: .navigationBarTrailing) { GlassSettingsButton() }
                } else {
                    ToolbarItem(placement: .navigationBarTrailing) { GlassSearchButton() }
                    ToolbarItem(placement: .navigationBarTrailing) { GlassSettingsButton() }
                }
            }
            .task(id: playlistURL) { await store.loadIfNeeded(url: playlistURL) }
        }
    }
}

private struct GroupIconView: View {
    let logoURL: String?
    let fallbackSystemImage: String
    let baseHost: String

    var body: some View {
        // Immagine in cache (stessa di Live/VOD/Serie): niente flash del
        // segnaposto quando la riga viene riciclata durante lo scroll.
        CachedPosterImage(
            urlString: logoURL,
            baseHost: baseHost,
            width: 24,
            height: 24,
            cornerRadius: 6,
            placeholderSymbol: fallbackSystemImage
        )
    }
}

struct M3UGroupChannelsView: View {
    let groupTitle: String
    let channels: [M3UChannel]
    let sourceKey: String
    @EnvironmentObject var contentManagement: ContentManagementService
    @EnvironmentObject var recentlyWatched: RecentlyWatchedStore
    @EnvironmentObject var m3uStore: M3UPlaylistStore
    @State private var selectedChannel: M3UChannel?
    @State private var guideChannel: M3UChannel?

    var body: some View {
        List(channels) { channel in
            HStack(spacing: 12) {
                Button {
                    selectedChannel = channel
                } label: {
                    HStack(spacing: 12) {
                        CachedPosterImage(
                            urlString: channel.logoURL,
                            baseHost: sourceKey,
                            width: 36,
                            height: 36,
                            cornerRadius: 8,
                            placeholderSymbol: channel.kind.systemImage
                        )

                        VStack(alignment: .leading, spacing: 3) {
                            Text(channel.title)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            if channel.kind == .live {
                                // `epgRevision` fa rileggere la riga quando
                                // arriva la guida.
                                let _ = m3uStore.epgRevision
                                if let program = m3uStore.currentProgram(for: channel) {
                                    M3UProgramLine(program: program)
                                }
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if channel.kind == .live, !m3uStore.programs(for: channel).isEmpty {
                        Button {
                            guideChannel = channel
                        } label: {
                            Label("Guida programmi", systemImage: "list.bullet.rectangle")
                        }
                    }
                }

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
                .onAppear {
                    recentlyWatched.record(
                        id: "\(sourceKey)-\(channel.id)",
                        title: channel.title,
                        kind: channel.kind.rawValue,
                        streamURL: channel.streamURL
                    )
                }
        }
        .sheet(item: $guideChannel) { channel in
            M3UChannelGuideSheet(channel: channel)
                .environmentObject(m3uStore)
        }
    }
}

/// Riga "programma in onda" sotto il nome del canale, con barra di
/// avanzamento quando il programma è in corso.
private struct M3UProgramLine: View {
    let program: EPGProgram

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(program.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if program.isCurrent() {
                ProgressView(value: program.progress())
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(maxWidth: 140)
            } else {
                Text(program.start.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Elenco dei programmi del canale (oggi e prossime ore) preso dalla guida
/// XMLTV della playlist.
private struct M3UChannelGuideSheet: View {
    let channel: M3UChannel
    @EnvironmentObject var m3uStore: M3UPlaylistStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            let now = Date()
            let programs = m3uStore.programs(for: channel).filter { $0.end > now }

            List {
                if programs.isEmpty {
                    Text("Nessun programma disponibile per questo canale.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(programs) { program in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(program.start.formatted(date: .omitted, time: .shortened))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)

                                if program.isCurrent(at: now) {
                                    Text("IN ONDA")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.2), in: Capsule())
                                }
                            }

                            Text(program.title)
                                .font(.subheadline.weight(.medium))

                            if let description = program.description {
                                Text(description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle(channel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Chiudi") { dismiss() }
                }
            }
        }
    }
}
