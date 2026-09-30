import SwiftUI

// MARK: - Metriche condivise

/// Dimensioni delle locandine "Comoda" di `ChannelGridView`
/// (`GridMetrics.comfortable…`, che legge da qui): una sola fonte, così le
/// righe di locandine delle schede dettaglio restano IDENTICHE alla
/// griglia anche se in futuro cambiano.
enum PosterRowMetrics {
    static let artworkWidth: CGFloat = 100
    static let moviePosterHeight: CGFloat = 150
    static let seriesPosterHeight: CGFloat = 140

    /// Spaziatura orizzontale fra locandine (= `comfortableColumnSpacing`).
    static let itemSpacing: CGFloat = 14
    /// Spazio locandina → titolo (= `tileSpacing` in modalità comoda).
    static let titleSpacing: CGFloat = 6

    /// Locandine mostrate nella riga / nel "vedi tutto".
    static let rowItemLimit = 20
    static let gridItemLimit = 200

    static func posterHeight(isSeries: Bool) -> CGFloat {
        isSeries ? seriesPosterHeight : moviePosterHeight
    }
}

// MARK: - Continua a guardare (identico a HomeView)

/// Sezione "Continua a guardare" condivisa da `HomeView` (tutti i tipi) e
/// dalle schede dettaglio (solo il tipo della propria sezione: film in
/// `MovieDetailView`, serie in `SeriesEpisodesView`). Card, misure e
/// comportamento sono quelli storici di `HomeView`; ora la card mostra
/// l'immagine della scheda dettaglio invece della sola icona (l'icona resta
/// come segnaposto mentre carica o se l'immagine manca).
struct ContinueWatchingSection: View {
    /// `nil` = tutti i tipi; altrimenti solo `RecentlyWatchedItem.kind == kindFilter`.
    var kindFilter: String? = nil
    /// Margine laterale di header e riga (0 in `HomeView`, che ha già il
    /// proprio padding di contenitore).
    var horizontalInset: CGFloat = 0
    var topPadding: CGFloat = 0

    @EnvironmentObject private var recentlyWatched: RecentlyWatchedStore
    @State private var resumeItem: RecentlyWatchedItem?

    private static let cardWidth: CGFloat = 168
    private static let cardImageHeight: CGFloat = 94

    private var items: [RecentlyWatchedItem] {
        guard let kindFilter else { return recentlyWatched.items }
        return recentlyWatched.items.filter { $0.kind == kindFilter }
    }

