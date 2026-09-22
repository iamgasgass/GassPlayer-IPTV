import SwiftUI

/// Schermata "Gestisci" di una sorgente, aperta dal pulsante "Gestisci"
/// nella prima sezione di `HomeView` (card "Sorgente pronta"). Riproduce
/// la struttura mostrata nel riferimento fornito: intestazione con nome
/// sorgente, sezione "Informazioni sul server" e sezione "Impostazioni"
/// con le voci Ricarica / Modifica dettagli / Gestisci contenuto /
/// Gestisci EPG / Cancella, tutte con icone in stile Liquid Glass.
struct SourceManageView: View {
    let source: MediaSourceConfig

    @EnvironmentObject private var sourceManager: SourceManager
    @EnvironmentObject private var contentManagement: ContentManagementService
    @EnvironmentObject private var xtreamCatalog: XtreamCatalogStore
    @EnvironmentObject private var m3uStore: M3UPlaylistStore
    @Environment(\.dismiss) private var dismiss

    @State private var accountInfo: XtreamAuthResponse.UserInfo?
    @State private var isLoadingAccount = false
    @State private var accountErrorMessage: String?
    @State private var isReloading = false
    @State private var reloadFeedback: String?
    @State private var showEditDetails = false
    @State private var showManageContent = false
    @State private var showManageEPG = false
    @State private var showEPGUnavailableAlert = false
    @State private var showDeleteConfirm = false

