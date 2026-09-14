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
    @State private var checkingSourceID: UUID?
    @State private var connectionCheckResult: ConnectionCheckResult?

    private var displayedSources: [MediaSourceConfig] {
        let filtered = sourceManager.sources.filter { source in
            guard !searchQuery.isEmpty else { return true }

            return source.name.localizedCaseInsensitiveContains(searchQuery)
                || source.host.localizedCaseInsensitiveContains(searchQuery)
                || source.type.rawValue.localizedCaseInsensitiveContains(searchQuery)
        }

        switch sortMode {
        case .manual:
            return filtered
        case .name:
            return filtered.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .type:
            return filtered.sorted {
                let typeOrder = $0.type.rawValue.localizedCaseInsensitiveCompare($1.type.rawValue)

                if typeOrder == .orderedSame {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }

                return typeOrder == .orderedAscending
            }
        }
    }

    private var isManualOrderingAvailable: Bool {
        sortMode == .manual && searchQuery.isEmpty
    }

    private var canOpenAllSourcesLive: Bool {
        sourceManager.sources.contains { $0.type == .xtream && $0.isEnabled }
    }

    private var sourceCountText: String {
        let count = displayedSources.count
        return count == 1 ? "1 sorgente" : "\(count) sorgenti"
    }

    var body: some View {
        NavigationStack {
            List {
                liveAggregationSection
                sourcesSection
                mergedPlaylistsSection
                favoritesSection
                backupSection
            }
            .navigationTitle("Sorgenti")
            .searchable(text: $searchQuery, prompt: "Cerca sorgenti")
            .toolbar {
                toolbarContent
            }
            .sheet(isPresented: $showAddSheet) {
                AddSourceView { configuration in
                    sourceManager.add(configuration)
                }
            }
            .sheet(isPresented: $showMergeSheet) {
                MergePlaylistView(sources: sourceManager.sources) { name, sourceIDs in
                    contentManagement.createMergedPlaylist(
                        name: name,
                        sourceIds: sourceIDs
                    )
                }
            }
            .sheet(isPresented: $showAllSourcesLive) {
                AllSourcesLiveView(
                    sources: sourceManager.sources.filter { $0.isEnabled },
                    kind: .live
                )
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
                    renameSelectedSource()
                }

                Button("Annulla", role: .cancel) {
                    renamingSource = nil
                }
            } message: {
                Text("Scegli un nome riconoscibile per questa sorgente.")
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
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .navigationBarLeading) {
                GlassSearchButton()
            }

            ToolbarSpacer(.fixed, placement: .navigationBarLeading)

            ToolbarItem(placement: .navigationBarLeading) {
                GlassSettingsButton()
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                sortMenu
            }

            ToolbarSpacer(.fixed, placement: .navigationBarTrailing)

            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
                    .disabled(!isManualOrderingAvailable)
            }

            ToolbarSpacer(.fixed, placement: .navigationBarTrailing)

            ToolbarItem(placement: .navigationBarTrailing) {
                addSourceButton
            }
        } else {
            ToolbarItem(placement: .navigationBarLeading) {
                GlassSearchButton()
            }

            ToolbarItem(placement: .navigationBarLeading) {
                GlassSettingsButton()
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                sortMenu
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
                    .disabled(!isManualOrderingAvailable)
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                addSourceButton
            }
        }
    }

    private var sortMenu: some View {
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
        .accessibilityHint("Scegli l’ordinamento delle sorgenti")
    }

    private var addSourceButton: some View {
        Button {
            showAddSheet = true
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("Aggiungi sorgente")
    }

    private var liveAggregationSection: some View {
        Section {
            Button {
                showAllSourcesLive = true
            } label: {
                Label(
                    "Guarda tutte le liste insieme",
                    systemImage: "square.stack.3d.up.fill"
                )
            }
            .disabled(!canOpenAllSourcesLive)
        } header: {
            Text("Live TV")
        } footer: {
            if !canOpenAllSourcesLive {
                Text("Aggiungi e abilita almeno una sorgente Xtream per unire i canali Live TV.")
            }
        }
    }

    private var sourcesSection: some View {
        Section {
            if displayedSources.isEmpty {
                ContentUnavailableView(
                    searchQuery.isEmpty
                        ? "Nessuna sorgente configurata"
                        : "Nessun risultato",
                    systemImage: searchQuery.isEmpty
                        ? "square.stack.3d.up"
                        : "magnifyingglass",
                    description: Text(
                        searchQuery.isEmpty
                            ? "Tocca + per aggiungere una playlist M3U o un account supportato."
                            : "Prova a cercare con un altro nome, host o tipo."
                    )
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(displayedSources) { source in
                    sourceRow(source)
                }
                .onDelete(perform: deleteSources)
                .onMove(perform: moveSources)
            }
        } header: {
            HStack {
                Text("Le mie sorgenti")
                Spacer()
                Text(sourceCountText)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            if !isManualOrderingAvailable && !displayedSources.isEmpty {
                Text("Per modificare l’ordine, seleziona “Personalizzato” e svuota la ricerca.")
            }
        }
    }

    private var mergedPlaylistsSection: some View {
        Section {
            if contentManagement.mergedPlaylists.isEmpty {
                Text("Unisci più sorgenti in una sola playlist.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(contentManagement.mergedPlaylists) { mergedPlaylist in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(mergedPlaylist.name)
                            .font(.headline)

                        Text("\(mergedPlaylist.memberSourceIds.count) sorgenti unite")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    let playlistsToDelete = offsets.map {
                        contentManagement.mergedPlaylists[$0]
                    }

                    playlistsToDelete.forEach(contentManagement.removeMergedPlaylist)
                }
                .onMove { offsets, destination in
                    contentManagement.reorderMergedPlaylists(
                        fromOffsets: offsets,
                        toOffset: destination
                    )
                }
            }

            Button("Crea playlist unita") {
                showMergeSheet = true
            }
            .disabled(sourceManager.sources.count < 2)
        } header: {
            Text("Playlist unite")
        } footer: {
            Text("Sono necessarie almeno due sorgenti per creare una playlist unita.")
        }
    }

    private var favoritesSection: some View {
        Section {
            if contentManagement.favorites.isEmpty {
                Text("I tuoi contenuti preferiti appariranno qui.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(contentManagement.favorites) { favorite in
                    Label(favorite.title, systemImage: "star.fill")
                        .foregroundStyle(.yellow)
                }
            }
        } header: {
            Text("Preferiti")
        }
    }

    private var backupSection: some View {
        Section {
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
        } header: {
            Text("Backup")
        } footer: {
            Text("Il file JSON può contenere credenziali e token. Condividilo solo tramite servizi affidabili.")
        }
    }

    @ViewBuilder
    private func sourceRow(_ source: MediaSourceConfig) -> some View {
        HStack(spacing: 12) {
            Image(systemName: source.type.systemImage)
                .font(.body.weight(.semibold))
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

            if checkingSourceID == source.id {
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
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
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
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
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
        guard isManualOrderingAvailable else { return }

        sourceManager.move(fromOffsets: offsets, toOffset: destination)
    }

    private func renameSelectedSource() {
        guard let source = renamingSource else { return }

        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        sourceManager.rename(source, to: trimmedName)
        renamingSource = nil
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

    @MainActor
    private func testConnection(_ source: MediaSourceConfig) async {
        guard let username = source.username,
              !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let password = source.password,
              !password.isEmpty else {
            connectionCheckResult = ConnectionCheckResult(
                sourceName: source.name,
                succeeded: false,
                message: "Questa sorgente non contiene credenziali Xtream valide."
            )
            return
        }

        checkingSourceID = source.id
        defer { checkingSourceID = nil }

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

    private var requiresCredentials: Bool {
        type != .m3u8
    }

    private var canSave: Bool {
        guard !trimmedName.isEmpty, !trimmedHost.isEmpty else {
            return false
        }

        guard requiresCredentials else {
            return true
        }

        return !trimmedUsername.isEmpty && !trimmedPassword.isEmpty
    }

    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPassword: String {
        password.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nome sorgente", text: $name)

                    Picker("Tipo", selection: $type) {
                        ForEach(MediaSourceType.allCases) { sourceType in
                            Text(sourceType.rawValue).tag(sourceType)
                        }
                    }
                } header: {
                    Text("Informazioni")
                }

                Section {
                    TextField("Host / URL", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    if requiresCredentials {
                        TextField("Username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        SecureField("Password / Token", text: $password)
                    }
                } header: {
                    Text("Connessione")
                } footer: {
                    if type == .m3u8 {
                        Text("Inserisci un URL completo http:// o https:// della playlist M3U/M3U8.")
                    } else {
                        Text("Inserisci l’host completo, username e password o token del servizio.")
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
                                username: requiresCredentials ? trimmedUsername : nil,
                                password: requiresCredentials ? trimmedPassword : nil
                            )
                        )
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
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
                Section {
                    TextField("Nome playlist unita", text: $name)
                } header: {
                    Text("Playlist")
                }

                Section {
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
                } header: {
                    Text("Sorgenti da unire")
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
