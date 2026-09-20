import SwiftUI

/// Stile dell'aspetto dell'interfaccia EPG selezionabile dall'utente
enum EPGLayoutDensity: String, CaseIterable, Identifiable {
    case compact = "compatta"
    case comfortable = "comoda"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return "Compatta"
        case .comfortable: return "Comoda"
        }
    }

    var icon: String {
        switch self {
        case .compact: return "rectangle.grid.1x2"
        case .comfortable: return "rectangle.grid.2x2"
        }
    }
}

enum EPGTileAppearance: String, CaseIterable, Identifiable {
    case grids = "griglie"
    case cards = "schede"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grids: return "Griglie"
        case .cards: return "Schede"
        }
    }

    var icon: String {
        switch self {
        case .grids: return "square.grid.3x3"
        case .cards: return "rectangle.on.rectangle"
        }
    }
}

/// EPG touch-first ultra-ottimizzata con riproduzione nativa immediata a latenza zero:
/// - Avvio streaming istantaneo su banner canale: elimina ogni ritardo, dispatch o transizione modale ridondante.
/// - Il tocco sul banner canale attiva direttamente `livePlayback` (`AdaptivePlayerView`) a latenza zero, esattamente come in EPG da Home.
/// - Supporto per entrambe le densità di layout: "Compatta" (rowHeight 66, banner 80x58) e "Comoda" (rowHeight 96, banner 86x76).
/// - Colori pastello adattivi, avanzamento live coordinato e voce di menu dedicata "Aspetto EPG".
///
/// AGGIORNAMENTO 2026-09-20 (replica pixel-perfect del riferimento video):
/// - Il nome canale viene ora diviso in "nome base" + badge qualità finale (FHD/HD/SD/4K).
/// - Il banner canale mostra ora anche un'icona di catch-up ("clock.arrow.circlepath").
///
/// FIX 2026-09-20 (regressione "Dati non disponibili") — trigger reattivi debounced,
/// batch di fetch mai scartati a metà, cache/stato invalidati per giorno selezionato.
///
/// FIX 2026-09-20 (bis) — "cannot find 'EPGMemoryCache' in scope": un solo file
/// `EPGGridView.swift` nel target, con tutti i tipi di supporto definiti qui sotto.
///
/// FIX 2026-09-20 (ter) — "cannot convert value of type 'Int' to expected argument
/// type 'CGFloat'": `contentLeadingInset` ora è tipizzata esplicitamente `CGFloat`.
///
/// AGGIORNAMENTO 2026-09-21 (quater) — Aspetto "Schede": estensione tile↔banner ricalcolata
/// dopo analisi completa di `epgSurface`/`fixedDayAndChannelColumn`/`channelBanner`/`programBlock`:
/// 1) L'estensione della tile verso il banner NON deve più avere un proprio radius sul bordo
///    sinistro: deve essere un rettangolo PIENO e SQUADRATO che attraversa completamente l'area
///    dietro il banner, fino al punto esatto in cui inizia il radius del banner canale
///    (x = bordo destro banner − `bannerCornerRadius`). Il radius visibile resta un unico arco:
///    quello del banner stesso; la tile si limita a riempire pienamente lo spazio dietro di esso
///    (prima la tile aveva un proprio arco speculare che "ritagliava" quello stesso spazio,
///    lasciando un varco/gap visibile — bug ora corretto).
/// 2) L'estensione è ora calcolata IN UN UNICO PASSAGGIO, dentro lo stesso `GeometryReader` che
///    legge la posizione reale della tile (niente più maschera/`mask` applicata a posteriori,
///    fonte dei precedenti artefatti visivi intermittenti): l'estensione è attiva SOLO quando la
///    tile è effettivamente agganciata al banner (`tileMinX < bannerColumnWidth`) e si interrompe
///    ESATTAMENTE e istantaneamente a quel confine (`tileMinX >= bannerColumnWidth` ⇒ estensione
///    0, nessun residuo). Quando invece la tile è agganciata, l'estensione non supera comunque mai
///    il bordo sinistro dello schermo (clamp a `tileMinX`), quindi non può mai comparire a sinistra
///    del banner canale, in nessuna condizione di scroll/overscroll.
/// Parametri di tempo e numero di caricamenti concorrenti INVARIATI rispetto alla versione precedente.
struct EPGGridView: View {
    let credentials: XtreamCredentials
    let kind: XtreamStreamKind
    var onPlayLive: ((XtreamStream) -> Void)? = nil

    @EnvironmentObject private var xtreamCatalog: XtreamCatalogStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var favorites: EPGFavoritesStore

    @AppStorage("epg_layout_density") private var layoutDensity: EPGLayoutDensity = .compact
    @AppStorage("epg_tile_appearance") private var tileAppearance: EPGTileAppearance = .grids

    @State private var programsByStream: [Int: [EPGProgram]] = [:]
    @State private var failedStreamIDs = Set<Int>()
    @State private var loadingStreamIDs = Set<Int>()
    @State private var showLoadingIndicator = false
    @State private var loadingIndicatorTask: Task<Void, Never>?
    @State private var now = Date()
    @State private var selectedDayOffset = 0
    @State private var searchQuery = ""
    @State private var showFavoritesOnly = false
    @State private var selectedGroupID: String?
    @State private var selectedProgram: SelectedProgram?
    @State private var reminderToast: String?
    @State private var catchupPlayback: CatchupPlayback?
    @State private var livePlayback: LivePlaybackItem?
    @State private var renderLimit = 32
    @State private var reloadTaskBox = TaskBox()
    @State private var didAppear = false

    // MARK: - Parametri di tempo & concorrenza (INVARIATI)
    private let renderPageSize = 32
    private let hardRenderCap = 250
    private let maxConcurrentRequests = 24
    private let shortEPGLimit = 24
    private let searchDebounceNanoseconds: UInt64 = 120_000_000
    private let loadingIndicatorDelayNanoseconds: UInt64 = 150_000_000

    // MARK: - Dimensioni & Geometria Dinamiche (Compatta vs Comoda)

    private var bannerInset: CGFloat {
        layoutDensity == .compact ? 10 : 12
    }

    private var channelBannerWidth: CGFloat {
        layoutDensity == .compact ? 80 : 86
    }

    private var bannerHeight: CGFloat {
        layoutDensity == .compact ? 58 : 76
    }

    private var blockHeight: CGFloat {
        layoutDensity == .compact ? 58 : 82
    }

    private var rowHeight: CGFloat {
        layoutDensity == .compact ? 66 : 96
    }

    private var timelineHeaderHeight: CGFloat {
        layoutDensity == .compact ? 40 : 44
    }

    private var arrowGlyphWidth: CGFloat {
        layoutDensity == .compact ? 16 : 20
    }

    /// Spaziatura temporale (160pt ogni 30 minuti): scala pixel per minuto = 160 / 30 = 5.333 pt/min.
    private let halfHourPixelSpacing: CGFloat = 160
    private var pixelsPerMinute: CGFloat { halfHourPixelSpacing / 30 }

    /// Intercapedine visibile tra due tile di programma consecutivi nella stessa riga.
    private let tileHorizontalGap: CGFloat = 4

