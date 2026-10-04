import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var sourceManager: SourceManager
    @EnvironmentObject var lockManager: ParentalLockManager
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var xtreamCatalog: XtreamCatalogStore
    @EnvironmentObject var recentlyWatched: RecentlyWatchedStore
    @EnvironmentObject var contentManagement: ContentManagementService

    @StateObject private var cloudSync = CloudSyncService()
    // FIX: prima si creava qui un'istanza NUOVA e isolata di
    // `DownloadManager` — il toggle "Download solo Wi-Fi" modificava
    // quell'istanza, ma i download reali avviati dalle schede dettaglio
    // film/serie (icona "download") usano `DownloadManager.shared`: due
    // oggetti diversi, quindi il toggle non aveva alcun effetto pratico
    // sui download effettivi. Ora questa vista osserva la stessa istanza
    // condivisa: un solo stato, coerente ovunque nell'app.
    @ObservedObject private var downloadManager = DownloadManager.shared
    @ObservedObject private var catalogSettings = CatalogSettings.shared
    @ObservedObject private var epgManager = EPGManager.shared
    @ObservedObject private var traktAccount = TraktAccountManager.shared

    @AppStorage("gassplayer.subtitles.language")
    private var subtitleLanguage = "it"

    @AppStorage("gassplayer.network.preferredDNS")
    private var preferredDNS = "1.1.1.1"

    @State private var showResetConfirmation = false
    @State private var isRefreshingCatalog = false
    @State private var catalogActionFeedback: String?
    @State private var systemCacheCount: Int?
    @State private var isLoadingSystemCacheCount = false
    @State private var isClearingSystemCache = false
    @State private var showImportPreferencesSheet = false
    @State private var importPreferencesText = ""
    @State private var importPreferencesFeedback: String?

    @AppStorage("gassplayer.playback.autoplayNextEpisode")
    private var autoplayNextEpisode = true

    @AppStorage("gassplayer.playback.resumePlayback")
    private var resumePlayback = true

    @AppStorage("gassplayer.playback.speed")
    private var preferredPlaybackSpeed = 1.0

    // Preferenze del motore di riproduzione (le stesse lette da
    // `KSPlaybackController.PlaybackPreferences.loadFromDefaults()` e
    // scritte anche dal pannello avanzato dentro al player: le due
    // interfacce condividono lo stesso storage, non sono duplicate).
    @AppStorage("gassplayer.player.preferredForwardBufferDuration")
    private var playerForwardBuffer = 3.0

    @AppStorage("gassplayer.player.maxBufferDuration")
    private var playerMaxBuffer = 30.0

    @AppStorage("gassplayer.player.hardwareDecode")
    private var playerHardwareDecode = true

    @AppStorage("gassplayer.player.isAccurateSeek")
    private var playerAccurateSeek = false

    @AppStorage("gassplayer.player.autoDeInterlace")
    private var playerAutoDeInterlace = false

    @AppStorage("gassplayer.player.videoGravity")
    private var playerVideoGravity = VideoGravityMode.fit.rawValue

    @State private var showResetPlayerPreferencesConfirmation = false

    @AppStorage("gassplayer.grid.density")
    private var channelGridDensity = "comfortable"

    @AppStorage("gassplayer.grid.showChannelNumbers")
    private var showChannelNumbers = false

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?[
            "CFBundleShortVersionString"
        ] as? String ?? "-"

        let build = Bundle.main.infoDictionary?[
            "CFBundleVersion"
        ] as? String ?? "-"

        return "\(version) (\(build))"
    }

    private var sourceCountDescription: String {
        sourceManager.sources.isEmpty
            ? "Nessuna sorgente configurata"
            : "\(sourceManager.sources.count) sorgenti configurate"
    }

    private var subtitleLanguageName: String {
        switch subtitleLanguage {
        case "it":
            return "Italiano"
        case "en":
            return "English"
        case "es":
            return "Español"
        default:
            return subtitleLanguage
        }
    }

    private var gridDensityName: String {
        channelGridDensity == "compact" ? "Compatta" : "Comoda"
    }

    private var dnsDescription: String {
        switch preferredDNS {
        case "system":
            return "Automatico"
        case "1.1.1.1":
            return "1.1.1.1 · Cloudflare"
        case "8.8.8.8":
            return "8.8.8.8 · Google"
        default:
            return preferredDNS
        }
    }

    private var activeXtreamCredentials: XtreamCredentials? {
        sourceManager.activeSource?.xtreamCredentials
    }

    /// Binding usato dal Menu "Sorgente attiva": legge/imposta l'id della
    /// sorgente attiva traducendolo automaticamente in una chiamata a
    /// `SourceManager.setActive(_:)`, così il picker resta una semplice
    /// scelta dichiarativa senza logica duplicata altrove.
    private var activeSourceSelection: Binding<UUID?> {
        Binding(
            get: { sourceManager.activeSourceId },
            set: { newValue in
                guard let newValue,
                      let source = sourceManager.sources.first(where: { $0.id == newValue }) else {
                    return
                }

                sourceManager.setActive(source)
            }
        )
    }

    private var lastRefreshDescription: String {
        guard let date = xtreamCatalog.lastRefreshDate else {
            return "Mai aggiornato"
        }

        return "Aggiornato \(date.formatted(.relative(presentation: .named)))"
    }

    private var epgManagerDescription: String {
        let epgCapableCount = sourceManager.sources.filter { $0.xtreamCredentials != nil }.count

        if epgCapableCount == 0 {
            return "Nessuna playlist con guida disponibile"
        }

        let autoUpdateText = epgManager.autoUpdateEnabled ? "automatico" : "manuale"
        return "\(epgCapableCount) playlist con guida · Aggiornamento \(autoUpdateText)"
    }

    private var systemCacheDescription: String {
        guard let systemCacheCount else {
            return "Tocca per calcolare"
        }

        return systemCacheCount == 0
            ? "Vuota"
            : "\(systemCacheCount) element\(systemCacheCount == 1 ? "o" : "i") in memoria"
    }

    private var preferencesSnapshot: AppPreferencesBackup {
        AppPreferencesBackupCodec.currentSnapshot(
            themeManager: themeManager,
            catalogSettings: catalogSettings,
            epgManager: epgManager,
            downloadManager: downloadManager
        )
    }

    private var historyDetailDescription: String {
        recentlyWatched.items.isEmpty
            ? "Nessun elemento recente"
            : "\(recentlyWatched.items.count) element\(recentlyWatched.items.count == 1 ? "o" : "i") in \u{201C}Continua a guardare\u{201D}"
    }

    var body: some View {
        NavigationStack {
            // Hub: poche voci raggruppate (Playlist, Avanzate, Rete,
            // Integrazioni, Supporto); il resto vive nelle sottopagine,
            // aperte solo quando servono.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    playlistSection
                    advancedSection
                    networkSection
                    integrationsSection
                    supportSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .background(background)
            .navigationTitle("Impostazioni")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fine") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        // Dialoghi e fogli sono agganciati allo stack e non alla sola
        // pagina radice: le azioni (ripristino, import, feedback) partono
        // dalle sottopagine, e un alert legato alla radice mentre è
        // aperta un'altra pagina non si presenterebbe in modo affidabile.
        .confirmationDialog(
            "Ripristinare le impostazioni di riproduzione?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Ripristina", role: .destructive) {
                resetPlaybackDefaults()
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text(
                "Autoplay, ripresa, velocità e opzioni della griglia torneranno ai valori predefiniti. Sorgenti e preferiti non verranno modificati."
            )
        }
        .alert(
            "Impostazioni",
            isPresented: Binding(
                get: { catalogActionFeedback != nil },
                set: { isPresented in if !isPresented { catalogActionFeedback = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(catalogActionFeedback ?? "")
        }
        .sheet(isPresented: $showImportPreferencesSheet) {
            ImportPreferencesSheet(text: $importPreferencesText, onImport: importPreferences)
        }
        .alert(
            "Preferenze",
            isPresented: Binding(
                get: { importPreferencesFeedback != nil },
                set: { isPresented in if !isPresented { importPreferencesFeedback = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importPreferencesFeedback ?? "")
        }
    }

    // MARK: - Hub

    /// Riga di navigazione del hub verso una sottopagina.
    private func hubLink<Destination: View>(
        title: String,
        detail: String,
        symbol: String,
        tint: Color,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            SettingsRow(
                title: title,
                detail: detail,
                symbol: symbol,
                tint: tint,
                showsChevron: true
            )
        }
        .buttonStyle(.plain)
    }

    /// Pagina secondaria: stessa scena (sfondo, margini, card Liquid Glass)
    /// del hub, titolo in linea con il pulsante indietro.
    private func settingsPage<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                content()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var playlistSection: some View {
        SettingsSection(
            title: "Playlist",
            subtitle: "Sorgenti e sorgente attiva",
            symbol: "play.square.stack.fill",
            tint: .blue
        ) {
            hubLink(
                title: "Sorgenti",
                detail: sourceCountDescription,
                symbol: "square.stack.3d.up.fill",
                tint: .blue
            ) {
                SourcesView()
            }

            if sourceManager.sources.count > 1 {
                SettingsDivider()

                Menu {
                    Picker("Sorgente attiva", selection: activeSourceSelection) {
                        ForEach(sourceManager.sources) { source in
                            Label(source.name, systemImage: source.type.systemImage)
                                .tag(source.id as UUID?)
                        }
                    }
                } label: {
                    SettingsRow(
                        title: "Sorgente attiva",
                        detail: sourceManager.activeSource?.name ?? "Nessuna",
                        symbol: "checkmark.circle.fill",
                        tint: .green,
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
            }

            if sourceManager.sources.isEmpty {
                SettingsDivider()

                Text(
                    "Per configurare Live TV, VOD e Serie TV, apri Sorgenti e tocca \u{201C}Aggiungi playlist\u{201D}."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            }
        }
    }

    private var advancedSection: some View {
        SettingsSection(
            title: "Avanzate",
            subtitle: "Generale, interfaccia, lettore e backup",
            symbol: "gearshape.2.fill",
            tint: .gray
        ) {
            hubLink(
                title: "Generale",
                detail: "Catalogo e cronologia",
                symbol: "gearshape.fill",
                tint: .teal
            ) {
                generalPage
            }

            SettingsDivider()

            hubLink(
                title: "Interfaccia utente",
                detail: "Tema e griglia · \(themeManager.theme.rawValue), \(gridDensityName)",
                symbol: "slider.horizontal.3",
                tint: .purple
            ) {
                interfacePage
            }

            SettingsDivider()

            hubLink(
                title: "Lettore video",
                detail: "Riproduzione, buffer, decodifica e sottotitoli",
                symbol: "play.rectangle.fill",
                tint: .red
            ) {
                playerPage
            }

            SettingsDivider()

            hubLink(
                title: "Backup",
                detail: "iCloud, esporta e importa",
                symbol: "icloud.fill",
                tint: .blue
            ) {
                backupPage
            }

            SettingsDivider()

            hubLink(
                title: "EPG",
                detail: epgManagerDescription,
                symbol: "text.book.closed.fill",
                tint: .teal
            ) {
                EPGManageView()
            }

            SettingsDivider()

            hubLink(
                title: "Parental Lock",
                detail: "Limiti di visione e codice di protezione",
                symbol: "lock.shield",
                tint: .orange
            ) {
                ParentalLockView()
            }
        }
    }

    private var networkSection: some View {
        SettingsSection(
            title: "Rete",
            subtitle: "VPN, DNS e download",
            symbol: "network",
            tint: .indigo
        ) {
            hubLink(
                title: "VPN personale",
                detail: "Gestisci connessione e configurazione",
                symbol: "lock.shield.fill",
                tint: .indigo
            ) {
                PersonalVPNView()
            }

            SettingsDivider()

            Menu {
                Picker("DNS preferito", selection: $preferredDNS) {
                    Text("1.1.1.1 · Cloudflare").tag("1.1.1.1")
                    Text("8.8.8.8 · Google").tag("8.8.8.8")
                    Text("Automatico di sistema").tag("system")
                }
            } label: {
                SettingsRow(
                    title: "DNS preferito",
                    detail: dnsDescription,
                    symbol: "network",
                    tint: .mint,
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)

            SettingsDivider()

            SettingsToggleRow(
                title: "Download solo Wi-Fi",
                detail: "Evita l’utilizzo della rete cellulare",
                symbol: "wifi",
                tint: .green,
                isOn: $downloadManager.wifiOnly
            )
        }
    }

    /// Include \"Metadati\": prima non esisteva ALCUN punto della UI per
    /// inserire una API key TMDB (poster reali, cast, loghi, voti usati
    /// dalle schede dettaglio); la chiave OMDb è facoltativa (IMDb, Rotten
    /// Tomatoes, Metacritic nelle valutazioni).
    private var integrationsSection: some View {
        SettingsSection(
            title: "Integrazioni",
            subtitle: "Trakt, TMDB e OMDb",
            symbol: "puzzlepiece.extension.fill",
            tint: .orange
        ) {
            hubLink(
                title: "Trakt.tv",
                detail: traktAccount.isConnected ? "Connesso" : "Non connesso",
                symbol: "checkmark.seal.fill",
                tint: .orange
            ) {
                TraktConnectView()
            }

            SettingsDivider()

            hubLink(
                title: "TMDB e OMDb",
                detail: TMDBService.hasAPIKey
                    ? "TMDB configurato\(OMDbService.hasAPIKey ? " · OMDb configurato" : "")"
                    : "Nessuna API key configurata",
                symbol: "key.fill",
                tint: .indigo
            ) {
                MetadataSettingsView()
            }
        }
    }

    private var supportSection: some View {
        SettingsSection(
            title: "Supporto",
            subtitle: "Diagnostica e informazioni",
            symbol: "lifepreserver.fill",
            tint: .cyan
        ) {
            hubLink(
                title: "Diagnostica",
                detail: "Log, rete e cache di sistema",
                symbol: "wrench.and.screwdriver.fill",
                tint: .gray
            ) {
                diagnosticsPage
            }

            SettingsDivider()

            hubLink(
                title: "Informazioni",
                detail: "Versione \(appVersionString)",
                symbol: "info.circle.fill",
                tint: .blue
            ) {
                aboutPage
            }
        }
    }

    // MARK: - Sottopagine

    private var generalPage: some View {
        settingsPage(title: "Impostazioni generali") {
            catalogSection
            historySection
        }
    }

    private var interfacePage: some View {
        settingsPage(title: "Impostazioni dell'interfaccia utente") {
            appearanceSection
            librarySection
        }
    }

    private var playerPage: some View {
        settingsPage(title: "Impostazioni del player") {
            playbackSection
            subtitleSection
        }
    }

    private var backupPage: some View {
        settingsPage(title: "Backup e dispositivi") {
            cloudSection
            dataSection
        }
    }

    private var diagnosticsPage: some View {
        settingsPage(title: "Diagnostica") {
            diagnosticsSection
        }
    }

    private var aboutPage: some View {
        settingsPage(title: "Informazioni") {
            aboutSection
        }
    }

    private var playbackSection: some View {
        SettingsSection(
            title: "Riproduzione",
            subtitle: "Comportamento del player",
            symbol: "play.rectangle.fill",
            tint: .red
        ) {
            SettingsToggleRow(
                title: "Prossimo episodio automatico",
                detail: "Avvia automaticamente l’episodio successivo",
                symbol: "play.square.stack",
                tint: .red,
                isOn: $autoplayNextEpisode
            )

            SettingsDivider()

            SettingsToggleRow(
                title: "Riprendi la visione",
                detail: "Riparti dall’ultimo punto visto",
                symbol: "arrow.counterclockwise.circle",
                tint: .orange,
                isOn: $resumePlayback
            )

            SettingsDivider()

            Menu {
                Picker(
                    "Velocità predefinita",
                    selection: $preferredPlaybackSpeed
                ) {
                    Text("1.0×").tag(1.0)
                    Text("1.25×").tag(1.25)
                    Text("1.5×").tag(1.5)
                    Text("2.0×").tag(2.0)
                }
            } label: {
                SettingsRow(
                    title: "Velocità predefinita",
                    detail: String(format: "%.2g×", preferredPlaybackSpeed),
                    symbol: "speedometer",
                    tint: .indigo,
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)

            SettingsDivider()

            SettingsToggleRow(
                title: "Decodifica hardware",
                detail: "VideoToolbox quando possibile, più efficiente",
                symbol: "cpu",
                tint: .teal,
                isOn: $playerHardwareDecode
            )

            SettingsDivider()

            Menu {
                Picker("Buffer di partenza", selection: $playerForwardBuffer) {
                    Text("1 secondo").tag(1.0)
                    Text("3 secondi").tag(3.0)
                    Text("5 secondi").tag(5.0)
                    Text("8 secondi").tag(8.0)
                }
            } label: {
                SettingsRow(
                    title: "Buffer di partenza",
                    detail: "\(Int(playerForwardBuffer)) s — avvio più rapido con valori bassi",
                    symbol: "gauge.with.dots.needle.33percent",
                    tint: .mint,
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)

            SettingsDivider()

            Menu {
                Picker("Buffer massimo", selection: $playerMaxBuffer) {
                    Text("15 secondi").tag(15.0)
                    Text("30 secondi").tag(30.0)
                    Text("60 secondi").tag(60.0)
                    Text("120 secondi").tag(120.0)
                }
            } label: {
                SettingsRow(
                    title: "Buffer massimo",
                    detail: "\(Int(playerMaxBuffer)) s — più alto regge meglio le reti instabili",
                    symbol: "tray.full",
                    tint: .mint,
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)

            SettingsDivider()

            SettingsToggleRow(
                title: "Seek accurato",
                detail: "Salto al fotogramma esatto (più lento)",
                symbol: "target",
                tint: .orange,
                isOn: $playerAccurateSeek
            )

            SettingsDivider()

            SettingsToggleRow(
                title: "Deinterlacciamento automatico",
                detail: "Per sorgenti interlacciate (vecchie registrazioni TV)",
                symbol: "square.stack.3d.up.slash",
                tint: .brown,
                isOn: $playerAutoDeInterlace
            )

            SettingsDivider()

            Menu {
                Picker("Adattamento video", selection: $playerVideoGravity) {
                    ForEach(VideoGravityMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
            } label: {
                SettingsRow(
                    title: "Adattamento video predefinito",
                    detail: VideoGravityMode(rawValue: playerVideoGravity)?.label ?? "Adatta",
                    symbol: "rectangle.arrowtriangle.2.inward",
                    tint: .indigo,
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)

            SettingsDivider()

            Button(role: .destructive) {
                showResetPlayerPreferencesConfirmation = true
            } label: {
                SettingsRow(
                    title: "Ripristina impostazioni predefinite del player",
                    detail: "Buffer, decodifica, seek e adattamento video ai valori di fabbrica",
                    symbol: "arrow.counterclockwise.circle",
                    tint: .red,
                    showsChevron: false
                )
            }
            .buttonStyle(.plain)
        }
        .confirmationDialog(
            "Ripristinare le impostazioni predefinite del player?",
            isPresented: $showResetPlayerPreferencesConfirmation,
            titleVisibility: .visible
        ) {
            Button("Ripristina", role: .destructive) {
                resetPlayerEnginePreferences()
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Buffer, decodifica hardware, seek accurato, deinterlacciamento e adattamento video torneranno ai valori di fabbrica. Non tocca autoplay, ripresa né velocità, già ripristinabili qui sopra.")
        }
    }

    private var appearanceSection: some View {
        SettingsSection(
            title: "Aspetto",
            subtitle: "Personalizza l’interfaccia",
            symbol: "paintbrush.fill",
            tint: .purple
        ) {
            Menu {
                Picker("Tema", selection: $themeManager.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
            } label: {
                SettingsRow(
                    title: "Tema",
                    detail: themeManager.theme.rawValue,
                    symbol: "circle.lefthalf.filled",
                    tint: .purple,
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var librarySection: some View {
        SettingsSection(
            title: "Libreria",
            subtitle: "Griglia di canali, film e serie",
            symbol: "rectangle.grid.2x2.fill",
            tint: .cyan
        ) {
            Menu {
                Picker(
                    "Densità griglia canali",
                    selection: $channelGridDensity
                ) {
                    Text("Compatta").tag("compact")
                    Text("Comoda").tag("comfortable")
                }
            } label: {
                SettingsRow(
                    title: "Densità griglia",
                    detail: gridDensityName,
                    symbol: "square.grid.3x3",
                    tint: .cyan,
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)

            SettingsDivider()

            SettingsToggleRow(
                title: "Mostra numero canale",
                detail: "Visualizza la numerazione nella griglia Live TV",
                symbol: "number",
                tint: .teal,
                isOn: $showChannelNumbers
            )
        }
    }

    private var catalogSection: some View {
        SettingsSection(
            title: "Catalogo",
            subtitle: "Aggiornamento canali, VOD e serie",
            symbol: "arrow.triangle.2.circlepath",
            tint: .teal
        ) {
            Menu {
                Picker(
                    "Aggiornamento automatico",
                    selection: $catalogSettings.refreshInterval
                ) {
                    ForEach(CatalogSettings.RefreshInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
            } label: {
                SettingsRow(
                    title: "Aggiornamento automatico",
                    detail: catalogSettings.refreshInterval.title,
                    symbol: "clock.arrow.2.circlepath",
                    tint: .teal,
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)

            SettingsDivider()

            SettingsToggleRow(
                title: "Aggiorna all'avvio",
                detail: "Controlla nuovi contenuti ogni volta che apri l'app",
                symbol: "bolt.badge.clock",
                tint: .teal,
                isOn: $catalogSettings.refreshOnLaunch
            )

            SettingsDivider()

            SettingsToggleRow(
                title: "Programma in corso nelle celle",
                detail: "Mostra il programma live sotto ai canali in Live TV",
                symbol: "text.below.photo",
                tint: .cyan,
                isOn: $catalogSettings.showEPGInChannelTiles
            )

            SettingsDivider()

            SettingsToggleRow(
                title: "Precarica dettagli serie",
                detail: "Scarica stagioni ed episodi mentre scorri la griglia",
                symbol: "square.stack.3d.down.forward.fill",
                tint: .indigo,
                isOn: $catalogSettings.preloadSeries
            )

            SettingsDivider()

            Button {
                Task { await refreshCatalogNow() }
            } label: {
                HStack {
                    SettingsRow(
                        title: "Aggiorna catalogo ora",
                        detail: activeXtreamCredentials == nil
                            ? "Richiede una sorgente Xtream attiva"
                            : lastRefreshDescription,
                        symbol: "arrow.clockwise",
                        tint: .green,
                        showsChevron: false
                    )

                    if isRefreshingCatalog {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isRefreshingCatalog || activeXtreamCredentials == nil)

            SettingsDivider()

            Button(role: .destructive) {
                Task { await clearCatalogCache() }
            } label: {
                SettingsRow(
                    title: "Svuota cache catalogo",
                    detail: "La prossima apertura richiederà una nuova sincronizzazione",
                    symbol: "trash",
                    tint: .red,
                    showsChevron: false,
                    destructive: true
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var historySection: some View {
        SettingsSection(
            title: "Cronologia",
            subtitle: "\"Continua a guardare\" in Home",
            symbol: "clock.arrow.circlepath",
            tint: .pink
        ) {
            SettingsRow(
                title: "Elementi recenti",
                detail: historyDetailDescription,
                symbol: "play.rectangle.on.rectangle.fill",
                tint: .pink,
                showsChevron: false
            )

            SettingsDivider()

            Button(role: .destructive) {
                withAnimation(.snappy) { recentlyWatched.clear() }
            } label: {
                SettingsRow(
                    title: "Svuota cronologia",
                    detail: "Rimuove tutti gli elementi da \u{201C}Continua a guardare\u{201D}",
                    symbol: "trash",
                    tint: .red,
                    showsChevron: false,
                    destructive: true
                )
            }
            .buttonStyle(.plain)
            .disabled(recentlyWatched.items.isEmpty)
        }
    }

    /// Sottotitoli: la lingua preferita vive con le impostazioni del player.
    private var subtitleSection: some View {
        SettingsSection(
            title: "Sottotitoli",
            subtitle: "Lingua preferita",
            symbol: "captions.bubble.fill",
            tint: .blue
        ) {
            Menu {
                Picker(
                    "Lingua sottotitoli",
                    selection: $subtitleLanguage
                ) {
                    Text("Italiano").tag("it")
                    Text("English").tag("en")
                    Text("Español").tag("es")
                }
            } label: {
                SettingsRow(
                    title: "Lingua sottotitoli",
                    detail: subtitleLanguageName,
                    symbol: "captions.bubble.fill",
                    tint: .blue,
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)
        }
    }

    /// Sincronizzazione iCloud di sorgenti e preferiti (pagina Backup).
    private var cloudSection: some View {
        SettingsSection(
            title: "iCloud",
            subtitle: "Sincronizzazione di sorgenti e preferiti",
            symbol: "icloud.fill",
            tint: .blue
        ) {
            Button {
                syncToCloud()
            } label: {
                SettingsRow(
                    title: "Sincronizza con iCloud",
                    detail: "Salva sorgenti e preferiti",
                    symbol: "icloud.and.arrow.up",
                    tint: .blue,
                    showsChevron: false
                )
            }
            .buttonStyle(.plain)

            SettingsDivider()

            Button {
                restoreSourcesFromCloud()
            } label: {
                SettingsRow(
                    title: "Ripristina da iCloud",
                    detail: "Recupera le sorgenti salvate da un altro dispositivo",
                    symbol: "icloud.and.arrow.down",
                    tint: .blue,
                    showsChevron: false
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var diagnosticsSection: some View {
        SettingsSection(
            title: "Diagnostica",
            subtitle: "Strumenti tecnici",
            symbol: "wrench.and.screwdriver.fill",
            tint: .gray
        ) {
            NavigationLink {
                DebugConsoleView()
            } label: {
                SettingsRow(
                    title: "Debug e log",
                    detail: "Eventi e messaggi tecnici dell’app",
                    symbol: "ladybug.fill",
                    tint: .red,
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)

            SettingsDivider()

            NavigationLink {
                ATSDiagnosticView()
            } label: {
                SettingsRow(
                    title: "Diagnostica rete",
                    detail: "Verifica ATS e connettività",
                    symbol: "network.badge.shield.half.filled",
                    tint: .blue,
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)

            SettingsDivider()

            Button {
                Task { await refreshSystemCacheCount() }
            } label: {
                HStack {
                    SettingsRow(
                        title: "Cache di sistema",
                        detail: systemCacheDescription,
                        symbol: "memorychip.fill",
                        tint: .purple,
                        showsChevron: false
                    )

                    if isLoadingSystemCacheCount {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isLoadingSystemCacheCount)

            SettingsDivider()

            Button(role: .destructive) {
                Task { await clearSystemCache() }
            } label: {
                HStack {
                    SettingsRow(
                        title: "Svuota cache di sistema",
                        detail: "Rimuove guida TV e dati temporanei dalla memoria",
                        symbol: "trash",
                        tint: .red,
                        showsChevron: false,
                        destructive: true
                    )

                    if isClearingSystemCache {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isClearingSystemCache)
        }
        .task {
            await refreshSystemCacheCount()
        }
    }

    private var dataSection: some View {
        SettingsSection(
            title: "Dati",
            subtitle: "Backup e ripristino",
            symbol: "externaldrive.fill",
            tint: .brown
        ) {
            if let payload = try? SourceBackupCodec.encodeAsString(
                sourceManager.sources
            ) {
                ShareLink(
                    item: payload,
                    preview: SharePreview("Backup sorgenti GassPlayer")
                ) {
                    SettingsRow(
                        title: "Esporta sorgenti",
                        detail: "Backup JSON delle sorgenti configurate",
                        symbol: "square.and.arrow.up",
                        tint: .blue,
                        showsChevron: false
                    )
                }
                .buttonStyle(.plain)

                SettingsDivider()
            }

            if let payload = try? AppPreferencesBackupCodec.encodeAsString(preferencesSnapshot) {
                ShareLink(
                    item: payload,
                    preview: SharePreview("Backup preferenze GassPlayer")
                ) {
                    SettingsRow(
                        title: "Esporta preferenze",
                        detail: "Riproduzione, griglia, tema, catalogo e guida TV",
                        symbol: "slider.horizontal.3",
                        tint: .purple,
                        showsChevron: false
                    )
                }
                .buttonStyle(.plain)

                SettingsDivider()
            }

            Button {
                importPreferencesText = ""
                showImportPreferencesSheet = true
            } label: {
                SettingsRow(
                    title: "Importa preferenze",
                    detail: "Ripristina un backup preferenze incollato",
                    symbol: "square.and.arrow.down",
                    tint: .purple,
                    showsChevron: false
                )
            }
            .buttonStyle(.plain)

            SettingsDivider()

            Button(role: .destructive) {
                showResetConfirmation = true
            } label: {
                SettingsRow(
                    title: "Ripristina preferenze",
                    detail: "Riproduzione e griglia ai valori iniziali",
                    symbol: "arrow.counterclockwise",
                    tint: .red,
                    showsChevron: false,
                    destructive: true
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var aboutSection: some View {
        SettingsSection(
            title: "Informazioni",
            subtitle: "GassPlayer",
            symbol: "info.circle.fill",
            tint: .blue
        ) {
            SettingsRow(
                title: "Versione",
                detail: appVersionString,
                symbol: "app.badge.fill",
                tint: .gray,
                showsChevron: false
            )

            SettingsDivider()

            Link(
                destination: URL(
                    string: "https://github.com/iamgasgass/GassPlayer-IPTV"
                )!
            ) {
                SettingsRow(
                    title: "Repository GitHub",
                    detail: "Codice sorgente e segnalazioni",
                    symbol: "chevron.left.forwardslash.chevron.right",
                    tint: .indigo,
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)
        }
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

    private func resetPlaybackDefaults() {
        autoplayNextEpisode = true
        resumePlayback = true
        preferredPlaybackSpeed = 1.0
        channelGridDensity = "comfortable"
        showChannelNumbers = false
    }

    /// Dedicato alle sole preferenze del motore video (voce a fine sezione
    /// "Riproduzione"): non tocca autoplay/ripresa/velocità/griglia, che
    /// hanno già il proprio ripristino in "Backup e ripristino".
    private func resetPlayerEnginePreferences() {
        KSPlaybackController.PlayerEngineDefaultsStore.resetToFactoryDefaults()
        let factory = KSPlaybackController.PlaybackPreferences.factoryDefault
        playerForwardBuffer = factory.preferredForwardBufferDuration
        playerMaxBuffer = factory.maxBufferDuration
        playerHardwareDecode = factory.hardwareDecode
        playerAccurateSeek = factory.isAccurateSeek
        playerAutoDeInterlace = factory.autoDeInterlace
        playerVideoGravity = factory.videoGravity.rawValue
    }

    // MARK: - Azioni catalogo

    @MainActor
    private func refreshCatalogNow() async {
        guard let credentials = activeXtreamCredentials else { return }
        guard !isRefreshingCatalog else { return }

        isRefreshingCatalog = true
        defer { isRefreshingCatalog = false }

        await xtreamCatalog.refresh(credentials: credentials)

        switch xtreamCatalog.state {
        case .loaded:
            catalogActionFeedback = "Catalogo aggiornato correttamente."
        case .failed(let message):
            catalogActionFeedback = "Aggiornamento non riuscito: \(message)"
        default:
            catalogActionFeedback = "Aggiornamento avviato."
        }
    }

    @MainActor
    private func clearCatalogCache() async {
        await xtreamCatalog.clearPersistedCache(credentials: activeXtreamCredentials)
        xtreamCatalog.reset()
        catalogActionFeedback = "Cache del catalogo svuotata. Verrà ricostruita al prossimo aggiornamento."
    }

    // MARK: - Cache di sistema

    @MainActor
    private func refreshSystemCacheCount() async {
        guard !isLoadingSystemCacheCount else { return }
        isLoadingSystemCacheCount = true
        defer { isLoadingSystemCacheCount = false }
        systemCacheCount = await CacheService.shared.count()
    }

    @MainActor
    private func clearSystemCache() async {
        guard !isClearingSystemCache else { return }
        isClearingSystemCache = true
        defer { isClearingSystemCache = false }
        await CacheService.shared.clearAll()
        systemCacheCount = 0
        catalogActionFeedback = "Cache di sistema svuotata (guida TV e dati temporanei)."
    }

    // MARK: - iCloud

    /// Invia su iCloud esattamente ciò che la riga promette: sorgenti e
    /// preferiti. Il progresso di visione non viene incluso perché l'app
    /// non lo traccia ancora (vedi `RecentlyWatchedStore`), quindi
    /// includerlo qui direbbe il falso.
    private func syncToCloud() {
        cloudSync.pushSources(sourceManager.sources)
        cloudSync.pushFavorites(Set(contentManagement.favorites.map(\.id)))
        catalogActionFeedback = "Sorgenti e preferiti sincronizzati con iCloud."
    }

    /// Recupera le sorgenti salvate su iCloud e aggiunge solo quelle non
    /// ancora presenti su questo dispositivo (confronto per id, così una
    /// sorgente già sincronizzata in precedenza non viene duplicata).
    private func restoreSourcesFromCloud() {
        guard let pulled = cloudSync.pullSources(), !pulled.isEmpty else {
            catalogActionFeedback = "Nessuna sorgente trovata su iCloud."
            return
        }

        let existingIds = Set(sourceManager.sources.map(\.id))
        let newSources = pulled.filter { !existingIds.contains($0.id) }

        guard !newSources.isEmpty else {
            catalogActionFeedback = "Le sorgenti salvate su iCloud sono già tutte presenti su questo dispositivo."
            return
        }

        newSources.forEach(sourceManager.add)
        catalogActionFeedback = "\(newSources.count) sorgent\(newSources.count == 1 ? "e" : "i") ripristinat\(newSources.count == 1 ? "a" : "e") da iCloud."
    }

    // MARK: - Import preferenze

    private func importPreferences() {
        do {
            let backup = try AppPreferencesBackupCodec.decode(fromString: importPreferencesText)
            AppPreferencesBackupCodec.apply(
                backup,
                themeManager: themeManager,
                catalogSettings: catalogSettings,
                epgManager: epgManager,
                downloadManager: downloadManager
            )
            importPreferencesFeedback = "Preferenze importate correttamente."
            showImportPreferencesSheet = false
        } catch {
            importPreferencesFeedback = "Il testo incollato non è un backup preferenze GassPlayer valido."
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color

    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.headline)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            GlassCard {
                VStack(spacing: 0) {
                    content
                }
                // FIX — con il padding di default della GlassCard lo spazio
                // verticale sopra la prima riga e sotto l'ultima riga di ogni
                // card era eccessivo. Compensato solo sull'asse verticale,
                // senza toccare quello orizzontale (che regola la posizione
                // del chevron).
                .padding(.vertical, -8)
            }
        }
    }
}

/// Foglio "Importa preferenze": incolla un backup JSON prodotto da
/// "Esporta preferenze" e lo applica. Stessa struttura di
/// `ImportSourcesSheet` in `SourcesView`, per coerenza tra le due funzioni
/// di import dell'app.
private struct ImportPreferencesSheet: View {
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
                    Text("Incolla qui il contenuto JSON esportato in precedenza con \u{201C}Esporta preferenze\u{201D}. Sorgenti e preferiti non vengono modificati.")
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
            .navigationTitle("Importa preferenze")
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

private struct SettingsRow: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let showsChevron: Bool

    var destructive = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(iconTint)
                .frame(width: 32, height: 32)
                .background(
                    iconTint.opacity(0.14),
                    in: RoundedRectangle(
                        cornerRadius: 9,
                        style: .continuous
                    )
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(destructive ? .red : .primary)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var iconTint: Color {
        destructive ? .red : tint
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color

    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(
                    tint.opacity(0.14),
                    in: RoundedRectangle(
                        cornerRadius: 9,
                        style: .continuous
                    )
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Toggle(title, isOn: $isOn)
                .labelsHidden()
        }
        .padding(.vertical, 9)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 44)
    }
}
