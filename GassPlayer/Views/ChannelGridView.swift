import SwiftUI

struct ChannelGridView: View {
    let credentials: XtreamCredentials
    @EnvironmentObject var contentManagement: ContentManagementService
    @State private var categories: [XtreamCategory] = []
    @State private var streams: [XtreamStream] = []
    @State private var selectedCategory: XtreamCategory?
    @State private var selectedStream: XtreamStream?
    @State private var isLoading = false

    private var repository: CachedXtreamRepository { CachedXtreamRepository(credentials: credentials) }
    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                categoryChips
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(streams) { stream in
                        ChannelTile(
                            stream: stream,
                            isFavorite: contentManagement.isFavorite(id: "\(credentials.host)-\(stream.streamId)")
                        ) {
                            selectedStream = stream
                        } onFavoriteToggle: {
                            contentManagement.toggleFavorite(id: "\(credentials.host)-\(stream.streamId)", title: stream.name, kind: "live")
                        }
                    }
                }
                .padding()
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: streams.count)
            }
            .overlay { if isLoading { ProgressView() } }
            .navigationTitle("Live TV")
            .task { await loadCategories() }
            .fullScreenCover(item: $selectedStream) { stream in
                if let url = URL(string: "\(credentials.host)/live/\(credentials.username)/\(credentials.password)/\(stream.streamId).m3u8") {
                    PlayerView(url: url, title: stream.name)
                }
            }
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(categories) { category in
                    Button(category.categoryName) {
                        withAnimation { selectedCategory = category }
                        Task { await loadStreams(for: category) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .modifier(GlassOrMaterial(isSelected: selectedCategory?.id == category.id))
                }
            }
            .padding(.horizontal)
        }
    }

    private func loadCategories() async {
        isLoading = true
        categories = (try? await repository.categories(kind: .live)) ?? []
        isLoading = false
    }

    private func loadStreams(for category: XtreamCategory) async {
        isLoading = true
        streams = (try? await repository.streams(kind: .live, categoryId: category.categoryId)) ?? []
        isLoading = false
    }
}

private struct ChannelTile: View {
    let stream: XtreamStream
    let isFavorite: Bool
    let onTap: () -> Void
    let onFavoriteToggle: () -> Void

    var body: some View {
        VStack(spacing: 6) {
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
        }
        .onTapGesture { onTap() }
    }
}
