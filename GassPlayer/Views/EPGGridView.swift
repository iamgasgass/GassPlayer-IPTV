import SwiftUI

/// Guida TV a griglia in stile "grid EPG": colonna canali fissa a sinistra,
/// riga orario fissa in alto, timeline scorrevole con linea "ora" live,
/// dettaglio programma, preferiti canale e promemoria/riproduzione differita.
/// Tutta la superficie usa il linguaggio Liquid Glass nativo di iOS 26
/// (via GlassCard / GlassIconButton), con fallback .ultraThinMaterial < iOS 26.
struct EPGGridView: View {
    let credentials: XtreamCredentials
    let streams: [XtreamStream]
    var onPlayLive: (XtreamStream) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var favorites: EPGFavoritesStore

    @State private var programsByStream: [Int: [EPGProgram]] = [:]
    @State private var failedStreamIDs = Set<Int>()
    @State private var isLoading = false
    @State private var now = Date()
    @State private var timelineStart = Calendar.current.startOfDay(for: Date())
    @State private var scrollOffset: CGPoint = .zero
    @State private var searchQuery = ""
    @State private var showFavoritesOnly = false
    @State private var selectedProgram: SelectedProgram?
    @State private var reminderToast: String?
    @State private var jumpToNowRequested = false

    private let pixelsPerMinute: CGFloat = 2.6
    private let channelColumnWidth: CGFloat = 148
    private let rowHeight: CGFloat = 60
    private let rulerHeight: CGFloat = 30
    private let maxConcurrentRequests = 4
    private let calendar = Calendar.autoupdatingCurrent

    init(credentials: XtreamCredentials, streams: [XtreamStream], onPlayLive: @escaping (XtreamStream) -> Void = { _ in }) {
        self.credentials = credentials
        self.streams = streams
        self.onPlayLive = onPlayLive
        _favorites = StateObject(wrappedValue: EPGFavoritesStore(scopeKey: Self.scopeKey(for: credentials)))
    }

    private struct SelectedProgram: Identifiable {
        let program: EPGProgram
        let stream: XtreamStream
        var id: String { program.id }
    }

    private struct CatchupPlayback: Identifiable {
        let url: URL
        let title: String
        var id: String { url.absoluteString }
    }

    @State private var catchupPlayback: CatchupPlayback?

    private var timelineEnd: Date {
        calendar.date(byAdding: .day, value: 1, to: timelineStart) ?? timelineStart.addingTimeInterval(86_400)
    }

    private var timelineWidth: CGFloat {
        CGFloat(timelineEnd.timeIntervalSince(timelineStart) / 60) * pixelsPerMinute
    }

