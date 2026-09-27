import SwiftUI

/// Scheda dettaglio di una serie, aperta al tap sulla locandina. Stesso
/// nome/firma pubblica di sempre (`credentials`, `seriesId`, `seriesName`)
/// così tutti i punti d'ingresso esistenti (griglia VOD/Serie, ricerca
/// globale) continuano a funzionare senza modifiche: solo il contenuto è
/// stato riscritto per riprodurre fedelmente il video dimostrativo "I
/// Cesaroni" — hero con backdrop/logo, voto/anno/genere, pulsante
/// "Riproduci Stagione X: Episodio Y", riga preferiti/muto/download/altre
/// fonti, trama, valutazioni, cast e, sotto, i tab stagione con la lista
/// episodi (miniatura, codice SxxExx, titolo, trama).
struct SeriesEpisodesView: View {
    let credentials: XtreamCredentials
    let seriesId: Int
    let seriesName: String
    /// Copertina già nota dal catalogo (locandina Xtream), usata come
    /// sfondo hero finché il dettaglio (Xtream/TMDB) non è ancora arrivato
    /// e come riserva se nessuna delle due fonti fornisce un backdrop.
    /// Parametro opzionale con default `nil`: non richiede di toccare i
    /// chiamanti esistenti che non lo passano.
    var fallbackCoverURLString: String? = nil

    private struct AlternateSeriesTarget: Identifiable {
        let id = UUID()
        let credentials: XtreamCredentials
        let seriesId: Int
        let name: String
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var recentlyWatched: RecentlyWatchedStore
    @EnvironmentObject private var contentManagement: ContentManagementService
    @ObservedObject private var downloadManager = DownloadManager.shared

    @State private var seriesInfo: XtreamSeriesInfo?
    @State private var detail: MediaDetail = .empty
    @State private var selectedSeason: Int?
    @State private var isLoading = true
    @State private var isLoadingDetail = true
    @State private var errorMessage: String?
    @State private var selectedEpisode: XtreamSeriesInfo.Episode?
    @State private var showAlternateSources = false
    @State private var alternateSeriesTarget: AlternateSeriesTarget?
    @State private var downloadId: UUID?

    @AppStorage("gassplayer.detail.trailerMuted")
    private var isTrailerMuted = true

    private var favoriteID: String {
        credentials.favoriteID(kind: .series, streamId: seriesId)
    }

    private var isFavorite: Bool {
        contentManagement.isFavorite(id: favoriteID)
    }

    private var downloadProgress: Double? {
        guard let downloadId else { return nil }
        return downloadManager.activeDownloads[downloadId]
    }

    var body: some View {
        Group {
            if isLoading {
                loadingView
            } else if let errorMessage, seriesInfo == nil {
                errorView(errorMessage)
            } else if let info = seriesInfo {
                detailContent(info)
            }
        }
        .task(id: seriesId) {
            await loadSeriesInfo()
        }
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
                // Nessun `.id(episode.id)`: il controller carica il nuovo
                // episodio in-place nella stessa `PlayerView` invece di
                // ricreare l'intera vista (e il player sottostante) ad
                // ogni avanzamento — comportamento invariato rispetto a
                // prima di questa riscrittura.
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
        .sheet(isPresented: $showAlternateSources) {
            AlternateSourcesView(
                title: seriesName,
                kind: .series,
                excluding: credentials,
                onPickMovie: { _, _ in },
                onPickSeries: { altCredentials, altSeriesId, altName in
                    alternateSeriesTarget = AlternateSeriesTarget(
                        credentials: altCredentials,
                        seriesId: altSeriesId,
                        name: altName
                    )
                }
            )
        }
        .fullScreenCover(item: $alternateSeriesTarget) { target in
            NavigationStack {
                SeriesEpisodesView(credentials: target.credentials, seriesId: target.seriesId, seriesName: target.name)
            }
        }
    }

