import SwiftUI
import UIKit

// MARK: - Sezione "In evidenza" (Featured) della Home
//
// Carosello a tutta larghezza in cima alla Home con i contenuti più
// rilevanti della libreria della sorgente attiva:
//  1. "Continua a guardare": gli ultimi film/serie aperti (riprende subito);
//  2. "Per te": titoli consigliati da TMDB a partire dall'ultimo visto,
//     solo se presenti nel catalogo;
//  3. "Di tendenza": serie e film della settimana (TMDB) presenti nel catalogo.
// Ogni scheda: immagine a tutto schermo (sotto barra di navigazione e
// ricerca) che sfuma verso il basso, etichetta in capsula, logo del titolo,
// riga "generi · anno · ★voto" (o "S1, E3 · genere · ★voto"), pulsante bianco
// a capsula e puntini di pagina. Scorrimento automatico in dissolvenza e
// scorrimento manuale con il dito. Regolabile/rimovibile da "Personalizza".

enum HomeFeaturedBadge: Equatable {
    case continueWatching
    case forYou
    case trending

    var title: String {
        switch self {
        case .continueWatching: return "Continua a guardare"
        case .forYou: return "Per te"
        case .trending: return "Di tendenza"
        }
    }
}

struct HomeFeaturedEntry: Identifiable, Equatable {
    enum Action: Equatable {
        /// Ripresa dalla cronologia (film o episodio di una serie).
        case resume(RecentlyWatchedItem)
        /// Scheda dettaglio di un film del catalogo.
        case movie(XtreamStream)
        /// Scheda dettaglio di una serie del catalogo.
        case series(XtreamSeriesItem)
    }

    let id: String
    let badge: HomeFeaturedBadge
    let title: String
    let isSeries: Bool
    let action: Action
    /// Immagine del provider (cover / stream_icon), mostrata finché TMDB non
    /// fornisce la locandina.
    var providerImage: String?
    /// Id TMDB già noto (consigliati / tendenza); `nil` per la cronologia.
    var tmdbId: Int?
    /// Genere fornito dalla lista TMDB, prima del dettaglio completo.
    var fallbackGenre: String?
    var fallbackYear: String?

    // Dati del dettaglio TMDB (caricati dopo la comparsa della scheda).
    var episodeLabel: String?
    var posterURL: URL?
    var backdropURL: URL?
    var logoURL: URL?
    var genres: [String] = []
    var year: String?
    var rating: Double?

    var isResume: Bool {
        if case .resume = action { return true }
        return false
    }
}

@MainActor
final class HomeFeaturedModel: ObservableObject {
    @Published private(set) var entries: [HomeFeaturedEntry] = []

    static let maxEntries = 8
    private static let maxContinue = 2
    private static let maxForYou = 3

    private var lastSignature = ""
    private var loadTask: Task<Void, Never>?

    /// Indici normalizzati del catalogo (nome → contenuto), costruiti fuori
    /// dal main thread e riusati finché il catalogo non cambia.
    private var indexSignature = ""
    private var movieIndex: [String: XtreamStream] = [:]
    private var seriesIndex: [String: XtreamSeriesItem] = [:]

