import SwiftUI

/// Schermata globale "Gestisci guida TV", aperta dalla voce "Gestisci EPG"
/// in Impostazioni → Connessioni. Riproduce la struttura del riferimento
/// fornito: intestazione con freccia indietro, sezione "Impostazioni" con
/// "Aggiorna automaticamente" / "Aggiorna fonti" / "Cancella cache" /
/// "Aggiungi fonte EPG", e sezione "Dalle playlist" con l'elenco delle
/// sorgenti che possono fornire una guida programmi (solo Xtream: sono le
/// uniche con `xtreamCredentials`, la stessa condizione già usata da
/// `SourceManageView` per abilitare "Gestisci EPG" per singola sorgente).
struct EPGManageView: View {
    @EnvironmentObject private var sourceManager: SourceManager
    @EnvironmentObject private var xtreamCatalog: XtreamCatalogStore

    @ObservedObject private var epgManager = EPGManager.shared

    @State private var isRefreshingSources = false
    @State private var isClearingCache = false
    @State private var feedbackMessage: String?
    @State private var showAddEPGSource = false
    @State private var managingEPGSource: MediaSourceConfig?
    @State private var showEPGUnavailableAlert = false

    /// Solo le sorgenti con credenziali Xtream valide possono fornire una
    /// guida programmi (stessa regola di `MediaSourceConfig.xtreamCredentials`).
    private var epgCapableSources: [MediaSourceConfig] {
        sourceManager.sources.filter { $0.xtreamCredentials != nil }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    settingsSection

                    if !epgManager.externalSources.isEmpty {
                        externalSourcesSection
                    }

                    playlistsSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(background)
            .navigationTitle("Gestisci guida TV")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showAddEPGSource) {
                AddEPGSourceView { name, urlString in
                    if epgManager.addExternalSource(name: name, urlString: urlString) {
                        feedbackMessage = "Fonte EPG \u{201C}\(name)\u{201D} aggiunta."
                        return true
                    }
                    return false
                }
            }
            .fullScreenCover(item: $managingEPGSource) { source in
                if let credentials = source.xtreamCredentials {
                    EPGGridView(credentials: credentials, kind: .live)
                        .environmentObject(xtreamCatalog)
                } else {
                    ContentUnavailableView(
                        "Guida EPG non disponibile",
                        systemImage: "tv.slash"
                    )
                }
            }
            .alert("EPG non disponibile", isPresented: $showEPGUnavailableAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Questa sorgente non ha più credenziali Xtream valide.")
            }
            .alert(
                "Guida TV",
                isPresented: Binding(
                    get: { feedbackMessage != nil },
                    set: { isPresented in if !isPresented { feedbackMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(feedbackMessage ?? "")
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
                    GlassSettingsToggleRow(
                        icon: "arrow.triangle.2.circlepath",
                        title: "Aggiorna automaticamente",
                        subtitle: autoUpdateSubtitle,
                        tint: .green,
                        isOn: $epgManager.autoUpdateEnabled
                    )

                    GlassRowDivider()

                    GlassSettingsRow(
                        icon: "arrow.clockwise",
                        title: "Aggiorna fonti",
                        subtitle: lastRefreshDescription,
                        tint: .blue,
                        showsProgress: isRefreshingSources
                    ) {
                        Task { await refreshSourcesNow() }
                    }

                    GlassRowDivider()

                    GlassSettingsRow(
                        icon: "xmark",
                        title: "Cancella cache",
                        subtitle: "Svuota la guida programmi salvata localmente",
                        tint: .red,
                        showsProgress: isClearingCache
                    ) {
                        Task { await clearCacheNow() }
                    }

                    GlassRowDivider()

                    GlassSettingsRow(
                        icon: "plus",
                        title: "Aggiungi fonte EPG",
                        subtitle: "Collega una guida XMLTV esterna",
                        tint: .orange
                    ) {
                        showAddEPGSource = true
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }

    // MARK: - Fonti EPG esterne

    private var externalSourcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fonti EPG esterne")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            GlassCard(padding: 6) {
                VStack(spacing: 0) {
                    ForEach(Array(epgManager.externalSources.enumerated()), id: \.element.id) { index, source in
                        if index > 0 {
                            GlassRowDivider()
                        }

                        externalSourceRow(source)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }

    private func externalSourceRow(_ source: EPGExternalSource) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(source.isEnabled ? .teal : .secondary)
                .frame(width: 36, height: 36)
                .background((source.isEnabled ? Color.teal : Color.secondary).opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.body.weight(.medium))
                Text(source.urlString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Toggle(
                "Attiva \(source.name)",
                isOn: Binding(
                    get: { source.isEnabled },
                    set: { epgManager.setExternalSource(source, isEnabled: $0) }
                )
            )
            .labelsHidden()
            .tint(.teal)

            Button(role: .destructive) {
                withAnimation(.snappy) { epgManager.removeExternalSource(source) }
            } label: {
                Image(systemName: "trash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rimuovi \(source.name)")
        }
        .padding(.vertical, 10)
    }

    // MARK: - Dalle playlist

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dalle playlist")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if epgCapableSources.isEmpty {
                GlassCard {
                    Text("Nessuna playlist con supporto EPG. Aggiungi una sorgente Xtream dalle Sorgenti per vedere qui la sua guida programmi.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                GlassCard(padding: 6) {
                    VStack(spacing: 0) {
                        ForEach(Array(epgCapableSources.enumerated()), id: \.element.id) { index, source in
                            if index > 0 {
                                GlassRowDivider()
                            }

                            GlassSettingsRow(
                                icon: source.iconName ?? source.type.systemImage,
                                title: source.name,
                                subtitle: source.host,
                                tint: source.type.glassTint
                            ) {
                                openEPG(for: source)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
        }
    }

    // MARK: - Azioni

    private func openEPG(for source: MediaSourceConfig) {
        if source.xtreamCredentials != nil {
            managingEPGSource = source
        } else {
            showEPGUnavailableAlert = true
        }
    }

    @MainActor
    private func refreshSourcesNow() async {
        guard !isRefreshingSources else { return }
        isRefreshingSources = true
        defer { isRefreshingSources = false }

        let result = await epgManager.refreshSources(using: sourceManager)

        feedbackMessage = result.total == 0
            ? "Nessuna sorgente Xtream configurata da aggiornare."
            : "\(result.succeeded) su \(result.total) font\(result.total == 1 ? "e" : "i") aggiornat\(result.total == 1 ? "a" : "e") correttamente."
    }

    @MainActor
    private func clearCacheNow() async {
        guard !isClearingCache else { return }
        isClearingCache = true
        defer { isClearingCache = false }

        await EPGService.clearAllCache()
        feedbackMessage = "Cache della guida TV svuotata. Verrà ricostruita alla prossima consultazione."
    }

    // MARK: - Testo derivato

    private var autoUpdateSubtitle: String {
        epgManager.autoUpdateEnabled
            ? "Verifica periodicamente le fonti EPG configurate"
            : "Le fonti EPG si aggiornano solo manualmente"
    }

    private var lastRefreshDescription: String {
        guard let date = epgManager.lastSourcesRefreshDate else {
            return "Mai aggiornate"
        }
        return "Aggiornate \(date.formatted(.relative(presentation: .named)))"
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

// MARK: - Aggiungi fonte EPG

/// Form "Aggiungi fonte EPG": nome + URL XMLTV. Stile coerente con le altre
/// schermate custom dell'app (`EditSourceDetailsView`), non un `Form` di
/// sistema, per restare fedele all'estetica Liquid Glass del riferimento.
struct AddEPGSourceView: View {
    /// Ritorna `false` se l'URL non è valido, per mostrare l'errore senza
    /// chiudere il foglio.
    let onSave: (_ name: String, _ urlString: String) -> Bool

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var urlString = ""
    @State private var showInvalidURLAlert = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedURL: String { urlString.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSave: Bool {
        !trimmedName.isEmpty && !trimmedURL.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    fieldBlock(title: "Nome della fonte") {
                        TextField("es. Guida principale", text: $name)
                            .textInputAutocapitalization(.words)
                    }

                    fieldBlock(title: "URL XMLTV") {
                        TextField("es. https://il-tuo-dominio/epg.xml", text: $urlString)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }

                    Text("La fonte verrà affiancata alla guida già fornita dalle sorgenti Xtream, utile soprattutto per le playlist M3U prive di EPG integrata.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    GlassPrimaryButton(title: "Salva", systemImage: "checkmark") {
                        save()
                    }
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.5)
                }
                .padding(20)
            }
            .navigationTitle("Aggiungi fonte EPG")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
            .alert("URL non valido", isPresented: $showInvalidURLAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Inserisci un indirizzo http:// o https:// completo verso il file XMLTV.")
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
        guard onSave(trimmedName, trimmedURL) else {
            showInvalidURLAlert = true
            return
        }
        dismiss()
    }
}