    /// Rilegge sempre la versione più aggiornata della sorgente dal
    /// manager: se "Modifica dettagli" cambia nome/host mentre questa
    /// vista resta aperta, l'intestazione e le azioni restano coerenti.
    private var currentSource: MediaSourceConfig {
        sourceManager.sources.first(where: { $0.id == source.id }) ?? source
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if currentSource.type == .xtream {
                        serverInfoSection
                    }
                    settingsSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(background)
            .navigationTitle(currentSource.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
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
            .task(id: currentSource.id) {
                await loadAccountInfo()
            }
            .sheet(isPresented: $showEditDetails) {
                EditSourceDetailsView(source: currentSource) { updated in
                    sourceManager.update(updated)
                }
            }
            .sheet(isPresented: $showManageContent) {
                ManageSourceContentView(source: currentSource)
                    .environmentObject(sourceManager)
                    .environmentObject(contentManagement)
            }
            .fullScreenCover(isPresented: $showManageEPG) {
                EPGManageView()
                    .environmentObject(sourceManager)
                    .environmentObject(xtreamCatalog)
            }
            .alert("EPG non disponibile", isPresented: $showEPGUnavailableAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Questa funzione richiede credenziali Xtream valide per la sorgente.")
            }
            .confirmationDialog(
                "Eliminare \u{201C}\(currentSource.name)\u{201D}?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Elimina", role: .destructive) {
                    sourceManager.remove(currentSource)
                    dismiss()
                }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text("La sorgente e le sue credenziali verranno rimosse. I preferiti già salvati non vengono eliminati.")
            }
            .alert(
                "Aggiornamento",
                isPresented: Binding(
                    get: { reloadFeedback != nil },
                    set: { isPresented in if !isPresented { reloadFeedback = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(reloadFeedback ?? "")
            }
        }
    }

    // MARK: - Informazioni sul server

    private var serverInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Informazioni sul server")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            GlassCard {
                VStack(alignment: .leading, spacing: 18) {
                    infoRow(icon: "wifi", label: "Stato:", value: statusText, valueColor: statusColor)
                    infoRow(icon: "point.3.connected.trianglepath.dotted", label: "Connessioni:", value: connectionsText)
                    infoRow(icon: "calendar", label: "Data di scadenza:", value: expirationText)
                }
            }
        }
    }

    private func infoRow(icon: String, label: String, value: String, valueColor: Color = .primary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 22)

            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(isLoadingAccount ? "…" : value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(valueColor)

            Spacer()

            if isLoadingAccount {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: - Impostazioni

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Impostazioni")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            GlassCard(padding: 6) {
                VStack(spacing: 0) {
                    GlassSettingsRow(icon: "arrow.clockwise", title: "Ricarica", showsProgress: isReloading) {
                        Task { await reload() }
                    }

                    GlassRowDivider()

                    GlassSettingsRow(icon: "pencil", title: "Modifica dettagli") {
                        showEditDetails = true
                    }

                    GlassRowDivider()

                    GlassSettingsRow(icon: "square.stack.3d.up", title: "Gestisci contenuto") {
                        showManageContent = true
                    }

                    GlassRowDivider()

                    GlassSettingsRow(icon: "text.book.closed.fill", title: "Gestisci EPG") {
                        openManageEPG()
                    }

                    GlassRowDivider()

                    GlassSettingsRow(icon: "trash", title: "Cancella", tint: .red, showChevron: false) {
                        showDeleteConfirm = true
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }

    // MARK: - Azioni

    @MainActor
    private func loadAccountInfo() async {
        guard let credentials = currentSource.xtreamCredentials else { return }

        isLoadingAccount = true
        accountErrorMessage = nil
        defer { isLoadingAccount = false }

        let service = XtreamAPIService(credentials: credentials)

        do {
            let response = try await service.fetchAccountInfo()
            accountInfo = response.userInfo
        } catch let error as XtreamError {
            accountErrorMessage = error.errorDescription ?? "Errore Xtream sconosciuto."
        } catch {
            accountErrorMessage = error.localizedDescription
        }
    }

    /// FIX — "Ricarica" verificava soltanto le credenziali (account info +
    /// `authenticate()`), senza mai toccare il catalogo effettivo: la
    /// playlist mostrata in Live TV/VOD/Serie TV restava quella già in
    /// cache, per cui "Ricarica" non ricaricava davvero nulla. Ora, quando
    /// questa e' la sorgente attiva (quella la cui playlist e' mostrata
    /// nell'app), forza anche un fetch completo e non cacheato del
    /// catalogo Xtream o della playlist M3U. Per una sorgente non attiva
    /// resta solo la verifica delle credenziali: sovrascrivere il
    /// catalogo/la playlist condivisi con i dati di una sorgente diversa
    /// da quella attualmente mostrata creerebbe un disallineamento tra lo
    /// stato dell'app e i tab Live TV/VOD/Serie TV.
    @MainActor
    private func reload() async {
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }

        let isActiveSource = sourceManager.activeSourceId == currentSource.id

        if let credentials = currentSource.xtreamCredentials {
            await loadAccountInfo()

            if isActiveSource {
                await xtreamCatalog.refresh(credentials: credentials)

                if case .failed(let message) = xtreamCatalog.state {
                    sourceManager.recordVerification(for: currentSource, succeeded: false)
                    reloadFeedback = "Ricaricamento non riuscito: \(message)"
                } else {
                    sourceManager.recordVerification(for: currentSource, succeeded: true)
                    reloadFeedback = "Playlist ricaricata."
                }
                return
            }

            do {
                _ = try await XtreamAPIService(credentials: credentials).authenticate()
                sourceManager.recordVerification(for: currentSource, succeeded: true)
                reloadFeedback = "Sorgente aggiornata: le credenziali sono valide."
            } catch let error as XtreamError {
                sourceManager.recordVerification(for: currentSource, succeeded: false)
                reloadFeedback = error.errorDescription ?? "Aggiornamento non riuscito."
            } catch {
                sourceManager.recordVerification(for: currentSource, succeeded: false)
                reloadFeedback = "Aggiornamento non riuscito: \(error.localizedDescription)"
            }
            return
        }

        if let url = m3uPlaylistURL {
            if isActiveSource {
                await m3uStore.reload(url: url)
                reloadFeedback = m3uStore.errorMessage ?? "Playlist ricaricata."
            } else {
                reloadFeedback = "Sorgente aggiornata."
            }
            return
        }

        reloadFeedback = "Sorgente aggiornata."
    }

    /// Stesso parsing usato da `ContentView` per ricavare l'URL della
    /// playlist M3U di una sorgente dal campo `host`.
    private var m3uPlaylistURL: URL? {
        guard currentSource.type == .m3u8 else { return nil }

        let normalized = currentSource.host.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        return url
    }

    private func openManageEPG() {
        if currentSource.xtreamCredentials != nil {
            showManageEPG = true
        } else {
            showEPGUnavailableAlert = true
        }
    }

    // MARK: - Testo derivato

    private var statusText: String {
        if let accountInfo {
            return accountInfo.status.uppercased()
        }
        if accountErrorMessage != nil {
            return "SCONOSCIUTO"
        }
        return "—"
    }

    private var statusColor: Color {
        guard let accountInfo else { return .secondary }
        return accountInfo.status.lowercased() == "active" ? .green : .red
    }

    private var connectionsText: String {
        guard let accountInfo,
              let maxConnections = accountInfo.maxConnections,
              !maxConnections.isEmpty else {
            return "—"
        }
        let active = accountInfo.activeConnections ?? "0"
        return "\(active)/\(maxConnections)"
    }

    private var expirationText: String {
        guard let accountInfo, let expDate = accountInfo.expDate else { return "—" }

        if expDate == "-1" {
            return "Nessuna scadenza"
        }

        guard let seconds = TimeInterval(expDate), seconds > 0 else {
            return "—"
        }

        let date = Date(timeIntervalSince1970: seconds)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.10),
                Color(uiColor: .systemBackground),
                Color.purple.opacity(0.06)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

// MARK: - Modifica dettagli

/// Form di modifica di una sorgente esistente: nome, icona identificativa,
/// URL/host e — quando previste dal tipo di sorgente — username e password.
struct EditSourceDetailsView: View {
    let source: MediaSourceConfig
    let onSave: (MediaSourceConfig) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var iconName: String
    @State private var host: String
    @State private var username: String
    @State private var password: String

    /// Stesso set concettuale di icone mostrato nel riferimento (corona,
    /// luna, etichetta, ombrello, sparkle, avanti veloce, fulmine,
    /// triangolo, goccia): puramente identificativo, non influisce sulla
    /// logica della sorgente.
    static let iconChoices = [
        "crown.fill", "zzz", "tag.fill", "umbrella.fill",
        "sparkle", "forward.fill", "bolt.fill", "triangle.fill", "drop.fill"
    ]

    init(source: MediaSourceConfig, onSave: @escaping (MediaSourceConfig) -> Void) {
        self.source = source
        self.onSave = onSave
        _name = State(initialValue: source.name)
        _iconName = State(initialValue: source.iconName ?? Self.iconChoices[4])
        _host = State(initialValue: source.host)
        _username = State(initialValue: source.username ?? "")
        _password = State(initialValue: source.password ?? "")
    }

    private var requiresCredentials: Bool { source.type != .m3u8 }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSave: Bool {
        guard !trimmedName.isEmpty, !trimmedHost.isEmpty else { return false }
        guard requiresCredentials else { return true }
        return !trimmedUsername.isEmpty && !password.isEmpty
    }

    private var hostFieldLabel: String {
        switch source.type {
        case .xtream: return "URL al server Xtream"
        case .m3u8: return "URL della playlist M3U"
        default: return "Host / URL del server"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    fieldBlock(title: "Dai un nome a questa playlist") {
                        TextField("Nome", text: $name)
                            .textInputAutocapitalization(.words)
                    }

                    iconPicker

                    fieldBlock(title: hostFieldLabel) {
                        TextField(hostFieldLabel, text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }

                    if requiresCredentials {
                        fieldBlock(title: "Il tuo username") {
                            TextField("Username", text: $username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }

                        fieldBlock(title: "La tua password") {
                            SecureField("Password", text: $password)
                        }
                    }

                    GlassPrimaryButton(title: "Salva", systemImage: "checkmark") {
                        save()
                    }
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.5)
                }
                .padding(20)
            }
            .navigationTitle("Impostazioni della playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
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
                                    iconName == icon ? Color.pink : Color.secondary.opacity(0.12),
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
        var updated = source
        updated.name = trimmedName
        updated.iconName = iconName
        updated.host = trimmedHost

        if requiresCredentials {
            updated.username = trimmedUsername
            updated.password = password
        }

        onSave(updated)
        dismiss()
    }
}

// MARK: - Gestisci contenuto

/// Schermata "Gestisci contenuto": mostra quanti preferiti sono legati a
/// questa sorgente (per Live TV / VOD / Serie TV) e offre le azioni di
/// gestione playlist già presenti in `SourcesView` (duplica, unisci,
/// esporta), ma nel contesto della singola sorgente.
struct ManageSourceContentView: View {
    let source: MediaSourceConfig

    @EnvironmentObject private var sourceManager: SourceManager
    @EnvironmentObject private var contentManagement: ContentManagementService
    @Environment(\.dismiss) private var dismiss

    @State private var showMergeSheet = false

    private var normalizedHost: String {
        source.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Preferiti di questa sorgente") {
                    contentRow(title: "Live TV", systemImage: "tv.fill", tint: .red, count: favoritesCount(kind: .live))
                    contentRow(title: "VOD", systemImage: "film.fill", tint: .purple, count: favoritesCount(kind: .movie))
                    contentRow(title: "Serie TV", systemImage: "rectangle.stack.fill", tint: .blue, count: favoritesCount(kind: .series))
                }

                Section {
                    Button {
                        duplicate()
                    } label: {
                        Label("Duplica sorgente", systemImage: "plus.square.on.square")
                    }

                    Button {
                        showMergeSheet = true
                    } label: {
                        Label("Unisci con un'altra sorgente", systemImage: "square.stack.3d.up.fill")
                    }
                    .disabled(sourceManager.sources.count < 2)

                    if let payload = try? SourceBackupCodec.encodeAsString([source]) {
                        ShareLink(
                            item: payload,
                            preview: SharePreview("Backup \(source.name)")
                        ) {
                            Label("Esporta questa sorgente (JSON)", systemImage: "square.and.arrow.up")
                        }
                    }
                } header: {
                    Text("Playlist")
                } footer: {
                    Text("Il file JSON può contenere credenziali. Condividilo solo tramite servizi affidabili.")
                }
            }
            .navigationTitle("Gestisci contenuto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
            .sheet(isPresented: $showMergeSheet) {
                MergePlaylistView(sources: sourceManager.sources) { name, sourceIDs in
                    contentManagement.createMergedPlaylist(name: name, sourceIds: sourceIDs)
                }
            }
        }
    }

    private func favoritesCount(kind: XtreamStreamKind) -> Int {
        let prefix = [normalizedHost, source.username ?? "", kind.rawValue].joined(separator: "|")
        return contentManagement.favorites.filter { $0.id.hasPrefix(prefix) }.count
    }

    private func contentRow(title: String, systemImage: String, tint: Color, count: Int) -> some View {
        HStack {
            Label(title, systemImage: systemImage).foregroundStyle(tint)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary)
        }
    }

    private func duplicate() {
        sourceManager.add(
            MediaSourceConfig(
                name: "\(source.name) (copia)",
                type: source.type,
                host: source.host,
                username: source.username,
                password: source.password,
                iconName: source.iconName
            )
        )
    }
}
