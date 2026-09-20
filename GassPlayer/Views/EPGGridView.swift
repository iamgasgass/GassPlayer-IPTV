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

/// EPG touch-first ultra-ottimizzata con riproduzione nativa immediata a latenza zero:
/// - Avvio streaming istantaneo su banner canale: elimina ogni ritardo, dispatch o transizione modale ridondante.
/// - Il tocco sul banner canale attiva direttamente `livePlayback` (`AdaptivePlayerView`) a latenza zero, esattamente come in EPG da Home.
/// - Supporto per entrambe le densità di layout: "Compatta" (rowHeight 66, banner 80x58) e "Comoda" (rowHeight 96, banner 86x76).
/// - Colori pastello adattivi, avanzamento live coordinato e voce di menu dedicata "Aspetto EPG".
///
/// AGGIORNAMENTO 2026-09-20 (REPLICA MANIACALE AL 100% FEDELE AL VIDEO):
/// 1) NOME CANALE UNICO PER RIGA: il nome del canale e il relativo badge qualità non
///    sono più duplicati all'interno di ogni singola tile di programma. Una riga intera
///    mostra UN SOLO nome canale (overlay ancorato alla riga con z-index elevato), che resta
///    costantemente visibile agganciato al bordo della colonna fissa del banner laterale.
///    Durante lo scroll orizzontale, il nome canale galleggia fluidamente sopra le tile e
///    attraversa progressivamente i gap tra una tile e l'altra senza mai sparire o spezzarsi.
/// 2) TRANSIZIONE E ANIMAZIONE ORARI VECCHI/NUOVI (REPLICA FEDELE AL VIDEO):
///    - Ogni tile programma possiede il proprio orario di inizio (`program.start`), allineato a sinistra.
///    - Quando si scorre verso destra (la tile corrente scivola verso sinistra sotto il banner),
///      l'orario della tile corrente NON è sticky: rimane solidale con la tile e viene
///      progressivamente coperto e ritagliato dal bordo sinistro della tile stessa (clipShape).
///    - Sincronizzatamente, quando la tile successiva entra in vista avvicinandosi al banner,
///      il suo orario di inizio appare naturalmente a destra del nome canale galleggiante.
///    - Quando la tile corrente esce completamente e termina, il nome canale continua a
///      galleggiare in posizione ferma sopra la nuova tile, con una transizione perfettamente
///      continua e liscia al 100%.
///
/// FIX 2026-09-20 (regressione "Dati non disponibili"):
/// - Parametri di tempo, TTL, concorrenza e architettura rimangono INVARIATI al 100%.
struct EPGGridView: View {
    let credentials: XtreamCredentials
    let kind: XtreamStreamKind
    var onPlayLive: ((XtreamStream) -> Void)? = nil

    @EnvironmentObject private var xtreamCatalog: XtreamCatalogStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var favorites: EPGFavoritesStore

    @AppStorage("epg_layout_density") private var layoutDensity: EPGLayoutDensity = .compact

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

    /// Intercapedine visibile tra due tile di programma consecutivi nella stessa riga
    private let tileHorizontalGap: CGFloat = 4

    /// Larghezza della colonna fissa laterale
    private var bannerColumnWidth: CGFloat {
        bannerInset + channelBannerWidth + bannerInset
    }

    private var bannerContentWidth: CGFloat {
        bannerColumnWidth - (bannerInset * 2)
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

    /// Genera in modo deterministico e fluido il colore primario pastello per il canale
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
        guard !base.isEmpty else {
            return (trimmed, nil)
        }

        return (base, upperCandidate)
    }

    // MARK: - Sorgenti Dati Centralizzate

    private var streams: [XtreamStream] {
        xtreamCatalog.streams(for: kind)
    }

    private var liveCategories: [XtreamCategory] {
        xtreamCatalog.categories(for: .live)
    }

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

