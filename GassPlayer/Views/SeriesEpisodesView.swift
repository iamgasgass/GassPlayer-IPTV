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

    // FEATURE MANCANTE aggiunta: pulsanti precedente/successivo nel player.
    // Prima si teneva traccia solo dell'URL/titolo dell'episodio in
    // riproduzione, senza alcun riferimento all'episodio stesso: impossibile
    // calcolare "il prossimo" senza rifare la ricerca. Ora si tiene
    // l'`Episode` selezionato (già `Identifiable`), da cui URL, titolo e
    // adiacenza nella stagione si derivano tutti allo stesso modo.
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
            if let url = episodeStreamURL(for: episode) {
                AdaptivePlayerView(
                    url: url,
                    title: episode.title,
                    onPrevious: adjacentEpisode(to: episode, offset: -1).map { target in
                        { selectedEpisode = target }
                    },
                    onNext: adjacentEpisode(to: episode, offset: 1).map { target in
                        { selectedEpisode = target }
                    }
                )
                // FIX (episodio successivo "senza uscire e riaprire il
                // player"): come in ChannelGridView, nessun `.id(episode.id)`
                // — il controller carica il nuovo episodio in-place nella
                // stessa `PlayerView`. `.task(id: episode.id)` al posto di
                // `.onAppear` per registrare ogni episodio nei "visti di
                // recente", incluso il primo, dato che la vista non viene
                // più ricreata ad ogni avanzamento.
                .task(id: episode.id) {
                    recordRecentlyWatched(episode: episode, url: url)
                }
            } else {
                ContentUnavailableView(
                    "URL dell'episodio non valido",
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
    }

    private func episodeStreamURL(for episode: XtreamSeriesInfo.Episode) -> URL? {
        let service = XtreamAPIService(credentials: credentials)
        let ext = episode.containerExtension?.isEmpty == false ? episode.containerExtension! : "mp4"
        return service.episodeStreamURL(episodeId: episode.streamId, ext: ext)
    }

    /// FEATURE MANCANTE aggiunta: episodio adiacente nella stagione
    /// attualmente selezionata, ordinato per numero di episodio (come già
    /// mostrato nella lista). `nil` ai bordi della stagione, così i
    /// pulsanti precedente/successivo nel player si nascondono da soli
    /// sul primo/ultimo episodio invece di restare inattivi.
    private func adjacentEpisode(to episode: XtreamSeriesInfo.Episode, offset: Int) -> XtreamSeriesInfo.Episode? {
        guard let season = selectedSeason, let info = seriesInfo else { return nil }

        let episodes = info.episodes(forSeason: season)
        guard let currentIndex = episodes.firstIndex(where: { $0.id == episode.id }) else { return nil }

        let targetIndex = currentIndex + offset
        guard episodes.indices.contains(targetIndex) else { return nil }

        return episodes[targetIndex]
    }

    private func recordRecentlyWatched(episode: XtreamSeriesInfo.Episode, url: URL) {
        recentlyWatched.record(
            id: [
                credentials.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                credentials.username,
                "series",
                String(seriesId),
                String(episode.streamId)
            ].joined(separator: "|"),
            title: "\(seriesName) · \(episode.title)",
            kind: "series",
            streamURL: url
        )
    }

    private func loadSeriesInfo() async {
        isLoading = true; errorMessage = nil
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
