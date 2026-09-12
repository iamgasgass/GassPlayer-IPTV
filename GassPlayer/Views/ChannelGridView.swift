import SwiftUI

/// Vista dinamica per contenuti Xtream: `kind` decide se mostra Live TV,
/// VOD o Serie senza duplicare codice — prima esistevano solo canali Live,
/// VOD e Serie non avevano alcuna vista nonostante `XtreamStreamKind` le
/// prevedesse già nel modello dati.
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
                            isFavorite: contentManagement.isFavorite(id: "\(credentials.host)-\(kind.rawValue)-\(stream.streamId)")
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
            .task(id: kind) { await loadCategories() }
            .fullScreenCover(item: $selectedStream) { stream in
                if let url = streamURLFor(stream) {
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
