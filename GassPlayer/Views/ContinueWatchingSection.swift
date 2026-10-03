import SwiftUI

// MARK: - Continua a guardare (identico in Home, VOD e Serie TV)

/// Sezione "Continua a guardare" condivisa da `HomeView` (tutti i tipi) e
/// da `ChannelGridView` (solo il tipo della propria sezione: film in VOD,
/// serie in Serie TV): un'unica implementazione, quindi Home, VOD e Serie
/// TV mostrano esattamente la stessa card.
///
/// UI (riferimento a schermo, misure in punti):
/// - titolo sezione 18,5 pt medium, colore secondario;
/// - card con poster/backdrop a tutta card, 288×162 (16:9), angoli 16
///   continui e filo di bordo chiaro, nessun pannello vetro intorno;
/// - sotto la card: titolo (13,5 pt medium) e categoria del catalogo in
///   grigio, rientrati di 12 pt rispetto al bordo della card.
///
/// FIX (compariva solo al riavvio / senza poster): vedi
/// `RecentlyWatchedStore.refresh()` e `resolveMissingMetadata()`.
struct ContinueWatchingSection: View {
    /// `nil` = tutti i tipi; altrimenti solo `RecentlyWatchedItem.kind == kindFilter`.
    var kindFilter: String? = nil
    /// Margine laterale di header e riga (16 pt come nel riferimento).
    var horizontalInset: CGFloat = 16
    var topPadding: CGFloat = 0
    var bottomPadding: CGFloat = 0

    @EnvironmentObject private var recentlyWatched: RecentlyWatchedStore
    @EnvironmentObject private var xtreamCatalog: XtreamCatalogStore
    @EnvironmentObject private var sourceManager: SourceManager
    @State private var resumeItem: RecentlyWatchedItem?
    /// Ripresa di un episodio di una serie: il player riceve anche i tasti
    /// precedente/successivo e il "Prossimo Episodio" (vedi
    /// `SeriesResumePlayer`).
    @State private var seriesResume: SeriesResumeRequest?

    private enum Metrics {
        static let cardWidth: CGFloat = 288
        static let cardHeight: CGFloat = 162
        static let cornerRadius: CGFloat = 16
        static let cardSpacing: CGFloat = 11
        static let headerToCardSpacing: CGFloat = 10
        static let cardToTextSpacing: CGFloat = 5
        static let textInset: CGFloat = 12
        /// Risoluzione di decodifica: ~3× la larghezza della card, nitida
        /// anche sugli schermi più densi.
        static let imageMaxPixel: CGFloat = 1000
    }

    /// Elementi da mostrare: filtrati per tipo e, per le serie, UNA sola
    /// card per serie (l'episodio guardato più di recente) invece di una
    /// per ogni episodio aperto.
    private var items: [RecentlyWatchedItem] {
        let source = kindFilter.map { kind in
            recentlyWatched.items.filter { $0.kind == kind }
        } ?? recentlyWatched.items

        var seenSeries = Set<String>()

        return source.filter { item in
            guard item.kind == XtreamStreamKind.series.rawValue,
                  let key = Self.seriesKey(for: item) else {
                return true
            }

            return seenSeries.insert(key).inserted
        }
    }

