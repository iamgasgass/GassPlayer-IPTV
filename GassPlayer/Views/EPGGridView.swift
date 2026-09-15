import SwiftUI

/// EPG touch-first ottimizzato per apertura immediata. L'indicatore live e'
/// una freccia bianca rivolta verso il basso, ancorata nella sezione orario
/// condivisa con le tile: orario e programmi scorrono insieme in un unico
/// ScrollView orizzontale, cosi' restano sempre sincronizzati. Ogni tile ha
/// una resa "viva a sinistra, sfumata/sfocata a destra", uniforme su tutta
/// la griglia.
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
    private let loadingIndicatorDelayNanoseconds: UInt64 = 350_000_000
    private let channelLogoWidth: CGFloat = 86
    private let channelLogoHeight: CGFloat = 76
    private let rowHeight: CGFloat = 96
    private let blockHeight: CGFloat = 82
    private let timeAxisHeight: CGFloat = 26
    private let pixelsPerMinute: CGFloat = 1.85

    /// Visualizza 30 minuti passati e 2 ore complete future.
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

    /// Calcola gruppi e conteggi in un'unica passata O(n) invece di ripetere
    /// un filtro lineare per ogni gruppo nel menu (evitava un costo O(n*g)).
    private var groupsWithCounts: (groups: [XtreamCategory], counts: [String: Int]) {
        var counts: [String: Int] = [:]
        var usedIDs = Set<String>()

        for stream in streams {
            guard let raw = stream.categoryId else { continue }
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, normalized != "0" else { continue }
            counts[normalized, default: 0] += 1
            usedIDs.insert(normalized)
        }

        let groups = liveCategories
            .filter { usedIDs.contains($0.categoryId) }
            .sorted {
                $0.categoryName.localizedCaseInsensitiveCompare($1.categoryName) == .orderedAscending
            }

        return (groups, counts)
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

    /// Mantiene l'ordine nativo della playlist anche nella selezione "Tutti".
    /// Se nessun filtro e' attivo, evita del tutto il ciclo `.filter`.
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

    /// Non include il tempo corrente: evita ricaricamenti inutili ogni minuto.
    private var streamIdentity: String {
        let ids = pagedStreams.map(\.streamId).map(String.init).joined(separator: ",")
        return "\(normalizedSelectedGroupID ?? "all")|\(selectedDayOffset)|\(ids)"
    }

    // MARK: - Time axis

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

    /// Offset orizzontale della posizione live: costante rispetto all'inizio
    /// della finestra, perche' la finestra stessa si ricentra su `now` a ogni
    /// tick. Il risultato visivo e' che le tile scorrono sotto la freccia,
    /// che resta ancorata nello stesso punto della sezione orario.
    private var livePositionX: CGFloat {
        CGFloat(now.timeIntervalSince(windowStart) / 60) * pixelsPerMinute
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
            // Aggiorna solo l'orologio: la finestra si ricentra, la freccia
            // resta ferma nello stesso punto e le tile scorrono sotto di lei.
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

    /// Colonna loghi canale fissa a sinistra + un unico ScrollView
    /// orizzontale che racchiude sezione orario e tutte le righe programma:
    /// scorrendo insieme, restano perfettamente sincronizzati.
    private var epgGrid: some View {
        HStack(alignment: .top, spacing: 0) {
            LazyVStack(spacing: 0) {
                Color.clear.frame(height: timeAxisHeight)

                ForEach(pagedStreams) { stream in
                    channelLogoPanel(stream)
                        .frame(height: rowHeight)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                let totalWidth = max(timelineWidth, 380)

                LazyVStack(spacing: 0) {
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

    // MARK: - Toolbar Liquid Glass

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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

                    let data = groupsWithCounts
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

    private var dayTimeHeader: some View {
        HStack(alignment: .center) {
            Button {
                selectedDayOffset = max(selectedDayOffset - 1, -7)
                scheduleReload()
            } label: {
                Text(dayTitle)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                selectedDayOffset = 0
                now = Date()
            } label: {
                Text(displayedTimeLabel)
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.42))
            }
            .buttonStyle(.plain)

            Image(systemName: "chevron.down.fill")
                .font(.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)

            Button {
                selectedDayOffset = min(selectedDayOffset + 1, 7)
                scheduleReload()
            } label: {
                Text(selectedDate.addingTimeInterval(60 * 60).formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    /// Sezione orario condivisa: nessuna griglia di linee, solo la freccia
    /// bianca rivolta verso il basso, marcata alla posizione esatta del
    /// minuto corrente. Vive nello stesso ScrollView orizzontale delle tile,
    /// quindi scorre sempre in modo identico e sincronizzato.
    private func timeAxisRow(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if isToday {
                VStack(spacing: 2) {
                    Text(now.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Image(systemName: "arrowtriangle.down.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
                .fixedSize()
                .offset(x: livePositionX - 14, y: 0)
            }
        }
        .frame(width: width, height: timeAxisHeight, alignment: .topLeading)
    }

    private func timelineRow(for stream: XtreamStream, width: CGFloat) -> some View {
        let programs = visiblePrograms(for: stream)

        return ZStack(alignment: .leading) {
            if programs.isEmpty {
                unavailableBlock(for: stream, width: width)
            } else {
                ForEach(programs) { program in
                    programBlock(program, stream: stream)
                }
            }

            if isToday {
                liveMarkerLine
            }
        }
        .frame(width: width, height: rowHeight, alignment: .leading)
        .clipped()
    }

    /// Sottile riferimento verticale allineato alla freccia, limitato alla
    /// sola riga corrente: aiuta a collegare visivamente freccia e tile
    /// senza introdurre una linea continua su tutta la griglia.
    private var liveMarkerLine: some View {
        Rectangle()
            .fill(Color.white.opacity(0.16))
            .frame(width: 1)
            .offset(x: livePositionX)
            .allowsHitTesting(false)
    }

    private func channelLogoPanel(_ stream: XtreamStream) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
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
                    .padding(6)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(width: channelLogoWidth, height: channelLogoHeight)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            onPlayLive(stream)
        }
        .accessibilityLabel("Guarda \(stream.name) in diretta")
    }

    private func unavailableBlock(for stream: XtreamStream, width: CGFloat) -> some View {
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
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 18)
        .frame(width: width, height: rowHeight, alignment: .leading)
    }

    private func programBlock(_ program: EPGProgram, stream: XtreamStream) -> some View {
        let clippedStart = max(program.start, windowStart)
        let clippedEnd = min(program.end, windowEnd)
        let startMinutes = max(0, clippedStart.timeIntervalSince(windowStart) / 60)
        let durationMinutes = max(1, clippedEnd.timeIntervalSince(clippedStart) / 60)
        let width = max(CGFloat(durationMinutes) * pixelsPerMinute, 88)
        let isCurrent = isToday && program.isCurrent(at: now)
        let progress = isCurrent ? programProgress(for: program) : 0

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
                isCurrent: isCurrent,
                progress: progress
            )
        }
        .offset(
            x: CGFloat(startMinutes) * pixelsPerMinute,
            y: (rowHeight - blockHeight) / 2
        )
        .accessibilityLabel(
            "\(program.title), dalle \(program.start.formatted(date: .omitted, time: .shortened)) alle \(program.end.formatted(date: .omitted, time: .shortened))"
        )
    }

    /// Resa uniforme per ogni tile: viva a sinistra, progressivamente
    /// sfumata e sfocata verso destra. Il livello di blur e' ottenuto
    /// sovrapponendo un duplicato del riempimento sfocato e mascherato con
    /// un gradiente, cosi' solo la parte destra appare fuori fuoco senza
    /// impattare il testo (che resta sempre nitido e leggibile).
    @ViewBuilder
    private func programTileBackground(
        stream: XtreamStream,
        program: EPGProgram,
        isCurrent: Bool,
        progress: CGFloat
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let base = programColor(for: stream, program: program)

        ZStack {
            shape.fill(base)

            shape
                .fill(base.opacity(0.9))
                .blur(radius: 7)
                .mask(
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.55), .white],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

            shape.fill(
                LinearGradient(
                    colors: [Color.black.opacity(0.0), Color.black.opacity(0.34)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )

            if isCurrent {
                GeometryReader { geometry in
                    let playedWidth = max(0, min(geometry.size.width, geometry.size.width * progress))

                    shape
                        .fill(base)
                        .frame(width: playedWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .clipShape(shape)
    }

    private func programProgress(for program: EPGProgram) -> CGFloat {
        guard program.end > program.start else { return 0 }
        let elapsed = now.timeIntervalSince(program.start)
        let total = program.end.timeIntervalSince(program.start)
        return CGFloat(min(max(elapsed / total, 0), 1))
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

    /// Apertura rapida: idrata subito dalla cache in memoria, poi effettua
    /// richieste di rete concorrenti solo per i canali senza dati (o tutti
    /// in caso di refresh esplicito), con un limite EPG piu' leggero per
    /// ridurre tempo di risposta e payload della prima apertura.
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
        let fetchedAt: Date
    }

    private var storage: [String: Entry] = [:]

    private func key(scope: String, streamId: Int) -> String {
        "\(scope)#\(streamId)"
    }

    func programs(scope: String, streamId: Int) -> [EPGProgram]? {
        storage[key(scope: scope, streamId: streamId)]?.programs
    }

    func store(scope: String, streamId: Int, programs: [EPGProgram]) {
        storage[key(scope: scope, streamId: streamId)] = Entry(programs: programs, fetchedAt: Date())
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
