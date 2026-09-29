import SwiftUI

/// Scheda dettaglio di una serie TV identica al video di riferimento
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
    /// Offset di scroll per il blur parziale della barra superiore, come
    /// nel video di riferimento.
    @State private var scrollOffset: CGFloat = 0

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

    // MARK: - Stati di caricamento ed errore

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Caricamento serie...").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Riprova") { Task { await loadSeriesInfo() } }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }

    // MARK: - Contenuto principale

    private func detailContent(_ info: XtreamSeriesInfo) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    // Header Backdrop
                    MediaHeroHeader(
                        title: seriesName,
                        logoURL: detail.logoURL,
                        backdropURL: detail.backdropURL,
                        fallbackImageURLString: fallbackCoverURLString,
                        onClose: { dismiss() }
                    )
                    .frame(width: geometry.size.width)
                    .modifier(MediaDetailScrollTracker())

                    // Blocco centrale
                    VStack(spacing: 16) {
                        MediaMetaRow(
                            ratingText: MediaRatingFormatter.starText(fromPercent: detail.ratings.tmdbPercent),
                            secondaryText: detail.year,
                            genres: detail.genres
                        )

                        MediaPlayButton(title: playButtonTitle) {
                            playResumeOrFirstEpisode(info)
                        }

                        iconRow

                        if let overview = detail.overview, !overview.isEmpty {
                            Text(overview)
                                .font(.subheadline)
                                .foregroundStyle(.primary.opacity(0.92))
                                .lineSpacing(3.5)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if isLoadingDetail {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.top, 8)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .frame(width: geometry.size.width)

                    // Sezione Valutazioni
                    MediaRatingsSection(ratings: detail.ratings)
                        .padding(.top, 18)
                        .frame(width: geometry.size.width, alignment: .leading)

                    // Sezione Cast
                    MediaCastSection(cast: detail.cast)
                        .padding(.top, 18)
                        .frame(width: geometry.size.width, alignment: .leading)

                    // Sezione Episodi e Stagioni
                    episodesSection(info, containerWidth: geometry.size.width)
                        .padding(.top, 20)
                        .padding(.bottom, 40)
                        .frame(width: geometry.size.width, alignment: .leading)
                }
                .frame(width: geometry.size.width)
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(name: "mediaDetailScroll")
            .ignoresSafeArea(edges: .top)
            .background(Color(uiColor: .systemBackground))
            .onPreferenceChange(MediaDetailScrollOffsetKey.self) { scrollOffset = $0 }
            .overlay(alignment: .top) {
                MediaDetailScrollTopBar(
                    title: seriesName,
                    progress: MediaDetailScrollTopBar.progress(forOffset: scrollOffset),
                    onClose: { dismiss() }
                )
            }
        }
    }

    // MARK: - Riga icone

    private var iconRow: some View {
        HStack(spacing: 12) {
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

    // MARK: - Sezione Episodi e Stagioni

    private func episodesSection(_ info: XtreamSeriesInfo, containerWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("EPISODI")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)

            // Selettore stagioni (Pillole / Chip con angoli arrotondati)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(info.sortedSeasonNumbers, id: \.self) { season in
                        seasonChip(season)
                    }
                }
                .padding(.horizontal, 20)
            }

            // Lista episodi con card a piena larghezza, come nel video
            if let selectedSeason {
                VStack(spacing: 28) {
                    ForEach(info.episodes(forSeason: selectedSeason)) { episode in
                        episodeRow(episode, season: selectedSeason)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
            }
        }
    }

    private func seasonChip(_ season: Int) -> some View {
        let isSelected = selectedSeason == season

        return Button {
            withAnimation(.snappy(duration: 0.16)) { selectedSeason = season }
        } label: {
            Text("Stagione \(season)")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .background(
                    isSelected ? Color.white.opacity(0.18) : Color.white.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Color.white.opacity(0.2) : Color.clear, lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
    }

    /// Card episodio a piena larghezza, identica al video dimostrativo:
    /// miniatura 16:9 a tutta larghezza (con barra "riprendi da qui" quando
    /// è l'episodio segnato come in corso), poi sotto in verticale codice,
    /// titolo, trama COMPLETA (mai troncata) e data di uscita.
    private func episodeRow(_ episode: XtreamSeriesInfo.Episode, season: Int) -> some View {
        Button {
            selectedSeason = season
            selectedEpisode = episode
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                episodeThumbnail(episode)
                    .aspectRatio(16.0 / 9.0, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .bottom) {
                        if isResumeEpisode(episode) {
                            resumeProgressBar
                        }
                    }
                    .clipped()

                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.code(seasonFallback: season))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text(episode.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let plot = episode.plot, !plot.isEmpty {
                    Text(plot)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let date = episode.formattedReleaseDate {
                    Text(date)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.85))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Barra bianca "riprendi da qui" sovrapposta in basso alla miniatura,
    /// mostrata solo sull'episodio effettivamente registrato in "Continua a
    /// guardare" (vedi `resumeEpisode`). Il player attuale non riporta la
    /// posizione esatta di riproduzione all'esterno (nessun secondo/durata
    /// disponibile fuori da `PlayerView`), quindi qui si mostra solo
    /// l'indicatore "ripresa disponibile" del video, non una percentuale
    /// esatta calcolata da un dato che l'app non possiede.
    private var resumeProgressBar: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Color.white)
                .frame(width: proxy.size.width * 0.92, height: 5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 5)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private func isResumeEpisode(_ episode: XtreamSeriesInfo.Episode) -> Bool {
        resumeEpisode?.episode.id == episode.id
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
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
    }

    // MARK: - Riproduzione e ripresa automatica

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
