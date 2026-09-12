import SwiftUI

struct ChannelGridView: View {
    let credentials: XtreamCredentials
    let kind: XtreamStreamKind
    @EnvironmentObject var contentManagement: ContentManagementService
    @State private var categories: [XtreamCategory] = []
    @State private var streams: [XtreamStream] = []
    @State private var selectedCategory: XtreamCategory?
    @State private var selectedStream: XtreamStream?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var epgByStream: [Int: EPGProgram] = [:]

    private var repository: CachedXtreamRepository { CachedXtreamRepository(credentials: credentials) }
    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                categoryChips
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.secondary).padding()
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(streams) { stream in
                        ChannelTile(
                            stream: stream,
                            isFavorite: contentManagement.isFavorite(id: "\(credentials.host)-\(kind.rawValue)-\(stream.streamId)"),
                            currentProgram: kind == .live ? epgByStream[stream.streamId] : nil
                        ) {
                            selectedStream = stream
                        } onFavoriteToggle: {
                            contentManagement.toggleFavorite(id: "\(credentials.host)-\(kind.rawValue)-\(stream.streamId)", title: stream.name, kind: kind.rawValue)
                        }
                    }
                }
                .padding()
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: streams.count)
            }
            .overlay { if isLoading { ProgressView() } }
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
            .task(id: kind) { await loadCategories() }
            .fullScreenCover(item: $selectedStream) { stream in
                if kind == .series {
                    NavigationStack {
                        SeriesEpisodesView(credentials: credentials, seriesId: stream.streamId, seriesName: stream.name)
                    }
                } else if let url = streamURLFor(stream) {
                    PlayerView(url: url, title: stream.name)
                } else {
                    Text("URL dello stream non valido.")
                }
            }
        }
    }

    private func streamURLFor(_ stream: XtreamStream) -> URL? {
        let ext = (stream.containerExtension?.isEmpty == false) ? stream.containerExtension! : kind.defaultExtension
        return URL(string: "\(credentials.host)/\(kind.pathComponent)/\(credentials.username)/\(credentials.password)/\(stream.streamId).\(ext)")
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(categories) { category in
                    Button {
                        withAnimation { selectedCategory = category }
                        Task { await loadStreams(for: category) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: Self.categoryIcon(for: category.categoryName))
                                .font(.caption)
                            Text(category.categoryName)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .modifier(GlassOrMaterial(isSelected: selectedCategory?.id == category.id))
                }
            }
            .padding(.horizontal)
        }
    }

    private static func categoryIcon(for name: String) -> String {
        let normalized = name.lowercased()
        if normalized.contains("sport") { return "sportscourt" }
        if normalized.contains("kids") || normalized.contains("cartoon") || normalized.contains("bambini") { return "gamecontroller" }
        if normalized.contains("news") || normalized.contains("notizie") { return "newspaper" }
        if normalized.contains("music") || normalized.contains("musica") { return "music.note" }
        if normalized.contains("cinema") || normalized.contains("film") || normalized.contains("movie") { return "film" }
        if normalized.contains("document") { return "video" }
        if normalized.contains("relig") { return "building.columns" }
        if normalized.contains("adult") || normalized.contains("+18") || normalized.contains("xxx") { return "eye.slash" }
        return "tv"
    }

    private func loadCategories() async {
        isLoading = true; errorMessage = nil
        do {
            categories = try await repository.categories(kind: kind)
            if categories.isEmpty {
                errorMessage = "Nessuna categoria \(kind.displayName) trovata su questo server."
            } else if let first = categories.first {
                selectedCategory = first
                await loadStreams(for: first)
            }
        } catch let error as XtreamError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Errore imprevisto: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func loadStreams(for category: XtreamCategory) async {
        isLoading = true
        streams = (try? await repository.streams(kind: kind, categoryId: category.categoryId)) ?? []
        isLoading = false
        if kind == .live { await loadEPGForVisibleStreams() }
    }

    private func loadEPGForVisibleStreams() async {
        let epgService = EPGService(credentials: credentials)
        let visibleStreams = Array(streams.prefix(24))
        await withTaskGroup(of: (Int, EPGProgram?).self) { group in
            for stream in visibleStreams {
                group.addTask {
                    let programs = (try? await epgService.shortEPG(streamId: stream.streamId, limit: 1)) ?? []
                    return (stream.streamId, programs.first)
                }
            }
            for await (streamId, program) in group {
                if let program { epgByStream[streamId] = program }
            }
        }
    }
}

private struct ChannelTile: View {
    let stream: XtreamStream
    let isFavorite: Bool
    let currentProgram: EPGProgram?
    let onTap: () -> Void
    let onFavoriteToggle: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                AsyncImage(url: URL(string: stream.streamIcon ?? "")) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit()
                    default:
                        RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial)
                            .overlay(Image(systemName: "tv").foregroundStyle(.secondary))
                    }
                }
                .frame(width: 100, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Button(action: onFavoriteToggle) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.caption)
                        .padding(6)
                        .foregroundStyle(.yellow)
                }
                .background(.ultraThinMaterial, in: Circle())
                .padding(4)
            }
            Text(stream.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
            if let currentProgram {
                Text(currentProgram.title)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .onTapGesture { onTap() }
    }
}
