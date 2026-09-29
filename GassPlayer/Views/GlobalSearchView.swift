import SwiftUI

private struct SelectedSeriesResult: Identifiable, Hashable {
    let id = UUID()
    let credentials: XtreamCredentials
    let seriesId: Int
    let name: String

    static func == (lhs: SelectedSeriesResult, rhs: SelectedSeriesResult) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private struct SelectedPlayable: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let title: String

    static func == (lhs: SelectedPlayable, rhs: SelectedPlayable) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private extension XtreamStreamKind {
    /// Colore distintivo per riga nei risultati di ricerca (icona +
    /// alone dietro l'icona). Non nel modello condiviso `XtreamModels.swift`
    /// per non introdurre un import SwiftUI lì dove non serve altrove.
    var accentColor: Color {
        switch self {
        case .live: return .red
        case .movie: return .indigo
        case .series: return .teal
        }
    }
}

struct GlobalSearchView: View {
    @EnvironmentObject var sourceManager: SourceManager
    @StateObject private var history = SearchHistoryStore()

    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedPlayable: SelectedPlayable?
    @State private var selectedSeries: SelectedSeriesResult?
    @State private var selectedKindFilter: XtreamStreamKind?

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredResults: [SearchResult] {
        guard let selectedKindFilter else { return results }
        return results.filter { $0.kind == selectedKindFilter }
    }

    var body: some View {
        NavigationStack {
            Group {
                if trimmedQuery.count < 2 {
                    recentSearchesView
                } else {
                    searchResultsView
                }
            }
            .background(background)
            .navigationTitle("Ricerca globale")
            .searchable(text: $query, prompt: "Cerca in tutte le playlist")
            .onChange(of: query) { _, newValue in scheduleSearch(newValue) }
            // Piccolo indicatore discreto in alto durante la ricerca, non
            // più uno spinner centrale che blocca la vista dei risultati
            // già presenti (percepito come più fluido, meno "a scatti").
            .safeAreaInset(edge: .top) {
                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                }
            }
            .fullScreenCover(item: $selectedPlayable) { playable in
                AdaptivePlayerView(url: playable.url, title: playable.title)
            }
            .fullScreenCover(item: $selectedSeries) { selection in
                SeriesEpisodesView(credentials: selection.credentials, seriesId: selection.seriesId, seriesName: selection.name)
            }
        }
    }

    /// Stesso sfondo sfumato usato in `SettingsView`, per coerenza visiva.
    private var background: some View {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.08),
                Color(uiColor: .systemBackground),
                Color.purple.opacity(0.05)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var searchResultsView: some View {
        VStack(spacing: 0) {
            filterChips
            if filteredResults.isEmpty && !isSearching {
                ContentUnavailableView.search(text: query)
            } else {
                // `LazyVStack` invece di `List`: righe caricate solo quando
                // visibili (scorrimento più fluido su cataloghi con
                // migliaia di risultati aggregati da più playlist) e stile
                // Liquid Glass coerente col resto dell'app.
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredResults) { result in
                            searchResultRow(result)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.immediately)
            }
        }
    }

    private func searchResultRow(_ result: SearchResult) -> some View {
        Button {
            open(result)
        } label: {
            GlassCard(cornerRadius: 16, padding: 14) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(result.kind.accentColor.opacity(0.18))
                        Image(systemName: result.kind.systemImage)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(result.kind.accentColor)
                    }
                    .frame(width: 38, height: 38)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(result.sourceName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(title: "Tutti (\(results.count))", isSelected: selectedKindFilter == nil) {
                    selectedKindFilter = nil
                }
                ForEach(XtreamStreamKind.allCases) { kind in
                    let count = results.filter { $0.kind == kind }.count
                    filterChip(title: "\(kind.displayName) (\(count))", isSelected: selectedKindFilter == kind) {
                        selectedKindFilter = kind
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func filterChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        if isSelected {
            Button(action: action) {
                chipLabel(title, isSelected: true)
            }
            .modifier(NativeOrLegacyGlassCapsule())
        } else {
            Button(action: action) {
                chipLabel(title, isSelected: false)
            }
            .modifier(NativeOrLegacyGlassNeutralCapsule())
        }
    }

    private func chipLabel(_ title: String, isSelected: Bool) -> some View {
        Text(title)
            .font(.caption.weight(isSelected ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
    }

    @ViewBuilder
    private var recentSearchesView: some View {
        if history.items.isEmpty {
            ContentUnavailableView(
                "Cerca nel catalogo",
                systemImage: "magnifyingglass",
                description: Text("Inserisci almeno due caratteri per cercare canali, film e serie in tutte le tue sorgenti.")
            )
        } else {
            List {
                Section {
                    ForEach(history.items, id: \.self) { item in
                        Button {
                            query = item
                        } label: {
                            Label(item, systemImage: "clock.arrow.circlepath")
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { history.remove(item) } label: {
                                Label("Rimuovi", systemImage: "trash")
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    HStack {
                        Text("Ricerche recenti")
                        Spacer()
                        Button("Cancella") { history.clear() }
                            .font(.caption)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func open(_ result: SearchResult) {
        switch result.kind {
        case .live, .movie:
            let service = XtreamAPIService(credentials: result.credentials)
            guard let url = service.streamURL(for: result.streamId, kind: result.kind) else {
                DebugLogger.logAsync(.error, "GlobalSearchView: impossibile costruire l'URL per \(result.title)")
                return
            }
            selectedPlayable = SelectedPlayable(url: url, title: result.title)
        case .series:
            selectedSeries = SelectedSeriesResult(credentials: result.credentials, seriesId: result.streamId, name: result.title)
        }
    }

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await runSearch(text)
        }
    }

    private func runSearch(_ text: String) async {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else {
            results = []
            return
        }
        isSearching = true
        let service = GlobalSearchService(configs: sourceManager.sources)
        let newResults = await service.search(text)
        guard !Task.isCancelled else { return }
        results = newResults
        history.record(text)
        selectedKindFilter = nil
        isSearching = false
    }
}
