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
    @EnvironmentObject var sourceManager: SourceManager
    @EnvironmentObject var contentManagement: ContentManagementService
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
        let base = sourceManager.sources.filter {
            searchQuery.isEmpty ||
            $0.name.localizedCaseInsensitiveContains(searchQuery) ||
            $0.host.localizedCaseInsensitiveContains(searchQuery)
        }
        switch sortMode {
        case .manual:
            return base
        case .name:
            return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .type:
            return base.sorted { $0.type.rawValue < $1.type.rawValue }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showAllSourcesLive = true
                    } label: {
                        Label("Guarda tutte le liste insieme", systemImage: "square.stack.3d.up.fill")
                    }
                    .disabled(sourceManager.sources.filter { $0.type == .xtream }.isEmpty)
                }

                Section {
                    ForEach(displayedSources) { source in
                        sourceRow(source)
                    }
                    .onDelete { indices in
                        indices.map { displayedSources[$0] }.forEach { sourceManager.remove($0) }
                    }
                    .onMove { from, to in
                        guard sortMode == .manual, searchQuery.isEmpty else { return }
                        sourceManager.move(fromOffsets: from, toOffset: to)
                    }
                } header: {
                    HStack {
                        Text("Le mie sorgenti")
                        Spacer()
                        Text("\(displayedSources.count)").foregroundStyle(.secondary)
                    }
                }

                Section("Playlist unite (merge)") {
                    ForEach(contentManagement.mergedPlaylists) { merged in
                        VStack(alignment: .leading) {
                            Text(merged.name).font(.headline)
                            Text("\(merged.memberSourceIds.count) sorgenti unite").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { indices in indices.forEach { contentManagement.removeMergedPlaylist(contentManagement.mergedPlaylists[$0]) } }
                    .onMove { contentManagement.reorderMergedPlaylists(fromOffsets: $0, toOffset: $1) }
                    Button("Crea nuova playlist unita") { showMergeSheet = true }
                }

                Section("Preferiti") {
                    ForEach(contentManagement.favorites) { fav in
                        Label(fav.title, systemImage: "star.fill").foregroundStyle(.yellow)
                    }
                }

                Section {
                    if let payload = try? SourceBackupCodec.encodeAsString(sourceManager.sources) {
                        ShareLink(item: payload, preview: SharePreview("Backup sorgenti GassPlayer")) {
                            Label("Esporta sorgenti (JSON)", systemImage: "square.and.arrow.up")
                        }
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Esporta un file di testo JSON con tutte le sorgenti configurate, da salvare o condividere. Le password restano nel file: condividilo solo con app o luoghi di cui ti fidi.")
                }
            }
            .navigationTitle("Sorgenti e contenuti")
            .searchable(text: $searchQuery, prompt: "Cerca sorgenti")
            .toolbar {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .navigationBarLeading) { GlassSearchButton() }
                    ToolbarSpacer(.fixed, placement: .navigationBarLeading)
                    ToolbarItem(placement: .navigationBarLeading) { GlassSettingsButton() }
                    ToolbarItem(placement: .navigationBarTrailing) { sortMenu }
                    ToolbarSpacer(.fixed, placement: .navigationBarTrailing)
                    ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
                    ToolbarSpacer(.fixed, placement: .navigationBarTrailing)
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showAddSheet = true } label: { Image(systemName: "plus") }
                    }
                } else {
                    ToolbarItem(placement: .navigationBarLeading) { GlassSearchButton() }
                    ToolbarItem(placement: .navigationBarLeading) { GlassSettingsButton() }
                    ToolbarItem(placement: .navigationBarTrailing) { sortMenu }
                    ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showAddSheet = true } label: { Image(systemName: "plus") }
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) { AddSourceView { config in sourceManager.add(config) } }
            .sheet(isPresented: $showMergeSheet) {
                MergePlaylistView(sources: sourceManager.sources) { name, ids in
                    contentManagement.createMergedPlaylist(name: name, sourceIds: ids)
                }
            }
            .sheet(isPresented: $showAllSourcesLive) {
                AllSourcesLiveView(sources: sourceManager.sources, kind: .live)
            }
            .alert("Rinomina sorgente", isPresented: Binding(get: { renamingSource != nil }, set: { if !$0 { renamingSource = nil } })) {
                TextField("Nome", text: $newName)
                Button("Salva") {
                    if let source = renamingSource { sourceManager.rename(source, to: newName) }
                    renamingSource = nil
                }
                Button("Annulla", role: .cancel) { renamingSource = nil }
            }
            .alert(item: $connectionCheckResult) { result in
                Alert(
                    title: Text(result.succeeded ? "Connessione riuscita" : "Connessione non riuscita"),
                    message: Text("\(result.sourceName): \(result.message)"),
                    dismissButton: .default(Text("OK"))
                )
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
    }

    @ViewBuilder
    private func sourceRow(_ source: MediaSourceConfig) -> some View {
        HStack {
            Image(systemName: source.type.systemImage)
            VStack(alignment: .leading) {
                Text(source.name).font(.headline)
                Text(source.type.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if checkingSourceId == source.id {
                ProgressView().controlSize(.small)
            }
            if sourceManager.activeSourceId == source.id {
                Label("Attiva", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
            }
            Circle().fill(source.isEnabled ? .green : .gray).frame(width: 8, height: 8)
        }
        .contentShape(Rectangle())
        .onTapGesture { sourceManager.setActive(source) }
        .swipeActions(edge: .trailing) {
            Button { renamingSource = source; newName = source.name } label: {
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
                    Task { await testConnection(source) }
                } label: {
                    Label("Verifica", systemImage: "checkmark.shield")
                }
                .tint(.green)
            }
        }
    }

    private func duplicate(_ source: MediaSourceConfig) {
        sourceManager.add(MediaSourceConfig(
            name: "\(source.name) (copia)",
            type: source.type,
            host: source.host,
            username: source.username,
            password: source.password
        ))
    }

    private func testConnection(_ source: MediaSourceConfig) async {
        guard let username = source.username, let password = source.password else {
            connectionCheckResult = ConnectionCheckResult(
                sourceName: source.name,
                succeeded: false,
                message: "Questa sorgente non ha username/password Xtream configurati."
            )
            return
        }

        checkingSourceId = source.id
        defer { checkingSourceId = nil }

        let credentials = XtreamCredentials(host: source.host, username: username, password: password)
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
    var onSave: (MediaSourceConfig) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Nome sorgente", text: $name)
                Picker("Tipo", selection: $type) { ForEach(MediaSourceType.allCases) { Text($0.rawValue).tag($0) } }
                TextField("Host / URL", text: $host).textInputAutocapitalization(.never)
                if type != .m3u8 {
                    TextField("Username", text: $username).textInputAutocapitalization(.never)
                    SecureField("Password / Token", text: $password)
                }
            }
            .navigationTitle("Nuova sorgente")
            .toolbar {
                Button("Salva") {
                    onSave(MediaSourceConfig(name: name, type: type, host: host, username: username, password: password))
                    dismiss()
                }
                .disabled(name.isEmpty || host.isEmpty)
            }
        }
    }
}

struct MergePlaylistView: View {
    let sources: [MediaSourceConfig]
    var onCreate: (String, [UUID]) -> Void
    @State private var name = ""
    @State private var selectedIds: Set<UUID> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Nome playlist unita", text: $name)
                Section("Sorgenti da unire") {
                    ForEach(sources) { source in
                        Toggle(source.name, isOn: Binding(
                            get: { selectedIds.contains(source.id) },
                            set: { isOn in if isOn { selectedIds.insert(source.id) } else { selectedIds.remove(source.id) } }
                        ))
                    }
                }
            }
            .navigationTitle("Unisci playlist")
            .toolbar {
                Button("Crea") { onCreate(name, Array(selectedIds)); dismiss() }
                    .disabled(name.isEmpty || selectedIds.isEmpty)
            }
        }
    }
}
