import SwiftUI

/// EPG touch-first, ispirato al linguaggio visivo della guida UHF ma
/// implementato integralmente con componenti e logica originali.
///
/// Obiettivi del layout:
/// - menu gruppi Liquid Glass nativo nella toolbar centrale;
/// - header nero minimale, ricerca ampia e selettore data/orario;
/// - loghi canale grandi a sinistra, timeline a blocchi colorati a destra;
/// - blocchi EPG con orario e titolo in righe separate, senza sovrapposizioni;
/// - pagina limitata a 12 canali per mantenere rendering e scroll fluidi;
/// - cache memoria condivisa: nessun reload bloccante ad ogni apertura.
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
    @State private var isInitialEPGLoad = true
    @State private var isRefreshingEPG = false

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
    private let maxConcurrentRequests = 4
    private let shortEPGLimit = 48
    private let searchDebounceNanoseconds: UInt64 = 300_000_000

    // Metriche basate sullo screenshot: logo sinistro grande e timeline
    // compatta, leggibile su iPhone senza l'effetto zoom della griglia 24h.
    private let channelLogoWidth: CGFloat = 116
    private let channelLogoHeight: CGFloat = 102
    private let rowHeight: CGFloat = 118
    private let blockHeight: CGFloat = 102
    private let pixelsPerMinute: CGFloat = 1.90

    // Finestra orizzontale di circa 3 ore, con presente vicino al centro.
    private let pastWindow: TimeInterval = 50 * 60
    private let futureWindow: TimeInterval = 130 * 60

    init(
        credentials: XtreamCredentials,
        kind: XtreamStreamKind = .live,
        onPlayLive: @escaping (XtreamStream) -> Void = { _ in }
    ) {
        self.credentials = credentials
        self.kind = kind
        self.onPlayLive = onPlayLive
        _favorites = StateObject(
            wrappedValue: EPGFavoritesStore(
                scopeKey: Self.scopeKey(for: credentials)
            )
        )
    }

    private final class TaskBox {
        var task: Task<Void, Never>?
    }

    private struct SelectedProgram: Identifiable {
        let program: EPGProgram
        let stream: XtreamStream

        var id: String {
            "\(stream.streamId)-\(program.id)"
        }
    }

    private struct CatchupPlayback: Identifiable {
        let url: URL
        let title: String

        var id: String {
            url.absoluteString
        }
    }

    // MARK: - Sources and grouping

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

    private var epgGroups: [XtreamCategory] {
        let usedIDs = Set(
            streams.compactMap { stream -> String? in
                guard let raw = stream.categoryId else { return nil }
                let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return normalized.isEmpty || normalized == "0" ? nil : normalized
            }
        )

        return liveCategories
            .filter { usedIDs.contains($0.categoryId) }
            .sorted {
                $0.categoryName.localizedCaseInsensitiveCompare($1.categoryName) == .orderedAscending
            }
    }

    private var selectedGroupName: String {
        guard let groupID = normalizedSelectedGroupID else { return "Tutti" }
        return epgGroups.first(where: { $0.categoryId == groupID })?.categoryName ?? "Gruppo"
    }

    private var selectedGroupSystemImage: String {
        guard let groupID = normalizedSelectedGroupID,
              let group = epgGroups.first(where: { $0.categoryId == groupID }) else {
            return "square.grid.2x2"
        }
        return Self.groupIcon(for: group.categoryName)
    }

    private var groupSelectionBinding: Binding<String?> {
        Binding(
            get: { normalizedSelectedGroupID },
            set: { newValue in selectGroup(newValue) }
        )
    }

    private func selectGroup(_ groupID: String?) {
        guard groupID != normalizedSelectedGroupID else { return }
        selectedGroupID = groupID
        searchQuery = ""
        showFavoritesOnly = false
        renderLimit = renderPageSize
        scheduleReload()
    }

    /// L'ordine della sezione "Tutti" resta ESATTAMENTE quello di `streams`,
    /// ovvero l'ordine pubblicato dalla playlist/provider. Qui non esiste
    /// alcun `.sorted` sui canali: i filtri mantengono l'ordine relativo.
    private var filteredStreams: [XtreamStream] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupID = normalizedSelectedGroupID

        return streams.filter { stream in
            let categoryID = stream.categoryId?.trimmingCharacters(in: .whitespacesAndNewlines)

            if let groupID, categoryID != groupID { return false }
            if showFavoritesOnly, !favorites.isFavorite(stream.streamId) { return false }
            if !query.isEmpty, !stream.name.localizedCaseInsensitiveContains(query) { return false }
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
        let streamIDs = pagedStreams.map(\.streamId).map(String.init).joined(separator: ",")
        return "\(normalizedSelectedGroupID ?? "all")|\(selectedDayOffset)|\(streamIDs)"
    }

    // MARK: - Time axis

    private var selectedDate: Date {
        Calendar.autoupdatingCurrent.date(
            byAdding: .day,
            value: selectedDayOffset,
            to: now
        ) ?? now
    }

    private var isToday: Bool {
        selectedDayOffset == 0
    }

    private var windowCenter: Date {
        if isToday {
            return now
        }

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
        if isToday {
            return now.formatted(date: .omitted, time: .shortened)
        }

        return "12:00"
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

    // MARK: - View

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
                    if let toastMessage = reminderToast {
                        toast(toastMessage)
                            .task(id: toastMessage) {
                                try? await Task.sleep(nanoseconds: 2_200_000_000)
                                guard !Task.isCancelled else { return }
                                reminderToast = nil
                            }
                    }
                }
        }
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            scheduleReload()
        }
        .onChange(of: streams.map(\.streamId)) { _, _ in
            if pagedStreams.isEmpty {
                renderLimit = min(renderPageSize, max(streams.count, 1))
            }
            scheduleReload()
        }
        .onChange(of: streamIdentity) { _, _ in
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
            ScrollView {
                LazyVStack(spacing: 0) {
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
                        ForEach(pagedStreams) { stream in
                            epgRow(for: stream)
                        }

                        if canLoadMore {
                            loadMoreButton
                        }
                    }
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .overlay(alignment: .topTrailing) {
                if isInitialEPGLoad || isRefreshingEPG {
                    ProgressView()
                        .tint(.white)
                        .padding(12)
                }
            }
        }
    }

    // MARK: - Toolbar: native Liquid Glass group menu

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.medium))
                    .frame(width: 44, height: 44)
            }
            .modifier(UHFGlassCircleButton())
            .accessibilityLabel("Indietro")
        }

        ToolbarItem(placement: .principal) {
            Menu {
                Picker("Gruppo playlist", selection: groupSelectionBinding) {
                    Label("Tutti i canali", systemImage: "square.grid.2x2")
                        .tag(String?.none)

                    if !epgGroups.isEmpty {
                        Divider()
                        ForEach(epgGroups) { group in
                            Label(
                                "\(group.categoryName) (\(groupChannelCount(group.categoryId)))",
                                systemImage: Self.groupIcon(for: group.categoryName)
                            )
                            .tag(Optional(group.categoryId))
                        }
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: selectedGroupSystemImage)
                        .font(.headline.weight(.semibold))

                    Text(selectedGroupName)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .frame(height: 48)
            }
            .modifier(UHFGlassCapsule())
            .accessibilityLabel("Gruppo playlist: \(selectedGroupName)")
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
                    .font(.title3.weight(.bold))
                    .frame(width: 44, height: 44)
            }
            .modifier(UHFGlassCircleButton())
            .accessibilityLabel("Opzioni guida")
        }
    }

    // MARK: - Header

    private var searchHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)

            TextField("Cerca per nome del programma", text: $searchQuery)
                .font(.title3)
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
        .padding(.horizontal, 18)
        .frame(height: 62)
        .background(Color.white.opacity(0.09), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 26)
    }

    private var dayTimeHeader: some View {
        HStack(alignment: .center) {
            Button {
                selectedDayOffset = max(selectedDayOffset - 1, -7)
                scheduleReload()
            } label: {
                Text(dayTitle)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                selectedDayOffset = 0
                now = Date()
            } label: {
                Text(displayedTimeLabel)
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.42))
            }
            .buttonStyle(.plain)

            Image(systemName: "chevron.down.fill")
                .font(.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)

            Button {
                selectedDayOffset = min(selectedDayOffset + 1, 7)
                scheduleReload()
            } label: {
                Text(
                    selectedDate.addingTimeInterval(60 * 60).formatted(date: .omitted, time: .shortened)
                )
                .font(.system(size: 28, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 38)
        .padding(.bottom, 20)
    }

    // MARK: - UHF-like row

    private func epgRow(for stream: XtreamStream) -> some View {
        HStack(spacing: 0) {
            channelLogoPanel(stream)
            timelinePanel(stream)
        }
        .frame(height: rowHeight)
        .background(Color.white.opacity(0.018))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.055))
                .frame(height: 1)
        }
    }

    private func channelLogoPanel(_ stream: XtreamStream) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .fill(logoBackgroundColor(for: stream))

            AsyncImage(url: URL(string: stream.streamIcon ?? "")) { phase in
                if case .success(let image) = phase {
                    image
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                } else {
                    Image(systemName: "tv")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }

            if favorites.isFavorite(stream.streamId) {
                Image(systemName: "star.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.yellow)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(width: channelLogoWidth, height: channelLogoHeight)
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            onPlayLive(stream)
        }
        .accessibilityLabel("Guarda \(stream.name) in diretta")
    }

    private func timelinePanel(_ stream: XtreamStream) -> some View {
        let programs = visiblePrograms(for: stream)
        let timelineTotalWidth = max(timelineWidth, 420)

        return ScrollView(.horizontal, showsIndicators: false) {
            ZStack(alignment: .leading) {
                timelineGrid(width: timelineTotalWidth)

                if programs.isEmpty {
                    unavailableBlock(for: stream, width: timelineTotalWidth)
                } else {
                    ForEach(programs) { program in
                        programBlock(program, stream: stream)
                    }
                }

                if isToday {
                    nowMarker
                }
            }
            .frame(width: timelineTotalWidth, height: rowHeight, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private func timelineGrid(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Color.clear

            HStack(spacing: 0) {
                ForEach(0...3, id: \.self) { index in
                    let marker = windowStart.addingTimeInterval(TimeInterval(index) * 60 * 60)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(marker.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.35))
                            .padding(.leading, 10)
                            .padding(.top, 8)

                        Spacer()
                    }
                    .frame(width: 60 * pixelsPerMinute, height: rowHeight, alignment: .leading)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.white.opacity(0.05))
                            .frame(width: 1)
                    }
                }
            }
        }
        .frame(width: width, height: rowHeight)
    }

    private func unavailableBlock(for stream: XtreamStream, width: CGFloat) -> some View {
        let isLoading = loadingStreamIDs.contains(stream.streamId)
        let failed = failedStreamIDs.contains(stream.streamId)

        return HStack(spacing: 8) {
            if isLoading {
                ProgressView()
                    .tint(.white)
                    .controlSize(.small)
                Text("Caricamento EPG")
            } else if failed {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("EPG non disponibile")
            } else {
                Image(systemName: "calendar.badge.exclamationmark")
                Text("Dati non disponibili")
            }
        }
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(.white.opacity(0.88))
        .padding(.horizontal, 24)
        .frame(width: width, height: rowHeight, alignment: .leading)
    }

    private func programBlock(_ program: EPGProgram, stream: XtreamStream) -> some View {
        let clippedStart = max(program.start, windowStart)
        let clippedEnd = min(program.end, windowEnd)
        let startMinutes = max(0, clippedStart.timeIntervalSince(windowStart) / 60)
        let durationMinutes = max(1, clippedEnd.timeIntervalSince(clippedStart) / 60)
        let width = max(CGFloat(durationMinutes) * pixelsPerMinute, 58)
        let isLive = program.isCurrent(at: now)

        return Button {
            selectedProgram = SelectedProgram(program: program, stream: stream)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(program.start.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.48))

                    Spacer(minLength: 0)
                }

                Text(program.title)
                    .font(.system(size: 22, weight: .regular, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .frame(width: width, height: blockHeight, alignment: .leading)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .fill(programColor(for: stream, program: program, isLive: isLive))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .strokeBorder(
                    isLive ? Color.accentColor.opacity(0.95) : Color.white.opacity(0.045),
                    lineWidth: isLive ? 2 : 1
                )
        }
        .offset(x: CGFloat(startMinutes) * pixelsPerMinute, y: 8)
        .accessibilityLabel(
            "\(program.title), dalle \(program.start.formatted(date: .omitted, time: .shortened)) alle \(program.end.formatted(date: .omitted, time: .shortened))"
        )
    }

    private var nowMarker: some View {
        let minutesFromStart = now.timeIntervalSince(windowStart) / 60
        let x = CGFloat(minutesFromStart) * pixelsPerMinute

        return Rectangle()
            .fill(Color.accentColor)
            .frame(width: 2, height: rowHeight)
            .overlay(alignment: .top) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .offset(y: -4)
            }
            .offset(x: x)
            .allowsHitTesting(false)
    }

    private var loadMoreButton: some View {
        Button {
            let newLimit = min(
                renderLimit + renderPageSize,
                min(filteredStreams.count, hardRenderCap)
            )
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
            .padding(.vertical, 18)
        }
        .foregroundStyle(.white)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(18)
    }

    // MARK: - Colors

    private func logoBackgroundColor(for stream: XtreamStream) -> Color {
        paletteColor(seed: stream.streamId, saturation: 0.34, brightness: 0.78)
    }

    private func programColor(for stream: XtreamStream, program: EPGProgram, isLive: Bool) -> Color {
        if isLive {
            return Color.accentColor.opacity(0.54)
        }

        let seed = stream.streamId ^ Int(program.start.timeIntervalSince1970)
        return paletteColor(seed: seed, saturation: 0.56, brightness: 0.34)
    }

    private func paletteColor(seed: Int, saturation: Double, brightness: Double) -> Color {
        let normalized = abs(seed % 360)
        return Color(
            hue: Double(normalized) / 360.0,
            saturation: saturation,
            brightness: brightness
        )
    }

    // MARK: - Data and actions

    private func visiblePrograms(for stream: XtreamStream) -> [EPGProgram] {
        (programsByStream[stream.streamId] ?? []).filter {
            $0.end > windowStart && $0.start < windowEnd
        }
    }

    private func groupChannelCount(_ categoryID: String) -> Int {
        streams.lazy.filter {
            $0.categoryId?.trimmingCharacters(in: .whitespacesAndNewlines) == categoryID
        }
        .count
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
        catchupPlayback = CatchupPlayback(
            url: url,
            title: "\(stream.name) · \(program.title)"
        )
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
    private func reloadEPG(forceRefresh: Bool = false) async {
        guard !streams.isEmpty else {
            isInitialEPGLoad = false
            isRefreshingEPG = false
            return
        }

        let targets = pagedStreams
        guard !targets.isEmpty else {
            isInitialEPGLoad = false
            isRefreshingEPG = false
            return
        }

        let scope = cacheScope

        for stream in targets {
            if let cached = EPGMemoryCache.shared.programs(scope: scope, streamId: stream.streamId) {
                programsByStream[stream.streamId] = cached
                failedStreamIDs.remove(stream.streamId)
            }
        }

        let pending = targets.filter {
            forceRefresh || !EPGMemoryCache.shared.isFresh(scope: scope, streamId: $0.streamId)
        }

        guard !pending.isEmpty else {
            isInitialEPGLoad = false
            isRefreshingEPG = false
            return
        }

        let hasCachedData = targets.contains { programsByStream[$0.streamId]?.isEmpty == false }
        isInitialEPGLoad = !hasCachedData
        isRefreshingEPG = hasCachedData

        failedStreamIDs.subtract(Set(pending.map(\.streamId)))
        let service = EPGService(credentials: credentials)

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

        guard !Task.isCancelled else { return }
        isInitialEPGLoad = false
        isRefreshingEPG = false
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

// MARK: - Shared EPG cache

@MainActor
private final class EPGMemoryCache {
    static let shared = EPGMemoryCache()

    private struct Entry {
        let programs: [EPGProgram]
        let fetchedAt: Date
    }

    private var storage: [String: Entry] = [:]
    private let freshnessWindow: TimeInterval = 180

    private func key(scope: String, streamId: Int) -> String {
        "\(scope)#\(streamId)"
    }

    func programs(scope: String, streamId: Int) -> [EPGProgram]? {
        storage[key(scope: scope, streamId: streamId)]?.programs
    }

    func isFresh(scope: String, streamId: Int) -> Bool {
        guard let entry = storage[key(scope: scope, streamId: streamId)] else {
            return false
        }
        return Date().timeIntervalSince(entry.fetchedAt) < freshnessWindow
    }

    func store(scope: String, streamId: Int, programs: [EPGProgram]) {
        storage[key(scope: scope, streamId: streamId)] = Entry(programs: programs, fetchedAt: Date())
    }
}

// MARK: - Glass modifiers

private struct UHFGlassCircleButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        } else {
            content
                .buttonStyle(.plain)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                }
        }
    }
}

private struct UHFGlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                }
        }
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
