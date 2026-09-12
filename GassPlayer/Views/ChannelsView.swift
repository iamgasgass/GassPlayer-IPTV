import SwiftUI

/// Vista a lista (alternativa alla griglia), ora dinamica sul `kind`
/// come ChannelGridView, invece di essere fissa su Live TV.
struct ChannelsView: View {
    let credentials: XtreamCredentials
    var kind: XtreamStreamKind = .live
    @EnvironmentObject var contentManagement: ContentManagementService
    @State private var categories: [XtreamCategory] = []
    @State private var streams: [XtreamStream] = []
    @State private var selectedStream: XtreamStream?
    @State private var errorMessage: String?
    private var service: XtreamAPIService { XtreamAPIService(credentials: credentials) }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.secondary)
                }
                Section("Categorie") {
                    ForEach(categories) { category in
                        Button(category.categoryName) { Task { await loadStreams(for: category) } }
                    }
                }
                Section("Contenuti") {
                    ForEach(streams) { stream in
                        HStack {
                            Button(stream.name) { selectedStream = stream }
                            Spacer()
                            Button {
                                contentManagement.toggleFavorite(id: "\(credentials.host)-\(kind.rawValue)-\(stream.streamId)", title: stream.name, kind: kind.rawValue)
                            } label: {
                                Image(systemName: contentManagement.isFavorite(id: "\(credentials.host)-\(kind.rawValue)-\(stream.streamId)") ? "star.fill" : "star")
                                    .foregroundStyle(.yellow)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(kind.displayName)
            .task(id: kind) { await loadCategories() }
            .fullScreenCover(item: $selectedStream) { stream in
                if let url = service.streamURL(for: stream, kind: kind) {
                    PlayerView(url: url, title: stream.name)
                }
            }
        }
    }

    private func loadCategories() async {
        do {
            categories = try await service.fetchCategories(kind: kind)
            errorMessage = nil
        } catch let error as XtreamError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Errore imprevisto: \(error.localizedDescription)"
        }
    }
    private func loadStreams(for category: XtreamCategory) async {
        streams = (try? await service.fetchStreams(kind: kind, categoryId: category.categoryId)) ?? []
    }
}
