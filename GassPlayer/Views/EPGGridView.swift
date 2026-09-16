import SwiftUI

/// EPG "Top Italia": replica fedele della guida TV a blocchi colorati per
/// famiglia di canale, con pannello loghi fisso a sinistra e timeline
/// orizzontale sincronizzata a destra. Ogni variante di qualità dello stesso
/// canale (RAW / HEVC / FHD / HD / SD / 4K / +1) resta una riga indipendente
/// — esattamente come la sorgente Xtream la espone — ma tutte le varianti
/// dello stesso canale condividono la stessa tinta di famiglia, cosi' il
/// blocco visivo "Rai Uno", "Rai Uno +1", "Rai Due" eccetera risulta un'unica
/// fascia di colore continua fra pannello logo e timeline, come nello
/// screenshot di riferimento "Top Italia".
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

    /// Geometria di riga fedele allo screenshot "Top Italia": loghi più
    /// compatti (72x64) e riga più bassa (78pt) rispetto alla vecchia guida
    /// "touch-first", per ospitare più canali a schermo come nel target.
    private let channelLogoWidth: CGFloat = 72
    private let channelLogoHeight: CGFloat = 64
    private let rowHeight: CGFloat = 78
    private let rowSpacing: CGFloat = 3
    private let timeAxisHeight: CGFloat = 26
    private let pixelsPerMinute: CGFloat = 2.0
    private let minimumProgramBlockWidth: CGFloat = 150

    /// Finestra visuale: 30 minuti passati, 2 ore future.
    private let pastWindow: TimeInterval = 30 * 60
    private let futureWindow: TimeInterval = 120 * 60

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

    /// Gruppi e conteggi nell'ordine originario della playlist/provider.
    /// Nessun `.sorted`: "Tutti"/"Top Italia" e il menu mantengono la
    /// sequenza sorgente.
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

        let namesByID = Dictionary(
            uniqueKeysWithValues: liveCategories.map { ($0.categoryId, $0) }
        )
        let groups = orderedIDs.compactMap { namesByID[$0] }

        return (groups, counts)
    }

    private var selectedGroupName: String {
        guard let groupID = normalizedSelectedGroupID else { return "Top Italia" }
        return groupsWithCounts.groups.first(where: { $0.categoryId == groupID })?.categoryName ?? "Gruppo"
    }

    private var selectedGroupSystemImage: String {
        guard let groupID = normalizedSelectedGroupID,
              let group = groupsWithCounts.groups.first(where: { $0.categoryId == groupID }) else {
            return "square.grid.2x2"
        }
        return Self.groupIcon(for: group.categoryName)
    }

    /// Bandiera regionale mostrata al posto dell'icona quando il nome del
    /// gruppo/categoria richiama un paese noto (es. "Top Italia" -> 🇮🇹),
    /// per replicare esattamente il selettore visto nello screenshot target.
    private var selectedGroupFlag: String? {
        Self.regionFlag(for: selectedGroupName)
    }

    private var groupSelectionBinding: Binding<String?> {
        Binding(
            get: { normalizedSelectedGroupID },
            set: { selectGroup($0) }
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

    /// Asse "ora corrente" unico per freccia in header e taglio acceso/spento
    /// delle tile: la logica resta invariata rispetto alla versione touch,
    /// solo l'estetica del blocco cambia.
    private var liveAxisX: CGFloat {
        CGFloat(now.timeIntervalSince(windowStart) / 60) * pixelsPerMinute
    }

    /// Etichette dei due estremi della finestra visibile, formato "H:mm"
    /// senza zero iniziale (es. "3:30", "14:00") come nel target.
    private var windowStartLabel: String {
        Self.compactTimeFormatter.string(from: windowStart)
    }

    private var windowEndLabel: String {
        Self.compactTimeFormatter.string(from: windowEnd)
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

    /// Colonna loghi fissa a sinistra + timeline scrollabile in orizzontale
    /// a destra: le due colonne condividono lo stesso colore di famiglia per
    /// riga, cosi' l'occhio percepisce un'unica fascia continua come nel
    /// target, pur restando due `LazyVStack` sincronizzate per riga.
    private var epgGrid: some View {
        HStack(alignment: .top, spacing: 0) {
            LazyVStack(spacing: rowSpacing) {
                Color.clear.frame(width: channelLogoWidth + 18, height: timeAxisHeight)

                ForEach(pagedStreams) { stream in
                    channelLogoPanel(stream)
                        .frame(height: rowHeight)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                let totalWidth = max(timelineWidth, 380)

                LazyVStack(spacing: rowSpacing) {
                    timeAxisRow(width: totalWidth)

                    ForEach(pagedStreams) { stream in
                        timelineRow(for: stream, width: totalWidth)
                            .task(id: stream.streamId) {
                                await loadProgramsIfNeeded(for: stream)
                            }
                    }
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Indietro")
        }

        ToolbarItem(placement: .principal) {
            Menu {
                let data = groupsWithCounts

                Picker("Gruppo playlist", selection: groupSelectionBinding) {
                    Label("Top Italia", systemImage: "square.grid.2x2")
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
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Opzioni guida")
        }
    }

    /// Pillola centrale con bandiera regionale (🇮🇹 per "Top Italia") al
    /// posto dell'icona generica quando disponibile, per replicare
    /// esattamente il selettore del target.
    @ViewBuilder
    private var groupPillLabel: some View {
        let pill = HStack(spacing: 8) {
            if let flag = selectedGroupFlag {
                Text(flag)
                    .font(.system(size: 16))
            } else {
                Image(systemName: selectedGroupSystemImage)
                    .font(.system(size: 16, weight: .semibold))
            }

            Text(selectedGroupName)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
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
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    /// Header "Oggi" + estremi della finestra temporale visibile con
    /// freccia centrale di "torna a ora": nel target i due orari (es.
    /// "3:30" e "14:00") delimitano l'intera finestra scrollabile, non lo
    /// scorrimento istantaneo — quindi qui usiamo `windowStart`/`windowEnd`.
    private var dayTimeHeader: some View {
        HStack(alignment: .center) {
            Button {
                selectedDayOffset = max(selectedDayOffset - 1, -7)
                scheduleReload()
            } label: {
                Text(dayTitle)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Spacer()

            Text(windowStartLabel)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))

            Button {
                selectedDayOffset = 0
                now = Date()
                scheduleReload()
            } label: {
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Torna a ora")

            Text(windowEndLabel)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    /// Freccia bianca nella riga orario, allineata a `liveAxisX`: stessa
    /// meccanica di taglio "acceso/spento" già validata, riportata qui solo
    /// come indicatore discreto della posizione "ora" sulla timeline.
    private func timeAxisRow(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if isToday {
                VStack(spacing: 1) {
                    Text(now.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Image(systemName: "arrowtriangle.down.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .white.opacity(0.8), radius: 3)
                }
                .fixedSize()
                .frame(width: 30, alignment: .center)
                .offset(x: liveAxisX - 15, y: 0)
                .accessibilityLabel("Ora: \(now.formatted(date: .omitted, time: .shortened))")
            }
        }
        .frame(width: width, height: timeAxisHeight, alignment: .topLeading)
        .clipped()
    }

    private func timelineRow(for stream: XtreamStream, width: CGFloat) -> some View {
        let programs = visiblePrograms(for: stream)
        let family = Self.channelFamily(for: stream)

        return ZStack(alignment: .leading) {
            Self.rowGradient(for: family)

            if programs.isEmpty {
                unavailableBlock(for: stream, width: width, family: family)
            } else {
                ForEach(programs) { program in
                    programBlock(program, stream: stream, family: family)
                }

                if isToday {
                    liveScrubPill(width: width)
                }
            }
        }
        .frame(width: width, height: rowHeight, alignment: .leading)
        .clipped()
    }

    /// Pallino/pillola blu di "posizione live" sul bordo destro della zona
    /// visibile: elemento decorativo che nel target compare sulle righe
    /// della variante di qualità attualmente sintonizzata.
    private func liveScrubPill(width: CGFloat) -> some View {
        Capsule()
            .fill(Color.blue)
            .frame(width: 5, height: 34)
            .offset(x: min(liveAxisX + 6, width - 10))
            .opacity(0.9)
    }

    private func channelLogoPanel(_ stream: XtreamStream) -> some View {
        let family = Self.channelFamily(for: stream)

        return ZStack {
            Self.rowGradient(for: family)

            AsyncImage(url: URL(string: stream.streamIcon ?? "")) { phase in
                if case .success(let image) = phase {
                    image
                        .resizable()
                        .scaledToFit()
                        .padding(10)
                } else {
                    Image(systemName: "tv")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: channelLogoWidth, height: channelLogoHeight)

            if favorites.isFavorite(stream.streamId) {
                Image(systemName: "star.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.yellow)
                    .padding(5)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            if Self.hasCatchupBadge(for: stream) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white, .black.opacity(0.35))
                    .background(Circle().fill(.black.opacity(0.001)))
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: channelLogoWidth + 18, height: rowHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            onPlayLive(stream)
        }
        .accessibilityLabel("Guarda \(stream.name) in diretta")
    }

    private func unavailableBlock(for stream: XtreamStream, width: CGFloat, family: ChannelFamily) -> some View {
        let loading = loadingStreamIDs.contains(stream.streamId)
        let failed = failedStreamIDs.contains(stream.streamId)

        return HStack(spacing: 7) {
            if loading {
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
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 18)
        .frame(width: width, height: rowHeight, alignment: .leading)
    }

    /// Blocco continuo per programma: etichetta breve del canale + tag di
    /// qualità + orario su una riga sottile, titolo in grassetto sotto —
    /// esattamente come "Ra 1 [FHD] 13:30 / TELEGIORNALE" nel target. Nessun
    /// arrotondamento/gap fra blocchi adiacenti: un separatore verticale
    /// sottile marca il confine fra due programmi, cosi' la fascia resta
    /// visivamente continua.
    private func programBlock(_ program: EPGProgram, stream: XtreamStream, family: ChannelFamily) -> some View {
        let clippedStart = max(program.start, windowStart)
        let clippedEnd = min(program.end, windowEnd)
        let startMinutes = max(0, clippedStart.timeIntervalSince(windowStart) / 60)
        let durationMinutes = max(1, clippedEnd.timeIntervalSince(clippedStart) / 60)
        let width = max(minimumProgramBlockWidth, CGFloat(durationMinutes) * pixelsPerMinute)
        let startX = CGFloat(startMinutes) * pixelsPerMinute
        let isPast = program.end <= now
        let tag = Self.qualityTag(for: stream.name)
        let shortLabel = Self.shortChannelLabel(for: stream.name)

        return Button {
            selectedProgram = SelectedProgram(program: program, stream: stream)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(shortLabel)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    if let tag {
                        Text(tag)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                    }
                    Text(program.start.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)

                Text(program.title.uppercased())
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(width: width, height: rowHeight, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .background(alignment: .leading) {
            Rectangle()
                .fill(isPast ? family.blockColor.opacity(0.62) : family.blockColor)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.black.opacity(0.22))
                .frame(width: 1)
        }
        .offset(x: startX, y: 0)
        .accessibilityLabel(
            "\(program.title), dalle \(program.start.formatted(date: .omitted, time: .shortened)) alle \(program.end.formatted(date: .omitted, time: .shortened))"
        )
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
            .padding(.vertical, 16)
        }
        .foregroundStyle(.white)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(16)
    }

    private func visiblePrograms(for stream: XtreamStream) -> [EPGProgram] {
        (programsByStream[stream.streamId] ?? []).filter {
            $0.end > windowStart && $0.start < windowEnd
        }
    }

    // MARK: - Colori di famiglia canale

    /// Famiglia di canale: nome "pulito" (senza tag qualità/numero) usato
    /// come seed di colore, cosi' RAW/HEVC/FHD/HD/SD/4K/+1 dello stesso
    /// canale ottengono sempre la stessa tinta — replicando la fascia
    /// colorata continua vista nello screenshot "Top Italia".
    private struct ChannelFamily {
        let hue: Double

        /// Tinta pastello per il pannello logo (chiara, poco satura).
        var logoColor: Color {
            Color(hue: hue, saturation: 0.30, brightness: 0.62)
        }

        /// Tinta satura per il blocco programma (piena, come i box
        /// "TELEGIORNALE" rosso mattone / "TG2" verde-teal nel target).
        var blockColor: Color {
            Color(hue: hue, saturation: 0.55, brightness: 0.42)
        }
    }

    private static func rowGradient(for family: ChannelFamily) -> some View {
        LinearGradient(
            colors: [family.logoColor, family.logoColor, family.blockColor],
            startPoint: .leading,
            endPoint: UnitPoint(x: 0.18, y: 0.5)
        )
    }

    private static func channelFamily(for stream: XtreamStream) -> ChannelFamily {
        let cleaned = cleanFamilyName(from: stream.name)
        let seed = fnv1a(cleaned)
        let hue = Double(seed % 360) / 360.0
        return ChannelFamily(hue: hue)
    }

    /// Rimuove tag qualità/numero canale per isolare il nome di famiglia
    /// (es. "Rai Uno RAW" e "Rai Uno HD" -> "rai uno").
    private static func cleanFamilyName(from rawName: String) -> String {
        var name = rawName.lowercased()
        for token in qualityTokens {
            name = name.replacingOccurrences(of: token, with: "")
        }
        name = name.replacingOccurrences(of: #"^[0-9]+\.?\s*"#, with: "", options: .regularExpression)
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let qualityTokens = [
        "raw", "hevc", "fhd", "4k", " hd", " sd", "+1", "(4k)", "(hd)", "(sd)"
    ]

    private static func fnv1a(_ string: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Int(hash % 1_000_000)
    }

    /// Estrae il tag di qualità visibile nel canale (RAW/HEVC/FHD/HD/SD/4K),
    /// mostrato come pillola inline accanto all'orario nel blocco programma.
    private static func qualityTag(for name: String) -> String? {
        let upper = name.uppercased()
        let tags = ["RAW", "HEVC", "FHD", "4K", "HD", "SD"]
        for tag in tags where upper.contains(tag) {
            return tag
        }
        if upper.contains("+1") { return "+1" }
        return nil
    }

    private static func hasCatchupBadge(for stream: XtreamStream) -> Bool {
        qualityTag(for: stream.name) == "HD"
    }

    /// Etichetta breve del canale (es. "Rai 1", "Rai 2") senza il tag
    /// qualità, per il rigo superiore del blocco programma.
    private static func shortChannelLabel(for name: String) -> String {
        var cleaned = name
        for token in ["RAW", "HEVC", "FHD", "4K", "HD", "SD", "+1"] {
            cleaned = cleaned.replacingOccurrences(of: token, with: "", options: .caseInsensitive)
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? name : cleaned
    }

    private static let compactTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "H:mm"
        formatter.locale = Locale(identifier: "it_IT")
        return formatter
    }()

    /// Bandiera regionale in emoji per nomi di gruppo noti (Italia, ecc.),
    /// usata al posto dell'icona generica nella pillola di selezione.
    private static func regionFlag(for groupName: String) -> String? {
        let name = groupName.lowercased()
        if name.contains("italia") { return "🇮🇹" }
        if name.contains("uk") || name.contains("regno unito") { return "🇬🇧" }
        if name.contains("germania") || name.contains("deutsch") { return "🇩🇪" }
        if name.contains("francia") { return "🇫🇷" }
        if name.contains("spagna") { return "🇪🇸" }
        if name.contains("usa") || name.contains("stati uniti") { return "🇺🇸" }
        if name.contains("albania") { return "🇦🇱" }
        if name.contains("top italia") { return "🇮🇹" }
        return nil
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

    // MARK: - Actions

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