    private var filteredStreams: [XtreamStream] {
        streams.filter { stream in
            if showFavoritesOnly, !favorites.isFavorite(stream.streamId) { return false }
            guard !searchQuery.isEmpty else { return true }
            return stream.name.localizedCaseInsensitiveContains(searchQuery)
        }
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
                        .task {
                            try? await Task.sleep(nanoseconds: 2_200_000_000)
                            self.reminderToast = nil
                        }
                }
            }
        }
        .task(id: streamIdentity) {
            await reloadEPG()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            timelineStart = calendar.startOfDay(for: Date())
            now = Date()
            Task { await reloadEPG() }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { date in
            now = date
        }
    }

    // MARK: - Chrome

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color.black.opacity(0.02), Color.accentColor.opacity(0.05)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Chiudi") { dismiss() }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            GlassIconButton(
                systemImage: showFavoritesOnly ? "star.fill" : "star",
                tint: showFavoritesOnly ? .yellow : nil,
                size: 36,
                accessibilityLabel: "Mostra solo i preferiti"
            ) {
                withAnimation(.snappy) { showFavoritesOnly.toggle() }
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
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .modifier(GlassCardBackground(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
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

    // MARK: - Grid (colonna fissa + ruler fisso + timeline scorrevole)

    private var gridBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: channelColumnWidth, height: rulerHeight)
                rulerClip
            }

            if filteredStreams.isEmpty {
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

                    if isLoading {
                        ProgressView("Caricamento guida TV…")
                            .padding(16)
                            .modifier(GlassCardBackground(cornerRadius: 16))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    }
                }
            }
        }
    }

    private var rulerClip: some View {
        timeRuler
            .offset(x: scrollOffset.x)
            .frame(width: nil, height: rulerHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
    }

    private var channelColumnClip: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(filteredStreams) { stream in
                channelLabel(for: stream)
            }
        }
        .offset(y: scrollOffset.y)
        .frame(width: channelColumnWidth, alignment: .topLeading)
        .clipped()
    }

    private var timelineScroll: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredStreams) { stream in
                            timelineRow(for: stream)
                        }
                    }

                    nowLine
                        .id("nowAnchor")
                }
                .background(scrollTracker)
            }
            .coordinateSpace(name: "epgScroll")
            .onPreferenceChange(EPGScrollOffsetKey.self) { scrollOffset = $0 }
            .onChange(of: jumpToNowRequested) { _, requested in
                guard requested else { return }
                withAnimation(.snappy) {
                    proxy.scrollTo("nowAnchor", anchor: UnitPoint(x: 0.15, y: 0))
                }
                jumpToNowRequested = false
            }
            .task(id: streamIdentity) {
                // Centra automaticamente sull'orario corrente al primo caricamento.
                try? await Task.sleep(nanoseconds: 300_000_000)
                withAnimation(.snappy) {
                    proxy.scrollTo("nowAnchor", anchor: UnitPoint(x: 0.15, y: 0))
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

    private var streamIdentity: String {
        streams.map { String($0.streamId) }.joined(separator: ",")
    }

    // MARK: - Ruler

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

    // MARK: - Channel column

    private func channelLabel(for stream: XtreamStream) -> some View {
        HStack(spacing: 8) {
            AsyncImage(url: URL(string: stream.streamIcon ?? "")) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFit()
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
                } else {
                    Text(failedStreamIDs.contains(stream.streamId) ? "EPG non disponibile" : "—")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            Button {
                favorites.toggle(stream.streamId)
            } label: {
                Image(systemName: favorites.isFavorite(stream.streamId) ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(favorites.isFavorite(stream.streamId) ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(width: channelColumnWidth, height: rowHeight, alignment: .leading)
        .background(.ultraThinMaterial)
        .contentShape(Rectangle())
        .onTapGesture { onPlayLive(stream) }
        .accessibilityElement(children: .contain)
        .accessibilityHint("Tocca per guardare in diretta, tocca la stella per aggiungere ai preferiti")
    }

    private func progressBar(for program: EPGProgram) -> some View {
        GeometryReader { proxy in
            let total = program.end.timeIntervalSince(program.start)
            let elapsed = min(max(now.timeIntervalSince(program.start), 0), max(total, 1))
            let fraction = total > 0 ? elapsed / total : 0

            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(Color.accentColor).frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 3)
    }

    // MARK: - Timeline rows

    private func timelineRow(for stream: XtreamStream) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 0, style: .continuous)
                .fill(Color.primary.opacity(0.03))
                .frame(width: timelineWidth, height: rowHeight)

            ForEach(programsByStream[stream.streamId] ?? []) { program in
                programBlock(program, stream: stream)
            }
        }
        .frame(width: timelineWidth, height: rowHeight, alignment: .leading)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.15)
        }
    }

    private func programBlock(_ program: EPGProgram, stream: XtreamStream) -> some View {
        let clippedStart = max(program.start, timelineStart)
        let clippedEnd = min(program.end, timelineEnd)
        let startMinutes = max(0, clippedStart.timeIntervalSince(timelineStart) / 60)
        let durationMinutes = max(1, clippedEnd.timeIntervalSince(clippedStart) / 60)
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
            .frame(width: width, height: rowHeight - 10, alignment: .leading)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isLive ? Color.accentColor.opacity(0.32) : Color.primary.opacity(0.07))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isLive ? Color.accentColor.opacity(0.6) : Color.white.opacity(0.12), lineWidth: isLive ? 1.2 : 0.5)
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
        let visible = now >= timelineStart && now <= timelineEnd

        return Group {
            if visible {
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 1.5, height: CGFloat(filteredStreams.count) * rowHeight)
                    .overlay(alignment: .top) {
                        Circle().fill(Color.red).frame(width: 7, height: 7).offset(y: -3.5)
                    }
                    .offset(x: x)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Helpers

    private func isCurrentProgram(_ program: EPGProgram) -> Bool {
        program.start <= now && program.end > now
    }

    private func currentProgram(for stream: XtreamStream) -> EPGProgram? {
        programsByStream[stream.streamId]?.first { $0.start <= now && $0.end > now }
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
        withAnimation { reminderToast = "Promemoria impostato per \"\(program.title)\"" }
        selectedProgram = nil
    }

    @MainActor
    private func reloadEPG() async {
        programsByStream = [:]
        failedStreamIDs = []
        guard !streams.isEmpty else { return }

        isLoading = true
        defer { isLoading = false }

        let service = EPGService(credentials: credentials)
        let streamIDs = streams.map(\.streamId)
        let chunks = stride(from: 0, to: streamIDs.count, by: maxConcurrentRequests).map {
            Array(streamIDs[$0..<min($0 + maxConcurrentRequests, streamIDs.count)])
        }

        for chunk in chunks {
            await withTaskGroup(of: (Int, Result<[EPGProgram], Error>).self) { group in
                for streamID in chunk {
                    group.addTask {
                        do {
                            return (streamID, .success(try await service.shortEPG(streamId: streamID, limit: 24)))
                        } catch {
                            return (streamID, .failure(error))
                        }
                    }
                }

                for await (streamID, result) in group {
                    switch result {
                    case .success(let programs):
                        programsByStream[streamID] = programs
                    case .failure:
                        failedStreamIDs.insert(streamID)
                    }
                }
            }
        }
    }

    private static func scopeKey(for credentials: XtreamCredentials) -> String {
        let host = credentials.host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        let stableInput = "\(host)|\(credentials.username)"
        let digest = stableInput.utf8.reduce(UInt64(14695981039346656037)) { partial, byte in
            (partial ^ UInt64(byte)) &* UInt64(1099511628211)
        }
        return String(digest, radix: 16)
    }
}

