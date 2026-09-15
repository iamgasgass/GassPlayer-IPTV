import SwiftUI

/// Versione compatibile con il call-site esistente:
///
/// EPGGridView(credentials: credentials, kind: .live) { stream in
///     // azione di riproduzione/canale già presente in ChannelGridView
/// }
///
/// Non usa EPGMemoryCache, credentials.serverURL o .tint.gradient.
/// Mantiene il provider/cache EPG già implementato nel progetto tramite EPGService.
struct EPGGridView: View {
    let credentials: XtreamCredentials
    let kind: XtreamContentKind
    let onSelect: (XtreamStream) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var streams: [XtreamStream] = []
    @State private var selectedGroupID: String?
    @State private var searchText = ""
    @State private var selectedDayOffset = 0
    @State private var didLoadStreams = false
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var programsByStream: [Int: [EPGProgram]] = [:]
    @State private var loadingStreamIDs = Set<Int>()

    private let programCardWidth: CGFloat = 212
    private let programCardHeight: CGFloat = 76
    private let streamColumnWidth: CGFloat = 96

    init(
        credentials: XtreamCredentials,
        kind: XtreamContentKind,
        onSelect: @escaping (XtreamStream) -> Void
    ) {
        self.credentials = credentials
        self.kind = kind
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Guida TV")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $searchText, prompt: "Cerca canale")
                .toolbar(content: toolbarContent)
                .task {
                    await initialLoad()
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            guideHeader

            if isLoading && streams.isEmpty {
                ProgressView("Caricamento guida…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError, streams.isEmpty {
                unavailableState(
                    title: "Impossibile caricare la guida",
                    systemImage: "exclamationmark.triangle",
                    message: loadError
                )
            } else if filteredStreams.isEmpty {
                unavailableState(
                    title: searchText.isEmpty ? "Nessun canale" : "Nessun risultato",
                    systemImage: searchText.isEmpty ? "tv.slash" : "magnifyingglass",
                    message: searchText.isEmpty
                        ? "Non ci sono canali nel gruppo selezionato."
                        : "Prova con un altro termine di ricerca."
                )
            } else {
                channelList
            }
        }
    }

    private var channelList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(filteredStreams, id: \.streamId) { stream in
                    channelRow(stream)
                        .task(id: stream.streamId) {
                            await loadProgramsIfNeeded(for: stream)
                        }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 20)
        }
    }

    private var guideHeader: some View {
        HStack(spacing: 10) {
            Button {
                selectedDayOffset -= 1
                reloadVisiblePrograms()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)

            Text(dayTitle)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)

            Button {
                selectedDayOffset += 1
                reloadVisiblePrograms()
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func unavailableState(
        title: String,
        systemImage: String,
        message: String
    ) -> some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(message)
        )
    }

    private func channelRow(_ stream: XtreamStream) -> some View {
        HStack(alignment: .top, spacing: 10) {
            channelLabel(stream)
                .frame(width: streamColumnWidth, alignment: .leading)

            programArea(stream)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(stream)
        }
    }

    private func channelLabel(_ stream: XtreamStream) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(stream.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)

            Text("CH \(stream.streamId)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func programArea(_ stream: XtreamStream) -> some View {
        if let programs = programsByStream[stream.streamId], !programs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(programs, id: \.id) { program in
                        programCard(program, stream: stream)
                    }
                }
                .padding(.vertical, 2)
            }
        } else if loadingStreamIDs.contains(stream.streamId) {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: programCardHeight)
        } else {
            Text("Nessun programma disponibile")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: programCardHeight, alignment: .leading)
        }
    }

    private func programCard(_ program: EPGProgram, stream: XtreamStream) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Punto 2: il titolo resta tassativamente su una sola riga.
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
        .frame(width: programCardWidth, height: programCardHeight, alignment: .leading)
        .background(programCardBackground)
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stream.name), \(program.title), \(programTimeText(program))")
    }

    private var programCardBackground: some View {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
            .fill(Color.accentColor.gradient)
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
                Picker("Gruppo playlist", selection: $selectedGroupID) {
                    Label("Tutti i canali", systemImage: "square.grid.2x2")
                        .tag(String?.none)

                    if !groups.isEmpty {
                        Divider()

                        ForEach(groups) { group in
                            Label(
                                "\(group.name) (\(group.count))",
                                systemImage: Self.groupIcon(for: group.name)
                            )
                            .tag(Optional(group.id))
                        }
                    }
                }
                .pickerStyle(.inline)
            } label: {
                // Capsule centrale: stessa resa Liquid Glass nativa della toolbar,
                // ma forma e proporzioni larghe come nel design di riferimento.
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
                    Task { await reloadAllPrograms() }
                } label: {
                    Label("Aggiorna guida", systemImage: "arrow.clockwise")
                }

                Divider()

                Button {
                    selectedDayOffset -= 1
                    reloadVisiblePrograms()
                } label: {
                    Label("Ieri", systemImage: "chevron.left")
                }

                Button {
                    selectedDayOffset = 0
                    reloadVisiblePrograms()
                } label: {
                    Label("Oggi", systemImage: "calendar")
                }

                Button {
                    selectedDayOffset += 1
                    reloadVisiblePrograms()
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

    private var filteredStreams: [XtreamStream] {
        streams.filter { stream in
            let matchesGroup = selectedGroupID == nil || stream.categoryId == selectedGroupID
            let matchesSearch = searchText.isEmpty || stream.name.localizedCaseInsensitiveContains(searchText)
            return matchesGroup && matchesSearch
        }
    }

    private var groups: [GuideGroup] {
        var knownIDs = Set<String>()
        var result: [GuideGroup] = []

        for stream in streams {
            guard let id = stream.categoryId, !id.isEmpty else { continue }
            guard knownIDs.insert(id).inserted else { continue }

            let name = stream.categoryName ?? "Senza nome"
            let count = streams.lazy.filter { $0.categoryId == id }.count
            result.append(GuideGroup(id: id, name: name, count: count))
        }

        return result
    }

    private var selectedGroupName: String {
        guard let selectedGroupID else { return "Tutti" }
        return groups.first(where: { $0.id == selectedGroupID })?.name ?? "Tutti"
    }

    private var selectedGroupSystemImage: String {
        selectedGroupID == nil ? "square.grid.2x2" : Self.groupIcon(for: selectedGroupName)
    }

    private var dayTitle: String {
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: selectedDayOffset, to: Date()) ?? Date()

        if calendar.isDateInToday(date) { return "Oggi" }
        if calendar.isDateInYesterday(date) { return "Ieri" }
        if calendar.isDateInTomorrow(date) { return "Domani" }

        return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    @MainActor
    private func initialLoad() async {
        guard !didLoadStreams else { return }
        didLoadStreams = true
        await loadStreams()
    }

    @MainActor
    private func loadStreams() async {
        isLoading = true
        loadError = nil

        do {
            // Usa l'API che il progetto aveva già prima della sostituzione.
            // Se nel tuo EPGService il metodo ha un nome diverso, conserva la
            // chiamata precedente esclusivamente in questo punto.
            streams = try await EPGService(credentials: credentials).streams(kind: kind)
        } catch {
            loadError = error.localizedDescription
        }

        isLoading = false
    }

    private func loadProgramsIfNeeded(for stream: XtreamStream) async {
        guard programsByStream[stream.streamId] == nil else { return }
        await loadPrograms(for: stream, forceRefresh: false)
    }

    @MainActor
    private func loadPrograms(for stream: XtreamStream, forceRefresh: Bool) async {
        guard !loadingStreamIDs.contains(stream.streamId) else { return }
        loadingStreamIDs.insert(stream.streamId)
        defer { loadingStreamIDs.remove(stream.streamId) }

        do {
            let programs = try await EPGService(credentials: credentials).shortEPG(
                streamId: stream.streamId,
                limit: 12,
                forceRefresh: forceRefresh
            )
            programsByStream[stream.streamId] = programs
        } catch {
            programsByStream[stream.streamId] = []
        }
    }

    @MainActor
    private func reloadVisiblePrograms() {
        programsByStream.removeAll()
    }

    @MainActor
    private func reloadAllPrograms() async {
        programsByStream.removeAll()

        for stream in filteredStreams {
            await loadPrograms(for: stream, forceRefresh: true)
        }
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

private struct GuideGroup: Identifiable {
    let id: String
    let name: String
    let count: Int
}