    var body: some View {
        let visibleItems = items

        VStack(alignment: .leading, spacing: Metrics.headerToCardSpacing) {
            if !visibleItems.isEmpty {
                HStack(alignment: .center) {
                    Text("Continua a guardare")
                        .font(.system(size: 18.5, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 12)

                    // Tasto "Svuota" (stessa azione dell'implementazione
                    // originale: svuota solo il tipo della sezione, tutto
                    // in Home) con lo stesso materiale Liquid Glass della
                    // "X" delle schede dettaglio VOD/Serie TV, in forma di
                    // capsula perché contiene testo.
                    Button {
                        withAnimation(.snappy) {
                            if let kindFilter {
                                recentlyWatched.clear(kind: kindFilter)
                            } else {
                                recentlyWatched.clear()
                            }
                        }
                    } label: {
                        Text("Svuota")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                    }
                    .modifier(ClearGlassCapsule())
                    .accessibilityLabel("Svuota Continua a guardare")
                }
                .padding(.horizontal, horizontalInset)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Metrics.cardSpacing) {
                        ForEach(visibleItems) { item in
                            card(item)
                                // La card rimossa sparisce SUBITO (nessuna
                                // dissolvenza): con la transizione di
                                // default restava a metà per tutta
                                // l'animazione mentre la card seguente
                                // scorreva sopra di lei, mostrando residui
                                // del contenuto rimosso.
                                .transition(.identity)
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                }
            }
        }
        .padding(.top, visibleItems.isEmpty ? 0 : topPadding)
        .padding(.bottom, visibleItems.isEmpty ? 0 : bottomPadding)
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
        // Completa poster e categoria dei contenuti registrati senza (es.
        // guardati prima che questi campi esistessero, o registrati prima
        // che la scheda dettaglio avesse caricato l'immagine): la card
        // mostra subito l'immagine del catalogo invece del segnaposto.
        .task(id: metadataSignature) {
            resolveMissingMetadata()
        }
    }

    // MARK: - Card

    private func card(_ item: RecentlyWatchedItem) -> some View {
        Button {
            resume(item)
        } label: {
            VStack(alignment: .leading, spacing: Metrics.cardToTextSpacing) {
                artwork(item)

                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.displayTitle(for: item))
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 13.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, Metrics.textInset)
                .frame(width: Metrics.cardWidth, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                // Scorrimento rapido delle card seguenti (0,2 s) invece
                // della `.snappy` di default, percepita come lenta.
                withAnimation(.easeOut(duration: 0.2)) { recentlyWatched.remove(item) }
            } label: {
                Label("Rimuovi", systemImage: "trash")
            }

            Button(role: .destructive) {
                withAnimation(.snappy) {
                    if let kindFilter {
                        recentlyWatched.clear(kind: kindFilter)
                    } else {
                        recentlyWatched.clear()
                    }
                }
            } label: {
                Label("Svuota tutto", systemImage: "trash.slash")
            }
        }
        .accessibilityLabel(Self.displayTitle(for: item))
        .accessibilityHint("Riprendi la riproduzione")
    }

