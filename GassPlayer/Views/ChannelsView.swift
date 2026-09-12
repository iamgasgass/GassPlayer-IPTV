import SwiftUI

struct ChannelsView: View {
    let credentials: XtreamCredentials
    @EnvironmentObject var contentManagement: ContentManagementService
    @State private var categories: [XtreamCategory] = []
    @State private var streams: [XtreamStream] = []
    @State private var selectedStream: XtreamStream?
    private var service: XtreamAPIService { XtreamAPIService(credentials: credentials) }

    var body: some View {
        NavigationStack {
            List {
                Section("Categorie") {
                    ForEach(categories) { category in
                        Button(category.categoryName) { Task { await loadStreams(for: category) } }
                    }
                }
                Section("Canali") {
                    ForEach(streams) { stream in
                        HStack {
                            Button(stream.name) { selectedStream = stream }
                            Spacer()
                            Button {
                                contentManagement.toggleFavorite(id: "\(credentials.host)-\(stream.streamId)", title: stream.name, kind: "live")
                            } label: {
                                Image(systemName: contentManagement.isFavorite(id: "\(credentials.host)-\(stream.streamId)") ? "star.fill" : "star")
                                    .foregroundStyle(.yellow)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Live TV")
            .task { await loadCategories() }
            .fullScreenCover(item: $selectedStream) { stream in
                if let url = service.streamURL(for: stream.streamId, kind: .live) {
                    PlayerView(url: url, title: stream.name)
                }
            }
        }
    }

    private func loadCategories() async { categories = (try? await service.fetchCategories(kind: .live)) ?? [] }
    private func loadStreams(for category: XtreamCategory) async {
        streams = (try? await service.fetchStreams(kind: .live, categoryId: category.categoryId)) ?? []
    }
}
