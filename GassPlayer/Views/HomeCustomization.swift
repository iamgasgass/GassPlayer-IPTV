import SwiftUI
import UIKit

// MARK: - Sezioni della Home

/// Le sezioni della panoramica Home che l'utente può riordinare, nascondere
/// e riaggiungere da "Personalizza" (le stesse sette del foglio "Sezioni
/// home" di riferimento). Intestazione, scheda sorgente, Live TV, On demand e
/// Sorgenti restano blocchi fissi della Home, non personalizzabili.
enum HomeSectionID: String, CaseIterable, Codable, Identifiable {
    case continueWatching
    case guidaTV
    case favoriteChannels
    case favoriteSeries
    case favoriteMovies
    case trendingSeries
    case trendingMovies

    var id: String { rawValue }

    var title: String {
        switch self {
        case .continueWatching: return "Continua a guardare"
        case .guidaTV: return "Guida TV"
        case .favoriteChannels: return "Canali preferiti"
        case .favoriteSeries: return "Serie TV preferite"
        case .favoriteMovies: return "Film preferiti"
        case .trendingSeries: return "Serie di tendenza"
        case .trendingMovies: return "Film di tendenza"
        }
    }

    /// Solo "Continua a guardare" ha opzioni (pulsante a cursori).
    var hasOptions: Bool { self == .continueWatching }
}

/// Ordine e visibilità delle sezioni della Home, salvati su disco. Le
/// modifiche si applicano all'istante alla Home (che osserva lo store) e
/// sopravvivono al riavvio. Le sezioni introdotte in versioni future dell'app
/// vengono aggiunte in coda all'elenco senza perdere la scelta dell'utente.
@MainActor
final class HomeLayoutStore: ObservableObject {
    /// Sezioni visibili, nell'ordine mostrato in Home.
    @Published private(set) var order: [HomeSectionID]
    /// Filtro di "Continua a guardare": `nil` = tutti i tipi, altrimenti
    /// `XtreamStreamKind.rawValue`.
    @Published private(set) var continueKind: String?

    private struct Stored: Codable {
        var order: [String]
        var hidden: [String]
        var continueKind: String?
    }

    private let storageKey = "gassplayer.home.layout"

    private static let defaultOrder: [HomeSectionID] = [
        .continueWatching, .guidaTV, .favoriteChannels, .favoriteSeries,
        .favoriteMovies, .trendingSeries, .trendingMovies
    ]

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            var visible = stored.order.compactMap(HomeSectionID.init(rawValue:))
            let hidden = Set(stored.hidden.compactMap(HomeSectionID.init(rawValue:)))

            // Sezioni nate dopo il salvataggio: in coda, visibili.
            for section in Self.defaultOrder where !visible.contains(section) && !hidden.contains(section) {
                visible.append(section)
            }

            order = visible
            continueKind = stored.continueKind
        } else {
            order = Self.defaultOrder
            continueKind = nil
        }
    }

    var hiddenSections: [HomeSectionID] {
        HomeSectionID.allCases.filter { !order.contains($0) }
    }

    func remove(_ section: HomeSectionID) {
        order.removeAll { $0 == section }
        persist()
    }

    func add(_ section: HomeSectionID) {
        guard !order.contains(section) else { return }
        order.append(section)
        persist()
    }

    /// Sposta una sezione alla posizione `index` (0-based) dell'elenco visibile.
    func move(_ section: HomeSectionID, to index: Int) {
        guard let current = order.firstIndex(of: section) else { return }

        let target = max(0, min(index, order.count - 1))
        guard target != current else { return }

        order.remove(at: current)
        order.insert(section, at: target)
        persist()
    }

    func setContinueKind(_ kind: String?) {
        guard continueKind != kind else { return }
        continueKind = kind
        persist()
    }

    private func persist() {
        let stored = Stored(
            order: order.map(\.rawValue),
            hidden: hiddenSections.map(\.rawValue),
            continueKind: continueKind
        )

        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

// MARK: - Pulsante "Personalizza" (Liquid Glass)

/// Capsula Liquid Glass neutra, stesso `.glass` della `GlassIconButton`
/// ("X" delle schede dettaglio VOD/Serie TV) in forma di pillola; su iOS < 26
/// ripiega su materiale sottile con filo di bordo, come il fallback della X.
struct HomeGlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .foregroundStyle(.primary)
        } else {
            content
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
                }
        }
    }
}