    /// Poster a tutta card. Le icone dei canali live (quadrate, con
    /// sfondo trasparente) restano intere (`.fit`); film e serie riempiono
    /// la card (`.fill`).
    private func artwork(_ item: RecentlyWatchedItem) -> some View {
        CachedPosterImage(
            urlString: item.imageURLString,
            baseHost: sourceManager.activeSource?.host ?? "",
            width: Metrics.cardWidth,
            height: Metrics.cardHeight,
            cornerRadius: Metrics.cornerRadius,
            placeholderSymbol: systemImage(item),
            contentMode: item.kind == XtreamStreamKind.live.rawValue ? .fit : .fill,
            maxPixel: Metrics.imageMaxPixel
        )
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.7)
        }
    }

    private func systemImage(_ item: RecentlyWatchedItem) -> String {
        switch item.kind {
        case XtreamStreamKind.live.rawValue: return "tv.fill"
        case XtreamStreamKind.movie.rawValue: return "film.fill"
        case XtreamStreamKind.series.rawValue: return "rectangle.stack.fill"
        default: return "play.rectangle.fill"
        }
    }

    // MARK: - Ripresa

    /// Le serie riaprono il player con il contesto dell'episodio (stagione
    /// e info serie caricate in background); tutto il resto (film, live)
    /// riapre direttamente lo stream salvato, come prima.
    private func resume(_ item: RecentlyWatchedItem) {
        if item.kind == XtreamStreamKind.series.rawValue,
           let credentials = sourceManager.activeSource?.xtreamCredentials {
            let parts = item.id.components(separatedBy: "|")
            let host = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            if parts.count >= 5,
               parts[0] == host,
               parts[1] == credentials.username,
               let seriesId = Int(parts[3]) {
                seriesResume = SeriesResumeRequest(
                    item: item,
                    credentials: credentials,
                    seriesId: seriesId,
                    seriesName: Self.displayTitle(for: item),
                    episodeStreamId: parts[4],
                    idPrefix: parts[0..<4].joined(separator: "|")
                )
                return
            }
        }

        resumeItem = item
    }

    // MARK: - Titolo e identità

    /// Per le serie il titolo registrato è "Serie · Episodio": la card
    /// mostra solo il nome della serie, come nel riferimento.
    private static func displayTitle(for item: RecentlyWatchedItem) -> String {
        guard item.kind == XtreamStreamKind.series.rawValue,
              let name = item.title.components(separatedBy: " · ").first?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return item.title
        }

        return name
    }

    /// `host|utente|series|idSerie` (l'id registrato ha in coda l'id
    /// dell'episodio): identifica la serie a prescindere dall'episodio.
    private static func seriesKey(for item: RecentlyWatchedItem) -> String? {
        let parts = item.id.components(separatedBy: "|")
        guard parts.count >= 4 else { return nil }
        return parts[0..<4].joined(separator: "|")
    }

    // MARK: - Metadati mancanti (poster/categoria) dal catalogo Xtream

    /// Cambia quando cambia l'elenco o il catalogo: rilancia la risoluzione.
    private var metadataSignature: String {
        [
            String(recentlyWatched.items.count),
            recentlyWatched.items.first?.id ?? "",
            String(xtreamCatalog.liveStreams.count),
            String(xtreamCatalog.vodStreams.count),
            String(xtreamCatalog.seriesItems.count),
            String(xtreamCatalog.lastRefreshDate?.timeIntervalSince1970 ?? 0)
        ].joined(separator: "|")
    }

    private func resolveMissingMetadata() {
        guard let credentials = sourceManager.activeSource?.xtreamCredentials else { return }

        let pending = recentlyWatched.items.filter { $0.imageURLString == nil || $0.subtitle == nil }
        guard !pending.isEmpty else { return }

        let host = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Dizionari costruiti solo se serve, una volta per passata.
        var liveByID: [Int: XtreamStream]?
        var vodByID: [Int: XtreamStream]?
        var seriesByID: [Int: XtreamSeriesItem]?

        func categoryNames(_ categories: [XtreamCategory]) -> [String: String] {
            Dictionary(categories.map { ($0.categoryId, $0.categoryName) }, uniquingKeysWith: { first, _ in first })
        }

        var liveNames: [String: String]?
        var vodNames: [String: String]?
        var seriesNames: [String: String]?

        for item in pending {
            let parts = item.id.components(separatedBy: "|")

            guard parts.count >= 4,
                  parts[0] == host,
                  parts[1] == credentials.username,
                  let streamID = Int(parts[3]) else {
                continue
            }

            var image: String?
            var subtitle: String?

            switch parts[2] {
            case XtreamStreamKind.live.rawValue:
                if liveByID == nil {
                    liveByID = Dictionary(xtreamCatalog.liveStreams.map { ($0.streamId, $0) }, uniquingKeysWith: { first, _ in first })
                    liveNames = categoryNames(xtreamCatalog.liveCategories)
                }
                if let stream = liveByID?[streamID] {
                    image = stream.streamIcon
                    subtitle = stream.categoryId.flatMap { liveNames?[$0] }
                }

            case XtreamStreamKind.movie.rawValue:
                if vodByID == nil {
                    vodByID = Dictionary(xtreamCatalog.vodStreams.map { ($0.streamId, $0) }, uniquingKeysWith: { first, _ in first })
                    vodNames = categoryNames(xtreamCatalog.vodCategories)
                }
                if let stream = vodByID?[streamID] {
                    image = stream.streamIcon
                    subtitle = stream.categoryId.flatMap { vodNames?[$0] }
                }

            case XtreamStreamKind.series.rawValue:
                if seriesByID == nil {
                    seriesByID = Dictionary(xtreamCatalog.seriesItems.map { ($0.seriesId, $0) }, uniquingKeysWith: { first, _ in first })
                    seriesNames = categoryNames(xtreamCatalog.seriesCategories)
                }
                if let series = seriesByID?[streamID] {
                    image = series.cover
                    subtitle = series.categoryId.flatMap { seriesNames?[$0] }
                }

            default:
                continue
            }

            recentlyWatched.updateMetadata(
                id: item.id,
                imageURLString: image.flatMap { $0.isEmpty ? nil : $0 },
                subtitle: subtitle.flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }
}


/// Capsula Liquid Glass neutra: stesso `.glass` della `GlassIconButton`
/// ("X" delle schede dettaglio) in forma di pillola. Il testo usa il colore
/// primario di sistema (leggibile anche con tema chiaro); su iOS < 26
/// ripiega su materiale sottile con filo di bordo, come il fallback della X.
struct ClearGlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .foregroundStyle(.primary)
        } else {
            content
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
                }
        }
    }
}