    func reload(
        signature: String,
        recent: [RecentlyWatchedItem],
        movies: [XtreamStream],
        series: [XtreamSeriesItem],
        credentials: XtreamCredentials?
    ) {
        guard signature != lastSignature else { return }
        lastSignature = signature
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.build(recent: recent, movies: movies, series: series, credentials: credentials)
        }
    }

    private func build(
        recent: [RecentlyWatchedItem],
        movies: [XtreamStream],
        series: [XtreamSeriesItem],
        credentials: XtreamCredentials?
    ) async {
        let catalogSignature = "\(movies.count)|\(series.count)|\(movies.first?.streamId ?? 0)|\(series.first?.seriesId ?? 0)"
        if catalogSignature != indexSignature {
            let built = await Task.detached(priority: .utility) { () -> ([String: XtreamStream], [String: XtreamSeriesItem]) in
                var movieMap: [String: XtreamStream] = [:]
                movieMap.reserveCapacity(movies.count)
                for stream in movies {
                    let key = HomeTrendingMatcher.normalized(stream.name)
                    if !key.isEmpty, movieMap[key] == nil { movieMap[key] = stream }
                }
                var seriesMap: [String: XtreamSeriesItem] = [:]
                seriesMap.reserveCapacity(series.count)
                for item in series {
                    let key = HomeTrendingMatcher.normalized(item.name)
                    if !key.isEmpty, seriesMap[key] == nil { seriesMap[key] = item }
                }
                return (movieMap, seriesMap)
            }.value
            guard !Task.isCancelled else { return }
            movieIndex = built.0
            seriesIndex = built.1
            indexSignature = catalogSignature
        }

        var result: [HomeFeaturedEntry] = []
        var usedKeys = Set<String>()

        func key(_ title: String, isSeries: Bool) -> String {
            (isSeries ? "s:" : "m:") + HomeTrendingMatcher.normalized(title)
        }

        // 1. Continua a guardare: film e serie (una scheda per serie).
        let movieByID = Dictionary(movies.map { ($0.streamId, $0) }, uniquingKeysWith: { first, _ in first })
        let seriesByID = Dictionary(series.map { ($0.seriesId, $0) }, uniquingKeysWith: { first, _ in first })
        var seenSeries = Set<String>()
        for item in recent where result.count < Self.maxContinue {
            let isSeries = item.kind == XtreamStreamKind.series.rawValue
            guard isSeries || item.kind == XtreamStreamKind.movie.rawValue else { continue }
            if isSeries, let seriesKey = ContinueWatchingSection.seriesKey(for: item) {
                guard seenSeries.insert(seriesKey).inserted else { continue }
            }
            let title = ContinueWatchingSection.displayTitle(for: item)
            guard usedKeys.insert(key(title, isSeries: isSeries)).inserted else { continue }

            // Copertina del catalogo se la cronologia non ne ha una.
            var image = item.imageURLString
            let parts = item.id.components(separatedBy: "|")
            if image == nil, parts.count >= 4, let catalogID = Int(parts[3]) {
                image = isSeries ? seriesByID[catalogID]?.cover : movieByID[catalogID]?.streamIcon
            }

            result.append(HomeFeaturedEntry(
                id: "cw|\(item.id)",
                badge: .continueWatching,
                title: title,
                isSeries: isSeries,
                action: .resume(item),
                providerImage: image
            ))
        }

        if TMDBService.hasAPIKey, !(movies.isEmpty && series.isEmpty) {
            // 2. Per te: consigliati TMDB dall'ultimo film/serie visto.
            if let seed = result.first {
                if let found = try? await TMDBService.shared.lookup(title: seed.title, isSeries: seed.isSeries),
                   let recommended = try? await TMDBService.shared.recommendations(id: found.id, isSeries: seed.isSeries) {
                    var added = 0
                    for item in recommended where added < Self.maxForYou && result.count < Self.maxEntries {
                        if let entry = matchedEntry(item, badge: .forYou), usedKeys.insert(key(entry.title, isSeries: entry.isSeries)).inserted {
                            result.append(entry)
                            added += 1
                        }
                    }
                }
            }
            guard !Task.isCancelled else { return }

            // 3. Di tendenza: serie e film della settimana, alternati.
            if result.count < Self.maxEntries {
                async let trendingSeries = try? TMDBService.shared.trending(isSeries: true, limit: 20)
                async let trendingMovies = try? TMDBService.shared.trending(isSeries: false, limit: 20)
                let seriesList = await trendingSeries ?? []
                let movieList = await trendingMovies ?? []
                var mixed: [TMDBTrendingItem] = []
                for index in 0..<max(seriesList.count, movieList.count) {
                    if index < movieList.count { mixed.append(movieList[index]) }
                    if index < seriesList.count { mixed.append(seriesList[index]) }
                }
                for item in mixed where result.count < Self.maxEntries {
                    if let entry = matchedEntry(item, badge: .trending), usedKeys.insert(key(entry.title, isSeries: entry.isSeries)).inserted {
                        result.append(entry)
                    }
                }
            }
        }

        guard !Task.isCancelled else { return }
        entries = result

        // Dettagli TMDB (locandina senza testo, logo, generi, anno, voto) ed
        // episodio della ripresa, aggiornati scheda per scheda appena pronti.
        await withTaskGroup(of: (String, HomeFeaturedEntry?).self) { group in
            for entry in result {
                group.addTask {
                    (entry.id, await Self.enrich(entry, credentials: credentials))
                }
            }
            for await (id, enriched) in group {
                guard !Task.isCancelled, let enriched,
                      let index = entries.firstIndex(where: { $0.id == id }) else { continue }
                entries[index] = enriched
            }
        }
    }

    private func matchedEntry(_ item: TMDBTrendingItem, badge: HomeFeaturedBadge) -> HomeFeaturedEntry? {
        let keys = HomeTrendingMatcher.keys(for: item)
        if item.isSeries {
            guard let match = keys.lazy.compactMap({ self.seriesIndex[$0] }).first else { return nil }
            return HomeFeaturedEntry(
                id: "\(badge.title)|tv|\(item.id)",
                badge: badge,
                title: match.name,
                isSeries: true,
                action: .series(match),
                providerImage: match.cover,
                tmdbId: item.id,
                fallbackGenre: item.genre,
                fallbackYear: item.year
            )
        } else {
            guard let match = keys.lazy.compactMap({ self.movieIndex[$0] }).first else { return nil }
            return HomeFeaturedEntry(
                id: "\(badge.title)|movie|\(item.id)",
                badge: badge,
                title: match.name,
                isSeries: false,
                action: .movie(match),
                providerImage: match.streamIcon,
                tmdbId: item.id,
                fallbackGenre: item.genre,
                fallbackYear: item.year
            )
        }
    }

    private nonisolated static func enrich(_ entry: HomeFeaturedEntry, credentials: XtreamCredentials?) async -> HomeFeaturedEntry? {
        var updated = entry
        var changed = false

        let details: TMDBDetails?
        if let tmdbId = entry.tmdbId {
            details = try? await TMDBService.shared.details(id: tmdbId, isSeries: entry.isSeries)
        } else if TMDBService.hasAPIKey {
            details = try? await TMDBService.shared.fullDetails(title: entry.title, isSeries: entry.isSeries)
        } else {
            details = nil
        }

        if let details {
            updated.posterURL = details.textlessPosterURL
            updated.backdropURL = details.textlessBackdropURL
            updated.logoURL = details.logoURL
            updated.genres = Array(details.genreNames.prefix(2))
            updated.year = details.year
            updated.rating = details.voteAverage
            changed = true
        }

        // "S1, E3" per la ripresa di un episodio.
        if case .resume(let item) = entry.action, entry.isSeries, let credentials {
            let parts = item.id.components(separatedBy: "|")
            if parts.count >= 5, let seriesId = Int(parts[3]),
               let info = try? await CachedXtreamRepository(credentials: credentials).seriesInfo(seriesId: seriesId) {
                for season in info.sortedSeasonNumbers {
                    if let episode = info.episodes(forSeason: season).first(where: { String($0.streamId) == parts[4] }) {
                        updated.episodeLabel = "S\(episode.season ?? season), E\(episode.episodeNum)"
                        changed = true
                        break
                    }
                }
            }
        }

        return changed ? updated : nil
    }
}