    var body: some View {
        let visibleItems = items

        VStack(alignment: .leading, spacing: 12) {
            if !visibleItems.isEmpty {
                HStack {
                    Text("Continua a guardare")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Button("Svuota") {
                        withAnimation(.snappy) {
                            if let kindFilter {
                                recentlyWatched.clear(kind: kindFilter)
                            } else {
                                recentlyWatched.clear()
                            }
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, horizontalInset)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(visibleItems) { item in
                            card(item)
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.top, visibleItems.isEmpty ? 0 : topPadding)
        .fullScreenCover(item: $resumeItem) { item in
            AdaptivePlayerView(url: item.streamURL, title: item.title)
        }
    }

    private func card(_ item: RecentlyWatchedItem) -> some View {
        Button {
            resumeItem = item
        } label: {
            GlassCard(cornerRadius: 16, padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack(alignment: .bottomTrailing) {
                        artwork(item)

                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, tint(item))
                            .padding(8)
                    }

                    Text(item.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(width: Self.cardWidth, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                withAnimation(.snappy) { recentlyWatched.remove(item) }
            } label: {
                Label("Rimuovi", systemImage: "trash")
            }
        }
        .accessibilityLabel(item.title)
        .accessibilityHint("Riprendi la riproduzione")
    }

    /// Immagine della scheda dettaglio, ritagliata 168×94 (angoli 11) come
    /// il vecchio riquadro a icona, che resta come segnaposto.
    private func artwork(_ item: RecentlyWatchedItem) -> some View {
        ZStack {
            placeholder(item)

            if let urlString = item.imageURLString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                            .transaction { $0.animation = nil }
                    }
                }
            }
        }
        .frame(width: Self.cardWidth, height: Self.cardImageHeight)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func placeholder(_ item: RecentlyWatchedItem) -> some View {
        ZStack {
            Rectangle().fill(tint(item).opacity(0.16))

            Image(systemName: systemImage(item))
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint(item))
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

    private func tint(_ item: RecentlyWatchedItem) -> Color {
        switch item.kind {
        case XtreamStreamKind.live.rawValue: return .red
        case XtreamStreamKind.movie.rawValue: return .purple
        case XtreamStreamKind.series.rawValue: return .blue
        default: return .accentColor
        }
    }
}

// MARK: - Aggiunto di recente (locandine "Comoda")

private struct RelatedPoster: Identifiable, Hashable {
    let id: Int
    let title: String
    let iconURLString: String?
    let stream: XtreamStream?
    let series: XtreamSeriesItem?
}

/// Ordina per id decrescente (in Xtream gli id crescono con l'aggiunta al
/// catalogo, quindi i più alti sono i più recenti), toglie il titolo
/// corrente e i doppioni con lo stesso nome. Funzioni libere (non legate a
/// una `View`) così girano fuori dal main actor.
private func recentPosters(fromMovies streams: [XtreamStream], excluding excludedId: Int) -> [RelatedPoster] {
    var seen = Set<String>()
    var result: [RelatedPoster] = []

    for stream in streams.sorted(by: { $0.streamId > $1.streamId }) where stream.streamId != excludedId {
        guard seen.insert(stream.name.lowercased()).inserted else { continue }
        result.append(RelatedPoster(id: stream.streamId, title: stream.name, iconURLString: stream.streamIcon, stream: stream, series: nil))
        if result.count >= PosterRowMetrics.gridItemLimit { break }
    }
    return result
}

private func recentPosters(fromSeries items: [XtreamSeriesItem], excluding excludedId: Int) -> [RelatedPoster] {
    var seen = Set<String>()
    var result: [RelatedPoster] = []

    for item in items.sorted(by: { $0.seriesId > $1.seriesId }) where item.seriesId != excludedId {
        guard seen.insert(item.name.lowercased()).inserted else { continue }
        result.append(RelatedPoster(id: item.seriesId, title: item.name, iconURLString: item.cover, stream: nil, series: item))
        if result.count >= PosterRowMetrics.gridItemLimit { break }
    }
    return result
}

/// Locandina + titolo, con le stesse misure della griglia in modalità
/// "Comoda" e la nota di voto in alto a destra come nel riferimento.
private struct RelatedPosterCard: View {
    let poster: RelatedPoster
    let isSeries: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: PosterRowMetrics.titleSpacing) {
                TMDBEnrichedPoster(
                    title: poster.title,
                    isSeries: isSeries,
                    fallbackIconURL: poster.iconURLString,
                    width: PosterRowMetrics.artworkWidth,
                    height: PosterRowMetrics.posterHeight(isSeries: isSeries),
                    badgeStyle: .topTrailing
                )
                .transaction { $0.animation = nil }

                Text(poster.title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: PosterRowMetrics.artworkWidth, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(poster.title)
    }
}

/// Apre la scheda dettaglio del film/serie toccato sopra quella corrente.
private struct RelatedPosterDetailCovers: ViewModifier {
    let credentials: XtreamCredentials
    @Binding var movie: XtreamStream?
    @Binding var series: XtreamSeriesItem?

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $movie) { stream in
                MovieDetailView(credentials: credentials, stream: stream)
            }
            .fullScreenCover(item: $series) { item in
                SeriesEpisodesView(
                    credentials: credentials,
                    seriesId: item.seriesId,
                    seriesName: item.name,
                    fallbackCoverURLString: item.cover
                )
            }
    }
}

/// Riga "Aggiunto di recente" per le schede dettaglio: solo film in
/// `MovieDetailView`, solo serie in `SeriesEpisodesView` (dalla stessa
/// sorgente della scheda aperta, con la cache di `CachedXtreamRepository`).
struct MediaRelatedPostersSection: View {
    let credentials: XtreamCredentials
    /// `.movie` oppure `.series`.
    let kind: XtreamStreamKind
    /// Il titolo della scheda aperta, da non riproporre.
    let excludingId: Int
    var horizontalInset: CGFloat = 20
    var topPadding: CGFloat = 24

    @State private var posters: [RelatedPoster] = []
    @State private var showAll = false
    @State private var selectedMovie: XtreamStream?
    @State private var selectedSeries: XtreamSeriesItem?

    private var isSeries: Bool { kind == .series }

    private var taskID: String {
        [credentials.host.lowercased(), credentials.username, kind.rawValue, String(excludingId)].joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Ancora di altezza zero che avvia il caricamento anche quando la
            // sezione è ancora vuota (`.task` su una vista vuota non parte).
            Color.clear
                .frame(height: 0)
                .task(id: taskID) { await load() }

            if !posters.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Aggiunto di recente")
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Button("vedi tutto") { showAll = true }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, horizontalInset)

                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: PosterRowMetrics.itemSpacing) {
                            ForEach(posters.prefix(PosterRowMetrics.rowItemLimit)) { poster in
                                RelatedPosterCard(poster: poster, isSeries: isSeries) {
                                    open(poster)
                                }
                            }
                        }
                        .padding(.horizontal, horizontalInset)
                    }
                }
                .padding(.top, topPadding)
            }
        }
        .modifier(RelatedPosterDetailCovers(credentials: credentials, movie: $selectedMovie, series: $selectedSeries))
        .sheet(isPresented: $showAll) {
            RelatedPostersGridSheet(credentials: credentials, posters: posters, isSeries: isSeries)
        }
    }

    private func open(_ poster: RelatedPoster) {
        if let stream = poster.stream {
            selectedMovie = stream
        } else if let series = poster.series {
            selectedSeries = series
        }
    }

    private func load() async {
        let repository = CachedXtreamRepository(credentials: credentials)
        let excluded = excludingId
        let loaded: [RelatedPoster]

        if isSeries {
            guard let list = try? await repository.seriesList() else { return }
            loaded = await Task.detached(priority: .userInitiated) {
                recentPosters(fromSeries: list, excluding: excluded)
            }.value
        } else {
            guard let list = try? await repository.allStreams(kind: .movie) else { return }
            loaded = await Task.detached(priority: .userInitiated) {
                recentPosters(fromMovies: list, excluding: excluded)
            }.value
        }

        guard !Task.isCancelled else { return }
        posters = loaded
    }
}

/// "vedi tutto": griglia delle stesse locandine, con le misure "Comoda"
/// di `ChannelGridView` (colonne adattive 110–140, spaziatura 14/16).
private struct RelatedPostersGridSheet: View {
    let credentials: XtreamCredentials
    let posters: [RelatedPoster]
    let isSeries: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var selectedMovie: XtreamStream?
    @State private var selectedSeries: XtreamSeriesItem?

    private let columns = [
        GridItem(.adaptive(minimum: 110, maximum: 140), spacing: PosterRowMetrics.itemSpacing)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(posters) { poster in
                        RelatedPosterCard(poster: poster, isSeries: isSeries) {
                            if let stream = poster.stream {
                                selectedMovie = stream
                            } else if let series = poster.series {
                                selectedSeries = series
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom)
            }
            .navigationTitle("Aggiunto di recente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Chiudi") { dismiss() }
                }
            }
        }
        .modifier(RelatedPosterDetailCovers(credentials: credentials, movie: $selectedMovie, series: $selectedSeries))
    }
}