    // MARK: - Stati di caricamento/errore

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Caricamento serie...").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Riprova") { Task { await loadSeriesInfo() } }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(seriesName)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Contenuto principale

    private func detailContent(_ info: XtreamSeriesInfo) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                MediaHeroHeader(
                    title: seriesName,
                    logoURL: detail.logoURL,
                    backdropURL: detail.backdropURL,
                    fallbackImageURLString: fallbackCoverURLString,
                    onClose: { dismiss() }
                )

                VStack(alignment: .leading, spacing: 20) {
                    MediaMetaRow(
                        ratingText: MediaRatingFormatter.starText(fromPercent: detail.ratings.tmdbPercent),
                        secondaryText: detail.year,
                        genres: detail.genres
                    )
                    .frame(maxWidth: .infinity)

                    MediaPlayButton(title: playButtonTitle) {
                        playResumeOrFirstEpisode(info)
                    }

                    iconRow

                    if let overview = detail.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.subheadline)
                            .foregroundStyle(.primary.opacity(0.9))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if isLoadingDetail {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                    }

                    MediaRatingsSection(ratings: detail.ratings)

                    MediaCastSection(cast: detail.cast)

                    episodesSection(info)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity)
        .ignoresSafeArea(edges: .top)
        .background(Color(uiColor: .systemBackground))
    }

    // MARK: - Riga icone

    private var iconRow: some View {
        HStack(spacing: 12) {
            MediaIconButton(
                systemImage: isFavorite ? "heart.fill" : "heart",
                tint: isFavorite ? .red : .primary,
                accessibilityLabel: isFavorite ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti"
            ) {
                contentManagement.toggleFavorite(id: favoriteID, title: seriesName, kind: XtreamStreamKind.series.rawValue)
            }

            MediaIconButton(
                systemImage: isTrailerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                accessibilityLabel: isTrailerMuted ? "Attiva audio anteprima" : "Disattiva audio anteprima"
            ) {
                isTrailerMuted.toggle()
            }

            MediaIconButton(
                systemImage: downloadProgress == 1 ? "checkmark.circle.fill" : "arrow.down.circle",
                tint: downloadProgress == 1 ? .green : .primary,
                progress: downloadProgress,
                accessibilityLabel: "Scarica episodio"
            ) {
                startDownloadOfNextEpisodeIfNeeded()
            }

            AltreFontiButton {
                showAlternateSources = true
            }
        }
    }

    // MARK: - Sezione episodi

    private func episodesSection(_ info: XtreamSeriesInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("EPISODI")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(info.sortedSeasonNumbers, id: \.self) { season in
                        seasonChip(season)
                    }
                }
            }

            if let selectedSeason {
                VStack(spacing: 14) {
                    ForEach(info.episodes(forSeason: selectedSeason)) { episode in
                        episodeRow(episode, season: selectedSeason)
                    }
                }
            }
        }
    }

    private func seasonChip(_ season: Int) -> some View {
        let isSelected = selectedSeason == season

        return Button {
            withAnimation(.snappy(duration: 0.16)) { selectedSeason = season }
        } label: {
            Text("Stagione \(season)")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(isSelected ? Color.accentColor : Color.primary.opacity(0.08), in: Capsule())
    }

    private func episodeRow(_ episode: XtreamSeriesInfo.Episode, season: Int) -> some View {
        Button {
            selectedSeason = season
            selectedEpisode = episode
        } label: {
            HStack(alignment: .top, spacing: 12) {
                episodeThumbnail(episode)
                    .frame(width: 112, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(episode.code(seasonFallback: season)) · \(episode.title)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let plot = episode.plot, !plot.isEmpty {
                        Text(plot)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func episodeThumbnail(_ episode: XtreamSeriesInfo.Episode) -> some View {
        if let url = episode.stillImageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    episodeThumbnailPlaceholder
                }
            }
        } else {
            episodeThumbnailPlaceholder
        }
    }

    private var episodeThumbnailPlaceholder: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay {
                Image(systemName: "play.rectangle.fill")
                    .foregroundStyle(.secondary)
            }
    }

    // MARK: - Riproduzione / ripresa

    /// Ultimo episodio di questa serie registrato in "Continua a
    /// guardare", se presente: usato per etichettare e avviare il
    /// pulsante di riproduzione principale su "Stagione X: Episodio Y"
    /// come nel video, invece di ripartire sempre dal primo episodio.
    private var resumeEpisode: (season: Int, episode: XtreamSeriesInfo.Episode)? {
        guard let info = seriesInfo else { return nil }

        let host = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefix = [host, credentials.username, "series", String(seriesId), ""].joined(separator: "|")

        guard let item = recentlyWatched.items.first(where: { $0.id.hasPrefix(prefix) }) else {
            return nil
        }

        let episodeStreamId = item.id.split(separator: "|").last.map(String.init) ?? ""

        for season in info.sortedSeasonNumbers {
            if let episode = info.episodes(forSeason: season).first(where: { String($0.streamId) == episodeStreamId }) {
                return (season, episode)
            }
        }

        return nil
    }

    private var playButtonTitle: String {
        if let resume = resumeEpisode {
            return "Riproduci Stagione \(resume.season): Episodio \(resume.episode.episodeNum)"
        }

        if let info = seriesInfo,
           let season = info.sortedSeasonNumbers.first,
           let episode = info.episodes(forSeason: season).first {
            return "Riproduci Stagione \(season): Episodio \(episode.episodeNum)"
        }

        return "Riproduci"
    }

    private func playResumeOrFirstEpisode(_ info: XtreamSeriesInfo) {
        if let resume = resumeEpisode {
            selectedSeason = resume.season
            selectedEpisode = resume.episode
            return
        }

        guard let season = info.sortedSeasonNumbers.first,
              let episode = info.episodes(forSeason: season).first else { return }

        selectedSeason = season
        selectedEpisode = episode
    }

    private func startDownloadOfNextEpisodeIfNeeded() {
        guard downloadId == nil else { return }

        let target = resumeEpisode?.episode ?? seriesInfo.flatMap { info in
            info.sortedSeasonNumbers.first.flatMap { info.episodes(forSeason: $0).first }
        }

        guard let episode = target, let url = episodeStreamURL(for: episode) else { return }

        let id = UUID()
        downloadId = id
        downloadManager.startDownload(url: url, id: id)
    }

    private func episodeStreamURL(for episode: XtreamSeriesInfo.Episode) -> URL? {
        let service = XtreamAPIService(credentials: credentials)
        let ext = episode.containerExtension?.isEmpty == false ? episode.containerExtension! : "mp4"
        return service.episodeStreamURL(episodeId: episode.streamId, ext: ext)
    }

    /// Episodio adiacente nella stagione attualmente selezionata, ordinato
    /// per numero di episodio. `nil` ai bordi della stagione, così i
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

    // MARK: - Caricamento

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
            isLoading = false

            await loadDetail(info)
        } catch let error as XtreamError {
            errorMessage = error.errorDescription
            isLoading = false
        } catch {
            errorMessage = "Errore imprevisto: \(error.localizedDescription)"
            isLoading = false
        }
    }

    private func loadDetail(_ info: XtreamSeriesInfo) async {
        isLoadingDetail = true

        let seed = MediaDetailSeed(
            title: seriesName,
            isSeries: true,
            overview: info.details?.plot,
            backdropURLString: info.backdropURL?.absoluteString ?? fallbackCoverURLString,
            genreNames: info.genreNames,
            castNames: info.castNames,
            year: info.year,
            runtimeMinutes: nil,
            xtreamRating: info.details?.rating.flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
        )

        detail = await MediaDetailLoader.load(seed)
        isLoadingDetail = false
    }
}