    /// Larghezza della colonna fissa laterale. "Griglie" conserva entrambi gli
    /// inset originali; "Schede" elimina esclusivamente quello a destra del banner.
    private var bannerColumnWidth: CGFloat {
        bannerInset + channelBannerWidth + (tileAppearance == .grids ? bannerInset : 0)
    }

    private var bannerContentWidth: CGFloat {
        channelBannerWidth
    }

    /// Raggio del corner radius del banner canale — UNICA fonte di verità condivisa sia dal
    /// banner stesso (`channelBanner`) sia dalla profondità massima dell'estensione della tile
    /// (`tileLeadingExtension`): la tile deve attraversare COMPLETAMENTE, come rettangolo pieno
    /// e squadrato, lo spazio dietro il banner fino ESATTAMENTE al punto in cui inizia il radius
    /// del banner (bordo destro banner − `bannerCornerRadius`). L'unico arco visibile resta
    /// quello del banner: la tile non deve avere un proprio radius che ritagli quello spazio.
    private var bannerCornerRadius: CGFloat {
        layoutDensity == .compact ? 14 : 16
    }

    /// Profondità MASSIMA (non ancora vincolata dallo scroll) con cui, in "Schede", la tile può
    /// attraversare lo spazio dietro il banner: esattamente `bannerCornerRadius`, cioè fino al
    /// punto preciso in cui il bordo destro del banner comincia a curvare.
    private var tileLeadingExtension: CGFloat {
        guard tileAppearance == .cards else { return 0 }
        return bannerCornerRadius
    }

    /// Finestra temporale: 30 minuti passati, 3 ore future. (INVARIATA)
    private let pastWindow: TimeInterval = 30 * 60
    private let futureWindow: TimeInterval = 180 * 60

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    init(
        credentials: XtreamCredentials,
        kind: XtreamStreamKind = .live,
        onPlayLive: ((XtreamStream) -> Void)? = nil
    ) {
        self.credentials = credentials
        self.kind = kind
        self.onPlayLive = onPlayLive
        _favorites = StateObject(
            wrappedValue: EPGFavoritesStore(scopeKey: Self.scopeKey(for: credentials))
        )
    }

    private final class TaskBox {
        var task: Task<Void, Never>?
    }

    private struct SelectedProgram: Identifiable {
        let program: EPGProgram
        let stream: XtreamStream
        var id: String { "\(stream.streamId)-\(program.id)" }
    }

    private struct CatchupPlayback: Identifiable {
        let url: URL
        let title: String
        var id: String { url.absoluteString }
    }

    private struct LivePlaybackItem: Identifiable {
        let stream: XtreamStream
        let url: URL
        var id: Int { stream.streamId }
    }

    // MARK: - Palette Dinamica Pastello Adattiva

    private static func adaptivePastelColor(for stream: XtreamStream) -> Color {
        let name = stream.name.lowercased()
        if name.contains("rai 1") || name.contains("rai1") {
            return Color(red: 0.88, green: 0.28, blue: 0.34)
        } else if name.contains("rai 2") || name.contains("rai2") {
            return Color(red: 0.89, green: 0.38, blue: 0.28)
        } else if name.contains("rai 3") || name.contains("rai3") {
            return Color(red: 0.28, green: 0.68, blue: 0.48)
        } else if name.contains("rai 4") || name.contains("rai4") {
            return Color(red: 0.58, green: 0.36, blue: 0.72)
        } else if name.contains("rai news") || name.contains("rainews") {
            return Color(red: 0.24, green: 0.54, blue: 0.82)
        } else if name.contains("rai sport") {
            return Color(red: 0.86, green: 0.62, blue: 0.22)
        } else if name.contains("canale 5") || name.contains("mediaset") || name.contains("italia 1") {
            return Color(red: 0.22, green: 0.58, blue: 0.86)
        } else if name.contains("sky") {
            return Color(red: 0.26, green: 0.52, blue: 0.88)
        } else if name.contains("dazn") || name.contains("sport") {
            return Color(red: 0.82, green: 0.74, blue: 0.28)
        } else if name.contains("cinema") || name.contains("film") || name.contains("movie") {
            return Color(red: 0.72, green: 0.32, blue: 0.58)
        } else if name.contains("private") {
            return Color(red: 0.85, green: 0.30, blue: 0.36)
        }

        let pastelPalette: [Color] = [
            Color(red: 0.86, green: 0.32, blue: 0.36),
            Color(red: 0.88, green: 0.45, blue: 0.32),
            Color(red: 0.85, green: 0.65, blue: 0.26),
            Color(red: 0.32, green: 0.70, blue: 0.52),
            Color(red: 0.28, green: 0.64, blue: 0.78),
            Color(red: 0.35, green: 0.52, blue: 0.88),
            Color(red: 0.58, green: 0.42, blue: 0.78),
            Color(red: 0.78, green: 0.38, blue: 0.66)
        ]

        let hash = abs(stream.name.hashValue ^ stream.streamId.hashValue)
        return pastelPalette[hash % pastelPalette.count]
    }

    // MARK: - Nome Canale & Badge Qualità

    private static let qualityBadgeTokens: Set<String> = ["4K", "FHD", "HD", "SD"]

