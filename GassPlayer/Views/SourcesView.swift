import SwiftUI

private enum SourceSortMode: String, CaseIterable, Identifiable {
    case manual = "Personalizzato"
    case name = "Nome (A-Z)"
    case type = "Tipo"

    var id: String { rawValue }
}

private struct ConnectionCheckResult: Identifiable {
    let id = UUID()
    let sourceName: String
    let succeeded: Bool
    let message: String
}

struct SourcesView: View {
    @EnvironmentObject private var sourceManager: SourceManager
    @EnvironmentObject private var contentManagement: ContentManagementService

    @State private var showAddSheet = false
    @State private var renamingSource: MediaSourceConfig?
    @State private var newName = ""
    @State private var showMergeSheet = false
    @State private var showAllSourcesLive = false
    @State private var searchQuery = ""
    @State private var sortMode: SourceSortMode = .manual
    @State private var checkingSourceId: UUID?
    @State private var connectionCheckResult: ConnectionCheckResult?

    private var displayedSources: [MediaSourceConfig] {
        let filteredSources = sourceManager.sources.filter { source in
            searchQuery.isEmpty
                || source.name.localizedCaseInsensitiveContains(searchQuery)
                || source.host.localizedCaseInsensitiveContains(searchQuery)
        }

        switch sortMode {
        case .manual:
            return filteredSources
        case .name:
            return filteredSources.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .type:
            return filteredSources.sorted {
                $0.type.rawValue.localizedCaseInsensitiveCompare($1.type.rawValue)
                    == .orderedAscending
            }
        }
    }

    private var canReorder: Bool {
        sortMode == .manual && searchQuery.isEmpty
    }

    private var xtreamSources: [MediaSourceConfig] {
        sourceManager.sources.filter { $0.type == .xtream }
    }

