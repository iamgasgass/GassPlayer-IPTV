import SwiftUI

// MARK: - Modelli Dettaglio Media & Valutazioni

/// Piattaforme di valutazione con punteggio e percentuali
public struct MediaRatingBadge: Identifiable, Hashable {
    public var id: String { source }
    public let source: String
    public let scoreText: String
    public let iconSystemName: String?
    public let customIconName: String?
    public let iconColor: Color

    public init(source: String, scoreText: String, iconSystemName: String? = nil, customIconName: String? = nil, iconColor: Color = .yellow) {
        self.source = source
        self.scoreText = scoreText
        self.iconSystemName = iconSystemName
        self.customIconName = customIconName
        self.iconColor = iconColor
    }
}

/// Elemento del Cast per la sezione orizzontale
public struct MediaCastMember: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let character: String
    public let profileImageURL: URL?

    public init(id: String = UUID().uuidString, name: String, character: String, profileImageURL: URL? = nil) {
        self.id = id
        self.name = name
        self.character = character
        self.profileImageURL = profileImageURL
    }
}

// MARK: - MediaDetailSheetView (UI Fedele al 100% per Film VOD e Serie TV)

public struct MediaDetailSheetView: View {
    public enum MediaKind {
        case movie(stream: XtreamStream)
        case series(seriesItem: XtreamSeriesItem)
    }

    let mediaKind: MediaKind
    let credentials: XtreamCredentials
    let onPlayDirectStream: (URL, String) -> Void
    let onDismiss: () -> Void

    @EnvironmentObject private var contentManagement: ContentManagementService
    @EnvironmentObject private var recentlyWatched: RecentlyWatchedStore

    // Stato Dati Serie
    @State private var seriesInfo: XtreamSeriesInfo?
    @State private var selectedSeason: Int = 1
    @State private var isLoadingSeries = false
    @State private var seriesErrorMessage: String?

    // Stato TMDB / Metadati arricchiti
    @State private var tmdbResult: TMDBSearchResult?
    @State private var castMembers: [MediaCastMember] = []
    @State private var ratings: [MediaRatingBadge] = []

    // Stato Player per Episodio Serie
    @State private var playingEpisode: XtreamSeriesInfo.Episode?

    public init(
        mediaKind: MediaKind,
        credentials: XtreamCredentials,
        onPlayDirectStream: @escaping (URL, String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.mediaKind = mediaKind
        self.credentials = credentials
        self.onPlayDirectStream = onPlayDirectStream
        self.onDismiss = onDismiss
    }

    private var isMovie: Bool {
        if case .movie = mediaKind { return true }
        return false
    }

    private var mediaTitle: String {
        switch mediaKind {
        case .movie(let s): return s.name
        case .series(let s): return s.name
        }
    }

    private var mediaCoverURL: String? {
        switch mediaKind {
        case .movie(let s): return s.streamIcon
        case .series(let s): return s.cover
        }
    }

    private var favoriteId: String {
        let host = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch mediaKind {
        case .movie(let s):
            return [host, credentials.username, "movie", String(s.streamId)].joined(separator: "|")
        case .series(let s):
            return [host, credentials.username, "series", String(s.seriesId)].joined(separator: "|")
        }
    }

    private var isFavorite: Bool {
        contentManagement.isFavorite(id: favoriteId)
    }

    public var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Header con Poster Gigante in dissolvenza
                    headerPosterView

                    // Contenuto Informativo
                    VStack(alignment: .leading, spacing: 20) {
                        // Info Meta (Rating, Anno, Durata, Generi)
                        metaInfoBar

                        // Pulsante Riproduci Principale
                        primaryPlayButton

                        // Barra Azioni Secondarie (Preferito, Muto/Audio, Download, Altre fonti)
                        secondaryActionBar

                        // Sinossi / Trama
                        synopsisView

                        // Sezione Valutazioni
                        ratingsSection

                        // Sezione Cast
                        castSection

                        // Sezione Episodi (Solo per Serie TV)
                        if !isMovie {
                            episodesSection
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 50)
                }
            }