    private static func splitNameAndQualityBadge(_ rawName: String) -> (name: String, badge: String?) {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastSpace = trimmed.range(of: " ", options: .backwards) else {
            return (trimmed, nil)
        }

        let candidate = trimmed[lastSpace.upperBound...]
        let upperCandidate = candidate.uppercased()
        guard qualityBadgeTokens.contains(upperCandidate) else {
            return (trimmed, nil)
        }

        let base = trimmed[..<lastSpace.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return (base.isEmpty ? trimmed : base, String(upperCandidate))
    }

    // MARK: - Sorgenti Dati Centralizzate

    private var streams: [XtreamStream] { xtreamCatalog.streams(for: kind) }
    private var liveCategories: [XtreamCategory] { xtreamCatalog.categories(for: .live) }
    private var isCatalogStillLoading: Bool {
        streams.isEmpty && (xtreamCatalog.state == .loading || xtreamCatalog.state == .idle)
    }

    private var normalizedSelectedGroupID: String? {
        guard let selectedGroupID else { return nil }
        let normalized = selectedGroupID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private var groupData: (groups: [XtreamCategory], counts: [String: Int], name: String, icon: String) {
        var counts: [String: Int] = [:]
        var seenIDs = Set<String>()
        var orderedIDs: [String] = []

        for stream in streams {
            guard let raw = stream.categoryId else { continue }
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id != "0" else { continue }
            counts[id, default: 0] += 1
            if seenIDs.insert(id).inserted {
                orderedIDs.append(id)
            }
        }

        let categoryByID = Dictionary(
            uniqueKeysWithValues: liveCategories.map { ($0.categoryId, $0) }
        )

        let groups = orderedIDs.compactMap { categoryByID[$0] }

        let currentGroupName: String
        let currentGroupIcon: String
        if let targetID = normalizedSelectedGroupID, let found = groups.first(where: { $0.categoryId == targetID }) {
            currentGroupName = found.categoryName
            currentGroupIcon = Self.groupIcon(for: found.categoryName)
        } else {
            currentGroupName = "Tutti"
            currentGroupIcon = "square.grid.2x2"
        }

        return (groups, counts, currentGroupName, currentGroupIcon)
    }

    private var groupSelectionBinding: Binding<String?> {
        Binding(get: { normalizedSelectedGroupID }, set: { selectGroup($0) })
    }

    private func selectGroup(_ groupID: String?) {
        guard groupID != normalizedSelectedGroupID else { return }
        selectedGroupID = groupID
        searchQuery = ""
        showFavoritesOnly = false
        renderLimit = renderPageSize
    }

    private var streamData: (filteredCount: Int, paged: [XtreamStream], canLoadMore: Bool, remainingCount: Int, identity: String) {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupID = normalizedSelectedGroupID
        let isFiltering = !query.isEmpty || groupID != nil || showFavoritesOnly

        let filtered: [XtreamStream]
        if !isFiltering {
            filtered = streams
        } else {
            filtered = streams.filter { stream in
                let categoryID = stream.categoryId?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let groupID, categoryID != groupID { return false }
                if showFavoritesOnly && !favorites.isFavorite(stream.streamId) { return false }
                if !query.isEmpty && !stream.name.localizedCaseInsensitiveContains(query) { return false }
                return true
            }
        }

        let totalFiltered = filtered.count
        let effectiveCap = min(totalFiltered, hardRenderCap)
        let countToTake = min(max(renderLimit, 0), effectiveCap)
        let paged = Array(filtered.prefix(countToTake))
        let canMore = renderLimit < effectiveCap
        let remaining = max(0, effectiveCap - renderLimit)

        let ids = paged.map(\.streamId).map(String.init).joined(separator: ",")
        let identity = "\(groupID ?? "all")|\(selectedDayOffset)|\(ids)"

        return (totalFiltered, paged, canMore, remaining, identity)
    }

    private var cacheScope: String {
        "\(Self.scopeKey(for: credentials))|d\(selectedDayOffset)"
    }

    // MARK: - Geometria Temporale

    private var selectedDate: Date {
        Calendar.autoupdatingCurrent.date(byAdding: .day, value: selectedDayOffset, to: now) ?? now
    }

    private var isToday: Bool {
        selectedDayOffset == 0
    }

    private var windowCenter: Date {
        if isToday { return now }
        return Calendar.autoupdatingCurrent.date(
            bySettingHour: 12,
            minute: 0,
            second: 0,
            of: selectedDate
        ) ?? selectedDate
    }

    private var windowStart: Date {
        windowCenter.addingTimeInterval(-pastWindow)
    }

    private var windowEnd: Date {
        windowCenter.addingTimeInterval(futureWindow)
    }

    private var gridOrigin: Date {
        let calendar = Calendar.autoupdatingCurrent
        let startMinute = calendar.component(.minute, from: windowStart)
        let flooredMinute = startMinute < 30 ? 0 : 30
        return calendar.date(
            bySettingHour: calendar.component(.hour, from: windowStart),
            minute: flooredMinute,
            second: 0,
            of: windowStart
        ) ?? windowStart
    }

    private var halfHourTicks: [Date] {
        var ticks: [Date] = []
        var cursor = gridOrigin
        while cursor <= windowEnd {
            ticks.append(cursor)
            cursor = cursor.addingTimeInterval(30 * 60)
        }
        return ticks
    }

    private var canvasWidth: CGFloat {
        max(CGFloat(halfHourTicks.count) * halfHourPixelSpacing, 500)
    }

    private func xCoordinate(for date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(gridOrigin) / 60) * pixelsPerMinute
    }

    private var liveAxisX: CGFloat {
        xCoordinate(for: windowCenter)
    }

    private var dayTitle: String {
        switch selectedDayOffset {
        case 0: return "Oggi"
        case 1: return "Domani"
        case -1: return "Ieri"
        default:
            return selectedDate.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        }
    }

    var body: some View {
        let currentStreamData = streamData
        let currentGroupData = groupData

        NavigationStack {
            content(streamData: currentStreamData)
                .background(Color.black.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent(groupData: currentGroupData) }
                .sheet(item: $selectedProgram) { selection in
                    ProgramDetailSheet(
                        program: selection.program,
                        stream: selection.stream,
                        isCurrentlyLive: selection.program.isCurrent(at: now),
                        onPlayLive: {
                            playLiveStream(selection.stream, dismissSheetFirst: true)
                        },
                        onPlayCatchup: {
                            playCatchup(program: selection.program, stream: selection.stream)
                        },
                        onSetReminder: {
                            Task { await scheduleReminder(for: selection.program) }
                        }
                    )
                    .presentationDetents([.medium, .large])
                    .presentationBackground(.thinMaterial)
                }
                .fullScreenCover(item: $livePlayback) { item in
                    AdaptivePlayerView(url: item.url, title: item.stream.name)
                }
                .fullScreenCover(item: $catchupPlayback) { playback in
                    AdaptivePlayerView(url: playback.url, title: playback.title)
                }
                .overlay(alignment: .top) {
                    if let reminderToast {
                        toast(reminderToast)
                            .task(id: reminderToast) {
                                try? await Task.sleep(nanoseconds: 2_200_000_000)
                                guard !Task.isCancelled else { return }
                                self.reminderToast = nil
                            }
                    }
                }
                .onAppear {
                    guard !didAppear else { return }
                    didAppear = true
                    scheduleReload()
                }
                .onChange(of: streams.map(\.streamId)) { _, _ in
                    if currentStreamData.paged.isEmpty {
                        renderLimit = min(renderPageSize, max(streams.count, 1))
                    }
                    scheduleReload(debounced: true)
                }
                .onChange(of: currentStreamData.identity) { _, _ in
                    scheduleReload(debounced: true)
                }
                .onChange(of: selectedDayOffset) { _, _ in
                    programsByStream.removeAll()
                    failedStreamIDs.removeAll()
                    loadingStreamIDs.removeAll()
                    renderLimit = renderPageSize
                    scheduleReload(debounced: true)
                }
                .onChange(of: searchQuery) { _, _ in
                    renderLimit = renderPageSize
                    scheduleReload(debounced: true)
                }
                .onChange(of: showFavoritesOnly) { _, _ in
                    renderLimit = renderPageSize
                    scheduleReload(debounced: true)
                }
                .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { date in
                    now = date
                }
                .onDisappear {
                    reloadTaskBox.task?.cancel()
                    loadingIndicatorTask?.cancel()
                }
        }
    }

    @ViewBuilder
    private func content(streamData: (filteredCount: Int, paged: [XtreamStream], canLoadMore: Bool, remainingCount: Int, identity: String)) -> some View {
        if streams.isEmpty {
            ContentUnavailableView(
                isCatalogStillLoading ? "Caricamento canali…" : "Nessun canale live",
                systemImage: isCatalogStillLoading ? "hourglass" : "tv.slash",
                description: Text(
                    isCatalogStillLoading
                        ? "Il catalogo si sta ancora caricando."
                        : "Questa sorgente non contiene canali live."
                )
            )
            .foregroundStyle(.white)
        } else {
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    searchHeader
                    epgSurface(pagedStreams: streamData.paged)

                    if streamData.canLoadMore {
                        loadMoreButton(remainingCount: streamData.remainingCount, filteredCount: streamData.filteredCount)
                    }
                }
                .padding(.bottom, layoutDensity == .compact ? 24 : 32)
            }
            .coordinateSpace(name: "epgViewportCoordinateSpace")
            .scrollIndicators(.hidden)
            .overlay(alignment: .topTrailing) {
                if showLoadingIndicator {
                    ProgressView()
                        .tint(.white)
                        .padding(12)
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: - Superficie EPG (HStack Principale)

    private func epgSurface(pagedStreams: [XtreamStream]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            fixedDayAndChannelColumn(pagedStreams: pagedStreams)
                .frame(width: bannerColumnWidth, alignment: .leading)
                .zIndex(10)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    scrollingTimelineHeader

                    ForEach(pagedStreams) { stream in
                        timelineRow(for: stream)
                    }
                }
            }
            .scrollClipDisabled(tileAppearance == .cards)
        }
    }