// MARK: - Vista

struct HomeFeaturedSection: View {
    @ObservedObject var model: HomeFeaturedModel
    /// Host della sorgente attiva, per i percorsi relativi delle immagini del provider.
    let baseHost: String
    let onSelect: (HomeFeaturedEntry) -> Void

    /// Spazio di coordinate del contenuto della Home: l'immagine si estende
    /// verso l'alto fino al bordo dello schermo, sotto barra e ricerca.
    static let coordinateSpaceName = "gassplayer.home.overview"

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection = 0

    private enum Metrics {
        static let compactHeight: CGFloat = 430
        static let regularHeight: CGFloat = 520
        /// Spazio oltre il bordo superiore del contenuto coperto dall'immagine
        /// (barra di stato + barra di navigazione).
        static let topBleed: CGFloat = 220
        static let logoMaxWidth: CGFloat = 270
        static let logoMaxHeight: CGFloat = 86
        static let dotSize: CGFloat = 7
        static let buttonHeight: CGFloat = 46
    }

    var body: some View {
        let entries = model.entries

        if !entries.isEmpty {
            let index = min(selection, entries.count - 1)

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                ZStack(alignment: .bottom) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { offset, entry in
                        slide(entry)
                            .opacity(offset == index ? 1 : 0)
                            .allowsHitTesting(offset == index)
                            .accessibilityHidden(offset != index)
                    }
                }

                if entries.count > 1 {
                    pageDots(count: entries.count, index: index)
                        .padding(.top, 18)
                }
            }
            // Testi e pulsante sempre chiari sull'immagine; lo sfondo invece
            // sfuma nel colore reale della Home (tema chiaro o scuro).
            .environment(\.colorScheme, .dark)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
            .frame(height: horizontalSizeClass == .regular ? Metrics.regularHeight : Metrics.compactHeight)
            .background(alignment: .bottom) {
                artworkLayer(entries: entries, index: index)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(swipeGesture(count: entries.count, index: index))
            // Nessun cambio automatico: si scorre solo col dito o toccando i puntini.
            .animation(.easeInOut(duration: 0.6), value: index)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("In evidenza")
        }
    }

    // MARK: Scheda

    private func slide(_ entry: HomeFeaturedEntry) -> some View {
        VStack(spacing: 0) {
            Text(entry.badge.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.38), in: Capsule())
                .padding(.bottom, 10)

            titleView(entry)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            if let meta = metaLine(entry) {
                Text(meta)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 13)
            }

            // Vetro del tasto "Modifica" con le dimensioni del pulsante bianco
            // di prima (testo 17, altezza 46, margini 22).
            Button {
                onSelect(entry)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: entry.isResume ? "play.fill" : "info.circle")
                        .font(.system(size: 17, weight: .semibold))
                    Text(entry.isResume ? "Continua a guardare" : "Maggiori informazioni")
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 22)
                .frame(height: Metrics.buttonHeight)
                .modifier(HomeFeaturedGlassCapsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.isResume ? "Continua a guardare" : "Maggiori informazioni"): \(entry.title)")
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func titleView(_ entry: HomeFeaturedEntry) -> some View {
        if let logoURL = entry.logoURL {
            AsyncImage(url: logoURL) { phase in
                if case .success(let image) = phase {
                    image
                        .resizable()
                        .scaledToFit()
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                } else {
                    titleText(entry)
                }
            }
            .frame(maxWidth: Metrics.logoMaxWidth, maxHeight: Metrics.logoMaxHeight)
        } else {
            titleText(entry)
        }
    }

    private func titleText(_ entry: HomeFeaturedEntry) -> some View {
        Text(entry.title)
            .font(.system(size: 34, weight: .heavy))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .shadow(color: .black.opacity(0.45), radius: 10, y: 2)
            .frame(maxWidth: Metrics.logoMaxWidth + 40)
    }

    /// "S1, E3 · Commedia · ★7" (ripresa di una serie) oppure
    /// "Azione, Crime · 2025 · ★7".
    private func metaLine(_ entry: HomeFeaturedEntry) -> String? {
        var parts: [String] = []
        let genres = entry.genres.isEmpty ? [entry.fallbackGenre].compactMap { $0 } : entry.genres

        if entry.isResume, entry.isSeries {
            if let episode = entry.episodeLabel { parts.append(episode) }
            if let genre = genres.first { parts.append(genre) }
        } else {
            if !genres.isEmpty { parts.append(genres.joined(separator: ", ")) }
            if let year = entry.year ?? entry.fallbackYear { parts.append(year) }
        }

        if let rating = entry.rating, rating > 0 {
            parts.append("★\(Int(rating.rounded()))")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func pageDots(count: Int, index: Int) -> some View {
        HStack(spacing: 6.5) {
            ForEach(0..<count, id: \.self) { dot in
                Circle()
                    .fill(Color.white.opacity(dot == index ? 1 : 0.35))
                    .frame(width: Metrics.dotSize, height: Metrics.dotSize)
                    .onTapGesture { selection = dot }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Pagina \(index + 1) di \(count)")
    }

    // MARK: Immagine di sfondo

    private func artworkLayer(entries: [HomeFeaturedEntry], index: Int) -> some View {
        GeometryReader { proxy in
            let minY = proxy.frame(in: .named(Self.coordinateSpaceName)).minY
            let extra = max(0, minY) + Metrics.topBleed
            let width = proxy.size.width
            let height = proxy.size.height + extra
            let wide = width > height * 0.9

            ZStack {
                Color.black

                ForEach(Array(entries.enumerated()), id: \.element.id) { offset, entry in
                    HomeFeaturedArtwork(
                        url: wide ? (entry.backdropURL ?? entry.posterURL) : (entry.posterURL ?? entry.backdropURL),
                        providerImage: entry.providerImage,
                        baseHost: baseHost
                    )
                    .frame(width: width, height: height)
                    .clipped()
                    .opacity(offset == index ? 1 : 0)
                }

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.38), location: 0),
                        .init(color: .clear, location: 0.2),
                        .init(color: .clear, location: 0.46),
                        .init(color: .black.opacity(0.42), location: 0.66),
                        .init(color: .black.opacity(0.72), location: 0.88),
                        .init(color: Color(uiColor: .systemBackground), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: width, height: height)
            .offset(y: -extra)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Scorrimento manuale

    private func swipeGesture(count: Int, index: Int) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let horizontal = value.translation.width
                guard count > 1, abs(horizontal) > 50, abs(horizontal) > abs(value.translation.height) * 1.4 else { return }
                selection = horizontal < 0 ? (index + 1) % count : (index - 1 + count) % count
            }
    }
}

/// Immagine dell'hero: locandina TMDB senza testo (o backdrop) con
/// riempimento; finché non c'è, l'immagine del provider. Usa lo stesso
/// downloader tollerante delle griglie (nuovi tentativi, https → http).
private struct HomeFeaturedArtwork: View {
    let url: URL?
    let providerImage: String?
    let baseHost: String

    @State private var image: UIImage?
    @State private var loadedKey: String?

    private var resolved: URL? {
        url ?? PosterImageStore.url(from: providerImage, baseHost: baseHost)
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(white: 0.08)
            }
        }
        .task(id: resolved?.absoluteString) {
            guard let target = resolved else { return }
            if let cached = PosterImageStore.cachedImage(for: target, maxPixel: 1400) {
                image = cached
                loadedKey = target.absoluteString
                return
            }
            guard let loaded = await PosterDownloader.shared.image(for: target, maxPixel: 1400), !Task.isCancelled else { return }
            image = loaded
            loadedKey = target.absoluteString
        }
    }
}

