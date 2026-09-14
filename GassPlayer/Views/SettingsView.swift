import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var sourceManager: SourceManager
    @EnvironmentObject var lockManager: ParentalLockManager
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var cloudSync = CloudSyncService()
    @StateObject private var downloadManager = DownloadManager()
    @State private var subtitleLanguage = "it"
    @State private var traktConnected = false
    @State private var preferredDNS = "1.1.1.1"

    @AppStorage("gassplayer.playback.autoplayNextEpisode") private var autoplayNextEpisode = true
    @AppStorage("gassplayer.playback.resumePlayback") private var resumePlayback = true
    @AppStorage("gassplayer.playback.speed") private var preferredPlaybackSpeed = 1.0
    @AppStorage("gassplayer.grid.density") private var channelGridDensity = "comfortable"
    @AppStorage("gassplayer.grid.showChannelNumbers") private var showChannelNumbers = false
    @State private var showResetConfirmation = false

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $themeManager.theme) {
                        ForEach(AppTheme.allCases) { Text($0.rawValue).tag($0) }
                    } label: { Label("Tema", systemImage: "circle.lefthalf.filled") }
                } header: { Label("Aspetto", systemImage: "paintbrush") }

                Section {
                    Toggle(isOn: $autoplayNextEpisode) {
                        Label("Riproduci automaticamente il prossimo episodio", systemImage: "play.square.stack")
                    }
                    Toggle(isOn: $resumePlayback) {
                        Label("Riprendi dall'ultimo punto visto", systemImage: "arrow.counterclockwise.circle")
                    }
                    Picker(selection: $preferredPlaybackSpeed) {
                        Text("1.0×").tag(1.0)
                        Text("1.25×").tag(1.25)
                        Text("1.5×").tag(1.5)
                        Text("2.0×").tag(2.0)
                    } label: { Label("Velocità predefinita", systemImage: "speedometer") }
                } header: { Label("Riproduzione", systemImage: "play.rectangle") }

                Section {
                    Picker(selection: $channelGridDensity) {
                        Text("Compatta").tag("compact")
                        Text("Comoda").tag("comfortable")
                    } label: { Label("Densità griglia canali", systemImage: "square.grid.3x3") }
                    Toggle(isOn: $showChannelNumbers) {
                        Label("Mostra numero canale", systemImage: "number")
                    }
                } header: { Label("Griglia canali", systemImage: "rectangle.grid.2x2") }

                Section {
                    Button { cloudSync.pushSources(sourceManager.sources) } label: {
                        Label("Sincronizza ora con iCloud", systemImage: "icloud.and.arrow.up")
                    }
                    Text("Sorgenti, preferiti e progresso visione su tutti i tuoi dispositivi Apple.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Label("Sincronizzazione", systemImage: "icloud") }

                Section {
                    Toggle(isOn: $downloadManager.wifiOnly) { Label("Scarica solo su Wi-Fi", systemImage: "wifi") }
                } header: { Label("Download offline", systemImage: "arrow.down.circle") }

                Section {
                    Picker(selection: $preferredDNS) {
                        Text("1.1.1.1 (Cloudflare)").tag("1.1.1.1")
                        Text("8.8.8.8 (Google)").tag("8.8.8.8")
                        Text("Automatico (di sistema)").tag("system")
                    } label: { Label("DNS preferito", systemImage: "network") }
                    Text("Se i canali vanno spesso in buffering, prova a cambiare DNS.").font(.caption).foregroundStyle(.secondary)
                } header: { Label("Rete e streaming", systemImage: "antenna.radiowaves.left.and.right") }

                Section {
                    Picker(selection: $subtitleLanguage) {
                        Text("Italiano").tag("it"); Text("English").tag("en"); Text("Español").tag("es")
                    } label: { Label("Lingua sottotitoli", systemImage: "captions.bubble") }
                } header: { Label("Audio e sottotitoli", systemImage: "waveform") }

                Section {
                    HStack {
                        Label("Trakt.tv", systemImage: "checkmark.seal")
                        Spacer()
                        Text(traktConnected ? "Connesso" : "Non connesso").foregroundStyle(.secondary)
                    }
                } header: { Label("Integrazioni", systemImage: "puzzlepiece.extension") }

                Section {
                    NavigationLink { ParentalLockView() } label: { Label("Parental Lock", systemImage: "lock.shield") }
                } header: { Label("Sicurezza", systemImage: "checkmark.shield") }

                Section {
                    NavigationLink { DebugConsoleView() } label: { Label("Debug Mode e log", systemImage: "ladybug") }
                    NavigationLink { ATSDiagnosticView() } label: { Label("Diagnostica rete (ATS)", systemImage: "network.badge.shield.half.filled") }
                } header: { Label("Diagnostica", systemImage: "wrench.and.screwdriver") }

                Section {
                    if let payload = try? SourceBackupCodec.encodeAsString(sourceManager.sources) {
                        ShareLink(item: payload, preview: SharePreview("Backup sorgenti GassPlayer")) {
                            Label("Esporta sorgenti (JSON)", systemImage: "square.and.arrow.up")
                        }
                    }
                    Text("\(sourceManager.sources.count) sorgenti configurate")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(role: .destructive) {
                        showResetConfirmation = true
                    } label: {
                        Label("Ripristina impostazioni di riproduzione", systemImage: "arrow.counterclockwise")
                    }
                } header: { Label("Dati", systemImage: "externaldrive") }

                Section {
                    LabeledContent("Versione") { Text(appVersionString) }
                    Link(destination: URL(string: "https://github.com/iamgasgass/GassPlayer-IPTV")!) {
                        Label("Repository GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                } header: { Label("Informazioni", systemImage: "info.circle") }

                Section {
                    Text("Nessun livello Pro: ogni modulo è attivo di default per tutti gli utenti.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Label("Trasparenza", systemImage: "info.circle") }
            }
            .navigationTitle("Impostazioni")
            .confirmationDialog(
                "Ripristinare le impostazioni di riproduzione ai valori predefiniti?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Ripristina", role: .destructive) { resetPlaybackDefaults() }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text("Autoplay, ripresa e velocità torneranno ai valori di default. Sorgenti e preferiti non vengono toccati.")
            }
        }
    }

    private func resetPlaybackDefaults() {
        autoplayNextEpisode = true
        resumePlayback = true
        preferredPlaybackSpeed = 1.0
        channelGridDensity = "comfortable"
        showChannelNumbers = false
    }
}