    private func fixedDayAndChannelColumn(pagedStreams: [XtreamStream]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    selectedDayOffset = max(selectedDayOffset - 1, -7)
                } label: {
                    Text(dayTitle)
                        .font(
                            .system(
                                size: layoutDensity == .compact ? 24 : 28,
                                weight: .bold,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(.white)
                        .frame(height: timelineHeaderHeight, alignment: .leading)
                        .padding(.leading, bannerInset)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Giorno: \(dayTitle)")
            }
            .background(alignment: .leading) {
                if tileAppearance == .cards {
                    Color.black
                        .frame(width: bannerColumnWidth, height: timelineHeaderHeight)
                }
            }

            if pagedStreams.isEmpty {
                Color.clear.frame(width: bannerColumnWidth, height: 1)
            } else {
                ForEach(pagedStreams) { stream in
                    channelBanner(stream)
                }
            }
        }
        .background(tileAppearance == .grids ? Color.black : Color.clear)
    }

    private var scrollingTimelineHeader: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                for tick in halfHourTicks {
                    let fontSize: CGFloat = layoutDensity == .compact ? 20 : 22
                    let text = Text(Self.timeFormatter.string(from: tick))
                        .font(.system(size: fontSize, weight: layoutDensity == .compact ? .semibold : .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(layoutDensity == .compact ? 0.60 : 0.58))
                        .monospacedDigit()
                    context.draw(text, at: CGPoint(x: xCoordinate(for: tick), y: size.height / 2), anchor: .leading)
                }
            }
            .frame(width: canvasWidth, height: timelineHeaderHeight)