private struct EPGScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {
        value = nextValue()
    }
}

@MainActor
private final class EPGFavoritesStore: ObservableObject {
    @Published private(set) var favoriteStreamIDs: Set<Int>
    private let key: String

    init(scopeKey: String) {
        self.key = "gassplayer.epgFavorites.\(scopeKey)"
        if let saved = UserDefaults.standard.array(forKey: key) as? [Int] {
            favoriteStreamIDs = Set(saved)
        } else {
            favoriteStreamIDs = []
        }
    }

    func isFavorite(_ streamID: Int) -> Bool { favoriteStreamIDs.contains(streamID) }

    func toggle(_ streamID: Int) {
        if favoriteStreamIDs.contains(streamID) {
            favoriteStreamIDs.remove(streamID)
        } else {
            favoriteStreamIDs.insert(streamID)
        }
        UserDefaults.standard.set(Array(favoriteStreamIDs), forKey: key)
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

    private var isFuture: Bool { program.start > Date() }

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
                                Label("In onda ora", systemImage: "dot.radiowaves.left.and.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.red)
                            }

                            if let description = program.description, !description.isEmpty {
                                Text(description)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .padding(.top, 4)
                            }
                        }
                    }

                    VStack(spacing: 10) {
                        if isCurrentlyLive {
                            GlassPrimaryButton(title: "Guarda in diretta", systemImage: "play.fill", action: onPlayLive)
                        } else if program.hasArchive {
                            GlassPrimaryButton(title: "Riproduci differita", systemImage: "gobackward", action: onPlayCatchup)
                        }

                        if isFuture {
                            Button {
                                onSetReminder()
                            } label: {
                                Label("Imposta promemoria", systemImage: "bell")
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
                    Button("Chiudi") { dismiss() }
                }
            }
        }
    }
}
