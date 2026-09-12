import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var sourceManager: SourceManager
    @EnvironmentObject var lockManager: ParentalLockManager
    @StateObject private var cloudSync = CloudSyncService()
    @StateObject private var downloadManager = DownloadManager()
    @State private var subtitleLanguage = "it"
    @State private var traktConnected = false
    @State private var preferredDNS = "1.1.1.1"

    var body: some View {
        NavigationStack {
            Form {
                Section("Sincronizzazione") {
                    Button("Sincronizza ora con iCloud") { cloudSync.pushSources(sourceManager.sources) }
                    Text("Sorgenti, preferiti e progresso visione sincronizzati su tutti i tuoi dispositivi Apple.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Download") { Toggle("Scarica solo su Wi-Fi", isOn: $downloadManager.wifiOnly) }
                Section("Rete") {
                    Picker("DNS preferito", selection: $preferredDNS) {
                        Text("1.1.1.1 (Cloudflare)").tag("1.1.1.1")
                        Text("8.8.8.8 (Google)").tag("8.8.8.8")
                        Text("Automatico (di sistema)").tag("system")
                    }
                    Text("Se i canali vanno spesso in buffering, prova a cambiare DNS.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Sottotitoli") {
                    Picker("Lingua preferita", selection: $subtitleLanguage) {
                        Text("Italiano").tag("it"); Text("English").tag("en"); Text("Español").tag("es")
                    }
                }
                Section("Integrazioni") {
                    HStack { Text("Trakt.tv"); Spacer(); Text(traktConnected ? "Connesso" : "Non connesso").foregroundStyle(.secondary) }
                }
                Section("Sicurezza") { NavigationLink("Parental Lock") { ParentalLockView() } }
                Section("Diagnostica") { NavigationLink("Debug Mode e log") { DebugConsoleView() } }
                Section("Tutte le funzioni sono incluse") {
                    Text("Nessun livello Pro: ogni modulo è attivo di default per tutti gli utenti.").font(.footnote)
                }
            }
            .navigationTitle("Impostazioni")
        }
    }
}