            if isToday {
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: layoutDensity == .compact ? 15 : 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: arrowGlyphWidth, height: timelineHeaderHeight, alignment: .center)
                    .offset(x: liveAxisX - arrowGlyphWidth / 2)
                    .accessibilityLabel("Ora corrente: \(Self.timeFormatter.string(from: windowCenter))")
            }
        }
        .frame(width: canvasWidth, height: timelineHeaderHeight, alignment: .topLeading)
        .clipped()
    }

    // MARK: - Righe Canali e Tile Programmi

    private func timelineRow(for stream: XtreamStream) -> some View {
        let programs = visiblePrograms(for: stream)

        return ZStack(alignment: .leading) {
            if programs.isEmpty {
                unavailableBlock(for: stream)
            } else {
                ForEach(Array(programs.enumerated()), id: \.element.id) { index, program in
                    let nextStart = index + 1 < programs.count ? programs[index + 1].start : nil
                    programBlock(
                        program,
                        stream: stream,
                        nextProgramStart: nextStart,
                        isFirstVisibleProgram: index == programs.startIndex
                    )
                }
            }
        }
        .frame(width: canvasWidth, height: rowHeight, alignment: .leading)
        .clipped()
    }

    /// Banner Canale Adattivo con avvio immediato a latenza zero
    private func channelBanner(_ stream: XtreamStream) -> some View {
        let channelColor = Self.adaptivePastelColor(for: stream)

        return Button {
            playLiveStream(stream, dismissSheetFirst: false)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: bannerCornerRadius, style: .continuous)
                    .fill(channelColor)

                if let icon = stream.streamIcon, !icon.isEmpty {
                    AsyncImage(url: URL(string: icon)) { phase in
                        if case .success(let image) = phase {
                            image
                                .renderingMode(.original)
                                .resizable()
                                .scaledToFit()
                                .padding(layoutDensity == .compact ? 8 : 12)
                        } else {
                            Image(systemName: "play.tv.fill")
                                .renderingMode(.original)
                                .font(.system(size: layoutDensity == .compact ? 22 : 26))
                                .foregroundStyle(.white)
                        }
                    }
                } else {
                    Image(systemName: "play.tv.fill")
                        .renderingMode(.original)
                        .font(.system(size: layoutDensity == .compact ? 22 : 26))
                        .foregroundStyle(.white)
                }

                if favorites.isFavorite(stream.streamId) {
                    Image(systemName: "star.fill")
                        .font(.system(size: layoutDensity == .compact ? 10 : 11, weight: .bold))
                        .foregroundStyle(.yellow)
                        .padding(4)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .frame(width: channelBannerWidth, height: bannerHeight)
            .overlay(alignment: .trailing) {
                if hasVisibleCatchup(for: stream) {
                    catchupBadge
                        .offset(x: channelBannerWidth * 0.14)
                }
            }
            .frame(
                width: bannerColumnWidth,
                height: rowHeight,
                alignment: tileAppearance == .cards ? .trailing : .center
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .zIndex(1)
        .accessibilityLabel("Guarda \(stream.name) in diretta")
    }

    private func hasVisibleCatchup(for stream: XtreamStream) -> Bool {
        visiblePrograms(for: stream).contains { $0.hasArchive }
    }

    private var catchupBadge: some View {
        Image(systemName: "clock.arrow.circlepath")
            .font(.system(size: layoutDensity == .compact ? 13 : 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(
                width: layoutDensity == .compact ? 26 : 30,
                height: layoutDensity == .compact ? 26 : 30
            )
            .background(Color(white: 0.30), in: Circle())
            .accessibilityLabel("Contenuti in differita disponibili")
    }

    /// Blocco "Dati non disponibili"/"Caricamento"/"EPG non disponibile" per l'intera riga.
    /// In "Schede" attraversa lo spazio dietro il banner esattamente come le tile di programma:
    /// stesso calcolo dinamico dell'estensione dentro `GeometryReader`, stesso bordo sinistro
    /// squadrato (nessun radius proprio) fino al punto esatto in cui inizia il radius del banner.
    private func unavailableBlock(for stream: XtreamStream) -> some View {
        let loading = loadingStreamIDs.contains(stream.streamId)
        let failed = failedStreamIDs.contains(stream.streamId)
        let channelColor = Self.adaptivePastelColor(for: stream)
        let cornerRadius: CGFloat = layoutDensity == .compact ? 12 : 18
        let maxExtension = tileLeadingExtension

        return GeometryReader { geo in
            let tileMinX = geo.frame(in: .named("epgViewportCoordinateSpace")).minX
            // Attiva SOLO quando il blocco è realmente agganciato al banner (tileMinX < bannerColumnWidth);
            // appena lo supera del tutto, l'estensione si interrompe esattamente in quel punto (nessun residuo).
            // Quando agganciato, non supera comunque mai il bordo sinistro dello schermo (clamp a tileMinX).
            let extensionWidth: CGFloat = tileMinX < bannerColumnWidth
                ? max(0, min(maxExtension, tileMinX))
                : 0
            let isDockedUnderBanner = tileAppearance == .cards && extensionWidth > 0
            let totalWidth = canvasWidth + extensionWidth

            HStack(spacing: 6) {
                if loading {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.small)
                    Text("Caricamento EPG")
                } else if failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("EPG non disponibile")
                } else {
                    Text("Dati non disponibili")
                }
            }
            .font(.system(size: layoutDensity == .compact ? 14 : 15, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.65))
            .padding(
                .leading,
                (layoutDensity == .compact ? 14 : 18) + extensionWidth
            )
            .padding(.trailing, layoutDensity == .compact ? 14 : 18)
            .frame(height: blockHeight)
            .background {
                ZStack {
                    tileBackgroundFill(Color(white: 0.10), cornerRadius: cornerRadius, isDockedUnderBanner: isDockedUnderBanner)
                    tileBackgroundFill(channelColor.opacity(0.12), cornerRadius: cornerRadius, isDockedUnderBanner: isDockedUnderBanner)
                }
            }
            .frame(width: totalWidth, height: rowHeight, alignment: .leading)
            .offset(x: -extensionWidth)
            .epgTileClip(cornerRadius: cornerRadius, isDockedUnderBanner: isDockedUnderBanner)
        }
    }

    /// Layout scroll-linked della riga superiore in modalità Compatta.
    private struct SlidingCompactHeaderLayout: Layout {
        let pinnedNameOffset: CGFloat
        let keepsNaturalCurrentPosition: Bool
        private let itemSpacing: CGFloat = 6

        func sizeThatFits(
            proposal: ProposedViewSize,
            subviews: Subviews,
            cache: inout ()
        ) -> CGSize {
            guard subviews.count == 2 else {
                return proposal.replacingUnspecifiedDimensions()
            }

            let nameSize = subviews[0].sizeThatFits(.unspecified)
            let timeSize = subviews[1].sizeThatFits(.unspecified)
            return CGSize(
                width: proposal.width ?? (nameSize.width + itemSpacing + timeSize.width),
                height: max(nameSize.height, timeSize.height)
            )
        }

        func placeSubviews(
            in bounds: CGRect,
            proposal: ProposedViewSize,
            subviews: Subviews,
            cache: inout ()
        ) {
            guard subviews.count == 2 else { return }

            let nameSize = subviews[0].sizeThatFits(.unspecified)
            let timeSize = subviews[1].sizeThatFits(.unspecified)
            let finalTimeX = nameSize.width + itemSpacing

            let nameX: CGFloat
            let timeX: CGFloat

            if keepsNaturalCurrentPosition && pinnedNameOffset < 0 {
                nameX = 0
                timeX = finalTimeX
            } else if pinnedNameOffset < 0 {
                nameX = pinnedNameOffset
                timeX = min(max(finalTimeX + pinnedNameOffset, 0), finalTimeX)
            } else {
                nameX = pinnedNameOffset
                timeX = pinnedNameOffset + finalTimeX
            }

            subviews[0].place(
                at: CGPoint(x: bounds.minX + nameX, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(nameSize)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.minX + timeX, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(timeSize)
            )
        }
    }

    /// Tile del programma con transizioni scroll-linked di nome canale e orari.
    /// In "Schede", l'estensione verso il banner è calcolata IN UN UNICO PASSAGGIO dentro lo
    /// stesso `GeometryReader` che legge la posizione reale della tile (`tileMinX`): è attiva
    /// SOLO quando la tile è effettivamente agganciata al banner (`tileMinX < bannerColumnWidth`)
    /// e si interrompe esattamente e istantaneamente a quel confine — nessun residuo visivo per
    /// le tile già scorse oltre il banner. Quando agganciata, l'estensione è un rettangolo pieno
    /// e squadrato (nessun radius proprio sul bordo sinistro) che attraversa completamente lo
    /// spazio dietro il banner fino al punto esatto in cui inizia il radius del banner stesso, e
    /// non supera comunque mai il bordo sinistro dello schermo (clamp a `tileMinX`).
    private func programBlock(
        _ program: EPGProgram,
        stream: XtreamStream,
        nextProgramStart: Date?,
        isFirstVisibleProgram: Bool
    ) -> some View {
        let clippedStart = max(program.start, windowStart)
        let clippedEnd = min(program.end, windowEnd)
        let startX = xCoordinate(for: clippedStart)
        let calculatedEndX = xCoordinate(for: clippedEnd)

        let endX: CGFloat
        if let nextProgramStart {
            let nextStartX = xCoordinate(for: max(nextProgramStart, windowStart))
            endX = min(calculatedEndX, nextStartX)
        } else {
            endX = calculatedEndX
        }

        let width = max(32, endX - startX)
        let maxExtension = tileLeadingExtension
        let visibleWidth = max(0, width - tileHorizontalGap)
        let contentLeadingInset: CGFloat = layoutDensity == .compact ? 10 : 13
        let cornerRadius: CGFloat = layoutDensity == .compact ? 12 : 18

        return GeometryReader { geo in
            let tileMinX = geo.frame(in: .named("epgViewportCoordinateSpace")).minX
            let overlap = max(0, bannerColumnWidth - tileMinX)
            let stickyContentX = min(overlap, visibleWidth)
            let pinnedNameX = bannerColumnWidth - tileMinX
            let keepsNaturalCurrentPosition = isFirstVisibleProgram && tileMinX > bannerColumnWidth

            // Estensione dinamica verso il banner: attiva SOLO quando la tile è realmente
            // agganciata/dietro il banner (tileMinX < bannerColumnWidth). Appena la tile supera
            // completamente il banner (tileMinX >= bannerColumnWidth) l'estensione si interrompe
            // ESATTAMENTE e istantaneamente in quel punto: nessun residuo visivo. Quando invece la
            // tile è agganciata, l'estensione non supera comunque mai il bordo sinistro dello
            // schermo (clamp a tileMinX): non può quindi mai comparire a sinistra del banner,
            // in nessuna condizione di scroll/overscroll.
            let extensionWidth: CGFloat = tileMinX < bannerColumnWidth
                ? max(0, min(maxExtension, tileMinX))
                : 0
            let isDockedUnderBanner = tileAppearance == .cards && extensionWidth > 0
            let renderedWidth = visibleWidth + extensionWidth

            Button {
                selectedProgram = SelectedProgram(program: program, stream: stream)
            } label: {
                let nameParts = Self.splitNameAndQualityBadge(stream.name)

                ZStack(alignment: .topLeading) {
                    if layoutDensity == .compact {
                        VStack(alignment: .leading, spacing: 3) {
                            SlidingCompactHeaderLayout(
                                pinnedNameOffset: pinnedNameX,
                                keepsNaturalCurrentPosition: keepsNaturalCurrentPosition
                            ) {
                                HStack(spacing: 6) {
                                    Text(nameParts.name)
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)

                                    if let badge = nameParts.badge {
                                        qualityBadge(badge, fontSize: 11)
                                    }
                                }
                                .fixedSize(horizontal: true, vertical: false)

                                Text(program.start.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.60))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }

                            Text(program.title)
                                .font(.system(size: 14, weight: .regular, design: .rounded))
                                .lineLimit(1)
                                .hidden()
                        }
                        .padding(.leading, contentLeadingInset)
                        .padding(.trailing, 10)
                        .frame(width: visibleWidth, height: blockHeight, alignment: .leading)
                        .offset(x: extensionWidth)

                        compactProgramTitle(
                            nameParts: nameParts,
                            program: program,
                            leadingInset: contentLeadingInset
                        )
                        .offset(x: stickyContentX)
                        .frame(width: visibleWidth, height: blockHeight, alignment: .leading)
                        .offset(x: extensionWidth)
                    } else {
                        comfortableProgramName(
                            nameParts: nameParts,
                            program: program,
                            leadingInset: contentLeadingInset
                        )
                        .offset(x: keepsNaturalCurrentPosition ? 0 : pinnedNameX)
                        .frame(width: visibleWidth, height: blockHeight, alignment: .topLeading)
                        .offset(x: extensionWidth)

                        comfortableProgramTime(
                            nameParts: nameParts,
                            program: program,
                            leadingInset: contentLeadingInset
                        )
                        .offset(x: stickyContentX)
                        .frame(width: visibleWidth, height: blockHeight, alignment: .topLeading)
                        .offset(x: extensionWidth)

                        comfortableProgramTitle(
                            nameParts: nameParts,
                            program: program,
                            leadingInset: contentLeadingInset
                        )
                        .offset(x: stickyContentX)
                        .frame(width: visibleWidth, height: blockHeight, alignment: .topLeading)
                        .offset(x: extensionWidth)
                    }
                }
                .frame(width: renderedWidth, height: blockHeight, alignment: .topLeading)
                .background {
                    programTileBackground(
                        stream: stream,
                        program: program,
                        tileStartX: startX - extensionWidth,
                        tileWidth: renderedWidth,
                        isDockedUnderBanner: isDockedUnderBanner,
                        cornerRadius: cornerRadius
                    )
                }
                .epgTileClip(cornerRadius: cornerRadius, isDockedUnderBanner: isDockedUnderBanner)
            }
            .buttonStyle(.plain)
            .frame(width: renderedWidth, height: blockHeight, alignment: .leading)
            .offset(x: -extensionWidth)
        }
        .frame(width: width, height: blockHeight)
        .offset(x: startX)
        .accessibilityLabel(
            "\(stream.name), \(program.title), dalle \(program.start.formatted(date: .omitted, time: .shortened)) alle \(program.end.formatted(date: .omitted, time: .shortened))"
        )
    }

    private func compactProgramTitle(
        nameParts: (name: String, badge: String?),
        program: EPGProgram,
        leadingInset: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(nameParts.name).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
                if let badge = nameParts.badge { qualityBadge(badge, fontSize: 11) }
                Text(program.start.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 13, weight: .medium, design: .rounded)).lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .hidden()

            Text(program.title)
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.92)).lineLimit(1).truncationMode(.tail)
        }
        .padding(.leading, leadingInset).padding(.trailing, 10)
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    private func comfortableProgramName(
        nameParts: (name: String, badge: String?),
        program: EPGProgram,
        leadingInset: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(nameParts.name)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.70)).lineLimit(1)
                if let badge = nameParts.badge { qualityBadge(badge, fontSize: 10) }
            }
            .fixedSize(horizontal: true, vertical: false)
            Text(program.start.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12, weight: .medium, design: .rounded)).lineLimit(1).hidden()
            Text(program.title)
                .font(.system(size: 16, weight: .semibold, design: .rounded)).lineLimit(1).hidden()
            Spacer(minLength: 0)
        }
        .padding(.leading, leadingInset).padding(.trailing, 13).padding(.vertical, 8)
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    private func comfortableProgramTime(
        nameParts: (name: String, badge: String?),
        program: EPGProgram,
        leadingInset: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(nameParts.name).font(.system(size: 11, weight: .semibold, design: .rounded)).lineLimit(1)
                if let badge = nameParts.badge { qualityBadge(badge, fontSize: 10) }
            }
            .fixedSize(horizontal: true, vertical: false).hidden()
            Text(program.start.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            Text(program.title)
                .font(.system(size: 16, weight: .semibold, design: .rounded)).lineLimit(1).hidden()
            Spacer(minLength: 0)
        }
        .padding(.leading, leadingInset).padding(.trailing, 13).padding(.vertical, 8)
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    private func comfortableProgramTitle(
        nameParts: (name: String, badge: String?),
        program: EPGProgram,
        leadingInset: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(nameParts.name).font(.system(size: 11, weight: .semibold, design: .rounded)).lineLimit(1)
                if let badge = nameParts.badge { qualityBadge(badge, fontSize: 10) }
            }
            .fixedSize(horizontal: true, vertical: false).hidden()
            Text(program.start.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12, weight: .medium, design: .rounded)).lineLimit(1)
                .fixedSize(horizontal: true, vertical: false).hidden()
            Text(program.title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, leadingInset).padding(.trailing, 13).padding(.vertical, 8)
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    private func qualityBadge(_ text: String, fontSize: CGFloat) -> some View {
        Text(text)
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.65))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.45), lineWidth: 1)
            }
    }

    /// Riempimento del corpo della tile. Quando `isDockedUnderBanner` è `true` (tile agganciata
    /// dietro il banner, in "Schede"), il bordo sinistro NON ha alcun radius proprio (0, squadrato):
    /// la tile deve riempire per intero, senza tagli ad arco, lo spazio dietro il banner fino al
    /// punto esatto in cui inizia il radius del banner — l'unico arco visibile resta quello del
    /// banner stesso. In tutti gli altri casi (card libera non agganciata, o "Griglie") il radius
    /// resta uniforme su tutti i lati, come una normale card.
    @ViewBuilder
    private func tileBackgroundFill<S: ShapeStyle>(_ style: S, cornerRadius: CGFloat, isDockedUnderBanner: Bool) -> some View {
        if isDockedUnderBanner {
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: cornerRadius,
                topTrailingRadius: cornerRadius,
                style: .continuous
            )
            .fill(style)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(style)
        }
    }

    @ViewBuilder
    private func programTileBackground(
        stream: XtreamStream,
        program: EPGProgram,
        tileStartX: CGFloat,
        tileWidth: CGFloat,
        isDockedUnderBanner: Bool,
        cornerRadius: CGFloat
    ) -> some View {
        let channelColor = Self.adaptivePastelColor(for: stream)
        let brightWidth = isToday ? min(max(liveAxisX - tileStartX, 0), tileWidth) : 0

        ZStack(alignment: .leading) {
            tileBackgroundFill(Color(white: 0.10), cornerRadius: cornerRadius, isDockedUnderBanner: isDockedUnderBanner)
            tileBackgroundFill(channelColor.opacity(layoutDensity == .compact ? 0.18 : 0.22), cornerRadius: cornerRadius, isDockedUnderBanner: isDockedUnderBanner)

            if brightWidth > 0 {
                Rectangle()
                    .fill(channelColor.opacity(layoutDensity == .compact ? 0.38 : 0.45))
                    .frame(width: brightWidth)
            }
        }
    }

    private func loadMoreButton(remainingCount: Int, filteredCount: Int) -> some View {
        Button {
            let newLimit = min(
                renderLimit + renderPageSize,
                min(filteredCount, hardRenderCap)
            )
            guard newLimit != renderLimit else { return }
            renderLimit = newLimit
        } label: {
            Label(
                "Carica altri \(min(renderPageSize, remainingCount)) canali",
                systemImage: "arrow.down.circle"
            )
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .frame(maxWidth: .infinity)
            .padding(.vertical, layoutDensity == .compact ? 14 : 16)
            .foregroundStyle(.white)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: layoutDensity == .compact ? 14 : 16, style: .continuous))
        }
        .padding(16)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbarContent(groupData: (groups: [XtreamCategory], counts: [String: Int], name: String, icon: String)) -> some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Indietro")
        }

        ToolbarItem(placement: .principal) {
            Menu {
                Picker("Gruppo playlist", selection: groupSelectionBinding) {
                    Label("Tutti i canali", systemImage: "square.grid.2x2")
                        .tag(String?.none)

                    if !groupData.groups.isEmpty {
                        Divider()
                        ForEach(groupData.groups) { group in
                            Label(
                                "\(group.categoryName) (\(groupData.counts[group.categoryId] ?? 0))",
                                systemImage: Self.groupIcon(for: group.categoryName)
                            )
                            .tag(Optional(group.categoryId))
                        }
                    }
                }
                .pickerStyle(.inline)
            } label: {
                groupPillLabel(name: groupData.name, icon: groupData.icon)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel("Gruppo playlist: \(groupData.name)")
            .accessibilityHint("Tocca per scegliere il gruppo da visualizzare")
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Menu {
                    Picker("Aspetto EPG", selection: $layoutDensity) {
                        ForEach(EPGLayoutDensity.allCases) { density in
                            Label(density.title, systemImage: density.icon)
                                .tag(density)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Aspetto EPG", systemImage: "aspectratio")
                }

                Menu {
                    Picker("Aspetto Tile", selection: $tileAppearance) {
                        ForEach(EPGTileAppearance.allCases) { appearance in
                            Label(appearance.title, systemImage: appearance.icon)
                                .tag(appearance)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Aspetto Tile", systemImage: "rectangle.3.group")
                }

                Divider()

                Button {
                    reminderToast = "Aggiornamento guida in corso…"
                    Task { await refreshAll() }
                } label: {
                    Label("Aggiorna guida", systemImage: "arrow.clockwise")
                }

                Button {
                    withAnimation(.snappy) {
                        showFavoritesOnly.toggle()
                    }
                } label: {
                    Label(
                        showFavoritesOnly ? "Mostra tutti" : "Solo preferiti",
                        systemImage: showFavoritesOnly ? "star.fill" : "star"
                    )
                }

                Divider()

                Button {
                    selectedDayOffset = -1
                } label: {
                    Label("Ieri", systemImage: "chevron.left")
                }

                Button {
                    selectedDayOffset = 0
                    now = Date()
                } label: {
                    Label("Oggi", systemImage: "calendar")
                }

                Button {
                    selectedDayOffset = 1
                } label: {
                    Label("Domani", systemImage: "chevron.right")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 19, weight: .bold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Opzioni guida")
        }
    }

    @ViewBuilder
    private func groupPillLabel(name: String, icon: String) -> some View {
        let pill = HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))

            Text(name)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(minWidth: 116, maxWidth: 238, minHeight: 44)
        .contentShape(Capsule())

        if #available(iOS 26.0, *) {
            pill.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            pill
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6)
                }
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.body)
                .foregroundStyle(.secondary)

            TextField("Cerca per nome del programma", text: $searchQuery)
                .font(.body)
                .foregroundStyle(.white)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(Color.white.opacity(0.09), in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .padding(.horizontal, bannerInset)
        .padding(.top, 10)
        .padding(.bottom, layoutDensity == .compact ? 16 : 18)
    }

    // MARK: - Gestione Dati e Riproduzione Live Istantanea a Latenza Zero

    private func playLiveStream(_ stream: XtreamStream, dismissSheetFirst: Bool) {
        if dismissSheetFirst {
            selectedProgram = nil
        }
        if let streamURL = makeLiveStreamURL(for: stream) {
            self.livePlayback = LivePlaybackItem(stream: stream, url: streamURL)
        }
    }

    private func makeLiveStreamURL(for stream: XtreamStream) -> URL? {
        let rawHost = credentials.host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let scheme = rawHost.lowercased().hasPrefix("http") ? "" : "http://"
        let fullHost = scheme.isEmpty ? rawHost : "\(scheme)\(rawHost)"
        let ext = stream.containerExtension?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "ts"
        let validExt = ext.isEmpty ? "ts" : ext
        let urlString = "\(fullHost)/live/\(credentials.username)/\(credentials.password)/\(stream.streamId).\(validExt)"
        return URL(string: urlString)
    }

    private func visiblePrograms(for stream: XtreamStream) -> [EPGProgram] {
        (programsByStream[stream.streamId] ?? []).filter {
            $0.end > windowStart && $0.start < windowEnd
        }
    }

    private static func groupIcon(for groupName: String) -> String {
        let name = groupName.lowercased()
        if name.contains("sport") { return "sportscourt" }
        if name.contains("news") || name.contains("notizie") { return "newspaper" }
        if name.contains("film") || name.contains("movie") || name.contains("cinema") { return "film" }
        if name.contains("kids") || name.contains("bambini") || name.contains("cartoon") { return "gamecontroller" }
        if name.contains("music") || name.contains("musica") { return "music.note" }
        if name.contains("document") { return "video" }
        if name.contains("relig") { return "building.columns" }
        if name.contains("adult") || name.contains("xxx") || name.contains("+18") { return "eye.slash" }
        return "tv"
    }

    private func playCatchup(program: EPGProgram, stream: XtreamStream) {
        let service = EPGService(credentials: credentials)
        let duration = max(1, Int(program.end.timeIntervalSince(program.start) / 60))
        let request = CatchupRequest(
            streamId: stream.streamId,
            start: program.start,
            durationMinutes: duration
        )

        guard let url = service.catchupURL(for: request) else {
            reminderToast = "Impossibile generare il link per la riproduzione differita."
            return
        }

        selectedProgram = nil
        catchupPlayback = CatchupPlayback(url: url, title: "\(stream.name) · \(program.title)")
    }

    @MainActor
    private func scheduleReminder(for program: EPGProgram) async {
        let granted = await ReminderService.shared.requestAuthorization()
        guard granted else {
            reminderToast = "Abilita le notifiche per ricevere promemoria."
            return
        }

        ReminderService.shared.scheduleReminder(for: program, minutesBefore: 5)
        reminderToast = "Promemoria impostato per \"\(program.title)\""
        selectedProgram = nil
    }

    private func refreshAll() async {
        await xtreamCatalog.refresh(credentials: credentials, kind: kind)
        await reloadEPG(forceRefresh: true)
    }

    private func scheduleReload(forceRefresh: Bool = false, debounced: Bool = false) {
        reloadTaskBox.task?.cancel()
        reloadTaskBox.task = Task { @MainActor in
            if debounced {
                try? await Task.sleep(nanoseconds: searchDebounceNanoseconds)
                guard !Task.isCancelled else { return }
            }
            await reloadEPG(forceRefresh: forceRefresh)
        }
    }

    @MainActor
    private func hydrateVisibleProgramsFromCache(for targetStreams: [XtreamStream]) {
        let scope = cacheScope
        for stream in targetStreams {
            guard let cached = EPGMemoryCache.shared.programs(scope: scope, streamId: stream.streamId) else {
                continue
            }
            programsByStream[stream.streamId] = cached
            failedStreamIDs.remove(stream.streamId)
        }
    }

    @MainActor
    private func reloadEPG(forceRefresh: Bool = false) async {
        loadingIndicatorTask?.cancel()

        guard !streams.isEmpty else {
            showLoadingIndicator = false
            return
        }

        let targets = streamData.paged
        guard !targets.isEmpty else {
            showLoadingIndicator = false
            return
        }

        hydrateVisibleProgramsFromCache(for: targets)

        let pending = targets.filter { stream in
            forceRefresh || programsByStream[stream.streamId] == nil
        }
        guard !pending.isEmpty else {
            showLoadingIndicator = false
            return
        }

        loadingIndicatorTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: loadingIndicatorDelayNanoseconds)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.15)) {
                showLoadingIndicator = true
            }
        }

        failedStreamIDs.subtract(Set(pending.map(\.streamId)))
        let service = EPGService(credentials: credentials)
        let scope = cacheScope

        for start in stride(from: 0, to: pending.count, by: maxConcurrentRequests) {
            guard !Task.isCancelled else { break }

            let end = min(start + maxConcurrentRequests, pending.count)
            let batch = Array(pending[start..<end])
            for stream in batch {
                loadingStreamIDs.insert(stream.streamId)
            }

            await withTaskGroup(of: (Int, Result<[EPGProgram], Error>).self) { group in
                for stream in batch {
                    group.addTask {
                        do {
                            let programs = try await service.shortEPG(
                                streamId: stream.streamId,
                                limit: shortEPGLimit,
                                forceRefresh: forceRefresh
                            )
                            return (stream.streamId, .success(programs))
                        } catch {
                            return (stream.streamId, .failure(error))
                        }
                    }
                }

                for await (streamID, result) in group {
                    loadingStreamIDs.remove(streamID)

                    switch result {
                    case .success(let programs):
                        programsByStream[streamID] = programs
                        EPGMemoryCache.shared.store(scope: scope, streamId: streamID, programs: programs)
                        if programs.isEmpty {
                            failedStreamIDs.insert(streamID)
                        } else {
                            failedStreamIDs.remove(streamID)
                        }
                    case .failure(let error):
                        failedStreamIDs.insert(streamID)
                        DebugLogger.logAsync(
                            .warning,
                            "EPG: caricamento fallito per stream \(streamID): \(error.localizedDescription)"
                        )
                    }
                }
            }
        }

        loadingIndicatorTask?.cancel()
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            showLoadingIndicator = false
        }
    }

    private func toast(_ message: String) -> some View {
        Text(message)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            }
            .padding(.top, 8)
    }

    private static func scopeKey(for credentials: XtreamCredentials) -> String {
        let host = credentials.host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        let input = "\(host)|\(credentials.username)"
        let digest = input.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)) &* UInt64(1_099_511_628_211)
        }
        return String(digest, radix: 16)
    }
}

