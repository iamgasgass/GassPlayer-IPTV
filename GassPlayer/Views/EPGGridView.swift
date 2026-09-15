import SwiftUI

/// EPG touch-first con geometria a coordinata temporale fissa: il cursore
/// live (ora + freccia in giu') resta ancorato nel layout, mentre la timeline
/// e le tile avanzano progressivamente verso sinistra sotto quell'asse.
/// La colonna banner e l'inizio della timeline sono coordinate esplicite e
/// condivise, cosi' logo e prima tile iniziano sempre nello stesso punto.
struct EPGGridView: View {
    let credentials: XtreamCredentials
    let kind: XtreamStreamKind
    var onPlayLive: (XtreamStream) -> Void = { _ in }

    @EnvironmentObject private var xtreamCatalog: XtreamCatalogStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var favorites: EPGFavoritesStore

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
    @State private var renderLimit = 12
    @State private var reloadTaskBox = TaskBox()
    @State private var didAppear = false

    private let renderPageSize = 12
    private let hardRenderCap = 72
    private let maxConcurrentRequests = 8
    private let shortEPGLimit = 24
    private let searchDebounceNanoseconds: UInt64 = 250_000_000
    private let loadingIndicatorDelayNanoseconds: UInt64 = 300_000_000

    // Layout reference geometry: shared x-boundaries for banners and timeline.
    private let horizontalLayoutInset: CGFloat = 16
    private let channelColumnWidth: CGFloat = 86
    private let channelColumnGap: CGFloat = 12
    private let rowHeight: CGFloat = 96
    private let bannerHeight: CGFloat = 76
    private let blockHeight: CGFloat = 82
    private let timelineTopInset: CGFloat = 6
    private let pixelsPerMinute: CGFloat = 1.85
    private let minimumProgramBlockWidth: CGFloat = 46
    private let liveAnchorRatio: CGFloat = 0.26

    // Time window: content travels from right to left under a fixed live axis.
    private let pastWindow: TimeInterval = 45 * 60
    private let futureWindow: TimeInterval = 135 * 60

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

    // MARK: - Sources

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

    /// Playlist order is intentionally preserved for both "Tutti" and groups.
    private var groupsWithCounts: (groups: [XtreamCategory], counts: [String: Int]) {
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

        let categoryByID = Dictionary(uniqueKeysWithValues: liveCategories.map { ($0.categoryId, $0) })
        return (orderedIDs.compactMap { categoryByID[$0] }, counts)
    }

    private var selectedGroupName: String {
        guard let groupID = normalizedSelectedGroupID else { return "Tutti" }
        return groupsWithCounts.groups.first(where: { $0.categoryId == groupID })?.categoryName ?? "Gruppo"
    }

    private var selectedGroupSystemImage: String {
        guard let groupID = normalizedSelectedGroupID,
              let group = groupsWithCounts.groups.first(where: { $0.categoryId == groupID }) else {
            return "square.grid.2x2"
        }
        return Self.groupIcon(for: group.categoryName)
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

    private var filteredStreams: [XtreamStream] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupID = normalizedSelectedGroupID

        guard !query.isEmpty || groupID != nil || showFavoritesOnly else {
            return streams
        }

        return streams.filter { stream in
            let categoryID = stream.categoryId?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let groupID, categoryID != groupID { return false }
            if showFavoritesOnly && !favorites.isFavorite(stream.streamId) { return false }
            if !query.isEmpty && !stream.name.localizedCaseInsensitiveContains(query) { return false }
            return true
        }
    }

    private var pagedStreams: [XtreamStream] {
        Array(filteredStreams.prefix(min(max(renderLimit, 0), hardRenderCap)))
    }

    private var canLoadMore: Bool {
        renderLimit < min(filteredStreams.count, hardRenderCap)
    }

    private var remainingCount: Int {
        max(0, min(filteredStreams.count, hardRenderCap) - renderLimit)
    }

    private var cacheScope: String {
        Self.scopeKey(for: credentials)
    }

    private var streamIdentity: String {
        let ids = pagedStreams.map(\.streamId).map(String.init).joined(separator: ",")
        return "\(normalizedSelectedGroupID ?? "all")|\(selectedDayOffset)|\(ids)"
    }