    var body: some View {
        List {
            allSourcesSection
            sourcesSection
            mergedPlaylistsSection
            favoritesSection
            backupSection
        }
        .navigationTitle("Sorgenti")
        .searchable(text: $searchQuery, prompt: "Cerca sorgenti")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Ordina per", selection: $sortMode) {
                        ForEach(SourceSortMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down.circle")
                }
                .accessibilityLabel("Ordina sorgenti")
            }

            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
                    .disabled(!canReorder)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Aggiungi sorgente")
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddSourceView { config in
                sourceManager.add(config)
            }
        }
        .sheet(isPresented: $showMergeSheet) {
            MergePlaylistView(sources: sourceManager.sources) { name, ids in
                contentManagement.createMergedPlaylist(name: name, sourceIds: ids)
            }
        }
        .sheet(isPresented: $showAllSourcesLive) {
            AllSourcesLiveView(sources: sourceManager.sources, kind: .live)
        }
        .alert(
            "Rinomina sorgente",
            isPresented: Binding(
                get: { renamingSource != nil },
                set: { isPresented in
                    if !isPresented {
                        renamingSource = nil
                    }
                }
            )
        ) {
            TextField("Nome", text: $newName)

            Button("Salva") {
                guard let source = renamingSource else { return }

                let trimmedName = newName.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

                if !trimmedName.isEmpty {
                    sourceManager.rename(source, to: trimmedName)
                }

                renamingSource = nil
            }

            Button("Annulla", role: .cancel) {
                renamingSource = nil
            }
        }
        .alert(item: $connectionCheckResult) { result in
            Alert(
                title: Text(
                    result.succeeded
                        ? "Connessione riuscita"
                        : "Connessione non riuscita"
                ),
                message: Text("\(result.sourceName): \(result.message)"),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var allSourcesSection: some View {
        Section {
            Button {
                showAllSourcesLive = true
            } label: {
                Label(
                    "Guarda tutte le liste insieme",
                    systemImage: "square.stack.3d.up.fill"
                )
            }
            .disabled(xtreamSources.isEmpty)
        } footer: {
            if xtreamSources.isEmpty {
                Text("Aggiungi almeno una sorgente Xtream per usare questa funzione.")
            }
        }
    }

    private var sourcesSection: some View {
        Section {
            if displayedSources.isEmpty {
                ContentUnavailableView(
                    searchQuery.isEmpty
                        ? "Nessuna sorgente"
                        : "Nessun risultato",
                    systemImage: searchQuery.isEmpty
                        ? "square.stack.3d.up"
                        : "magnifyingglass",
                    description: Text(
                        searchQuery.isEmpty
                            ? "Tocca + per aggiungere una playlist o un account supportato."
                            : "Prova a modificare la ricerca."
                    )
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(displayedSources) { source in
                    sourceRow(source)
                }
                .onDelete(deleteSources)
                .onMove(perform: moveSources)
            }
        } header: {
            HStack {
                Text("Le mie sorgenti")
                Spacer()
                Text("\(displayedSources.count)")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            if !canReorder && !displayedSources.isEmpty {
                Text("Per modificare l’ordine, usa l’ordinamento Personalizzato e svuota la ricerca.")
            }
        }
    }

    private var mergedPlaylistsSection: some View {
        Section("Playlist unite") {
            if contentManagement.mergedPlaylists.isEmpty {
                Text("Unisci più sorgenti in una sola playlist.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(contentManagement.mergedPlaylists) { merged in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(merged.name)
                            .font(.headline)

                        Text("\(merged.memberSourceIds.count) sorgenti unite")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { indices in
                    indices.forEach { index in
                        contentManagement.removeMergedPlaylist(
                            contentManagement.mergedPlaylists[index]
                        )
                    }
                }
                .onMove { from, to in
                    contentManagement.reorderMergedPlaylists(
                        fromOffsets: from,
                        toOffset: to
                    )
                }
            }

            Button("Crea playlist unita") {
                showMergeSheet = true
            }
            .disabled(sourceManager.sources.count < 2)
        }
    }

    private var favoritesSection: some View {
        Section("Preferiti") {
            if contentManagement.favorites.isEmpty {
                Text("I tuoi contenuti preferiti appariranno qui.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(contentManagement.favorites) { favorite in
                    Label(favorite.title, systemImage: "star.fill")
                        .foregroundStyle(.yellow)
                }
            }
        }
    }

    private var backupSection: some View {
        Section("Backup") {
            if let payload = try? SourceBackupCodec.encodeAsString(
                sourceManager.sources
            ) {
                ShareLink(
                    item: payload,
                    preview: SharePreview("Backup sorgenti GassPlayer")
                ) {
                    Label(
                        "Esporta sorgenti (JSON)",
                        systemImage: "square.and.arrow.up"
                    )
                }
            }
        } footer: {
            Text(
                "Il backup JSON può includere password e token. Condividilo solo tramite servizi affidabili."
            )
        }
    }

    @ViewBuilder
    private func sourceRow(_ source: MediaSourceConfig) -> some View {
        HStack(spacing: 12) {
            Image(systemName: source.type.systemImage)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(source.name)
                    .font(.headline)

                Text(source.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(source.type.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            if checkingSourceId == source.id {
                ProgressView()
                    .controlSize(.small)
            }

            if sourceManager.activeSourceId == source.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Sorgente attiva")
            }

            Circle()
                .fill(source.isEnabled ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
                .accessibilityLabel(
                    source.isEnabled ? "Sorgente abilitata" : "Sorgente disabilitata"
                )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            sourceManager.setActive(source)
        }
        .swipeActions(edge: .trailing) {
            Button {
                newName = source.name
                renamingSource = source
            } label: {
                Label("Rinomina", systemImage: "pencil")
            }
            .tint(.blue)

            Button {
                duplicate(source)
            } label: {
                Label("Duplica", systemImage: "plus.square.on.square")
            }
            .tint(.indigo)
        }
        .swipeActions(edge: .leading) {
            if source.type == .xtream {
                Button {
                    Task {
                        await testConnection(source)
                    }
                } label: {
                    Label("Verifica", systemImage: "checkmark.shield")
                }
                .tint(.green)
            }
        }
        .accessibilityHint("Tocca per impostare questa sorgente come attiva")
    }

    private func deleteSources(at offsets: IndexSet) {
        let sourcesToDelete = offsets.map { displayedSources[$0] }

        sourcesToDelete.forEach { source in
            sourceManager.remove(source)
        }
    }

    private func moveSources(from offsets: IndexSet, to destination: Int) {
        guard canReorder else { return }

        sourceManager.move(fromOffsets: offsets, toOffset: destination)
    }

    private func duplicate(_ source: MediaSourceConfig) {
        sourceManager.add(
            MediaSourceConfig(
                name: "\(source.name) (copia)",
                type: source.type,
                host: source.host,
                username: source.username,
                password: source.password
            )
        )
    }

    private func testConnection(_ source: MediaSourceConfig) async {
        guard let username = source.username,
              let password = source.password else {
            connectionCheckResult = ConnectionCheckResult(
                sourceName: source.name,
                succeeded: false,
                message: "Questa sorgente non contiene credenziali Xtream configurate."
            )
            return
        }

        checkingSourceId = source.id
        defer { checkingSourceId = nil }

        let credentials = XtreamCredentials(
            host: source.host,
            username: username,
            password: password
        )

        let service = XtreamAPIService(credentials: credentials)

        do {
            _ = try await service.authenticate()

            connectionCheckResult = ConnectionCheckResult(
                sourceName: source.name,
                succeeded: true,
                message: "Le credenziali sono valide e il server risponde correttamente."
            )
        } catch let error as XtreamError {
            connectionCheckResult = ConnectionCheckResult(
                sourceName: source.name,
                succeeded: false,
                message: error.errorDescription ?? "Errore Xtream sconosciuto."
            )
        } catch {
            connectionCheckResult = ConnectionCheckResult(
                sourceName: source.name,
                succeeded: false,
                message: error.localizedDescription
            )
        }
    }
}

struct AddSourceView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type: MediaSourceType = .xtream
    @State private var host = ""
    @State private var username = ""
    @State private var password = ""

    let onSave: (MediaSourceConfig) -> Void

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && !trimmedHost.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Informazioni") {
                    TextField("Nome sorgente", text: $name)

                    Picker("Tipo", selection: $type) {
                        ForEach(MediaSourceType.allCases) { sourceType in
                            Text(sourceType.rawValue).tag(sourceType)
                        }
                    }
                }

                Section("Connessione") {
                    TextField("Host / URL", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    if type != .m3u8 {
                        TextField("Username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        SecureField("Password / Token", text: $password)
                    }
                }
            }
            .navigationTitle("Nuova sorgente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        onSave(
                            MediaSourceConfig(
                                name: trimmedName,
                                type: type,
                                host: trimmedHost,
                                username: normalizedOptional(username),
                                password: normalizedOptional(password)
                            )
                        )
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private func normalizedOptional(_ value: String) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

struct MergePlaylistView: View {
    let sources: [MediaSourceConfig]
    let onCreate: (String, [UUID]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedIDs: Set<UUID> = []

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCreate: Bool {
        !trimmedName.isEmpty && selectedIDs.count >= 2
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Playlist") {
                    TextField("Nome playlist unita", text: $name)
                }

                Section("Sorgenti da unire") {
                    ForEach(sources) { source in
                        Toggle(
                            source.name,
                            isOn: Binding(
                                get: { selectedIDs.contains(source.id) },
                                set: { isSelected in
                                    if isSelected {
                                        selectedIDs.insert(source.id)
                                    } else {
                                        selectedIDs.remove(source.id)
                                    }
                                }
                            )
                        )
                    }
                } footer: {
                    Text("Seleziona almeno due sorgenti.")
                }
            }
            .navigationTitle("Unisci playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Crea") {
                        onCreate(trimmedName, Array(selectedIDs))
                        dismiss()
                    }
                    .disabled(!canCreate)
                }
            }
        }
    }
}