// MARK: - Ripresa di un episodio con precedente/successivo

/// Dati per riprendere un episodio da "Continua a guardare".
private struct SeriesResumeRequest: Identifiable {
    let id = UUID()
    let item: RecentlyWatchedItem
    let credentials: XtreamCredentials
    let seriesId: Int
    let seriesName: String
    let episodeStreamId: String
    /// `host|utente|series|idSerie`.
    let idPrefix: String

    func episodeID(_ streamId: Int) -> String {
        idPrefix + "|" + String(streamId)
    }

    /// Titolo dell'episodio dal titolo registrato "Serie · Episodio".
    var initialEpisodeTitle: String {
        let parts = item.title.components(separatedBy: " · ")
        return parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : item.title
    }
}

/// Player di ripresa per le serie: parte SUBITO dallo stream salvato (nessuna
/// attesa di rete) e, appena le info della serie sono in cache/caricate,
/// abilita gli stessi comandi di `SeriesEpisodesView`: tasti
/// precedente/successivo e "Prossimo Episodio" (tasto negli ultimi 60 s e
/// avanzamento automatico a fine episodio, se attivo in Impostazioni),
/// navigando gli episodi della stessa stagione.
private struct SeriesResumePlayer: View {
    let request: SeriesResumeRequest
    let record: (XtreamSeriesInfo.Episode, URL) -> Void

    @State private var info: XtreamSeriesInfo?
    @State private var season: Int?
    @State private var currentEpisode: XtreamSeriesInfo.Episode?
    @State private var playingURL: URL
    @State private var playingTitle: String

    init(request: SeriesResumeRequest, record: @escaping (XtreamSeriesInfo.Episode, URL) -> Void) {
        self.request = request
        self.record = record
        _playingURL = State(initialValue: request.item.streamURL)
        _playingTitle = State(initialValue: request.initialEpisodeTitle)
    }

    var body: some View {
        AdaptivePlayerView(
            url: playingURL,
            title: playingTitle,
            onPrevious: adjacentEpisode(offset: -1).map { target in
                { select(target) }
            },
            onNext: adjacentEpisode(offset: 1).map { target in
                { select(target) }
            }
        )
        .task {
            await loadSeriesInfo()
        }
        .task(id: currentEpisode?.id) {
            guard let episode = currentEpisode, let url = streamURL(for: episode) else { return }
            record(episode, url)
        }
    }

    /// Carica le info della serie (cache `CachedXtreamRepository`, spesso
    /// già calda) senza toccare lo stream in riproduzione: l'URL cambia
    /// solo quando l'utente passa a un altro episodio.
    private func loadSeriesInfo() async {
        guard let loaded = try? await CachedXtreamRepository(credentials: request.credentials)
            .seriesInfo(seriesId: request.seriesId),
              !Task.isCancelled else {
            return
        }

        for seasonNumber in loaded.sortedSeasonNumbers {
            if let episode = loaded.episodes(forSeason: seasonNumber)
                .first(where: { String($0.streamId) == request.episodeStreamId }) {
                info = loaded
                season = seasonNumber
                currentEpisode = episode
                return
            }
        }
    }

    private func streamURL(for episode: XtreamSeriesInfo.Episode) -> URL? {
        let ext = episode.containerExtension?.isEmpty == false ? episode.containerExtension! : "mp4"
        return XtreamAPIService(credentials: request.credentials)
            .episodeStreamURL(episodeId: episode.streamId, ext: ext)
    }

    private func adjacentEpisode(offset: Int) -> XtreamSeriesInfo.Episode? {
        guard let info, let season, let currentEpisode else { return nil }

        let episodes = info.episodes(forSeason: season)
        guard let index = episodes.firstIndex(where: { $0.id == currentEpisode.id }) else { return nil }

        let target = index + offset
        guard episodes.indices.contains(target) else { return nil }

        return episodes[target]
    }

    private func select(_ episode: XtreamSeriesInfo.Episode) {
        guard let url = streamURL(for: episode) else { return }

        playingURL = url
        playingTitle = episode.title
        currentEpisode = episode
    }
}