            if pagedStreams.isEmpty {
                Color.clear.frame(width: bannerColumnWidth, height: 1)
            } else {
                ForEach(pagedStreams) { stream in
                    channelBanner(stream)
                }
            }
        }
        .background(Color.black)
    }

    /// Header orari su Canvas con disegno immediato e freccia live allineata
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

    // MARK: - Righe Canali, Tile Programmi e Nome Canale Galleggiante

    private func timelineRow(for stream: XtreamStream) -> some View {
        let programs = visiblePrograms(for: stream)

        return ZStack(alignment: .leading) {
            if programs.isEmpty {
                unavailableBlock(for: stream)
            } else {
                // 1) Griglia tile dei programmi: sfondo, titolo del programma e orario proprio
                ForEach(Array(programs.enumerated()), id: \.element.id) { index, program in
                    let nextStart = index + 1 < programs.count ? programs[index + 1].start : nil
                    programBlock(program, stream: stream, nextProgramStart: nextStart)
                }

                // 2) NOME CANALE UNICO PER RIGA (OVERLAY STICKY FLUIDO):
                // compare una sola volta all'altezza della riga corrente, resta fermo
                // agganciato al margine sinistro del banner laterale durante lo scroll
                // e attraversa fluidamente le tile e i relativi gap con zIndex superiore.
                stickyChannelNameOverlay(for: stream, programs: programs)
                    .zIndex(5)
            }
        }
        .frame(width: canvasWidth, height: rowHeight, alignment: .leading)
        .clipped()
    }

    /// Overlay del nome canale unico per la riga:
    /// Calcola la posizione del blocco programmi visibile nella riga per ancorarsi al bordo
    /// sinistro visibile (`bannerColumnWidth`) e rimanere fluido e visibile al 100%.
    private func stickyChannelNameOverlay(
        for stream: XtreamStream,
        programs: [EPGProgram]
    ) -> some View {
        guard let first = programs.first, let last = programs.last else {
            return AnyView(EmptyView())
        }

        let firstStartX = xCoordinate(for: max(first.start, windowStart))
        let lastEndX = xCoordinate(for: min(last.end, windowEnd))
        let rowSpanWidth = max(0, lastEndX - firstStartX)

        let nameParts = Self.splitNameAndQualityBadge(stream.name)
        let cornerRadius: CGFloat = layoutDensity == .compact ? 12 : 18

        return GeometryReader { geo in
            let frameInViewport = geo.frame(in: .named("epgViewportCoordinateSpace"))
            let rowMinX = frameInViewport.minX

            // Distanza tra il bordo del banner fisso e l'inizio della riga in coordinate canvas
            let overlap = max(0, bannerColumnWidth - rowMinX)
            let maxSticky = max(0, rowSpanWidth - 60)
            let stickyX = min(overlap, maxSticky)

            HStack(spacing: 6) {
                Text(nameParts.name)
                    .font(.system(
                        size: layoutDensity == .compact ? 13 : 11,
                        weight: .semibold,
                        design: .rounded
                    ))
                    .foregroundStyle(.white.opacity(layoutDensity == .compact ? 1.0 : 0.70))
                    .lineLimit(1)

                if let badge = nameParts.badge {
                    qualityBadge(badge, fontSize: layoutDensity == .compact ? 11 : 10)
                }
            }
            .padding(.horizontal, layoutDensity == .compact ? 10 : 13)
            .padding(.top, layoutDensity == .compact ? 8 : 8)
            .offset(x: stickyX)
            .allowsHitTesting(false) // I tocchi passano sotto alle tile dei programmi
        }
        .frame(width: rowSpanWidth, height: blockHeight, alignment: .topLeading)
        .offset(x: firstStartX)
    }

    /// Banner Canale Adattivo con avvio immediato a latenza zero
    private func channelBanner(_ stream: XtreamStream) -> some View {
        let channelColor = Self.adaptivePastelColor(for: stream)
        let cornerRadius: CGFloat = layoutDensity == .compact ? 14 : 16

        return Button {
            playLiveStream(stream, dismissSheetFirst: false)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
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
            .frame(width: bannerColumnWidth, height: rowHeight, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Guarda \(stream.name) in diretta")
    }

    /// Vero se lo stream ha in questo momento (o nella finestra visibile) almeno un programma con catchup
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

    private func unavailableBlock(for stream: XtreamStream) -> some View {
        let loading = loadingStreamIDs.contains(stream.streamId)
        let failed = failedStreamIDs.contains(stream.streamId)
        let channelColor = Self.adaptivePastelColor(for: stream)
        let cornerRadius: CGFloat = layoutDensity == .compact ? 12 : 18

        return HStack(spacing: 6) {
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
        .padding(.horizontal, layoutDensity == .compact ? 14 : 18)
        .frame(height: blockHeight)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(white: 0.10))
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(channelColor.opacity(0.12))
            }
        }
        .frame(width: canvasWidth, height: rowHeight, alignment: .leading)
    }

    /// Tile del programma:
    /// - Gestisce la larghezza e lo sfondo della singola trasmissione
    /// - Mostra l'orario proprio della trasmissione e il titolo del programma
    /// - L'orario e il titolo sono solidali con la tile e vengono progressivamente coperti
    ///   dal bordo arrotondato della tile stessa durante lo scorrimento verso destra,
    ///   esattamente identico al video di riferimento.
    private func programBlock(
        _ program: EPGProgram,
        stream: XtreamStream,
        nextProgramStart: Date?
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

        let totalWidth = max(32, endX - startX)
        let tileVisualWidth = max(0, totalWidth - tileHorizontalGap)
        let cornerRadius: CGFloat = layoutDensity == .compact ? 12 : 18

        return GeometryReader { geo in
            let frameInViewport = geo.frame(in: .named("epgViewportCoordinateSpace"))
            let tileMinX = frameInViewport.minX

            // Calcolo del ritaglio e dell'animazione del titolo programma:
            // il titolo programma si sposta leggermente per restare leggibile
            // mentre l'orario scorre verso sinistra venendo coperto dal bordo.
            let overlap = max(0, bannerColumnWidth - tileMinX)
            let maxSticky = max(0, tileVisualWidth - 60)
            let titleStickyX = min(overlap, maxSticky)

            Button {
                selectedProgram = SelectedProgram(program: program, stream: stream)
            } label: {
                Group {
                    if layoutDensity == .compact {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                // Spazio riservato al nome canale galleggiante (trasparente qui)
                                Spacer(minLength: 0)
                                    .frame(width: 2)

                                // Orario proprio del programma: solidale con la tile, scorre a sinistra
                                // e viene coperto progressivamente dal bordo della tile
                                Text(program.start.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.60))
                                    .lineLimit(1)
                            }

                            Text(program.title)
                                .font(.system(size: 14, weight: .regular, design: .rounded))
                                .foregroundStyle(.white.opacity(0.92))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .offset(x: titleStickyX)
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .frame(width: tileVisualWidth, height: blockHeight, alignment: .topLeading)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Spacer(minLength: 0)
                                    .frame(width: 2)

                                Text(program.start.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .lineLimit(1)
                            }

                            Text(program.title)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .offset(x: titleStickyX)

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .frame(width: tileVisualWidth, height: blockHeight, alignment: .topLeading)
                    }
                }
            }
            .buttonStyle(.plain)
            .background {
                programTileBackground(
                    stream: stream,
                    program: program,
                    tileStartX: startX,
                    tileWidth: tileVisualWidth
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .frame(width: totalWidth, height: blockHeight)
        .offset(x: startX)
        .accessibilityLabel(
            "\(stream.name), \(program.title), dalle \(program.start.formatted(date: .omitted, time: .shortened)) alle \(program.end.formatted(date: .omitted, time: .shortened))"
        )
    }

    /// Pillola badge qualità (es. "FHD", "HD", "SD", "4K")
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

    /// Background adattivo della tile
    @ViewBuilder
    private func programTileBackground(
        stream: XtreamStream,
        program: EPGProgram,
        tileStartX: CGFloat,
        tileWidth: CGFloat
    ) -> some View {
        let channelColor = Self.adaptivePastelColor(for: stream)
        let brightWidth = isToday ? min(max(liveAxisX - tileStartX, 0), tileWidth) : 0
        let cornerRadius: CGFloat = layoutDensity == .compact ? 12 : 18

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(white: 0.10))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(channelColor.opacity(layoutDensity == .compact ? 0.18 : 0.22))

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

    // MARK: - Cache & Stores

    @MainActor
    private final class EPGMemoryCache {
        static let shared = EPGMemoryCache()

        private struct Entry {
            let programs: [EPGProgram]
        }

        private var storage: [String: Entry] = [:]

        private func key(scope: String, streamId: Int) -> String {
            "\(scope)#\(streamId)"
        }

        func programs(scope: String, streamId: Int) -> [EPGProgram]? {
            storage[key(scope: scope, streamId: streamId)]?.programs
        }

        func store(scope: String, streamId: Int, programs: [EPGProgram]) {
            storage[key(scope: scope, streamId: streamId)] = Entry(programs: programs)
        }
    }

    @MainActor
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