    // MARK: - Time geometry

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

    private var windowDuration: TimeInterval {
        windowEnd.timeIntervalSince(windowStart)
    }

    private var timelineWidth: CGFloat {
        CGFloat(windowDuration / 60) * pixelsPerMinute
    }

    private var displayedTimeLabel: String {
        isToday ? now.formatted(date: .omitted, time: .shortened) : "12:00"
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
        NavigationStack {
            content
                .background(Color.black.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .sheet(item: $selectedProgram) { selection in
                    ProgramDetailSheet(
                        program: selection.program,
                        stream: selection.stream,
                        isCurrentlyLive: selection.program.isCurrent(at: now),
                        onPlayLive: {
                            selectedProgram = nil
                            onPlayLive(selection.stream)
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
        }
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            hydrateVisibleProgramsFromCache()
            scheduleReload()
        }
        .onChange(of: streams.map(\.streamId)) { _, _ in
            if pagedStreams.isEmpty {
                renderLimit = min(renderPageSize, max(streams.count, 1))
            }
            hydrateVisibleProgramsFromCache()
            scheduleReload()
        }
        .onChange(of: streamIdentity) { _, _ in
            hydrateVisibleProgramsFromCache()
            scheduleReload()
        }
        .onChange(of: searchQuery) { _, _ in
            renderLimit = renderPageSize
            hydrateVisibleProgramsFromCache()
            scheduleReload(debounced: true)
        }
        .onChange(of: showFavoritesOnly) { _, _ in
            renderLimit = renderPageSize
            hydrateVisibleProgramsFromCache()
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

    @ViewBuilder
    private var content: some View {
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
                    dayTimeHeader

                    if pagedStreams.isEmpty {
                        ContentUnavailableView(
                            "Nessun canale trovato",
                            systemImage: "magnifyingglass",
                            description: Text("Modifica ricerca, preferiti o gruppo playlist.")
                        )
                        .foregroundStyle(.white)
                        .padding(.top, 40)
                    } else {
                        epgGrid

                        if canLoadMore {
                            loadMoreButton
                        }
                    }
                }
                .padding(.bottom, 32)
            }
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

    /// The fixed live anchor is resolved from real available width. The clock
    /// and arrow remain fixed at that coordinate; timeline content is shifted
    /// by the same amount so programs move beneath the marker as time changes.
    private var epgGrid: some View {
        GeometryReader { proxy in
            let availableTimelineWidth = max(
                1,
                proxy.size.width - horizontalLayoutInset * 2 - channelColumnWidth - channelColumnGap
            )
            let fixedLiveX = availableTimelineWidth * liveAnchorRatio
            let contentOriginX = fixedLiveX - CGFloat(pastWindow / 60) * pixelsPerMinute
            let totalContentWidth = max(
                availableTimelineWidth - contentOriginX,
                timelineWidth
            )

            HStack(alignment: .top, spacing: channelColumnGap) {
                LazyVStack(spacing: 0) {
                    ForEach(pagedStreams) { stream in
                        channelBanner(stream)
                            .frame(width: channelColumnWidth, height: rowHeight)
                    }
                }

                ZStack(alignment: .topLeading) {
                    // Fixed marker in the viewport: it never moves with time.
                    if isToday {
                        liveTimelineMarker
                            .offset(x: fixedLiveX - 15, y: -2)
                            .zIndex(3)
                    }

                    // Timeline content changes origin as current time advances.
                    LazyVStack(spacing: 0) {
                        ForEach(pagedStreams) { stream in
                            timelineRow(
                                for: stream,
                                canvasWidth: totalContentWidth,
                                contentOriginX: contentOriginX
                            )
                            .task(id: stream.streamId) {
                                await loadProgramsIfNeeded(for: stream)
                            }
                        }
                    }
                    .offset(x: contentOriginX)
                }
                .frame(width: availableTimelineWidth, alignment: .leading)
                .clipped()
            }
            .padding(.horizontal, horizontalLayoutInset)
        }
        .frame(height: CGFloat(pagedStreams.count) * rowHeight)
    }

    // MARK: - Toolbar Liquid Glass

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Indietro")
        }

        ToolbarItem(placement: .principal) {
            Menu {
                let data = groupsWithCounts
                Picker("Gruppo playlist", selection: groupSelectionBinding) {
                    Label("Tutti i canali", systemImage: "square.grid.2x2")
                        .tag(String?.none)

                    if !data.groups.isEmpty {
                        Divider()
                        ForEach(data.groups) { group in
                            Label(
                                "\(group.categoryName) (\(data.counts[group.categoryId] ?? 0))",
                                systemImage: Self.groupIcon(for: group.categoryName)
                            )
                            .tag(Optional(group.categoryId))
                        }
                    }
                }
                .pickerStyle(.inline)
            } label: {
                groupPillLabel
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel("Gruppo playlist: \(selectedGroupName)")
            .accessibilityHint("Tocca per scegliere il gruppo da visualizzare")
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    reminderToast = "Aggiornamento guida in corso…"
                    Task { await refreshAll() }
                } label: {
                    Label("Aggiorna guida", systemImage: "arrow.clockwise")
                }

                Button {
                    withAnimation(.snappy) { showFavoritesOnly.toggle() }
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
    private var groupPillLabel: some View {
        let pill = HStack(spacing: 8) {
            Image(systemName: selectedGroupSystemImage)
                .font(.system(size: 16, weight: .semibold))

            Text(selectedGroupName)
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
                Button { searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(Color.white.opacity(0.09), in: Capsule())
        .overlay { Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1) }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    /// "Oggi" and the fixed live time remain in their dedicated header area.
    /// The arrow is the fixed reference; only EPG content below advances.
    private var dayTimeHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                selectedDayOffset = max(selectedDayOffset - 1, -7)
                scheduleReload()
            } label: {
                Text(dayTitle)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            if isToday {
                HStack(spacing: 4) {
                    Text(displayedTimeLabel)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Image(systemName: "arrowtriangle.down.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Ora corrente \(displayedTimeLabel)")
            }

            Spacer()

            Button {
                selectedDayOffset = min(selectedDayOffset + 1, 7)
                scheduleReload()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    /// The same clock + down arrow is placed at the invariant visual x-axis
    /// over the EPG viewport. It is intentionally independent from timeline
    /// content so it remains stationary while tiles progress under it.
    private var liveTimelineMarker: some View {
        VStack(spacing: 2) {
            Text(displayedTimeLabel)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .fixedSize()
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .white.opacity(0.75), radius: 3)
        }
        .frame(width: 30, alignment: .center)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func timelineRow(
        for stream: XtreamStream,
        canvasWidth: CGFloat,
        contentOriginX: CGFloat
    ) -> some View {
        let programs = visiblePrograms(for: stream)

        return ZStack(alignment: .leading) {
            if programs.isEmpty {
                unavailableBlock(for: stream, width: canvasWidth)
            } else {
                ForEach(programs) { program in
                    programBlock(
                        program,
                        stream: stream,
                        contentOriginX: contentOriginX
                    )
                }
            }
        }
        .frame(width: canvasWidth, height: rowHeight, alignment: .leading)
        .clipped()
    }

    /// Banner geometry uses the fixed 86pt column and 76pt height, vertically
    /// centered in its 96pt row. Its leading/trailing edges therefore match
    /// every row exactly, and the timeline begins after one shared 12pt gap.
    private func channelBanner(_ stream: XtreamStream) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(logoBackgroundColor(for: stream))

            AsyncImage(url: URL(string: stream.streamIcon ?? "")) { phase in
                if case .success(let image) = phase {
                    image
                        .resizable()
                        .scaledToFit()
                        .padding(12)
                } else {
                    Image(systemName: "tv")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }

            if favorites.isFavorite(stream.streamId) {
                Image(systemName: "star.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.yellow)
                    .padding(5)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(width: channelColumnWidth, height: bannerHeight)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onPlayLive(stream) }
        .accessibilityLabel("Guarda \(stream.name) in diretta")
    }

    private func unavailableBlock(for stream: XtreamStream, width: CGFloat) -> some View {
        let loading = loadingStreamIDs.contains(stream.streamId)
        let failed = failedStreamIDs.contains(stream.streamId)

        return HStack(spacing: 7) {
            if loading {
                ProgressView().tint(.white).controlSize(.small)
                Text("Caricamento EPG")
            } else if failed {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("EPG non disponibile")
            } else {
                Image(systemName: "calendar.badge.exclamationmark")
                Text("Dati non disponibili")
            }
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 18)
        .frame(width: width, height: rowHeight, alignment: .leading)
    }

    /// Tile width remains purely temporal. `contentOriginX` converts every
    /// program's absolute time coordinate into the fixed-anchor canvas; the
    /// result makes the tile stream progress leftward under the live marker.
    private func programBlock(
        _ program: EPGProgram,
        stream: XtreamStream,
        contentOriginX: CGFloat
    ) -> some View {
        let clippedStart = max(program.start, windowStart)
        let clippedEnd = min(program.end, windowEnd)
        let startMinutes = max(0, clippedStart.timeIntervalSince(windowStart) / 60)
        let durationMinutes = max(1, clippedEnd.timeIntervalSince(clippedStart) / 60)
        let width = max(minimumProgramBlockWidth, CGFloat(durationMinutes) * pixelsPerMinute)
        let startX = CGFloat(startMinutes) * pixelsPerMinute
        let liveCutInTile = isToday ? min(max(-contentOriginX - startX + liveAnchorLocalOffset, 0), width) : width

        return Button {
            selectedProgram = SelectedProgram(program: program, stream: stream)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(program.start.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(1)

                Text(program.title)
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(1.0)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(width: width, height: blockHeight, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .background {
            programTileBackground(
                stream: stream,
                program: program,
                brightWidth: liveCutInTile
            )
        }
        .offset(x: startX, y: timelineTopInset)
        .accessibilityLabel(
            "\(program.title), dalle \(program.start.formatted(date: .omitted, time: .shortened)) alle \(program.end.formatted(date: .omitted, time: .shortened))"
        )
    }

    /// In the local canvas generated by `timelineRow`, fixedLiveX is restored
    /// by `contentOriginX`; this term resolves to the exact live x position
    /// relative to the tile. Keeping the calculation centralized prevents
    /// visual drift between the marker and the bright/blurred transition.
    private var liveAnchorLocalOffset: CGFloat {
        CGFloat(pastWindow / 60) * pixelsPerMinute
    }

    /// Future/right side: muted frosted blur. Past/left side: dense saturated
    /// color. The cut occurs at `brightWidth`, which maps to the stationary
    /// live arrow in the visible viewport.
    @ViewBuilder
    private func programTileBackground(
        stream: XtreamStream,
        program: EPGProgram,
        brightWidth: CGFloat
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let base = programColor(for: stream, program: program)

        ZStack(alignment: .leading) {
            shape.fill(base.opacity(0.22))

            shape
                .fill(
                    LinearGradient(
                        colors: [base.opacity(0.38), base.opacity(0.16), Color.black.opacity(0.28)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .blur(radius: 12)
                .opacity(0.88)

            shape.fill(
                LinearGradient(
                    colors: [Color.black.opacity(0.02), Color.black.opacity(0.48)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )

            if brightWidth > 0 {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [base.opacity(1.0), base.opacity(0.92)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: brightWidth)
                    .overlay(alignment: .trailing) {
                        LinearGradient(
                            colors: [base.opacity(0.92), base.opacity(0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 14)
                        .offset(x: 14)
                    }
            }
        }
        .clipShape(shape)
    }

    private var loadMoreButton: some View {
        Button {
            let newLimit = min(renderLimit + renderPageSize, min(filteredStreams.count, hardRenderCap))
            guard newLimit != renderLimit else { return }
            renderLimit = newLimit
            scheduleReload()
        } label: {
            Label(
                "Carica altri \(min(renderPageSize, remainingCount)) canali",
                systemImage: "arrow.down.circle"
            )
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .foregroundStyle(.white)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(16)
    }

    private func logoBackgroundColor(for stream: XtreamStream) -> Color {
        paletteColor(seed: stream.streamId, saturation: 0.34, brightness: 0.78)
    }

    private func programColor(for stream: XtreamStream, program: EPGProgram) -> Color {
        let seed = stream.streamId ^ Int(program.start.timeIntervalSince1970)
        return paletteColor(seed: seed, saturation: 0.48, brightness: 0.30)
    }

    private func paletteColor(seed: Int, saturation: Double, brightness: Double) -> Color {
        let normalized = abs(seed % 360)
        return Color(hue: Double(normalized) / 360.0, saturation: saturation, brightness: brightness)
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
        let request = CatchupRequest(streamId: stream.streamId, start: program.start, durationMinutes: duration)

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
    private func hydrateVisibleProgramsFromCache() {
        let scope = cacheScope
        for stream in pagedStreams {
            guard let cached = EPGMemoryCache.shared.programs(scope: scope, streamId: stream.streamId) else {
                continue
            }
            programsByStream[stream.streamId] = cached
            failedStreamIDs.remove(stream.streamId)
        }
    }

    private func loadProgramsIfNeeded(for stream: XtreamStream) async {
        guard programsByStream[stream.streamId] == nil, !loadingStreamIDs.contains(stream.streamId) else {
            return
        }
        await loadPrograms(for: stream, forceRefresh: false)
    }

    @MainActor
    private func loadPrograms(for stream: XtreamStream, forceRefresh: Bool) async {
        guard !loadingStreamIDs.contains(stream.streamId) else { return }

        let scope = cacheScope
        if !forceRefresh, let cached = EPGMemoryCache.shared.programs(scope: scope, streamId: stream.streamId) {
            programsByStream[stream.streamId] = cached
            failedStreamIDs.remove(stream.streamId)
            return
        }

        loadingStreamIDs.insert(stream.streamId)
        defer { loadingStreamIDs.remove(stream.streamId) }

        do {
            let programs = try await EPGService(credentials: credentials).shortEPG(
                streamId: stream.streamId,
                limit: shortEPGLimit,
                forceRefresh: forceRefresh
            )
            programsByStream[stream.streamId] = programs
            EPGMemoryCache.shared.store(scope: scope, streamId: stream.streamId, programs: programs)
            if programs.isEmpty {
                failedStreamIDs.insert(stream.streamId)
            } else {
                failedStreamIDs.remove(stream.streamId)
            }
        } catch {
            failedStreamIDs.insert(stream.streamId)
            DebugLogger.logAsync(
                .warning,
                "EPG: caricamento fallito per stream \(stream.streamId): \(error.localizedDescription)"
            )
        }
    }

    @MainActor
    private func reloadEPG(forceRefresh: Bool = false) async {
        loadingIndicatorTask?.cancel()
        guard !streams.isEmpty else {
            showLoadingIndicator = false
            return
        }

        let targets = pagedStreams
        guard !targets.isEmpty else {
            showLoadingIndicator = false
            return
        }

        hydrateVisibleProgramsFromCache()
        let pending = targets.filter { forceRefresh || programsByStream[$0.streamId] == nil }

        guard !pending.isEmpty else {
            showLoadingIndicator = false
            return
        }

        loadingIndicatorTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: loadingIndicatorDelayNanoseconds)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.15)) { showLoadingIndicator = true }
        }

        failedStreamIDs.subtract(Set(pending.map(\.streamId)))
        let service = EPGService(credentials: credentials)
        let scope = cacheScope

        for start in stride(from: 0, to: pending.count, by: maxConcurrentRequests) {
            guard !Task.isCancelled else { break }
            let end = min(start + maxConcurrentRequests, pending.count)
            let batch = Array(pending[start..<end])
            loadingStreamIDs.formUnion(batch.map(\.streamId))

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
                        if programs.isEmpty { failedStreamIDs.insert(streamID) }
                        else { failedStreamIDs.remove(streamID) }
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
        withAnimation(.easeOut(duration: 0.15)) { showLoadingIndicator = false }
    }

    private func toast(_ message: String) -> some View {
        Text(message)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1) }
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
