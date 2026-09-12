import SwiftUI

struct SeriesEpisodesView: View {
    let credentials: XtreamCredentials
    let seriesId: Int
    let seriesName: String

    @State private var seriesInfo: XtreamSeriesInfo?
    @State private var selectedSeason: Int?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedEpisodeURL: URL?
    @State private var selectedEpisodeTitle = ""

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Caricamento episodi...").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    Text(errorMessage).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Riprova") { Task { await loadSeriesInfo() } }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let info = seriesInfo {
                List {
                    Section("Stagioni") {
                        ForEach(info.sortedSeasonNumbers, id: \.self) { season in
                            Button("Stagione \(season)") { selectedSeason = season }
                        }
                    }
                    if let selectedSeason {
                        Section("Episodi — Stagione \(selectedSeason)") {
                            ForEach(info.episodes(forSeason: selectedSeason)) { episode in
                                Button {
                                    play(episode)
                                } label: {
                                    HStack {
                                        Text("\(episode.episodeNum).")
                                            .foregroundStyle(.secondary)
                                        Text(episode.title)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(seriesName)
        .task { await loadSeriesInfo() }
        .fullScreenCover(item: Binding(
            get: { selectedEpisodeURL.map { IdentifiableURL(url: $0) } },
            set: { selectedEpisodeURL = $0?.url }
        )) { wrapped in
            PlayerView(url: wrapped.url, title: selectedEpisodeTitle)
        }
    }

    private func play(_ episode: XtreamSeriesInfo.Episode) {
        let service = XtreamAPIService(credentials: credentials)
        let ext = episode.containerExtension?.isEmpty == false ? episode.containerExtension! : "mp4"
        if let url = service.episodeStreamURL(episodeId: episode.streamId, ext: ext) {
            selectedEpisodeTitle = episode.title
            selectedEpisodeURL = url
        }
    }

    private func loadSeriesInfo() async {
        isLoading = true; errorMessage = nil
        let service = XtreamAPIService(credentials: credentials)
        do {
            let info = try await service.fetchSeriesInfo(seriesId: seriesId)
            seriesInfo = info
            selectedSeason = info.sortedSeasonNumbers.first
            if info.sortedSeasonNumbers.isEmpty {
                errorMessage = "Nessun episodio trovato per questa serie."
            }
        } catch let error as XtreamError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Errore imprevisto: \(error.localizedDescription)"
        }
        isLoading = false
    }
}

private struct IdentifiableURL: Identifiable {
    let url: URL
    var id: URL { url }
}
