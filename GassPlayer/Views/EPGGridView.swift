import SwiftUI

/// Guida TV a griglia.
///
/// FIX CRITICO (root cause della schermata vuota persistente): la guida NON
/// riceve piu' un array `streams` congelato al momento dell'apertura del
/// `fullScreenCover`. Con `.fullScreenCover(isPresented:)`, il contenuto
/// viene creato una sola volta nell'istante in cui il booleano diventa
/// `true`, catturando uno snapshot dei valori disponibili in quel momento.
/// Se in quell'istante il catalogo Xtream non aveva ancora finito di
/// caricare i canali live (es. refresh in corso, catalogo appena aperto),
/// la guida restava con un array vuoto per sempre, perche' un parametro
/// `let` non si aggiorna quando il dato a monte cambia in seguito.
///
/// La correzione legge i canali live direttamente da `XtreamCatalogStore`
/// tramite `@EnvironmentObject`, in modo reattivo: se il catalogo si
/// popola anche DOPO l'apertura della guida, la vista si ridisegna con i
/// dati corretti automaticamente, perche' osserva l'`ObservableObject`
/// invece di un valore congelato.
///
/// NOTA su Lazy stack: `LazyVStack`/`LazyHStack` sono lazy SOLO quando
/// hanno un `ScrollView` come antenato diretto. La colonna canali non vive
/// in un proprio `ScrollView` (e' sincronizzata via offset manuale con la
/// timeline), quindi usa `VStack` classico, reso sicuro dalla paginazione
/// (`pagedStreams`, mai piu' di `renderPageSize` righe per volta).
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
    @State private var timelineStart = Calendar.autoupdatingCurrent.startOfDay(for: Date())
    @State private var scrollOffset: CGPoint = .zero
    @State private var searchQuery = ""
    @State private var showFavoritesOnly = false
    @State private var selectedProgram: SelectedProgram?
    @State private var reminderToast: String?
    @State private var jumpToNowRequested = false
    @State private var catchupPlayback: CatchupPlayback?

    /// Numero di canali effettivamente renderizzati in questo momento.
    /// Cresce solo su richiesta esplicita dell'utente ("Carica altri").
    @State private var renderLimit = 40

    @State private var reloadTaskBox = TaskBox()
    @State private var didAppear = false

    private let pixelsPerMinute: CGFloat = 2.6
    private let channelColumnWidth: CGFloat = 148
    private let rowHeight: CGFloat = 60
    private let rulerHeight: CGFloat = 30

    private let renderPageSize = 40
    private let hardRenderCap = 400
    private let maxConcurrentRequests = 4
    private let shortEPGLimit = 48
    private let searchDebounceNanoseconds: UInt64 = 300_000_000

    private let calendar = Calendar.autoupdatingCurrent

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

    /// Fonte di verita' SEMPRE aggiornata: letta live dal catalogo condiviso,
    /// mai congelata al momento dell'apertura della guida.
    private var streams: [XtreamStream] {
        xtreamCatalog.streams(for: kind)
    }

    private var isCatalogStillLoading: Bool {
        streams.isEmpty && (xtreamCatalog.state == .loading || xtreamCatalog.state == .idle)
    }

    private var timelineEnd: Date {
        calendar.date(byAdding: .day, value: 1, to: timelineStart)
            ?? timelineStart.addingTimeInterval(86_400)
    }

    private var timelineWidth: CGFloat {
        CGFloat(timelineEnd.timeIntervalSince(timelineStart) / 60) * pixelsPerMinute
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
        let safeLimit = max(renderLimit, 0)
        return Array(filteredStreams.prefix(min(safeLimit, hardRenderCap)))
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
            VStack(spacing: 0) {
                searchBar
                gridBody
            }
            .background(backgroundGradient)
            .navigationTitle("Guida TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(item: $selectedProgram) { selection in
                ProgramDetailSheet(
                    program: selection.program,
                    stream: selection.stream,
                    isCurrentlyLive: isCurrentProgram(selection.program),
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

                            guard !Task.isCancelled else {
                                return
                            }

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
            if pagedStreams.isEmpty, renderLimit < renderPageSize {
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
            timelineStart = calendar.startOfDay(for: Date())
            now = Date()
            scheduleReload(forceRefresh: true)
        }
        .onReceive(
            Timer.publish(every: 60, on: .main, in: .common).autoconnect()
        ) { date in
            now = date
        }
        .onDisappear {
            reloadTaskBox.task?.cancel()
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Chiudi") {
                dismiss()
            }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            GlassIconButton(
                systemImage: "arrow.clockwise",
                size: 36,
                accessibilityLabel: "Aggiorna guida TV"
            ) {
                Task {
                    await xtreamCatalog.refresh(credentials: credentials, kind: kind)
                    scheduleReload(forceRefresh: true)
                }
            }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            GlassIconButton(
                systemImage: showFavoritesOnly ? "star.fill" : "star",
                tint: showFavoritesOnly ? .yellow : nil,
                size: 36,
                accessibilityLabel: "Mostra solo i preferiti"
            ) {
                withAnimation(.snappy) {
                    showFavoritesOnly.toggle()
                }
            }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            GlassIconButton(
                systemImage: "location.fill",
                size: 36,
                accessibilityLabel: "Vai all'orario corrente"
            ) {
                jumpToNowRequested = true
            }
        }
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            .padding(.vertical, 8)
            .modifier(GlassCardBackground(cornerRadius: 14))

            diagnosticBanner
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// Banner diagnostico sempre visibile: mostra lo stato reale dei dati
    /// (quanti canali totali, quanti dopo i filtri, quanti renderizzati,
    /// e lo stato del catalogo). Permette di distinguere immediatamente
    /// "il catalogo non ha ancora canali" da "i canali ci sono ma non si
    /// vedono", senza dover indovinare alla cieca.
    @ViewBuilder
    private var diagnosticBanner: some View {
        if streams.isEmpty {
            Label(
                isCatalogStillLoading
                    ? "Catalogo in caricamento…"
                    : "Il catalogo Live TV è vuoto per questa sorgente.",
                systemImage: isCatalogStillLoading ? "hourglass" : "exclamationmark.triangle"
            )
            .font(.caption2)
            .foregroundStyle(isCatalogStillLoading ? .secondary : .orange)
            .padding(.horizontal, 4)
        } else {
            Text(
                "Canali totali: \(streams.count) · Filtrati: \(filteredStreams.count) · Mostrati: \(pagedStreams.count)"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
    }

    private var gridBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: channelColumnWidth, height: rulerHeight)
                rulerClip
            }

            if streams.isEmpty {
                ContentUnavailableView(
                    isCatalogStillLoading ? "Caricamento canali…" : "Nessun canale live",
                    systemImage: isCatalogStillLoading ? "hourglass" : "tv.slash",
                    description: Text(
                        isCatalogStillLoading
                            ? "Il catalogo si sta ancora caricando. La guida si aggiornerà automaticamente."
                            : "Questa sorgente non ha canali live. Torna indietro e aggiorna il catalogo dal pulsante di refresh."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    if isCatalogStillLoading {
                        ProgressView()
                            .padding(.bottom, 24)
                    }
                }
            } else if pagedStreams.isEmpty {
                ContentUnavailableView(
                    showFavoritesOnly ? "Nessun canale preferito" : "Nessun canale trovato",
                    systemImage: showFavoritesOnly ? "star.slash" : "magnifyingglass",
                    description: Text(
                        showFavoritesOnly
                            ? "Aggiungi canali ai preferiti con la stella per vederli qui."
                            : "Prova con un altro nome."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        channelColumnClip
                        timelineScroll
                    }

                    if isInitialEPGLoad {
                        ProgressView("Caricamento guida TV…")
                            .padding(16)
                            .modifier(GlassCardBackground(cornerRadius: 16))
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: .center
                            )
                    } else if isRefreshingEPG {
                        ProgressView()
                            .controlSize(.small)
                            .padding(10)
                            .modifier(GlassCardBackground(cornerRadius: 14))
                            .frame(maxWidth: .infinity, alignment: .topTrailing)
                            .padding(10)
                    }
                }
            }
        }
    }

    private var rulerClip: some View {
        timeRuler
            .offset(x: scrollOffset.x)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: rulerHeight)
            .clipped()
    }

    private var channelColumnClip: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(pagedStreams) { stream in
                channelLabel(for: stream)
            }

            if canLoadMore {
                loadMoreFooter
                    .frame(width: channelColumnWidth, height: rowHeight)
            }
        }
        .offset(y: scrollOffset.y)
        .frame(width: channelColumnWidth, alignment: .topLeading)
        .clipped()
    }

    private var loadMoreFooter: some View {
        Button {
            loadMoreChannels()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "arrow.down.circle")
                Text("Altri \(min(renderPageSize, remainingCount))")
                    .font(.caption2)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .accessibilityLabel("Carica altri \(min(renderPageSize, remainingCount)) canali")
    }

    private var timelineScroll: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(pagedStreams) { stream in
                            timelineRow(for: stream)
                        }

                        if canLoadMore {
                            Color.clear
                                .frame(width: timelineWidth, height: rowHeight)
                        }
                    }

                    nowLine
                        .id("nowAnchor")
                }
                .background(scrollTracker)
            }
            .coordinateSpace(name: "epgScroll")
            .onPreferenceChange(EPGScrollOffsetKey.self) {
                scrollOffset = $0
            }
            .onChange(of: jumpToNowRequested) { _, requested in
                guard requested else {
                    return
                }

                withAnimation(.snappy) {
                    proxy.scrollTo(
                        "nowAnchor",
                        anchor: UnitPoint(x: 0.15, y: 0)
                    )
                }

                jumpToNowRequested = false
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.snappy) {
                        proxy.scrollTo(
                            "nowAnchor",
                            anchor: UnitPoint(x: 0.15, y: 0)
                        )
                    }
                }
            }
        }
    }

    private var scrollTracker: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: EPGScrollOffsetKey.self,
                value: proxy.frame(in: .named("epgScroll")).origin
            )
        }
    }

    private var timeRuler: some View {
        HStack(spacing: 0) {
            ForEach(0...24, id: \.self) { hour in
                Text(String(format: "%02d:00", hour % 24))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 60 * pixelsPerMinute, alignment: .leading)
            }
        }
        .frame(width: timelineWidth, alignment: .leading)
    }

    private func channelLabel(for stream: XtreamStream) -> some View {
        HStack(spacing: 8) {
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
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(stream.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                if let current = currentProgram(for: stream) {
                    Text(current.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    progressBar(for: current)
                } else if loadingStreamIDs.contains(stream.streamId) {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Caricamento…")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                } else if failedStreamIDs.contains(stream.streamId) {
                    Text("EPG non disponibile")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    Text("Nessun programma")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            Button {
                favorites.toggle(stream.streamId)
            } label: {
                Image(
                    systemName: favorites.isFavorite(stream.streamId)
                        ? "star.fill"
                        : "star"
                )
                .font(.caption)
                .foregroundStyle(
                    favorites.isFavorite(stream.streamId)
                        ? .yellow
                        : .secondary
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                favorites.isFavorite(stream.streamId)
                    ? "Rimuovi dai preferiti"
                    : "Aggiungi ai preferiti"
            )
        }
        .padding(.horizontal, 10)
        .frame(
            width: channelColumnWidth,
            height: rowHeight,
            alignment: .leading
        )
        .background(.ultraThinMaterial)
        .contentShape(Rectangle())
        .onTapGesture {
            onPlayLive(stream)
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint(
            "Tocca per guardare in diretta, tocca la stella per aggiungere ai preferiti"
        )
    }

    private func progressBar(for program: EPGProgram) -> some View {
        GeometryReader { proxy in
            let total = program.end.timeIntervalSince(program.start)
            let elapsed = min(
                max(now.timeIntervalSince(program.start), 0),
                max(total, 1)
            )
            let fraction = total > 0 ? elapsed / total : 0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.1))

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 3)
    }

    private func timelineRow(for stream: XtreamStream) -> some View {
        let programs = visiblePrograms(for: stream)
        let isLoadingRow = loadingStreamIDs.contains(stream.streamId)
        let hasFailed = failedStreamIDs.contains(stream.streamId)

        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 0, style: .continuous)
                .fill(Color.primary.opacity(0.03))
                .frame(width: timelineWidth, height: rowHeight)

            if programs.isEmpty {
                noProgramState(isLoading: isLoadingRow, failed: hasFailed)
            } else {
                ForEach(programs) { program in
                    programBlock(program, stream: stream)
                }
            }
        }
        .frame(width: timelineWidth, height: rowHeight, alignment: .leading)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.15)
        }
    }

    private func noProgramState(
        isLoading: Bool,
        failed: Bool
    ) -> some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("Caricamento palinsesto…")
            } else if failed {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Guida non disponibile")
            } else {
                Image(systemName: "calendar.badge.exclamationmark")
                Text("Nessun programma disponibile")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(width: timelineWidth, height: rowHeight, alignment: .leading)
    }

    private func visiblePrograms(for stream: XtreamStream) -> [EPGProgram] {
        (programsByStream[stream.streamId] ?? []).filter {
            $0.end > timelineStart && $0.start < timelineEnd
        }
    }

    private func programBlock(
        _ program: EPGProgram,
        stream: XtreamStream
    ) -> some View {
        let clippedStart = max(program.start, timelineStart)
        let clippedEnd = min(program.end, timelineEnd)
        let startMinutes = max(
            0,
            clippedStart.timeIntervalSince(timelineStart) / 60
        )
        let durationMinutes = max(
            1,
            clippedEnd.timeIntervalSince(clippedStart) / 60
        )
        let width = max(CGFloat(durationMinutes) * pixelsPerMinute, 32)
        let isLive = isCurrentProgram(program)

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
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(
                width: width,
                height: rowHeight - 10,
                alignment: .leading
            )
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isLive
                        ? Color.accentColor.opacity(0.32)
                        : Color.primary.opacity(0.07)
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isLive
                        ? Color.accentColor.opacity(0.6)
                        : Color.white.opacity(0.12),
                    lineWidth: isLive ? 1.2 : 0.5
                )
        }
        .overlay(alignment: .topTrailing) {
            if program.hasArchive {
                Image(systemName: "gobackward")
                    .font(.system(size: 9, weight: .bold))
                    .padding(3)
                    .background(.thinMaterial, in: Circle())
                    .padding(3)
            }
        }
        .offset(x: CGFloat(startMinutes) * pixelsPerMinute, y: 5)
        .accessibilityLabel(
            "\(program.title), \(program.start.formatted(date: .omitted, time: .shortened)) fino alle \(program.end.formatted(date: .omitted, time: .shortened))\(program.hasArchive ? ", disponibile in differita" : "")"
        )
    }

    private var nowLine: some View {
        let minutesFromStart = now.timeIntervalSince(timelineStart) / 60
        let x = CGFloat(minutesFromStart) * pixelsPerMinute
        let isVisible = now >= timelineStart && now <= timelineEnd

        return Group {
            if isVisible {
                Rectangle()
                    .fill(Color.red)
                    .frame(
                        width: 1.5,
                        height: CGFloat(pagedStreams.count) * rowHeight
                    )
                    .overlay(alignment: .top) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                            .offset(y: -3.5)
                    }
                    .offset(x: x)
                    .allowsHitTesting(false)
            }
        }
    }

    private func isCurrentProgram(_ program: EPGProgram) -> Bool {
        program.start <= now && program.end > now
    }

    private func currentProgram(for stream: XtreamStream) -> EPGProgram? {
        (programsByStream[stream.streamId] ?? []).first {
            $0.start <= now && $0.end > now
        }
    }

    private func playCatchup(
        program: EPGProgram,
        stream: XtreamStream
    ) {
        let service = EPGService(credentials: credentials)
        let duration = max(
            1,
            Int(program.end.timeIntervalSince(program.start) / 60)
        )
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

        ReminderService.shared.scheduleReminder(
            for: program,
            minutesBefore: 5
        )

        withAnimation {
            reminderToast = "Promemoria impostato per \"\(program.title)\""
        }

        selectedProgram = nil
    }

    private func loadMoreChannels() {
        let newLimit = min(
            renderLimit + renderPageSize,
            min(filteredStreams.count, hardRenderCap)
        )

        guard newLimit != renderLimit else {
            return
        }

        renderLimit = newLimit
        scheduleReload()
    }

    private func scheduleReload(
        forceRefresh: Bool = false,
        debounced: Bool = false
    ) {
        reloadTaskBox.task?.cancel()

        reloadTaskBox.task = Task { @MainActor in
            if debounced {
                try? await Task.sleep(nanoseconds: searchDebounceNanoseconds)

                guard !Task.isCancelled else {
                    return
                }
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
            guard !Task.isCancelled else {
                break
            }

            let end = min(start + maxConcurrentRequests, pending.count)
            let batch = Array(pending[start..<end])
            loadingStreamIDs.formUnion(batch.map(\.streamId))

            await withTaskGroup(
                of: (Int, Result<[EPGProgram], Error>).self
            ) { group in
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
                    guard !Task.isCancelled else {
                        continue
                    }

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

        guard !Task.isCancelled else {
            return
        }

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

private struct EPGScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero

    static func reduce(
        value: inout CGPoint,
        nextValue: () -> CGPoint
    ) {
        value = nextValue()
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
