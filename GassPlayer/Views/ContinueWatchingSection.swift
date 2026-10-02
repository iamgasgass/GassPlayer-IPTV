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
                Text("Continua a guardare")
                    .font(.system(size: 18.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, horizontalInset)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Metrics.cardSpacing) {
                        ForEach(visibleItems) { item in
                            card(item)
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
            resumeItem = item
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
                withAnimation(.snappy) { recentlyWatched.remove(item) }
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