// MARK: - Utility di Clip per l'Aspetto "Schede"

private extension View {
    /// Applica il clip della tile. Quando `isDockedUnderBanner` è `true` (tile agganciata dietro
    /// il banner, in "Schede"), il bordo sinistro non ha alcun radius proprio (squadrato): la tile
    /// riempie per intero, senza tagli ad arco, lo spazio dietro il banner — l'unico arco visibile
    /// resta quello del banner canale, che la tile attraversa completamente da dietro. In tutti gli
    /// altri casi il radius resta uniforme su tutti i lati (card libera, o "Griglie").
    @ViewBuilder
    func epgTileClip(cornerRadius: CGFloat, isDockedUnderBanner: Bool) -> some View {
        if isDockedUnderBanner {
            self.clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: cornerRadius,
                    topTrailingRadius: cornerRadius,
                    style: .continuous
                )
            )
        } else {
            self.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

// MARK: - Cache & Stores

@MainActor
private final class EPGMemoryCache {
    static let shared = EPGMemoryCache()
    private let maxEntries = 400

    private struct Entry {
        let programs: [EPGProgram]
    }

    private var storage: [String: Entry] = [:]
    private var insertionOrder: [String] = []

    private func key(scope: String, streamId: Int) -> String {
        "\(scope)#\(streamId)"
    }

    func programs(scope: String, streamId: Int) -> [EPGProgram]? {
        storage[key(scope: scope, streamId: streamId)]?.programs
    }

    func store(scope: String, streamId: Int, programs: [EPGProgram]) {
        let entryKey = key(scope: scope, streamId: streamId)

        if storage[entryKey] == nil {
            insertionOrder.append(entryKey)
        }
        storage[entryKey] = Entry(programs: programs)

        while insertionOrder.count > maxEntries {
            let oldestKey = insertionOrder.removeFirst()
            storage.removeValue(forKey: oldestKey)
        }
    }
}

private final class EPGFavoritesStore: ObservableObject {
    @Published private(set) var favoriteStreamIDs: Set<Int>
    private let key: String

    init(scopeKey: String) {
        key = "gassplayer.epgFavorites.\(scopeKey)"
        favoriteStreamIDs = Set(UserDefaults.standard.array(forKey: key) as? [Int] ?? [])
    }

    func isFavorite(_ streamID: Int) -> Bool {
        favoriteStreamIDs.contains(streamID)
    }

    func toggle(_ streamID: Int) {
        if favoriteStreamIDs.contains(streamID) {
            favoriteStreamIDs.remove(streamID)
        } else {
            favoriteStreamIDs.insert(streamID)
        }
        UserDefaults.standard.set(Array(favoriteStreamIDs).sorted(), forKey: key)
    }
}

// MARK: - Dettaglio Programma

private struct ProgramDetailSheet: View {
    let program: EPGProgram
    let stream: XtreamStream
    let isCurrentlyLive: Bool
    let onPlayLive: () -> Void
    let onPlayCatchup: () -> Void
    let onSetReminder: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var isFuture: Bool {
        program.start > Date()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(stream.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(program.title)
                            .font(.title3.weight(.bold))

                        Label(
                            "\(program.start.formatted(date: .abbreviated, time: .shortened)) – \(program.end.formatted(date: .omitted, time: .shortened))",
                            systemImage: "clock"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                        if isCurrentlyLive {
                            Label("In onda ora", systemImage: "dot.radiowaves.left.and.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.red)
                        }

                        if let description = program.description, !description.isEmpty {
                            Text(description)
                                .font(.body)
                                .padding(.top, 4)
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    VStack(spacing: 10) {
                        if isCurrentlyLive {
                            Button(action: onPlayLive) {
                                Label("Guarda in diretta", systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.borderedProminent)
                        } else if program.hasArchive {
                            Button(action: onPlayCatchup) {
                                Label("Riproduci differita", systemImage: "gobackward")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        if isFuture {
                            Button(action: onSetReminder) {
                                Label("Imposta promemoria", systemImage: "bell")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Dettaglio programma")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Chiudi") { dismiss() }
                }
            }
        }
    }
}
