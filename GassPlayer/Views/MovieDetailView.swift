import SwiftUI

/// Riproduzione in corso dalla scheda dettaglio: incapsula url+titolo così
/// da poterla usare come `item` di un `fullScreenCover`, sia per il film
/// aperto direttamente sia per un risultato scelto da "Altre fonti".
private struct MoviePlaybackTarget: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

/// Scheda dettaglio di un VOD, aperta al tap sulla locandina nella
/// griglia. Riproduce esattamente il layout del video dimostrativo
/// "Blow": hero con backdrop e logo TMDB, voto/durata/genere, pulsante
/// "Riproduci il film", riga preferiti/muto anteprima/download/altre
/// fonti, trama, sezione "VALUTAZIONI" (TMDB/Critica/Trakt/IMDb/
/// Metacritic, a seconda delle chiavi API configurate) e sezione "CAST".
struct MovieDetailView: View {
    let credentials: XtreamCredentials
    let stream: XtreamStream

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var contentManagement: ContentManagementService
    @EnvironmentObject private var recentlyWatched: RecentlyWatchedStore
    @ObservedObject private var downloadManager = DownloadManager.shared

    @State private var vodInfo: XtreamVODInfo?
    @State private var detail: MediaDetail = .empty
    @State private var isLoadingDetail = true

    @State private var playbackTarget: MoviePlaybackTarget?
    @State private var showAlternateSources = false
    @State private var downloadId: UUID?

    /// Cosmetico/preparatorio: l'hero mostra solo un'immagine statica (né
    /// Xtream né TMDB offrono qui un trailer riproducibile direttamente da
    /// AVPlayer, solo eventuali chiavi YouTube), quindi questo pulsante non
    /// ha ancora un audio reale da mutare. Resta comunque presente,
    /// identico al video, come stato pronto per una futura anteprima video
    /// con audio.
    @AppStorage("gassplayer.detail.trailerMuted")
    private var isTrailerMuted = true

    private var api: XtreamAPIService { XtreamAPIService(credentials: credentials) }

    private var favoriteID: String {
        credentials.favoriteID(kind: .movie, streamId: stream.streamId)
    }

    private var isFavorite: Bool {
        contentManagement.isFavorite(id: favoriteID)
    }

    private var downloadProgress: Double? {
        guard let downloadId else { return nil }
        return downloadManager.activeDownloads[downloadId]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                MediaHeroHeader(
                    title: stream.name,
                    logoURL: detail.logoURL,
                    backdropURL: detail.backdropURL,
                    fallbackImageURLString: stream.streamIcon,
                    onClose: { dismiss() }
                )

                VStack(alignment: .leading, spacing: 20) {
                    MediaMetaRow(
                        ratingText: MediaRatingFormatter.starText(fromPercent: detail.ratings.tmdbPercent),
                        secondaryText: detail.runtimeLabel ?? detail.year,
                        genres: detail.genres
                    )

                    MediaPlayButton(title: "Riproduci il film") {
                        play()
                    }

                    iconRow

                    if let overview = detail.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.subheadline)
                            .foregroundStyle(.primary.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    } else if isLoadingDetail {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                    }

                    MediaRatingsSection(ratings: detail.ratings)

                    MediaCastSection(cast: detail.cast)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
        .ignoresSafeArea(edges: .top)
        .background(Color(uiColor: .systemBackground))
        .task(id: stream.streamId) {
            await loadDetail()
        }
        .fullScreenCover(item: $playbackTarget) { target in
            AdaptivePlayerView(url: target.url, title: target.title)
                .task {
                    recentlyWatched.record(
                        id: favoriteID,
                        title: stream.name,
                        kind: XtreamStreamKind.movie.rawValue,
                        streamURL: target.url
                    )
                }
        }
        .sheet(isPresented: $showAlternateSources) {
            AlternateSourcesView(
                title: stream.name,
                kind: .movie,
                excluding: credentials,
                onPickMovie: { altCredentials, altStream in
                    playAlternate(credentials: altCredentials, stream: altStream)
                },
                onPickSeries: { _, _, _ in }
            )
        }
    }

    // MARK: - Riga icone

    private var iconRow: some View {
        HStack(spacing: 12) {
            MediaIconButton(
                systemImage: isFavorite ? "heart.fill" : "heart",
                tint: isFavorite ? .red : .primary,
                accessibilityLabel: isFavorite ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti"
            ) {
                contentManagement.toggleFavorite(id: favoriteID, title: stream.name, kind: XtreamStreamKind.movie.rawValue)
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
                accessibilityLabel: "Scarica"
            ) {
                startDownloadIfNeeded()
            }

            AltreFontiButton {
                showAlternateSources = true
            }
        }
    }

    // MARK: - Azioni

    private func play() {
        guard let url = api.streamURL(for: stream, kind: .movie) else { return }
        playbackTarget = MoviePlaybackTarget(url: url, title: stream.name)
    }

    private func playAlternate(credentials altCredentials: XtreamCredentials, stream altStream: XtreamStream) {
        guard let url = XtreamAPIService(credentials: altCredentials).streamURL(for: altStream, kind: .movie) else { return }
        playbackTarget = MoviePlaybackTarget(url: url, title: altStream.name)
    }

    private func startDownloadIfNeeded() {
        guard downloadId == nil, let url = api.streamURL(for: stream, kind: .movie) else { return }
        let id = UUID()
        downloadId = id
        downloadManager.startDownload(url: url, id: id)
    }

    // MARK: - Caricamento dettaglio

    private func loadDetail() async {
        isLoadingDetail = true

        let fetchedVODInfo = try? await CachedXtreamRepository(credentials: credentials).vodInfo(vodId: stream.streamId)
        vodInfo = fetchedVODInfo

        let seed = MediaDetailSeed(
            title: stream.name,
            isSeries: false,
            overview: fetchedVODInfo?.info?.plot,
            backdropURLString: fetchedVODInfo?.backdropURL?.absoluteString ?? stream.streamIcon,
            genreNames: fetchedVODInfo?.genreNames ?? [],
            castNames: fetchedVODInfo?.castNames ?? [],
            year: fetchedVODInfo?.year,
            runtimeMinutes: fetchedVODInfo?.runtimeMinutes,
            xtreamRating: fetchedVODInfo?.info?.rating.flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
        )

        detail = await MediaDetailLoader.load(seed)
        isLoadingDetail = false
    }
}
