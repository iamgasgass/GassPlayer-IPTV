import SwiftUI

/// Guida TV progettata specificamente per schermi iPhone.
///
/// ARCHITETTURA:
/// - lista verticale di canali, sempre leggibile e adattata allo schermo;
/// - ogni canale possiede una timeline orizzontale indipendente;
/// - nessuna griglia bidimensionale globale, nessun offset manuale
///   condiviso, nessun bridge UIKit e nessuna vista larga 24 ore;
/// - finestra EPG locale: 90 minuti prima di ora e 3 ore dopo ora;
/// - programma corrente centrato visivamente nell'area iniziale;
/// - 40 canali per pagina, massimo 120, per evitare blocchi/watchdog.
///
/// Questo design elimina i problemi di zoom, contenuto fuori schermo,
/// canali invisibili, colonne disallineate e timeline fantasma causati da
/// una griglia desktop larga 24 ore forzata dentro un iPhone.
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
    @State private var searchQuery = ""
    @State private var showFavoritesOnly = false
    @State private var selectedProgram: SelectedProgram?
    @State private var reminderToast: String?
    @State private var catchupPlayback: CatchupPlayback?
    @State private var renderLimit = 40
    @State private var reloadTaskBox = TaskBox()
    @State private var didAppear = false

    private let renderPageSize = 40
    private let hardRenderCap = 120
    private let maxConcurrentRequests = 4
    private let shortEPGLimit = 48
    private let searchDebounceNanoseconds: UInt64 = 300_000_000

    /// Finestra temporale leggibile su iPhone: 90 minuti prima e 3 ore dopo.
    /// I programmi in corso risultano visibili immediatamente, mentre il
    /// futuro prossimo resta raggiungibile con scroll orizzontale per riga.
    private let pastWindow: TimeInterval = 90 * 60
    private let futureWindow: TimeInterval = 3 * 60 * 60

    /// Scala volutamente contenuta: 1 minuto = 1,05pt. La finestra di 4,5h
    /// e' ~284pt e quindi si adatta quasi interamente allo schermo iPhone.
    private let pixelsPerMinute: CGFloat = 1.05
    private let channelRowHeight: CGFloat = 118
    private let logoSize: CGFloat = 34

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

    private var streams: [XtreamStream] {
        xtreamCatalog.streams(for: kind)
    }

    private var isCatalogStillLoading: Bool {
        streams.isEmpty && (xtreamCatalog.state == .loading || xtreamCatalog.state == .idle)
    }

    private var windowStart: Date {
        now.addingTimeInterval(-pastWindow)
    }

    private var windowEnd: Date {
        now.addingTimeInterval(futureWindow)
    }

    private var windowDuration: TimeInterval {
        windowEnd.timeIntervalSince(windowStart)
    }

    private var timelineWidth: CGFloat {
        CGFloat(windowDuration / 60) * pixelsPerMinute
    }

    private var filteredStreams: [XtreamStream] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        return streams.filter { stream in
            if showFavoritesOnly, !favorites.isFavorite(stream.streamId) {
                return false
            }

            guard !query.isEmpty else {
                return true
            }

            return stream.name.localizedCaseInsensitiveContains(query)
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

    private var streamIdentity: String {
        let host = credentials.host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let ids = pagedStreams.map(\.streamId).map(String.init).joined(separator: ",")
        return "\(host)|\(credentials.username)|\(ids)"
    }

    var body: some View {
        NavigationStack {
            content
                .background(backgroundGradient)
                .navigationTitle("Guida TV")
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
                            Task {
                                await scheduleReminder(for: selection.program)
                            }
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
            renderLimit = min(renderPageSize, max(filteredStreams.count, 1))
            scheduleReload(debounced: true)
        }
        .onChange(of: showFavoritesOnly) { _, _ in
            renderLimit = min(renderPageSize, max(filteredStreams.count, 1))
            scheduleReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            now = Date()
            scheduleReload(forceRefresh: true)
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
                        ? "Il catalogo si sta ancora caricando. La guida si aggiornerà automaticamente."
                        : "Questa sorgente non ha canali live. Torna indietro e aggiorna il catalogo."
                )
            )
            .overlay(alignment: .bottom) {
                if isCatalogStillLoading {
                    ProgressView()
                        .padding(.bottom, 32)
                }
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    header

                    if pagedStreams.isEmpty {
                        ContentUnavailableView(
                            showFavoritesOnly ? "Nessun canale preferito" : "Nessun canale trovato",
                            systemImage: showFavoritesOnly ? "star.slash" : "magnifyingglass",
                            description: Text(
                                showFavoritesOnly
                                    ? "Aggiungi canali ai preferiti con la stella."
                                    : "Prova con un altro nome."
                            )
                        )
                        .padding(.top, 36)
                    } else {
                        ForEach(pagedStreams) { stream in
                            channelEPGRow(for: stream)
                        }

                        if canLoadMore {
                            loadMoreButton
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .refreshable {
                await refreshAll()
            }
            .overlay(alignment: .topTrailing) {
                if isInitialEPGLoad {
                    ProgressView("Caricamento guida…")
                        .font(.caption)
                        .padding(10)
                        .modifier(GlassCardBackground(cornerRadius: 14))
                        .padding(12)
                } else if isRefreshingEPG {
                    ProgressView()
                        .controlSize(.small)
                        .padding(10)
                        .modifier(GlassCardBackground(cornerRadius: 14))
                        .padding(12)
                }
            }
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color.black.opacity(0.02),
                Color.accentColor.opacity(0.05)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Cerca canale", text: $searchQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Cancella ricerca")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .modifier(GlassCardBackground(cornerRadius: 14))

            HStack {
                Label(
                    "Ora: \(now.formatted(date: .omitted, time: .shortened))",
                    systemImage: "clock"
                )

                Spacer()

                Text("\(pagedStreams.count) di \(filteredStreams.count) canali")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
    }

    /// Riga EPG autosufficiente e ottimizzata per iPhone.
    /// Non dipende da alcun offset esterno: il canale e la sua timeline
    /// restano sempre insieme, eliminando in modo definitivo il problema
    /// di colonne invisibili o sfasate della vecchia griglia desktop.
    private func channelEPGRow(for stream: XtreamStream) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                channelLogo(for: stream)

                VStack(alignment: .leading, spacing: 2) {
                    Text(stream.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    if let current = currentProgram(for: stream) {
                        Text(current.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if loadingStreamIDs.contains(stream.streamId) {
                        Text("Caricamento palinsesto…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if failedStreamIDs.contains(stream.streamId) {
                        Text("Guida non disponibile")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("Nessun programma disponibile")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                Button {
                    favorites.toggle(stream.streamId)
                } label: {
                    Image(systemName: favorites.isFavorite(stream.streamId) ? "star.fill" : "star")
                        .foregroundStyle(favorites.isFavorite(stream.streamId) ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    favorites.isFavorite(stream.streamId)
                        ? "Rimuovi dai preferiti"
                        : "Aggiungi ai preferiti"
                )

                Button {
                    onPlayLive(stream)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.caption.weight(.semibold))
                        .frame(width: 30, height: 30)
                        .background(Color.accentColor.opacity(0.18), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Guarda \(stream.name) in diretta")
            }

            timeline(for: stream)
        }
        .padding(12)
        .modifier(GlassCardBackground(cornerRadius: 16))
        .frame(minHeight: channelRowHeight, alignment: .top)
    }

    private func channelLogo(for stream: XtreamStream) -> some View {
        AsyncImage(url: URL(string: stream.streamIcon ?? "")) { phase in
            if case .success(let image) = phase {
                image
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "tv")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: logoSize, height: logoSize)
        .padding(4)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// Timeline orizzontale indipendente del singolo canale.
    /// La larghezza della finestra e' piccola e leggibile, quindi non
    /// esiste piu' l'effetto "zoomato" o una gigantesca area nera vuota.
    private func timeline(for stream: XtreamStream) -> some View {
        let programs = visiblePrograms(for: stream)

        return ScrollView(.horizontal, showsIndicators: false) {
            ZStack(alignment: .leading) {
                timelineBackground

                if programs.isEmpty {
                    emptyTimelineState(
                        streamID: stream.streamId,
                        width: max(timelineWidth, 280)
                    )
                } else {
                    ForEach(programs) { program in
                        programBlock(program, stream: stream)
                    }
                }

                nowMarker
            }
            .frame(
                width: max(timelineWidth, 280),
                height: 54,
                alignment: .leading
            )
        }
        .frame(height: 54)
        .accessibilityLabel("Timeline di \(stream.name)")
    }

    private var timelineBackground: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))

            HStack(spacing: 0) {
                ForEach(0...4, id: \.self) { index in
                    let marker = windowStart.addingTimeInterval(TimeInterval(index) * 60 * 60)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(marker.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 4)

                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 1)
                    }
                    .frame(width: 60 * pixelsPerMinute, height: 54, alignment: .leading)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func emptyTimelineState(streamID: Int, width: CGFloat) -> some View {
        HStack(spacing: 7) {
            if loadingStreamIDs.contains(streamID) {
                ProgressView()
                    .controlSize(.small)
                Text("Caricamento…")
            } else if failedStreamIDs.contains(streamID) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("EPG non disponibile")
            } else {
                Image(systemName: "calendar.badge.exclamationmark")
                Text("Nessun programma")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(width: width, height: 54, alignment: .leading)
    }

    private func programBlock(
        _ program: EPGProgram,
        stream: XtreamStream
    ) -> some View {
        let clippedStart = max(program.start, windowStart)
        let clippedEnd = min(program.end, windowEnd)
        let startMinutes = max(0, clippedStart.timeIntervalSince(windowStart) / 60)
        let durationMinutes = max(1, clippedEnd.timeIntervalSince(clippedStart) / 60)
        let width = max(CGFloat(durationMinutes) * pixelsPerMinute, 54)
        let isLive = program.isCurrent(at: now)

        return Button {
            selectedProgram = SelectedProgram(program: program, stream: stream)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(program.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                Text(
                    "\(program.start.formatted(date: .omitted, time: .shortened))–\(program.end.formatted(date: .omitted, time: .shortened))"
                )
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(width: width, height: 46, alignment: .leading)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isLive ? Color.accentColor.opacity(0.32) : Color.primary.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    isLive ? Color.accentColor.opacity(0.75) : Color.white.opacity(0.12),
                    lineWidth: isLive ? 1.3 : 0.5
                )
        )
        .overlay(alignment: .topTrailing) {
            if program.hasArchive {
                Image(systemName: "gobackward")
                    .font(.system(size: 8, weight: .bold))
                    .padding(3)
                    .background(.thinMaterial, in: Circle())
                    .padding(2)
            }
        }
        .offset(x: CGFloat(startMinutes) * pixelsPerMinute, y: 4)
        .accessibilityLabel(
            "\(program.title), \(program.start.formatted(date: .omitted, time: .shortened)) fino alle \(program.end.formatted(date: .omitted, time: .shortened))"
        )
    }

    private var nowMarker: some View {
        let minutesFromStart = now.timeIntervalSince(windowStart) / 60
        let x = CGFloat(minutesFromStart) * pixelsPerMinute

        return Rectangle()
            .fill(Color.red)
            .frame(width: 1.5, height: 54)
            .overlay(alignment: .top) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                    .offset(y: -3)
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
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .modifier(GlassCardBackground(cornerRadius: 14))
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color.black.opacity(0.02),
                Color.accentColor.opacity(0.05)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private func toast(_ message: String) -> some View {
        Text(message)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .modifier(GlassCardBackground(cornerRadius: 20))
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Chiudi") {
                dismiss()
            }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    reminderToast = "Aggiornamento guida in corso…"

                    Task {
                        await refreshAll()
                    }
                } label: {
                    Label("Aggiorna guida", systemImage: "arrow.clockwise")
                }

                Button {
                    withAnimation(.snappy) {
                        showFavoritesOnly.toggle()
                    }

                    reminderToast = showFavoritesOnly
                        ? "Mostro solo i canali preferiti"
                        : "Mostro tutti i canali"
                } label: {
                    Label(
                        showFavoritesOnly ? "Mostra tutti i canali" : "Solo preferiti",
                        systemImage: showFavoritesOnly ? "star.fill" : "star"
                    )
                }

                Button {
                    now = Date()
                    reminderToast = "Orario della guida aggiornato"
                } label: {
                    Label("Aggiorna orario corrente", systemImage: "location.fill")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body.weight(.medium))
            }
            .accessibilityLabel("Altre azioni guida TV")
        }
    }

    private func visiblePrograms(for stream: XtreamStream) -> [EPGProgram] {
        (programsByStream[stream.streamId] ?? []).filter {
            $0.end > windowStart && $0.start < windowEnd
        }
    }

    private func currentProgram(for stream: XtreamStream) -> EPGProgram? {
        (programsByStream[stream.streamId] ?? []).first {
            $0.isCurrent(at: now)
        }
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

        withAnimation {
            reminderToast = "Promemoria impostato per \"\(program.title)\""
        }

        selectedProgram = nil
    }

    private func refreshAll() async {
        await xtreamCatalog.refresh(credentials: credentials, kind: kind)
        programsByStream = [:]
        failedStreamIDs = []
        await reloadEPG(forceRefresh: true)
    }

    private func scheduleReload(
        forceRefresh: Bool = false,
        debounced: Bool = false
    ) {
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

        let pending = targets.filter { stream in
            forceRefresh || programsByStream[stream.streamId] == nil
        }

        guard !pending.isEmpty else {
            isInitialEPGLoad = false
            isRefreshingEPG = false
            return
        }

        if programsByStream.isEmpty {
            isInitialEPGLoad = true
        } else {
            isRefreshingEPG = true
        }

        failedStreamIDs.subtract(Set(pending.map(\.streamId)))

        let service = EPGService(credentials: credentials)

        for start in stride(
            from: 0,
            to: pending.count,
            by: maxConcurrentRequests
        ) {
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

    private static func scopeKey(for credentials: XtreamCredentials) -> String {
        let host = credentials.host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()

        let input = "\(host)|\(credentials.username)"

        let digest = input.utf8.reduce(
            UInt64(14_695_981_039_346_656_037)
        ) { partial, byte in
            (partial ^ UInt64(byte)) &* UInt64(1_099_511_628_211)
        }

        return String(digest, radix: 16)
    }
}

@MainActor
private final class EPGFavoritesStore: ObservableObject {
    @Published private(set) var favoriteStreamIDs: Set<Int>

    private let key: String

    init(scopeKey: String) {
        key = "gassplayer.epgFavorites.\(scopeKey)"

        if let saved = UserDefaults.standard.array(forKey: key) as? [Int] {
            favoriteStreamIDs = Set(saved)
        } else {
            favoriteStreamIDs = []
        }
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

        UserDefaults.standard.set(
            Array(favoriteStreamIDs).sorted(),
            forKey: key
        )
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
                    GlassCard {
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
                                Label(
                                    "In onda ora",
                                    systemImage: "dot.radiowaves.left.and.right"
                                )
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.red)
                            }

                            if let description = program.description,
                               !description.isEmpty {
                                Text(description)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .padding(.top, 4)
                            }
                        }
                    }

                    VStack(spacing: 10) {
                        if isCurrentlyLive {
                            GlassPrimaryButton(
                                title: "Guarda in diretta",
                                systemImage: "play.fill",
                                action: onPlayLive
                            )
                        } else if program.hasArchive {
                            GlassPrimaryButton(
                                title: "Riproduci differita",
                                systemImage: "gobackward",
                                action: onPlayCatchup
                            )
                        }

                        if isFuture {
                            Button {
                                onSetReminder()
                            } label: {
                                Label(
                                    "Imposta promemoria",
                                    systemImage: "bell"
                                )
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                            }
                            .modifier(GlassCardBackground(cornerRadius: 16))
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Dettaglio programma")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Chiudi") {
                        dismiss()
                    }
                }
            }
        }
    }
}
