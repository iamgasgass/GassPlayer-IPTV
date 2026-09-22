import SwiftUI
import UIKit

private enum SourceSortMode: String, CaseIterable, Identifiable {
    case manual = "Personalizzato"
    case name = "Nome (A-Z)"
    case type = "Tipo"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .manual: return "hand.draw.fill"
        case .name: return "textformat.abc"
        case .type: return "square.grid.2x2.fill"
        }
    }
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
    @State private var isCheckingAll = false
    @State private var showImportSheet = false
    @State private var importText = ""
    @State private var importFeedback: ImportFeedback?

    private struct ImportFeedback: Identifiable {
        let id = UUID()
        let message: String
        let succeeded: Bool
    }

    /// UNICA spaziatura usata per OGNI gap del layout: header→tab,
    /// tab→tab, tab→header successivo.
    private let glassTabSpacing: CGFloat = 12

    private var displayedSources: [MediaSourceConfig] {
        let filtered = sourceManager.sources.filter { source in
            guard !searchQuery.isEmpty else { return true }

            return source.name.localizedCaseInsensitiveContains(searchQuery)
                || source.host.localizedCaseInsensitiveContains(searchQuery)
                || source.type.rawValue.localizedCaseInsensitiveContains(searchQuery)
        }

        let sorted: [MediaSourceConfig]
        switch sortMode {
        case .manual:
            sorted = filtered
        case .name:
            sorted = filtered.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .type:
            sorted = filtered.sorted {
                let typeOrder = $0.type.rawValue.localizedCaseInsensitiveCompare($1.type.rawValue)

                if typeOrder == .orderedSame {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }

                return typeOrder == .orderedAscending
            }
        }

        // Le sorgenti fissate restano sempre in cima, indipendentemente dall'ordinamento scelto.
        return sorted.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }

            return false
        }
    }

    private var verifiableSourceCount: Int {
        sourceManager.sources.filter { $0.type == .xtream }.count
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
            ScrollView {
                VStack(alignment: .leading, spacing: glassTabSpacing) {
                    liveAggregationHeader
                    liveAggregationRow

                    sourcesHeader
                    addPlaylistRow.glassTab()
                    manageSourcesRow
                    sourcesContent
                    sourcesFooter

                    mergedPlaylistsHeader
                    mergedPlaylistsContent
                    createMergedPlaylistRow.glassTab()
                    mergedPlaylistsFooter

                    favoritesHeader
                    favoritesContent

                    backupHeader
                    exportRow
                    importRow
                    verifyAllRow
                    backupFooter
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .glassScreenBackground()
            .navigationTitle("Sorgenti")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchQuery, prompt: "Cerca sorgenti")
            .toolbar {
                toolbarContent
            }
            .sheet(isPresented: $showAddSheet) {
                AddPlaylistView { configuration in
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
            .alert(item: $importFeedback) { feedback in
                Alert(
                    title: Text(feedback.succeeded ? "Importazione completata" : "Importazione non riuscita"),
                    message: Text(feedback.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .sheet(isPresented: $showImportSheet) {
                ImportSourcesSheet(text: $importText, onImport: importSources)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            sortPill
        }

        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .navigationBarLeading) {
                GlassSearchButton()
            }

            ToolbarSpacer(.fixed, placement: .navigationBarLeading)

            ToolbarItem(placement: .navigationBarLeading) {
                GlassSettingsButton()
            }

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
                addSourceButton
            }
        }
    }

    private var sortPill: some View {
        Menu {
            Picker("Ordina per", selection: $sortMode) {
                ForEach(SourceSortMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            GlassMenuPillLabel(
                systemImage: sortMode.systemImage,
                title: sortMode.rawValue,
                tint: .accentColor
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Ordina sorgenti: \(sortMode.rawValue)")
        .accessibilityHint("Tocca per cambiare l'ordinamento delle sorgenti")
    }

    private var addSourceButton: some View {
        Button {
            showAddSheet = true
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("Aggiungi sorgente")
    }

    // MARK: - Live TV

    private var liveAggregationHeader: some View {
        GlassSectionHeader(title: "Live TV")
    }

    private var liveAggregationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            GlassSettingsRow(
                icon: "square.stack.3d.up.fill",
                title: "Guarda tutte le liste insieme",
                tint: .red,
                showChevron: false,
                isDisabled: !canOpenAllSourcesLive
            ) {
                showAllSourcesLive = true
            }
            .glassTab()

            if !canOpenAllSourcesLive {
                Text("Aggiungi e abilita almeno una sorgente Xtream per unire i canali Live TV.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Le mie sorgenti

    private var sourcesHeader: some View {
        HStack {
            GlassSectionHeader(title: "Le mie sorgenti")
            Spacer()
            Text(sourceCountText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    /// Voce "Aggiungi playlist": stessa azione del pulsante "+" in toolbar,
    /// ma come voce esplicita della sezione Sorgenti.
    private var addPlaylistRow: some View {
        GlassSettingsRow(
            icon: "plus.circle.fill",
            title: "Aggiungi playlist",
            tint: .blue
        ) {
            showAddSheet = true
        }
    }

    /// Voce "Gestisci sorgenti": apre l'hub dedicato che elenca tutte le
    /// sorgenti e permette di entrare direttamente nella scheda di gestione
    /// (`SourceManageView`) di ciascuna.
    ///
    /// FIX — testo blu invece di bianco: `NavigationLink`, fuori da una
    /// `List`, applica di default il tint di sistema (blu) all'intera
    /// label, sovrascrivendo il `.foregroundStyle(.primary)` già impostato
    /// dentro `GlassSourceRowLabel`. `.buttonStyle(.plain)` disattiva quello
    /// stile automatico e lascia che il colore del testo sia quello
    /// impostato dalla label stessa (bianco in dark mode, come le altre tab).
    ///
    /// FIX — disallineamento: rimosso il `.padding(.horizontal, 16)`
    /// manuale che avevo aggiunto per errore dentro la label; `.glassTab()`
    /// applicato esternamente fornisce già lo stesso identico padding
    /// orizzontale delle altre tab, quindi quello interno duplicava
    /// l'inset e spostava icona/testo fuori asse rispetto al resto.
    private var manageSourcesRow: some View {
        NavigationLink {
            SourceManagerView()
        } label: {
            GlassSourceRowLabel(icon: "gearshape.2.fill", title: "Gestisci sorgenti", tint: .indigo)
        }
        .buttonStyle(.plain)
        .glassTab()
        .disabled(sourceManager.sources.isEmpty)
    }

    @ViewBuilder
    private var sourcesContent: some View {
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
                        ? "Tocca “Aggiungi playlist” per collegare una playlist M3U o un account supportato."
                        : "Prova a cercare con un altro nome, host o tipo."
                )
            )
        } else {
            ForEach(displayedSources) { source in
                sourceRow(source)
                    .glassTab()
            }
        }
    }

    @ViewBuilder
    private var sourcesFooter: some View {
        EmptyView()
    }

    // MARK: - Playlist unite

    private var mergedPlaylistsHeader: some View {
        GlassSectionHeader(title: "Playlist unite")
    }

    @ViewBuilder
    private var mergedPlaylistsContent: some View {
        if contentManagement.mergedPlaylists.isEmpty {
            Text("Unisci più sorgenti in una sola playlist.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(contentManagement.mergedPlaylists) { mergedPlaylist in
                HStack(spacing: 12) {
                    GlassSourceIcon(systemImage: "square.stack.3d.up.fill", tint: .purple, size: 36)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(mergedPlaylist.name)
                            .font(.headline)
                        Text("\(mergedPlaylist.memberSourceIds.count) sorgenti unite")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(role: .destructive) {
                        contentManagement.removeMergedPlaylist(mergedPlaylist)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Elimina \(mergedPlaylist.name)")
                }
                .glassTab()
            }
        }
    }

    private var createMergedPlaylistRow: some View {
        GlassSettingsRow(
            icon: "plus.square.on.square",
            title: "Crea playlist unita",
            tint: .purple,
            showChevron: false,
            isDisabled: sourceManager.sources.count < 2
        ) {
            showMergeSheet = true
        }
    }

    private var mergedPlaylistsFooter: some View {
        Text("Sono necessarie almeno due sorgenti per creare una playlist unita.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Preferiti

    private var favoritesHeader: some View {
        GlassSectionHeader(title: "Preferiti")
    }

    @ViewBuilder
    private var favoritesContent: some View {
        if contentManagement.favorites.isEmpty {
            Text("I tuoi contenuti preferiti appariranno qui.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(contentManagement.favorites) { favorite in
                HStack(spacing: 12) {
                    GlassSourceIcon(systemImage: "star.fill", tint: .yellow, size: 36)
                    Text(favorite.title)
                        .font(.body.weight(.medium))
                }
                .glassTab()
            }
        }
    }

    // MARK: - Backup

    private var backupHeader: some View {
        GlassSectionHeader(title: "Backup")
    }

    /// Voce "Esporta sorgenti (JSON)".
    ///
    /// FIX — stesse due correzioni di `manageSourcesRow`: `.buttonStyle(.plain)`
    /// su `ShareLink` (che, come `NavigationLink`, tinge di blu la label di
    /// default fuori da una `List`) e rimozione del padding orizzontale
    /// duplicato.
    @ViewBuilder
    private var exportRow: some View {
        if let payload = try? SourceBackupCodec.encodeAsString(sourceManager.sources) {
            ShareLink(
                item: payload,
                preview: SharePreview("Backup sorgenti GassPlayer")
            ) {
                GlassSourceRowLabel(
                    icon: "square.and.arrow.up",
                    title: "Esporta sorgenti (JSON)",
                    tint: .blue
                )
            }
            .buttonStyle(.plain)
            .glassTab()
        }
    }

    private var importRow: some View {
        GlassSettingsRow(
            icon: "square.and.arrow.down",
            title: "Importa sorgenti (JSON)",
            tint: .blue,
            showChevron: false
        ) {
            importText = ""
            showImportSheet = true
        }
        .glassTab()
    }

    private var verifyAllRow: some View {
        GlassSettingsRow(
            icon: "checkmark.shield",
            title: "Verifica tutte le sorgenti Xtream",
            tint: .green,
            showChevron: false,
            showsProgress: isCheckingAll,
            isDisabled: verifiableSourceCount == 0
        ) {
            Task { await verifyAllSources() }
        }
        .glassTab()
    }

    private var backupFooter: some View {
        Text("Il file JSON può contenere credenziali e token. Condividilo solo tramite servizi affidabili.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Riga sorgente

    @ViewBuilder
    private func sourceRow(_ source: MediaSourceConfig) -> some View {
        HStack(spacing: 12) {
            GlassSourceIcon(
                systemImage: source.iconName ?? source.type.systemImage,
                tint: source.type.glassTint,
                size: 40
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if source.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    Text(source.name)
                        .font(.headline)
                }

                Text(source.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(source.type.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if let succeeded = source.lastVerificationSucceeded, let verifiedAt = source.lastVerifiedAt {
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Label(
                            verifiedAt.formatted(date: .abbreviated, time: .shortened),
                            systemImage: succeeded ? "checkmark.circle" : "xmark.circle"
                        )
                        .font(.caption2)
                        .foregroundStyle(succeeded ? .green : .red)
                    }
                }
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
        .contextMenu {
            Button {
                newName = source.name
                renamingSource = source
            } label: {
                Label("Rinomina", systemImage: "pencil")
            }

            Button {
                sourceManager.togglePinned(source)
            } label: {
                Label(source.isPinned ? "Rimuovi pin" : "Fissa in alto", systemImage: "pin")
            }

            Button {
                sourceManager.setEnabled(source, isEnabled: !source.isEnabled)
            } label: {
                Label(source.isEnabled ? "Disabilita" : "Abilita", systemImage: "power")
            }

            if source.type == .xtream {
                Button {
                    Task { await testConnection(source) }
                } label: {
                    Label("Verifica connessione", systemImage: "checkmark.shield")
                }
            }

            Button {
                duplicate(source)
            } label: {
                Label("Duplica", systemImage: "plus.square.on.square")
            }

            Button(role: .destructive) {
                sourceManager.remove(source)
            } label: {
                Label("Elimina", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(source.name)
        .accessibilityHint("Tocca per impostare questa sorgente come attiva, tieni premuto per altre azioni")
    }

    // MARK: - Azioni

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

            sourceManager.recordVerification(for: source, succeeded: true)
            connectionCheckResult = ConnectionCheckResult(
                sourceName: source.name,
                succeeded: true,
                message: "Le credenziali sono valide e il server risponde correttamente."
            )
        } catch let error as XtreamError {
            sourceManager.recordVerification(for: source, succeeded: false)
            connectionCheckResult = ConnectionCheckResult(
                sourceName: source.name,
                succeeded: false,
                message: error.errorDescription ?? "Errore Xtream sconosciuto."
            )
        } catch {
            sourceManager.recordVerification(for: source, succeeded: false)
            connectionCheckResult = ConnectionCheckResult(
                sourceName: source.name,
                succeeded: false,
                message: error.localizedDescription
            )
        }
    }

    @MainActor
    private func verifyAllSources() async {
        let xtreamSources = sourceManager.sources.filter { $0.type == .xtream }
        guard !xtreamSources.isEmpty else { return }

        isCheckingAll = true
        defer { isCheckingAll = false }

        var successCount = 0

        for source in xtreamSources {
            guard let username = source.username, !username.isEmpty,
                  let password = source.password, !password.isEmpty else { continue }

            checkingSourceID = source.id
            let credentials = XtreamCredentials(host: source.host, username: username, password: password)
            let service = XtreamAPIService(credentials: credentials)

            do {
                _ = try await service.authenticate()
                sourceManager.recordVerification(for: source, succeeded: true)
                successCount += 1
            } catch {
                sourceManager.recordVerification(for: source, succeeded: false)
            }
        }

        checkingSourceID = nil
        connectionCheckResult = ConnectionCheckResult(
            sourceName: "Verifica multipla",
            succeeded: successCount == xtreamSources.count,
            message: "\(successCount) su \(xtreamSources.count) sorgenti Xtream hanno risposto correttamente."
        )
    }

    private func importSources() {
        do {
            let imported = try SourceBackupCodec.decode(fromString: importText)
            let addedCount = sourceManager.importSources(imported)
            importFeedback = ImportFeedback(
                message: addedCount == 0
                    ? "Nessuna nuova sorgente da importare (erano già presenti)."
                    : "\(addedCount) sorgent\(addedCount == 1 ? "e" : "i") importata\(addedCount == 1 ? "" : "e") con successo.",
                succeeded: true
            )
            showImportSheet = false
        } catch {
            importFeedback = ImportFeedback(
                message: "Il testo incollato non è un backup GassPlayer valido.",
                succeeded: false
            )
        }
    }
}

// MARK: - Aggiungi playlist

struct AddPlaylistView: View {
    let onSave: (MediaSourceConfig) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var type: MediaSourceType?
    @State private var isTypeListExpanded = true
    @State private var name = ""
    @State private var iconName: String?
    @State private var host = ""
    @State private var username = ""
    @State private var password = ""

    static let iconChoices = [
        "laptopcomputer", "circle.lefthalf.filled", "bubble.left.fill",
        "film.fill", "tornado", "eject.fill", "ticket.fill",
        "peacesign", "key.fill"
    ]

    private static let orderedTypes: [MediaSourceType] = [.m3u8, .xtream, .plex, .jellyfin, .emby]

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var requiresCredentials: Bool {
        type != nil && type != .m3u8
    }

    private var canSave: Bool {
        guard type != nil, !trimmedName.isEmpty, !trimmedHost.isEmpty else { return false }
        guard requiresCredentials else { return true }
        return !trimmedUsername.isEmpty && !password.isEmpty
    }

    private var hostFieldLabel: String {
        switch type {
        case .xtream: return "URL al server Xtream"
        case .m3u8: return "URL della playlist M3U"
        case .plex: return "URL al server Plex"
        case .jellyfin: return "URL al server Jellyfin"
        case .emby: return "URL al server Emby"
        case nil: return "URL del server"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    typeSection

                    if type != nil {
                        fieldBlock(title: "Dai un nome a questa playlist") {
                            TextField("es. La mia playlist", text: $name)
                                .textInputAutocapitalization(.words)
                        }

                        iconPicker

                        fieldBlock(title: hostFieldLabel) {
                            TextField("es. http://il-tuo-dominio:porta/percorso/file", text: $host)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                        }

                        if requiresCredentials {
                            fieldBlock(title: "Il tuo username") {
                                TextField("es. mio-username", text: $username)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }

                            fieldBlock(title: "La tua password") {
                                SecureField("es. la-mia-password", text: $password)
                            }
                        }

                        GlassPrimaryButton(title: "Salva", systemImage: "checkmark") {
                            save()
                        }
                        .disabled(!canSave)
                        .opacity(canSave ? 1 : 0.5)
                    }
                }
                .padding(20)
                .animation(.snappy, value: type)
                .animation(.snappy, value: isTypeListExpanded)
            }
            .navigationTitle("Aggiungi playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .glassScreenBackground()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    GlassIconButton(
                        systemImage: "chevron.left",
                        size: 36,
                        isInSystemToolbar: true,
                        accessibilityLabel: "Indietro"
                    ) {
                        dismiss()
                    }
                }
            }
        }
    }

    private var typeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Seleziona il tipo di playlist")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            GlassCard(padding: 6) {
                VStack(spacing: 0) {
                    if let type, !isTypeListExpanded {
                        typeRow(type, isSelected: true) {
                            isTypeListExpanded = true
                        }
                    } else {
                        ForEach(Array(Self.orderedTypes.enumerated()), id: \.element.id) { index, candidate in
                            if index > 0 {
                                GlassRowDivider(leading: 20)
                            }

                            typeRow(candidate, isSelected: candidate == type) {
                                selectType(candidate)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }

    private func typeRow(_ candidate: MediaSourceType, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(candidateTitle(candidate))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func candidateTitle(_ candidate: MediaSourceType) -> String {
        switch candidate {
        case .xtream: return "Xtream"
        case .m3u8: return "M3U8"
        case .plex: return "Plex"
        case .jellyfin: return "Jellyfin"
        case .emby: return "Emby"
        }
    }

    private func selectType(_ candidate: MediaSourceType) {
        let isChangingType = type != candidate
        type = candidate
        isTypeListExpanded = false

        if isChangingType {
            iconName = defaultIcon(for: candidate)
        }
    }

    private func defaultIcon(for candidate: MediaSourceType) -> String {
        switch candidate {
        case .xtream: return "tornado"
        case .m3u8: return "laptopcomputer"
        case .plex: return "ticket.fill"
        case .jellyfin: return "bubble.left.fill"
        case .emby: return "key.fill"
        }
    }

    private var iconPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Identifica con un'icona")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Self.iconChoices, id: \.self) { icon in
                        Button {
                            iconName = icon
                        } label: {
                            Image(systemName: icon)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(iconName == icon ? .white : .secondary)
                                .frame(width: 46, height: 46)
                                .background(
                                    iconName == icon
                                        ? AnyShapeStyle(
                                            LinearGradient(
                                                colors: [.orange, .red],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        : AnyShapeStyle(Color.secondary.opacity(0.12)),
                                    in: Circle()
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Icona \(icon)")
                        .accessibilityAddTraits(iconName == icon ? [.isSelected] : [])
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func fieldBlock<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            content()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    Color.secondary.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
        }
    }

    private func save() {
        guard let type else { return }

        onSave(
            MediaSourceConfig(
                name: trimmedName,
                type: type,
                host: trimmedHost,
                username: requiresCredentials ? trimmedUsername : nil,
                password: requiresCredentials ? password : nil,
                iconName: iconName
            )
        )

        dismiss()
    }
}

struct ImportSourcesSheet: View {
    @Binding var text: String
    let onImport: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var canImport: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.caption.monospaced())
                        .frame(minHeight: 220)
                } header: {
                    Text("Backup JSON")
                } footer: {
                    Text("Incolla qui il contenuto JSON esportato in precedenza da GassPlayer. Le sorgenti già presenti (stesso host e username) verranno saltate.")
                }

                Section {
                    Button {
                        if let clipboardText = UIPasteboard.general.string {
                            text = clipboardText
                        }
                    } label: {
                        Label("Incolla dagli appunti", systemImage: "doc.on.clipboard")
                    }
                }
            }
            .navigationTitle("Importa sorgenti")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Importa", action: onImport)
                        .disabled(!canImport)
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
