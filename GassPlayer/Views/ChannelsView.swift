import SwiftUI

/// Vista a lista (alternativa alla griglia), dinamica sul `kind`.
/// Le serie richiedono un percorso diverso da live/VOD: elenco via
/// fetchSeriesList() e navigazione a SeriesEpisodesView, non riproduzione diretta.
struct ChannelsView: View {
    let credentials: XtreamCredentials
    var kind: XtreamStreamKind = .live
    @EnvironmentObject var contentManagement: ContentManagementService
    @State private var categories: [XtreamCategory] = []
    @State private var streams: [XtreamStream] = []
    @State private var seriesItems: [XtreamSeriesItem] = []
    @State private var selectedStream: XtreamStream?
    @State private var selectedSeries: XtreamSeriesItem?
    @State private var errorMessage: String?
    @State private var showUnplayableAlert = false
    private var service: XtreamAPIService { XtreamAPIService(credentials: credentials) }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.secondary)
                }
                Section("Categorie") {
                    ForEach(categories) { category in
                        Button(category.categoryName) { Task { await loadContent(for: category) } }
                    }
                }
                Section("Contenuti") {
                    if kind == .series {
                        ForEach(seriesItems) { series in
                            Button(series.name) { selectedSeries = series }
                        }
                    } else {
                        ForEach(streams) { stream in
                            HStack {
                                Button(stream.name) { selectStream(stream) }
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
            }
            .navigationTitle(kind.displayName)
            .task(id: kind) { await loadCategories() }
            .fullScreenCover(item: $selectedStream) { stream in
                if let url = service.streamURL(for: stream, kind: kind) {
                    PlayerView(url: url, title: stream.name)
                }
            }
            .navigationDestination(item: $selectedSeries) { series in
                SeriesEpisodesView(credentials: credentials, seriesId: series.seriesId, seriesName: series.name)
            }
            .alert("Impossibile riprodurre", isPresented: $showUnplayableAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Non è stato possibile costruire un URL di streaming valido per questo contenuto. Controlla che username e password della sorgente non contengano caratteri non validi.")
            }
        }
    }

    private func selectStream(_ stream: XtreamStream) {
        guard service.streamURL(for: stream, kind: kind) != nil else {
            showUnplayableAlert = true
            return
        }
        selectedStream = stream
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

    private func loadContent(for category: XtreamCategory) async {
        if kind == .series {
            do {
                seriesItems = try await service.fetchSeriesList(categoryId: category.categoryId)
                errorMessage = nil
            } catch let error as XtreamError {
                seriesItems = []
                errorMessage = error.errorDescription
            } catch {
                seriesItems = []
                errorMessage = "Errore imprevisto: \(error.localizedDescription)"
            }
        } else {
            do {
                streams = try await service.fetchStreams(kind: kind, categoryId: category.categoryId)
                errorMessage = nil
            } catch let error as XtreamError {
                streams = []
                errorMessage = error.errorDescription
            } catch {
                streams = []
                errorMessage = "Errore imprevisto: \(error.localizedDescription)"
            }
        }
    }
}
