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

/// EPG touch-first ultra-ottimizzata con supporto dinamico per layout "Compatta" e "Comoda":
/// - Risolto il routing di riproduzione live in modo universale: quando invocato sia da ChannelGridView che da Home,
///   invoca `onPlayLive(stream)` e contestualmente attiva il fallback locale `livePlayback` se la closure esterna è no-op.
/// - Risolta la collisione modale / crash su "Guarda in diretta" nel dettaglio programma chiudendo in sicurezza la sheet
///   prima di innescare la riproduzione full-screen (evitando il tentato overlap simultaneo di presentation context UIKit/SwiftUI).
/// - Viste "Compatta" e "Comoda" con colori pastello adattivi, loghi originali e allineamento perfetto.
struct EPGGridView: View {
    let credentials: XtreamCredentials
    let kind: XtreamStreamKind
    var onPlayLive: (XtreamStream) -> Void = { _ in }

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

    /// Larghezza della colonna fissa laterale
    private var bannerColumnWidth: CGFloat {
        bannerInset + channelBannerWidth + bannerInset
    }

    private var bannerContentWidth: CGFloat {
        bannerColumnWidth - (bannerInset * 2)
    }

    /// Finestra temporale: 30 minuti passati, 3 ore future.
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
        onPlayLive: @escaping (XtreamStream) -> Void = { _ in }
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
        scheduleReload()
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
        Self.scopeKey(for: credentials)
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
                    scheduleReload()
                }
                .onChange(of: currentStreamData.identity) { _, _ in
                    scheduleReload()
                }
                .onChange(of: searchQuery) { _, _ in
                    renderLimit = renderPageSize
                    scheduleReload(debounced: true)
                }
                .onChange(of: showFavoritesOnly) { _, _ in
                    renderLimit = renderPageSize
                    scheduleReload()
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
                    scheduleReload()
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

    // MARK: - Righe Canali e Tile Programmi

    private func timelineRow(for stream: XtreamStream) -> some View {
        let programs = visiblePrograms(for: stream)

        return ZStack(alignment: .leading) {
            if programs.isEmpty {
                unavailableBlock(for: stream)
            } else {
                ForEach(Array(programs.enumerated()), id: \.element.id) { index, program in
                    let nextStart = index + 1 < programs.count ? programs[index + 1].start : nil
                    programBlock(program, stream: stream, nextProgramStart: nextStart)
                }
            }
        }
        .frame(width: canvasWidth, height: rowHeight, alignment: .leading)
        .clipped()
    }

    /// Banner Canale Adattivo (Compatta vs Comoda)
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
            .frame(width: bannerColumnWidth, height: rowHeight, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Guarda \(stream.name) in diretta")
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

    /// Tile del programma con supporto completo alle modalità Compatta e Comoda
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

        let width = max(32, endX - startX)
        let cornerRadius: CGFloat = layoutDensity == .compact ? 12 : 18

        return GeometryReader { geo in
            let frameInViewport = geo.frame(in: .named("epgViewportCoordinateSpace"))
            let tileMinX = frameInViewport.minX

            let overlap = max(0, bannerColumnWidth - tileMinX)
            let maxSticky = max(0, width - (layoutDensity == .compact ? 120 : 130))
            let stickyX = min(overlap, maxSticky)

            let transitionProgress = max(0, min(1, (overlap - maxSticky) / 30))
            let nameSlideOffset = stickyX
            let timeEntranceOpacity = max(0.2, 1.0 - Double(transitionProgress))

            Button {
                selectedProgram = SelectedProgram(program: program, stream: stream)
            } label: {
                Group {
                    if layoutDensity == .compact {
                        // MARK: Vista Compatta (Allineamento centrato verticale)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(stream.name)
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)

                                Text(program.start.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.60))
                                    .lineLimit(1)
                                    .opacity(timeEntranceOpacity)
                            }

                            Text(program.title)
                                .font(.system(size: 14, weight: .regular, design: .rounded))
                                .foregroundStyle(.white.opacity(0.92))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.horizontal, 10)
                        .offset(x: nameSlideOffset)
                        .frame(width: width, height: blockHeight, alignment: .leading)
                    } else {
                        // MARK: Vista Comoda (Layout a 3 righe ampie)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(stream.name)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.70))
                                .lineLimit(1)

                            Text(program.start.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                                .opacity(timeEntranceOpacity)

                            Text(program.title)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .offset(x: stickyX)
                        .frame(width: width, height: blockHeight, alignment: .topLeading)
                    }
                }
            }
            .buttonStyle(.plain)
            .background {
                programTileBackground(
                    stream: stream,
                    program: program,
                    tileStartX: startX,
                    tileWidth: width
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .frame(width: width, height: blockHeight)
        .offset(x: startX)
        .accessibilityLabel(
            "\(stream.name), \(program.title), dalle \(program.start.formatted(date: .omitted, time: .shortened)) alle \(program.end.formatted(date: .omitted, time: .shortened))"
        )
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
            scheduleReload()
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
            .padding(16)
        }
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
                // MARK: Voce specifica ASPETTO EPG
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
                    scheduleReload()
                } label: {
                    Label("Ieri", systemImage: "chevron.left")
                }

                Button {
                    selectedDayOffset = 0
                    now = Date()
                    scheduleReload()
                } label: {
                    Label("Oggi", systemImage: "calendar")
                }

                Button {
                    selectedDayOffset = 1
                    scheduleReload()
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

    // MARK: - Gestione Dati e Riproduzione Live Istantanea (A prova di crash e collisioni modali)

    /// Avvia la riproduzione live del canale a latenza zero sia se richiamata dalla Home sia da ChannelGridView.
    private func playLiveStream(_ stream: XtreamStream, dismissSheetFirst: Bool) {
        if dismissSheetFirst {
            selectedProgram = nil
        }

        // 1. Invocazione callback esterna (gestione Home / parent coordinator)
        onPlayLive(stream)

        // 2. Apertura del player locale istantaneo
        if let streamURL = makeLiveStreamURL(for: stream) {
            if dismissSheetFirst {
                // Piccolo defer dispatch per consentire a SwiftUI / UIKit di completare la dismissione della sheet prima di presentare il fullScreenCover
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    self.livePlayback = LivePlaybackItem(stream: stream, url: streamURL)
                }
            } else {
                self.livePlayback = LivePlaybackItem(stream: stream, url: streamURL)
            }
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
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            self.catchupPlayback = CatchupPlayback(url: url, title: "\(stream.name) · \(program.title)")
        }
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
                    guard !Task.isCancelled else { continue }
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

    // MARK: - Dettaglio Programma (Anti-Crash e Chiusura Protetta)

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
                                Button {
                                    dismiss()
                                    onPlayLive()
                                } label: {
                                    Label("Guarda in diretta", systemImage: "play.fill")
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                }
                                .buttonStyle(.borderedProminent)
                            } else if program.hasArchive {
                                Button {
                                    dismiss()
                                    onPlayCatchup()
                                } label: {
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
                        .padding()
                    }
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
}