/// Pulsante "Personalizza" in fondo alla Home: pillola 44 pt con icona a
/// griglia di punti e testo, centrata.
struct HomePersonalizeButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "circle.grid.3x3.fill")
                    .font(.system(size: 16, weight: .semibold))

                Text("Personalizza")
                    .font(.system(size: 17, weight: .medium))
            }
            .padding(.horizontal, 17)
            .frame(height: 44)
            .contentShape(Capsule())
        }
        .modifier(HomeGlassCapsule())
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Personalizza")
        .accessibilityHint("Riordina, nascondi o aggiungi le sezioni della Home")
    }
}

// MARK: - Foglio "Sezioni home"

/// Foglio di personalizzazione: ogni sezione è una riga con maniglia di
/// trascinamento (riordino dal vivo, la Home dietro si aggiorna subito),
/// cestino (nasconde la sezione) e, dove previsto, pulsante a cursori con le
/// opzioni; il "+" in fondo riaggiunge le sezioni nascoste. Pulsanti e "+" in
/// Liquid Glass come la "X" delle schede dettaglio.
struct HomeCustomizeSheet: View {
    @ObservedObject var layout: HomeLayoutStore

    private enum Metrics {
        static let rowHeight: CGFloat = 55
        static let rowSpacing: CGFloat = 9
        static let horizontalInset: CGFloat = 16
        static var pitch: CGFloat { rowHeight + rowSpacing }
    }

    @State private var draggingID: HomeSectionID?
    @State private var dragOffset: CGFloat = 0
    @State private var dragStartIndex = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("Sezioni home")
                    .font(.system(size: 17, weight: .semibold))
                    .padding(.top, 26)
                    .padding(.bottom, 37)

                VStack(spacing: Metrics.rowSpacing) {
                    ForEach(layout.order) { section in
                        row(section)
                    }
                }
                .padding(.horizontal, Metrics.horizontalInset)