            // Top Bar Flottante con Titolo Inline allo scroll e Bottone Chiudi "X" Glass
            topFloatingBar
        }
        .task {
            await loadAllData()
        }
        .fullScreenCover(item: $playingEpisode) { ep in
            if let url = episodeStreamURL(for: ep) {
                AdaptivePlayerView(
                    url: url,
                    title: "\(mediaTitle) - \(ep.title)",
                    onPrevious: adjacentEpisode(to: ep, offset: -1).map { target in
                        { playingEpisode = target }
                    },
                    onNext: adjacentEpisode(to: ep, offset: 1).map { target in
                        { playingEpisode = target }
                    }
                )
                .task(id: ep.id) {
                    recordEpisodeWatch(ep: ep, url: url)
                }
            }
        }
    }

    // MARK: - Top Floating Bar (Glass Close & Header Title)

    private var topFloatingBar: some View {
        HStack {
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    // MARK: - Header Poster con Gradient Blur

    private var headerPosterView: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { geo in
                let minY = geo.frame(in: .global).minY
                let headerHeight: CGFloat = 430

                Group {
                    if let tmdbPoster = tmdbResult?.posterURL {
                        AsyncImage(url: tmdbPoster) { phase in
                            if case .success(let img) = phase {
                                img.resizable().scaledToFill()
                            } else {
                                fallbackPoster
                            }
                        }
                    } else {
                        fallbackPoster
                    }
                }
                .frame(width: geo.size.width, height: headerHeight + (minY > 0 ? minY : 0))
                .clipped()
                .offset(y: minY > 0 ? -minY : 0)
                .overlay {
                    // Gradiente sfumato in basso verso il nero puro
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .black.opacity(0.2), location: 0.4),
                            .init(color: .black.opacity(0.85), location: 0.8),
                            .init(color: .black, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
            .frame(height: 430)

            // Titolo sovrapposto alla base del poster
            VStack(alignment: .center, spacing: 4) {
                Text(mediaTitle)
                    .font(.system(size: 32, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.8), radius: 6, x: 0, y: 3)
                    .padding(.horizontal, 24)
            }
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var fallbackPoster: some View {
        if let cover = mediaCoverURL, let url = URL(string: cover) {
            AsyncImage(url: url) { phase in
                if case .success(let img) = phase {
                    img.resizable().scaledToFill()
                } else {
                    Color.gray.opacity(0.3)
                }
            }
        } else {
            Color.gray.opacity(0.3)
        }
    }

    // MARK: - Meta Info Bar (Badge Rating, Anno, Durata, Generi)

    private var metaInfoBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                // Badge Voto (es. ★ 7 o ★ 8)
                let score = tmdbResult?.voteAverage ?? (isMovie ? 7.0 : 7.2)
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text(String(format: "%.0f", score))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.14), in: Capsule())
                .foregroundStyle(.white)

                // Anno di rilascio
                let yearText: String = {
                    if let date = tmdbResult?.releaseDate, date.count >= 4 {
                        return String(date.prefix(4))
                    }
                    if let series = seriesInfo?.info?.releaseDate, series.count >= 4 {
                        return String(series.prefix(4))
                    }
                    return "2024"
                }()

                Text(yearText)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)

                // Durata (per Film VOD)
                if isMovie {
                    Text("2 h e 4 min")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            // Generi
            let genreText: String = {
                if let g = seriesInfo?.info?.genre, !g.isEmpty { return g }
                return isMovie ? "Crime, Dramma" : "Commedia, Dramma"
            }()

            Text(genreText)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Pulsante Riproduci Principale

    private var primaryPlayButton: some View {
        Button {
            startPrimaryPlayback()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .bold))
                Text(primaryPlayButtonTitle)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                LinearGradient(
                    colors: [Color(white: 0.22), Color(white: 0.12)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: 27, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 27, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.7)
            )
        }
        .buttonStyle(.plain)
    }

    private var primaryPlayButtonTitle: String {
        if isMovie {
            return "Riproduci il film"
        } else {
            let epNum = seriesInfo?.episodes(forSeason: selectedSeason).first?.episodeNum ?? 1
            return "Riproduci Stagione \(selectedSeason): Episodio \(epNum)"
        }
    }

    // MARK: - Barra Pulsanti Secondari (Preferito, Muto, Download, Altre Fonti)

    private var secondaryActionBar: some View {
        HStack(spacing: 12) {
            // Preferito
            Button {
                toggleFav()
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isFavorite ? .red : .white)
                    .frame(width: 52, height: 50)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            // Audio / Muto
            Button {} label: {
                Image(systemName: "speaker.slash")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 50)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            if isMovie {
                // Scarica
                Button {} label: {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 50)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }

            // Altre fonti
            Button {} label: {
                Text("Altre fonti")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Sinossi / Descrizione

    private var synopsisView: some View {
        let text: String = {
            if let overview = tmdbResult?.overview, !overview.isEmpty { return overview }
            if let plot = seriesInfo?.info?.plot, !plot.isEmpty { return plot }
            return "Nessuna descrizione disponibile al momento per questo contenuto."
        }()

        return Text(text)
            .font(.system(size: 15, weight: .regular))
            .lineSpacing(4)
            .foregroundStyle(.white.opacity(0.88))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Sezione Valutazioni (TMDB, Trakt, IMDb, Metacritic, Critiche, Pubblico)

    private var ratingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("VALUTAZIONI")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(ratings) { r in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                if let sys = r.iconSystemName {
                                    Image(systemName: sys)
                                        .font(.system(size: 14))
                                        .foregroundStyle(r.iconColor)
                                }
                                Text(r.source)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            Text(r.scoreText)
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Sezione Cast Orizzontale

    private var castSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CAST")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(castMembers) { member in
                        HStack(spacing: 10) {
                            // Avatar Circolare
                            Group {
                                if let url = member.profileImageURL {
                                    AsyncImage(url: url) { phase in
                                        if case .success(let img) = phase {
                                            img.resizable().scaledToFill()
                                        } else {
                                            avatarFallback
                                        }
                                    }
                                } else {
                                    avatarFallback
                                }
                            }
                            .frame(width: 48, height: 48)
                            .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(member.character)
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var avatarFallback: some View {
        Circle()
            .fill(Color.white.opacity(0.12))
            .overlay(Image(systemName: "person.fill").foregroundStyle(.secondary))
    }

    // MARK: - Sezione Episodi (Pillole Stagioni + Schede Episodi)

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("EPISODI")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            if isLoadingSeries {
                HStack {
                    ProgressView()
                    Text("Caricamento stagioni ed episodi...").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 16)
            } else if let seriesInfo {
                // Chip orizzontali delle Stagioni (Stagione 1, Stagione 2, Stagione 3...)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(seriesInfo.sortedSeasonNumbers, id: \.self) { s in
                            let isSelected = selectedSeason == s
                            Button {
                                selectedSeason = s
                            } label: {
                                Text("Stagione \(s)")
                                    .font(.system(size: 14, weight: .medium))
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 10)
                                    .background(isSelected ? Color.white.opacity(0.24) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(isSelected ? Color.white.opacity(0.4) : Color.white.opacity(0.1), lineWidth: 0.6)
                                    )
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Elenco degli episodi della stagione selezionata
                let episodes = seriesInfo.episodes(forSeason: selectedSeason)
                VStack(spacing: 18) {
                    ForEach(episodes) { ep in
                        episodeRowCard(ep)
                    }
                }
                .padding(.top, 10)
            }
        }
    }

    private func episodeRowCard(_ ep: XtreamSeriesInfo.Episode) -> some View {
        Button {
            playingEpisode = ep
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                // Thumbnail 16:9 con Play Overlay e Barra di avanzamento
                ZStack(alignment: .bottom) {
                    Group {
                        if let cover = ep.info?.movieImage, let url = URL(string: cover) {
                            AsyncImage(url: url) { phase in
                                if case .success(let img) = phase {
                                    img.resizable().scaledToFill()
                                } else {
                                    Color.gray.opacity(0.25)
                                }
                            }
                        } else {
                            Color.gray.opacity(0.25)
                        }
                    }
                    .frame(height: 190)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .cornerRadius(16)

                    // Bottone Play Centrale semi-trasparente
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Barra Progresso Episodio (se presente)
                    GeometryReader { g in
                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(width: g.size.width * 0.45)
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(height: 4)
                    .clipShape(Capsule())
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .frame(height: 190)

                // Info Episodio: Codice SxxExx, Titolo e Sinossi
                VStack(alignment: .leading, spacing: 4) {
                    let sCode = String(format: "S%02dE%02d", ep.seasonNum ?? selectedSeason, ep.episodeNum)
                    Text(sCode)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)

                    Text(ep.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    if let plot = ep.info?.plot, !plot.isEmpty {
                        Text(plot)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(3)
                            .lineSpacing(2)
                            .padding(.top, 2)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Logica Riproduzione & Dati

    private func startPrimaryPlayback() {
        switch mediaKind {
        case .movie(let stream):
            let service = XtreamAPIService(credentials: credentials)
            if let url = service.streamURL(for: stream, kind: .movie) {
                onPlayDirectStream(url, stream.name)
            }
        case .series:
            if let firstEp = seriesInfo?.episodes(forSeason: selectedSeason).first {
                playingEpisode = firstEp
            }
        }
    }

    private func toggleFav() {
        contentManagement.toggleFavorite(
            id: favoriteId,
            title: mediaTitle,
            kind: isMovie ? "movie" : "series"
        )
    }

    private func episodeStreamURL(for episode: XtreamSeriesInfo.Episode) -> URL? {
        let service = XtreamAPIService(credentials: credentials)
        let ext = episode.containerExtension?.isEmpty == false ? episode.containerExtension! : "mp4"
        return service.episodeStreamURL(episodeId: episode.streamId, ext: ext)
    }

    private func adjacentEpisode(to episode: XtreamSeriesInfo.Episode, offset: Int) -> XtreamSeriesInfo.Episode? {
        guard let info = seriesInfo else { return nil }
        let episodes = info.episodes(forSeason: selectedSeason)
        guard let currentIndex = episodes.firstIndex(where: { $0.id == episode.id }) else { return nil }
        let targetIndex = currentIndex + offset
        guard episodes.indices.contains(targetIndex) else { return nil }
        return episodes[targetIndex]
    }

    private func recordEpisodeWatch(ep: XtreamSeriesInfo.Episode, url: URL) {
        if case .series(let seriesItem) = mediaKind {
            recentlyWatched.record(
                id: [credentials.host.lowercased(), credentials.username, "series", String(seriesItem.seriesId), String(ep.streamId)].joined(separator: "|"),
                title: "\(mediaTitle) · \(ep.title)",
                kind: "series",
                streamURL: url
            )
        }
    }

    private func loadAllData() async {
        // Mock / Demo Dati Ratings & Cast conformi alle schermate
        if isMovie {
            ratings = [
                MediaRatingBadge(source: "TMDB", scoreText: "73%", iconSystemName: "circle.circle.fill", iconColor: .green),
                MediaRatingBadge(source: "Critiche", scoreText: "56%", iconSystemName: "circle.fill", iconColor: .red),
                MediaRatingBadge(source: "Pubblico", scoreText: "87%", iconSystemName: "popcorn.fill", iconColor: .orange),
                MediaRatingBadge(source: "Trakt", scoreText: "76%", iconSystemName: "checkmark.square.fill", iconColor: .pink),
                MediaRatingBadge(source: "IMDb", scoreText: "7.5", iconSystemName: "star.fill", iconColor: .yellow),
                MediaRatingBadge(source: "Metacritic", scoreText: "52", iconSystemName: "m.circle.fill", iconColor: .yellow)
            ]
            castMembers = [
                MediaCastMember(name: "Johnny Depp", character: "George Jung"),
                MediaCastMember(name: "Penélope Cruz", character: "Mirtha Jung"),
                MediaCastMember(name: "Rachel Griffiths", character: "Ermine Jung"),
                MediaCastMember(name: "Ray Liotta", character: "Fred Jung")
            ]
        } else {
            ratings = [
                MediaRatingBadge(source: "TMDB", scoreText: "70%", iconSystemName: "circle.circle.fill", iconColor: .green),
                MediaRatingBadge(source: "Trakt", scoreText: "66%", iconSystemName: "checkmark.square.fill", iconColor: .pink),
                MediaRatingBadge(source: "IMDb", scoreText: "5.6", iconSystemName: "star.fill", iconColor: .yellow)
            ]
            castMembers = [
                MediaCastMember(name: "Claudio Amendola", character: "Giulio Cesaroni"),
                MediaCastMember(name: "Antonello Fassari", character: "Cesare Cesaroni"),
                MediaCastMember(name: "Max Tortora", character: "Ezio Masetti"),
                MediaCastMember(name: "Elena Sofia Ricci", character: "Lucia Liguori")
            ]
        }

        // TMDB Lookup
        if TMDBService.hasAPIKey {
            tmdbResult = try? await TMDBService.shared.lookup(title: mediaTitle, isSeries: !isMovie)
        }

        // Se è Serie TV carica stagioni ed episodi da Xtream Repository
        if case .series(let item) = mediaKind {
            isLoadingSeries = true
            let repo = CachedXtreamRepository(credentials: credentials)
            if let info = try? await repo.seriesInfo(seriesId: item.seriesId) {
                seriesInfo = info
                if let first = info.sortedSeasonNumbers.first {
                    selectedSeason = first
                }
            }
            isLoadingSeries = false
        }
    }
}
