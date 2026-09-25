import SwiftUI

struct SeriesEpisodesView: View {
    let credentials: XtreamCredentials
    let seriesId: Int
    let seriesName: String

    @EnvironmentObject private var recentlyWatched: RecentlyWatchedStore

    @State private var seriesInfo: XtreamSeriesInfo?
    @State private var selectedSeason: Int?
    @State private var isLoading = true
    @State private var errorMessage: String?

    @State private var selectedEpisode: XtreamSeriesInfo.Episode?

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
                                    selectedEpisode = episode
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
        .fullScreenCover(item: $selectedEpisode) { episode in
            let episodesPlaylist = buildSeriesPlaylist()
            let initialIdx = episodesPlaylist.firstIndex(where: { $0.id == String(episode.streamId) }) ?? 0

            AdaptivePlayerView(
                playlist: episodesPlaylist,
                initialIndex: initialIdx
            )
        }
    }

    private func buildSeriesPlaylist() -> [PlaybackItem] {
        guard let info = seriesInfo else { return [] }
        let service = XtreamAPIService(credentials: credentials)

        return info.sortedSeasonNumbers.flatMap { season in
            info.episodes(forSeason: season).compactMap { ep -> PlaybackItem? in
                let ext = ep.containerExtension?.isEmpty == false ? ep.containerExtension! : "mp4"
                guard let url = service.episodeStreamURL(episodeId: ep.streamId, ext: ext) else { return nil }
                return PlaybackItem(
                    id: String(ep.streamId),
                    url: url,
                    title: "\(seriesName) · S\(season)E\(ep.episodeNum) · \(ep.title)",
                    kind: "series",
                    rawItem: ep
                )
            }
        }
    }

    private func loadSeriesInfo() async {
        isLoading = true
        errorMessage = nil
        let repository = CachedXtreamRepository(credentials: credentials)
        do {
            let info = try await repository.seriesInfo(seriesId: seriesId)
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
