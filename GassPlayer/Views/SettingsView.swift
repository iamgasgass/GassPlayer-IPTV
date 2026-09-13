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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $themeManager.theme) {
                        ForEach(AppTheme.allCases) { Text($0.rawValue).tag($0) }
                    } label: { Label("Tema", systemImage: "circle.lefthalf.filled") }
                } header: { Label("Aspetto", systemImage: "paintbrush") }

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
                    Text("Nessun livello Pro: ogni modulo è attivo di default per tutti gli utenti.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Label("Trasparenza", systemImage: "info.circle") }
            }
            .navigationTitle("Impostazioni")
        }
    }
}