/// iOS 26: niente sfumatura della barra di navigazione sopra l'hero (che
/// deve arrivare limpido fino al bordo dello schermo, come nel riferimento).
struct HomeFeaturedScrollEdge: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), isActive {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}

/// Presentazioni della sezione "In evidenza": ripresa di un film (stesso
/// player di "Continua a guardare") o di un episodio con precedente/successivo
/// e "Prossimo episodio" (`SeriesResumePlayer`). Separate dal `body` della Home,
/// già lungo, per non appesantire il type-checker.
struct HomeFeaturedPresenter: ViewModifier {
    @Binding var resumeItem: RecentlyWatchedItem?
    @Binding var seriesResume: SeriesResumeRequest?
    let recentlyWatched: RecentlyWatchedStore

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $resumeItem) { item in
                AdaptivePlayerView(url: item.streamURL, title: item.title)
            }
            .fullScreenCover(item: $seriesResume) { request in
                SeriesResumePlayer(request: request) { episode, url in
                    recentlyWatched.record(
                        id: request.episodeID(episode.streamId),
                        title: "\(request.seriesName) · \(episode.title)",
                        kind: XtreamStreamKind.series.rawValue,
                        streamURL: url,
                        imageURLString: request.item.imageURLString
                    )
                }
            }
    }
}

/// Capsula Liquid Glass del pulsante "In evidenza": stesso vetro del tasto
/// "Modifica" (`ClearGlassCapsule`) applicato a un'etichetta a misura fissa.
private struct HomeFeaturedGlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
                }
        }
    }
}
