import SwiftUI

struct SourcesView: View {
    @EnvironmentObject var sourceManager: SourceManager
    @EnvironmentObject var contentManagement: ContentManagementService
    @State private var showAddSheet = false
    @State private var renamingSource: MediaSourceConfig?
    @State private var newName = ""
    @State private var showMergeSheet = false

    var body: some View {
        NavigationStack {
            List {
                Section("Le mie sorgenti") {
                    ForEach(sourceManager.sources) { source in
                        HStack {
                            Image(systemName: source.type.systemImage)
                            VStack(alignment: .leading) {
                                Text(source.name).font(.headline)
                                Text(source.type.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Circle().fill(source.isEnabled ? .green : .gray).frame(width: 8, height: 8)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { renamingSource = source; newName = source.name }
                    }
                    .onDelete { indices in indices.forEach { sourceManager.remove(sourceManager.sources[$0]) } }
                    .onMove { sourceManager.move(fromOffsets: $0, toOffset: $1) }
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
            }
            .navigationTitle("Sorgenti e contenuti")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { GlobalToolbarButtons() }
                ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAddSheet = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAddSheet) { AddSourceView { config in sourceManager.add(config) } }
            .sheet(isPresented: $showMergeSheet) {
                MergePlaylistView(sources: sourceManager.sources) { name, ids in
                    contentManagement.createMergedPlaylist(name: name, sourceIds: ids)
                }
            }
            .alert("Rinomina sorgente", isPresented: Binding(get: { renamingSource != nil }, set: { if !$0 { renamingSource = nil } })) {
                TextField("Nome", text: $newName)
                Button("Salva") {
                    if let source = renamingSource { sourceManager.rename(source, to: newName) }
                    renamingSource = nil
                }
                Button("Annulla", role: .cancel) { renamingSource = nil }
            }
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
