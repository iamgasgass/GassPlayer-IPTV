import SwiftUI

private struct MoviePlaybackTarget: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

/// Scheda dettaglio di un film VOD con UI identica al video dimostrativo
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
    /// Offset di scroll per il blur parziale della barra superiore, come
    /// nel video di riferimento (X sempre visibile, titolo e sfondo Liquid
    /// Glass che sfumano dentro solo scendendo oltre l'header).
    @State private var scrollOffset: CGFloat = 0

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
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    // Header con Backdrop e Logo
                    MediaHeroHeader(
                        title: stream.name,
                        logoURL: detail.logoURL,
                        backdropURL: detail.backdropURL,
                        fallbackImageURLString: stream.streamIcon
                    )
                    .frame(width: geometry.size.width)
                    .modifier(MediaDetailScrollTracker())

                    // Blocco informazioni centrali
                    VStack(spacing: 16) {
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

                    // Sezione Valutazioni (TMDB, Critica, Trakt, IMDb, Metacritic)
                    MediaRatingsSection(ratings: detail.ratings)
                        .padding(.top, 18)
                        .frame(width: geometry.size.width, alignment: .leading)

                    // Sezione Cast con attori e ruoli
                    MediaCastSection(cast: detail.cast)
                        .padding(.top, 18)
                        .padding(.bottom, 40)
                        .frame(width: geometry.size.width, alignment: .leading)
                }
                .frame(width: geometry.size.width)
            }
            .scrollIndicators(.hidden)
            .modifier(MediaDetailScrollObserver(offset: $scrollOffset))
            .ignoresSafeArea(edges: .top)
            .background(Color(uiColor: .systemBackground))
            .overlay(alignment: .top) {
                MediaDetailScrollTopBar(
                    title: stream.name,
                    progress: MediaDetailScrollTopBar.progress(forScrolled: scrollOffset),
                    topInset: geometry.safeAreaInsets.top,
                    onClose: { dismiss() }
                )
            }
        }
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

    // MARK: - Riga Icone d'azione (Preferiti, Muto anteprima, Download, Altre fonti)

    private var iconRow: some View {
        HStack(spacing: 12) {
            MediaIconButton(
                systemImage: isFavorite ? "heart.fill" : "heart",
                tint: isFavorite ? .red : .white,
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
                tint: downloadProgress == 1 ? .green : .white,
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

    // MARK: - Azioni di riproduzione e download

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

    // MARK: - Caricamento Metadati TMDB/Xtream

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
