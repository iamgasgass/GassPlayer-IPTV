import SwiftUI

/// Integra questa view nel progetto mantenendo i modelli e i servizi esistenti:
/// XtreamStream, XtreamCredentials, EPGProgram, EPGService, EPGMemoryCache e DebugLogger.
struct EPGGridView: View {
    let streams: [XtreamStream]
    let credentials: XtreamCredentials

    @Environment(\.dismiss) private var dismiss

    @State private var selectedGroupID: String?
    @State private var searchText = ""
    @State private var showFavoritesOnly = false
    @State private var selectedDayOffset = 0
    @State private var now = Date()
    @State private var didAppear = false
    @State private var renderLimit = 36
    @State private var programsByStream: [Int: [EPGProgram]] = [:]
    @State private var loadingStreamIDs: Set<Int> = []
    @State private var failedStreamIDs: Set<Int> = []
    @State private var showLoadingIndicator = false
    @State private var reminderToast: String?
    @State private var loadingIndicatorTask: Task<Void, Never>?
    @State private var reloadTask: Task<Void, Never>?

    private let renderPageSize = 36
    private let maxConcurrentRequests = 6
    private let shortEPGLimit = 12
    private let loadingIndicatorDelayNanoseconds: UInt64 = 400_000_000

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                dayTimeHeader

                if filteredStreams.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "Nessun canale" : "Nessun risultato",
                        systemImage: searchText.isEmpty ? "tv.slash" : "magnifyingglass",
                        description: Text(searchText.isEmpty
                            ? "Non ci sono canali nel gruppo selezionato."
                            : "Prova con un altro termine di ricerca.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(pagedStreams, id: \.streamId) { stream in
                                channelRow(stream)
                                    .task(id: stream.streamId) {
                                        await loadIfNeeded(stream)
                                    }
                            }

