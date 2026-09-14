import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var sourceManager: SourceManager
    @EnvironmentObject var lockManager: ParentalLockManager
    @EnvironmentObject var themeManager: ThemeManager

    @StateObject private var cloudSync = CloudSyncService()
    @StateObject private var downloadManager = DownloadManager()

    @State private var subtitleLanguage = "it"
    @State private var traktConnected = false
    @State private var preferredDNS = "1.1.1.1"
    @State private var showResetConfirmation = false

    @AppStorage("gassplayer.playback.autoplayNextEpisode")
    private var autoplayNextEpisode = true

    @AppStorage("gassplayer.playback.resumePlayback")
    private var resumePlayback = true

    @AppStorage("gassplayer.playback.speed")
    private var preferredPlaybackSpeed = 1.0

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

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    connectionsSection
                    playbackSection
                    appearanceSection
                    librarySection
                    servicesSection
                    securitySection
                    diagnosticsSection
                    dataSection
                    aboutSection
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
        }
    }

    private var connectionsSection: some View {
        SettingsSection(
            title: "Connessioni",
            subtitle: "Sorgenti e sicurezza della rete",
            symbol: "network",
            tint: .blue
        ) {
            NavigationLink {
                SourcesView()
            } label: {
                SettingsRow(
                    title: "Sorgenti",
                    detail: sourceCountDescription,
                    symbol: "square.stack.3d.up.fill",
                    tint: .blue,
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)

            SettingsDivider()

            NavigationLink {
                PersonalVPNView()
            } label: {
                SettingsRow(
                    title: "VPN personale",
                    detail: "Gestisci connessione e configurazione",
                    symbol: "lock.shield.fill",
                    tint: .indigo,
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)

            if sourceManager.sources.isEmpty {
                SettingsDivider()

                Text(
                    "Per configurare Live TV, VOD e Serie TV, apri Sorgenti e tocca il pulsante +."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            }
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
            subtitle: "Canali, film, serie e sottotitoli",
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

            SettingsDivider()

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

    private var servicesSection: some View {
        SettingsSection(
            title: "Servizi",
            subtitle: "Sincronizzazione, download e rete",
            symbol: "cloud.fill",
            tint: .green
        ) {
            Button {
                cloudSync.pushSources(sourceManager.sources)
            } label: {
                SettingsRow(
                    title: "Sincronizza con iCloud",
                    detail: "Sorgenti, preferiti e progresso visione",
                    symbol: "icloud.and.arrow.up",
                    tint: .blue,
                    showsChevron: false
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

            SettingsRow(
                title: "Trakt.tv",
                detail: traktConnected ? "Connesso" : "Non connesso",
                symbol: "checkmark.seal.fill",
                tint: .orange,
                showsChevron: false
            )
        }
    }

    private var securitySection: some View {
        SettingsSection(
            title: "Sicurezza",
            subtitle: "Protezione dei contenuti",
            symbol: "checkmark.shield.fill",
            tint: .orange
        ) {
            NavigationLink {
                ParentalLockView()
            } label: {
                SettingsRow(
                    title: "Parental Lock",
                    detail: "Limiti di visione e codice di protezione",
                    symbol: "lock.shield",
                    tint: .orange,
                    showsChevron: true
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