                addButton
                    .padding(.top, 17)
                    .padding(.bottom, 32)
            }
        }
        .scrollIndicators(.hidden)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }

    // MARK: Riga

    private func row(_ section: HomeSectionID) -> some View {
        let isDragging = draggingID == section

        return HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: Metrics.rowHeight)
                .contentShape(Rectangle())
                .gesture(dragGesture(for: section))
                .accessibilityLabel("Sposta \(section.title)")

            VStack(alignment: .leading, spacing: 0) {
                Text(section.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let subtitle = subtitle(for: section) {
                    Text(subtitle)
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if section.hasOptions {
                optionsMenu
            }

            GlassIconButton(
                systemImage: "trash",
                size: 40,
                accessibilityLabel: "Nascondi \(section.title)"
            ) {
                withAnimation(.snappy(duration: 0.25)) {
                    layout.remove(section)
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(height: Metrics.rowHeight)
        .background(Color.primary.opacity(0.09), in: Capsule())
        .scaleEffect(isDragging ? 1.02 : 1)
        .shadow(color: .black.opacity(isDragging ? 0.28 : 0), radius: 10, y: 4)
        .offset(y: isDragging ? dragOffset : 0)
        .zIndex(isDragging ? 1 : 0)
        // La riga trascinata segue il dito senza animazioni; le altre si
        // spostano con l'animazione esplicita di `move`.
        .transaction(value: dragOffset) { $0.animation = nil }
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    private func subtitle(for section: HomeSectionID) -> String? {
        guard section == .continueWatching, let kind = layout.continueKind else { return nil }

        switch kind {
        case XtreamStreamKind.movie.rawValue: return "Solo film"
        case XtreamStreamKind.series.rawValue: return "Solo serie TV"
        case XtreamStreamKind.live.rawValue: return "Solo Live TV"
        default: return nil
        }
    }

    // MARK: Opzioni "Continua a guardare"

    private var optionsMenu: some View {
        Menu {
            Picker(
                "Mostra",
                selection: Binding(
                    get: { layout.continueKind ?? "" },
                    set: { layout.setContinueKind($0.isEmpty ? nil : $0) }
                )
            ) {
                Text("Tutti").tag("")
                Text("Film").tag(XtreamStreamKind.movie.rawValue)
                Text("Serie TV").tag(XtreamStreamKind.series.rawValue)
                Text("Live TV").tag(XtreamStreamKind.live.rawValue)
            }
        } label: {
            GlassIconGlyph(systemImage: "slider.horizontal.3", size: 40)
        }
        .modifier(NativeOrLegacyGlassCircle(tint: nil, isInSystemToolbar: false))
        .accessibilityLabel("Opzioni di Continua a guardare")
    }

    // MARK: Aggiungi

    private var addButton: some View {
        let hidden = layout.hiddenSections

        return Menu {
            ForEach(hidden) { section in
                Button(section.title) {
                    withAnimation(.snappy(duration: 0.25)) {
                        layout.add(section)
                    }
                }
            }
        } label: {
            GlassIconGlyph(systemImage: "plus", size: 44)
        }
        .modifier(NativeOrLegacyGlassCircle(tint: nil, isInSystemToolbar: false))
        .disabled(hidden.isEmpty)
        .opacity(hidden.isEmpty ? 0.4 : 1)
        .accessibilityLabel("Aggiungi sezione")
    }

    // MARK: Trascinamento

    /// Riordino dal vivo: le righe hanno passo fisso, quindi la nuova
    /// posizione si ricava direttamente dalla traslazione verticale (in
    /// coordinate globali, stabili anche se la riga si sposta).
    private func dragGesture(for section: HomeSectionID) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if draggingID == nil {
                    draggingID = section
                    dragStartIndex = layout.order.firstIndex(of: section) ?? 0
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }

                guard draggingID == section,
                      let current = layout.order.firstIndex(of: section) else { return }

                let proposed = max(
                    0,
                    min(
                        layout.order.count - 1,
                        dragStartIndex + Int((value.translation.height / Metrics.pitch).rounded())
                    )
                )

                if proposed != current {
                    UISelectionFeedbackGenerator().selectionChanged()

                    withAnimation(.snappy(duration: 0.2)) {
                        layout.move(section, to: proposed)
                    }
                }

                dragOffset = value.translation.height - CGFloat(proposed - dragStartIndex) * Metrics.pitch
            }
            .onEnded { _ in
                withAnimation(.snappy(duration: 0.22)) {
                    dragOffset = 0
                    draggingID = nil
                }
            }
    }
}

// MARK: - Sezioni "Serie di tendenza" / "Film di tendenza"

/// Ultimo elenco di tendenza ricevuto, per mostrarlo subito al rientro in
/// Home senza attendere la rete. `NSCache` è thread-safe: lettura sincrona
/// dall'`init` della vista, senza vincoli di isolamento.
private enum HomeTrendingMemory {
    private final class Box {
        let items: [TMDBTrendingItem]
        init(_ items: [TMDBTrendingItem]) { self.items = items }
    }

    private static let cache = NSCache<NSString, Box>()

    static func items(for key: String) -> [TMDBTrendingItem] {
        cache.object(forKey: key as NSString)?.items ?? []
    }

    static func store(_ items: [TMDBTrendingItem], for key: String) {
        cache.setObject(Box(items), forKey: key as NSString)
    }
}

/// Riga orizzontale dei 20 titoli più in tendenza della settimana (TMDB),
/// con la stessa impostazione di "Continua a guardare": titolo sezione
/// 18,5 pt, card 16:9 a tutta immagine con filo di bordo e, sotto, numero di
/// classifica grande + titolo e genere.
struct HomeTrendingRail: View {
    let title: String
    let isSeries: Bool
    var horizontalInset: CGFloat = 16
    let onSelect: (TMDBTrendingItem) -> Void

    @AppStorage(TMDBService.apiKeyDefaultsKey) private var apiKey = ""

    @State private var items: [TMDBTrendingItem]
    @State private var didFail = false

    private enum Metrics {
        static let cardWidth: CGFloat = 200
        static let cardHeight: CGFloat = 112.5
        static let cornerRadius: CGFloat = 11
        static let cardSpacing: CGFloat = 11
        static let headerToCardSpacing: CGFloat = 10
        static let rankRowHeight: CGFloat = 44
        static let rankToTextSpacing: CGFloat = 9
        static let imageMaxPixel: CGFloat = 800
    }

    init(title: String, isSeries: Bool, horizontalInset: CGFloat = 16, onSelect: @escaping (TMDBTrendingItem) -> Void) {
        self.title = title
        self.isSeries = isSeries
        self.horizontalInset = horizontalInset
        self.onSelect = onSelect
        _items = State(initialValue: HomeTrendingMemory.items(for: isSeries ? "tv" : "movie"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.headerToCardSpacing) {
            Text(title)
                .font(.system(size: 18.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, horizontalInset)

            if apiKey.isEmpty {
                hint("Aggiungi la chiave API TMDB nelle Impostazioni per vedere i titoli di tendenza.")
            } else if !items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Metrics.cardSpacing) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            card(item, rank: index + 1)
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                }
            } else if didFail {
                hint("Impossibile caricare i titoli di tendenza.")
            } else {
                loadingPlaceholder
            }
        }
        .task(id: apiKey) {
            await load()
        }
    }

    // MARK: Card

    private func card(_ item: TMDBTrendingItem, rank: Int) -> some View {
        Button {
            onSelect(item)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                CachedPosterImage(
                    urlString: item.backdropURL?.absoluteString,
                    baseHost: "",
                    width: Metrics.cardWidth,
                    height: Metrics.cardHeight,
                    cornerRadius: Metrics.cornerRadius,
                    placeholderSymbol: isSeries ? "rectangle.stack.fill" : "film.fill",
                    contentMode: .fill,
                    maxPixel: Metrics.imageMaxPixel
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.7)
                }

                HStack(alignment: .center, spacing: Metrics.rankToTextSpacing) {
                    Text("\(rank)")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(height: Metrics.rankRowHeight)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if let genre = item.genre {
                            Text(genre)
                                .font(.system(size: 13.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .frame(width: Metrics.cardWidth, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(rank). \(item.title)")
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, horizontalInset)
    }

    private var loadingPlaceholder: some View {
        RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
            .fill(Color(uiColor: .secondarySystemFill))
            .frame(width: Metrics.cardWidth, height: Metrics.cardHeight)
            .padding(.horizontal, horizontalInset)
            .padding(.bottom, Metrics.rankRowHeight)
    }

    // MARK: Caricamento

    private func load() async {
        guard !apiKey.isEmpty else { return }

        do {
            let loaded = try await TMDBService.shared.trending(isSeries: isSeries, limit: 20)
            guard !Task.isCancelled else { return }

            HomeTrendingMemory.store(loaded, for: isSeries ? "tv" : "movie")
            items = loaded
            didFail = false
        } catch {
            guard !Task.isCancelled else { return }
            if items.isEmpty { didFail = true }
        }
    }
}

// MARK: - Corrispondenza titolo di tendenza → catalogo Xtream

/// Collega un titolo di tendenza TMDB al contenuto equivalente del catalogo
/// della sorgente attiva (stesso titolo, ignorando maiuscole, accenti,
/// punteggiatura, parentesi e anno finale). `nil` se la sorgente non lo ha.
enum HomeTrendingMatcher {
    static func normalized(_ text: String) -> String {
        var working = text
        for pattern in [#"\(.*?\)"#, #"\[.*?\]"#] {
            working = working.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        let folded = working.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        var result = ""
        var lastWasSpace = true

        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                result.append(" ")
                lastWasSpace = true
            }
        }

        result = result.trimmingCharacters(in: .whitespaces)

        if let range = result.range(of: #"\s+(?:19|20)\d{2}$"#, options: .regularExpression),
           result[..<range.lowerBound].count >= 2 {
            result.removeSubrange(range)
        }

        return result
    }

    static func keys(for item: TMDBTrendingItem) -> Set<String> {
        Set([item.title, item.originalTitle].compactMap { $0 }.map(normalized).filter { !$0.isEmpty })
    }

    static func movie(for item: TMDBTrendingItem, in streams: [XtreamStream]) -> XtreamStream? {
        let wanted = keys(for: item)
        return streams.first { wanted.contains(normalized($0.name)) }
    }

    static func series(for item: TMDBTrendingItem, in list: [XtreamSeriesItem]) -> XtreamSeriesItem? {
        let wanted = keys(for: item)
        return list.first { wanted.contains(normalized($0.name)) }
    }
}


// MARK: - Sezioni "Canali / Serie TV / Film preferiti"

/// Riga orizzontale dei preferiti di un tipo, con poster/icona presi dal
/// catalogo Xtream della sorgente attiva. La sezione non compare se non ci
/// sono preferiti (come nel riferimento, dove le sezioni vuote non si vedono).
struct HomeFavoritesRail: View {
    let title: String
    let kind: XtreamStreamKind
    var horizontalInset: CGFloat = 16
    let credentials: XtreamCredentials
    let onSelectLive: (XtreamStream) -> Void
    let onSelectMovie: (XtreamStream) -> Void
    let onSelectSeries: (XtreamSeriesItem) -> Void

    @EnvironmentObject private var contentManagement: ContentManagementService
    @EnvironmentObject private var xtreamCatalog: XtreamCatalogStore

    private enum Metrics {
        static let cardWidth: CGFloat = 120
        static let posterHeight: CGFloat = 180
        static let channelHeight: CGFloat = 120
        static let cornerRadius: CGFloat = 12
        static let cardSpacing: CGFloat = 11
        static let headerToCardSpacing: CGFloat = 10
        static let cardToTextSpacing: CGFloat = 5
    }

    private enum Entry: Identifiable {
        case stream(XtreamStream)
        case series(XtreamSeriesItem)

        var id: String {
            switch self {
            case .stream(let stream): return "s\(stream.streamId)"
            case .series(let series): return "r\(series.seriesId)"
            }
        }
    }

    /// Preferiti di questo tipo e di questa sorgente, dal più recente,
    /// risolti sul catalogo (quelli non più presenti nel catalogo non si
    /// mostrano).
    private var entries: [Entry] {
        let host = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let wanted = contentManagement.favorites
            .filter { $0.kind == kind.rawValue }
            .sorted { $0.addedAt > $1.addedAt }

        var ids: [Int] = []
        for favorite in wanted {
            let parts = favorite.id.components(separatedBy: "|")
            guard parts.count >= 4, parts[0] == host, parts[1] == credentials.username,
                  let id = Int(parts[3]) else { continue }
            ids.append(id)
        }

        guard !ids.isEmpty else { return [] }

        switch kind {
        case .series:
            let byID = Dictionary(xtreamCatalog.seriesItems.map { ($0.seriesId, $0) }, uniquingKeysWith: { first, _ in first })
            return ids.compactMap { byID[$0] }.map(Entry.series)

        case .movie:
            let byID = Dictionary(xtreamCatalog.vodStreams.map { ($0.streamId, $0) }, uniquingKeysWith: { first, _ in first })
            return ids.compactMap { byID[$0] }.map(Entry.stream)

        case .live:
            let byID = Dictionary(xtreamCatalog.liveStreams.map { ($0.streamId, $0) }, uniquingKeysWith: { first, _ in first })
            return ids.compactMap { byID[$0] }.map(Entry.stream)
        }
    }

    var body: some View {
        let visible = entries

        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.headerToCardSpacing) {
                Text(title)
                    .font(.system(size: 18.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, horizontalInset)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Metrics.cardSpacing) {
                        ForEach(visible) { entry in
                            card(entry)
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                }
            }
        }
    }

    private func card(_ entry: Entry) -> some View {
        let name: String
        let image: String?
        let height: CGFloat
        let symbol: String
        let mode: ContentMode

        switch entry {
        case .stream(let stream):
            name = stream.name
            image = stream.streamIcon
            height = kind == .live ? Metrics.channelHeight : Metrics.posterHeight
            symbol = kind == .live ? "tv" : "film"
            mode = kind == .live ? .fit : .fill

        case .series(let series):
            name = series.name
            image = series.cover
            height = Metrics.posterHeight
            symbol = "rectangle.stack.fill"
            mode = .fill
        }

        return Button {
            switch entry {
            case .stream(let stream):
                if kind == .live { onSelectLive(stream) } else { onSelectMovie(stream) }
            case .series(let series):
                onSelectSeries(series)
            }
        } label: {
            VStack(alignment: .leading, spacing: Metrics.cardToTextSpacing) {
                CachedPosterImage(
                    urlString: image,
                    baseHost: credentials.host,
                    width: Metrics.cardWidth,
                    height: height,
                    cornerRadius: Metrics.cornerRadius,
                    placeholderSymbol: symbol,
                    contentMode: mode
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.7)
                }

                Text(name)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(width: Metrics.cardWidth, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }
}