                            if pagedStreams.count < filteredStreams.count {
                                Color.clear
                                    .frame(height: 1)
                                    .onAppear {
                                        renderLimit = min(
                                            renderLimit + renderPageSize,
                                            filteredStreams.count
                                        )
                                    }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 20)
                    }
                }
            }
            .navigationTitle("Guida TV")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Cerca canale")
            .toolbar(content: toolbarContent)
            .overlay(alignment: .center) {
                if showLoadingIndicator {
                    ProgressView("Aggiornamento guida…")
                        .padding(18)
                }
            }
            .overlay(alignment: .bottom) {
                if let reminderToast {
                    Text(reminderToast)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onAppear {
                guard !didAppear else { return }
                didAppear = true
                hydrateVisibleProgramsFromCache()
            }
            .onChange(of: streams.map(\.streamId)) { _, _ in
                if pagedStreams.isEmpty {
                    renderLimit = min(renderPageSize, max(streams.count, 1))
                }
                hydrateVisibleProgramsFromCache()
            }
            .onChange(of: selectedGroupID) { _, _ in
                resetRenderedPage()
                hydrateVisibleProgramsFromCache()
            }
            .onChange(of: searchText) { _, _ in
                resetRenderedPage()
            }
            .onChange(of: showFavoritesOnly) { _, _ in
                resetRenderedPage()
            }
            .onDisappear {
                reloadTask?.cancel()
                loadingIndicatorTask?.cancel()
            }
        }
    }

    private var dayTimeHeader: some View {
        HStack(spacing: 10) {
            Button {
                selectedDayOffset -= 1
                scheduleReload()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)

            VStack(spacing: 1) {
                Text(selectedGroupName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(dayTitle)
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)

            Button {
                selectedDayOffset += 1
                scheduleReload()
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func channelRow(_ stream: XtreamStream) -> some View {
        HStack(alignment: .top, spacing: 10) {
            channelIdentity(stream)
                .frame(width: 92, alignment: .leading)

            if let programs = programsByStream[stream.streamId], !programs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(programs, id: \.id) { program in
                            programBlock(program, stream: stream)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } else if loadingStreamIDs.contains(stream.streamId) {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 76)
            } else if failedStreamIDs.contains(stream.streamId) {
                Button {
                    Task { await load(stream, forceRefresh: true) }
                } label: {
                    Label("Riprova", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 76)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(maxWidth: .infinity, minHeight: 76)
            }
        }
        .padding(.vertical, 4)
    }

    private func channelIdentity(_ stream: XtreamStream) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(stream.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)

            Text("CH \(stream.streamId)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func programBlock(_ program: EPGProgram, stream: XtreamStream) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(program.title)
                .font(.system(size: 16, weight: .regular, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(1.0)

            Text(programTimeText(program))
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
        }
        .padding(12)
        .frame(width: 212, height: 76, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.tint.gradient)
        }
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stream.name), \(program.title), \(programTimeText(program))")
    }

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
                HStack(spacing: 10) {
                    Image(systemName: selectedGroupSystemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 20)

                    Text(selectedGroupName)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }
                .padding(.horizontal, 16)
                .frame(minWidth: 156, maxWidth: 238, minHeight: 44)
                .contentShape(Capsule())
            }
            .menuStyle(.button)
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

    private var groupSelectionBinding: Binding<String?> {
        Binding(
            get: { selectedGroupID },
            set: { selectedGroupID = $0 }
        )
    }

    private var playlistOrderedStreams: [XtreamStream] {
        streams
    }

    private var filteredStreams: [XtreamStream] {
        playlistOrderedStreams.filter { stream in
            let groupMatches = selectedGroupID == nil || stream.categoryId == selectedGroupID
            let searchMatches = searchText.isEmpty || stream.name.localizedCaseInsensitiveContains(searchText)
            let favoriteMatches = !showFavoritesOnly || isFavorite(stream)
            return groupMatches && searchMatches && favoriteMatches
        }
    }

    private var pagedStreams: [XtreamStream] {
        Array(filteredStreams.prefix(max(renderLimit, 1)))
    }

    private var epgGroups: [EPGGroup] {
        var seen = Set<String>()
        return streams.compactMap { stream in
            guard let id = stream.categoryId, !id.isEmpty, seen.insert(id).inserted else {
                return nil
            }
            return EPGGroup(categoryId: id, categoryName: stream.categoryName ?? "Senza nome")
        }
    }

    private var selectedGroupName: String {
        guard let selectedGroupID else { return "Tutti" }
        return epgGroups.first(where: { $0.categoryId == selectedGroupID })?.categoryName ?? "Tutti"
    }

    private var selectedGroupSystemImage: String {
        selectedGroupID == nil
            ? "square.grid.2x2"
            : Self.groupIcon(for: selectedGroupName)
    }

    private var cacheScope: String {
        "\(credentials.serverURL.absoluteString)|\(credentials.username)"
    }

    private var dayTitle: String {
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: selectedDayOffset, to: Date()) ?? Date()

        if calendar.isDateInToday(date) { return "Oggi" }
        if calendar.isDateInYesterday(date) { return "Ieri" }
        if calendar.isDateInTomorrow(date) { return "Domani" }

        return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    private func groupChannelCount(_ categoryID: String) -> Int {
        streams.lazy.filter { $0.categoryId == categoryID }.count
    }

    private func resetRenderedPage() {
        renderLimit = min(renderPageSize, max(filteredStreams.count, 1))
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

    private func loadIfNeeded(_ stream: XtreamStream) async {
        guard programsByStream[stream.streamId] == nil, !loadingStreamIDs.contains(stream.streamId) else {
            return
        }
        await load(stream, forceRefresh: false)
    }

    @MainActor
    private func load(_ stream: XtreamStream, forceRefresh: Bool) async {
        guard !loadingStreamIDs.contains(stream.streamId) else { return }

        let scope = cacheScope
        if !forceRefresh,
           let cached = EPGMemoryCache.shared.programs(scope: scope, streamId: stream.streamId) {
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

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            await reloadEPG(forceRefresh: false)
        }
    }

    @MainActor
    private func refreshAll() async {
        await reloadEPG(forceRefresh: true)
        reminderToast = "Guida aggiornata"
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            reminderToast = nil
        }
    }

    private func isFavorite(_ stream: XtreamStream) -> Bool {
        false
    }

    private func programTimeText(_ program: EPGProgram) -> String {
        let start = program.start.formatted(date: .omitted, time: .shortened)
        let end = program.end.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    private static func groupIcon(for name: String) -> String {
        let normalized = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        if normalized.contains("sport") { return "sportscourt" }
        if normalized.contains("news") || normalized.contains("notizie") { return "newspaper" }
        if normalized.contains("movie") || normalized.contains("film") { return "film" }
        if normalized.contains("kid") || normalized.contains("bambin") { return "figure.and.child.holdinghands" }
        if normalized.contains("music") || normalized.contains("musica") { return "music.note" }
        return "tv"
    }
}

private struct EPGGroup: Identifiable {
    let categoryId: String
    let categoryName: String
    var id: String { categoryId }
}
