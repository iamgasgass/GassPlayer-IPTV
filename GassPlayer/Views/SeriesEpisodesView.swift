import SwiftUI

/// Scheda dettaglio di una serie TV a scala 1:1 identica al video di riferimento
struct SeriesEpisodesView: View {
    let credentials: XtreamCredentials
    let seriesId: Int
    let seriesName: String
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
        .background(Color.black)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Riprova") { Task { await loadSeriesInfo() } }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    // MARK: - Contenuto principale

    private func detailContent(_ info: XtreamSeriesInfo) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header compatto
                MediaHeroHeader(
                    title: seriesName,
                    logoURL: detail.logoURL,
                    backdropURL: detail.backdropURL,
                    fallbackImageURLString: fallbackCoverURLString,
                    onClose: { dismiss() }
                )

                // Blocco centrale
                VStack(spacing: 12) {
                    // Riga voto / anno / generi
                    MediaMetaRow(
                        ratingText: MediaRatingFormatter.starText(fromPercent: detail.ratings.tmdbPercent),
                        secondaryText: detail.year,
                        genres: detail.genres
                    )

                    // Pulsante Riproduci Stagione X: Episodio Y
                    MediaPlayButton(title: playButtonTitle) {
                        playResumeOrFirstEpisode(info)
                    }

                    // Riga icone
                    iconRow

                    // Trama
                    if let overview = detail.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary.opacity(0.92))
                            .lineSpacing(2.5)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if isLoadingDetail {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                // Sezione Valutazioni
                MediaRatingsSection(ratings: detail.ratings)
                    .padding(.top, 14)

                // Sezione Cast
                MediaCastSection(cast: detail.cast)
                    .padding(.top, 14)

                // Sezione Episodi e Stagioni
                episodesSection(info)
                    .padding(.top, 16)
                    .padding(.bottom, 36)
            }
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
        .background(Color.black)
    }

    // MARK: - Riga icone

    private var iconRow: some View {
        HStack(spacing: 8) {
            MediaIconButton(
                systemImage: isFavorite ? "heart.fill" : "heart",
                tint: isFavorite ? .red : .white,
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
                tint: downloadProgress == 1 ? .green : .white,
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
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)

            // Selettore stagioni (Pillole / Chip)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(info.sortedSeasonNumbers, id: \.self) { season in
                        seasonChip(season)
                    }
                }
                .padding(.horizontal, 16)
            }

            // Lista episodi
            if let selectedSeason {
                VStack(spacing: 14) {
                    ForEach(info.episodes(forSeason: selectedSeason)) { episode in
                        episodeRow(episode, season: selectedSeason)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
            }
        }
    }

    private func seasonChip(_ season: Int) -> some View {
        let isSelected = selectedSeason == season

        return Button {
            withAnimation(.snappy(duration: 0.16)) { selectedSeason = season }
        } label: {
            Text("Stagione \(season)")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .background(
                    isSelected ? Color.white.opacity(0.18) : Color.white.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isSelected ? Color.white.opacity(0.2) : Color.clear, lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
    }

    private func episodeRow(_ episode: XtreamSeriesInfo.Episode, season: Int) -> some View {
        Button {
            selectedSeason = season
            selectedEpisode = episode
        } label: {
            HStack(alignment: .top, spacing: 12) {
                episodeThumbnail(episode)
                    .frame(width: 104, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.code(seasonFallback: season))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)

                    Text(episode.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let plot = episode.plot, !plot.isEmpty {
                        Text(plot)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .lineSpacing(1.5)
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
            .fill(Color.white.opacity(0.08))
            .overlay {
                Image(systemName: "play.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
    }

    // MARK: - Riproduzione / ripresa

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
