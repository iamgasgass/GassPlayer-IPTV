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
    @EnvironmentObject var appSettings: AppSettings
    @State private var showEPGTest = false

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
                    Toggle(isOn: $appSettings.epgEnabled) {
                        Label("EPG integrato", systemImage: "calendar.badge.clock")
                    }
                    Toggle(isOn: $appSettings.showEPGOnLiveCards) {
                        Label("Programma corrente sulle card", systemImage: "rectangle.on.rectangle")
                    }
                    TextField("URL XMLTV / EPG per playlist M3U", text: $appSettings.epgURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    Picker("Aggiorna ogni", selection: $appSettings.epgRefreshMinutes) {
                        Text("15 min").tag(15)
                        Text("30 min").tag(30)
                        Text("60 min").tag(60)
                        Text("Manuale").tag(0)
                    }
                    Button {
                        showEPGTest = true
                    } label: {
                        Label("Verifica sorgente EPG", systemImage: "checkmark.shield")
                    }
                    Text("Xtream usa l'EPG del provider. Per M3U puoi collegare un feed XMLTV e associare i programmi tramite tvg-id.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Label("Guida TV (EPG)", systemImage: "calendar") }

                Section {
                    Picker("Layout contenuti", selection: $appSettings.preferredContentLayout) {
                        ForEach(AppSettings.ContentLayout.allCases) { layout in
                            Text(layout.rawValue).tag(layout)
                        }
                    }
                    Toggle(isOn: $appSettings.showUncategorizedGroup) {
                        Label("Mostra contenuti senza categoria", systemImage: "tray.full")
                    }
                    Toggle(isOn: $appSettings.deduplicateM3U) {
                        Label("Elimina duplicati M3U", systemImage: "square.stack.3d.up")
                    }
                    Text("Il parser conserva i titoli anche quando il provider omette group-title e riconosce VOD/Serie anche da tvg-type, URL e convenzioni S01E02.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Label("Catalogo e playlist", systemImage: "rectangle.3.group") }

                Section {
                    Toggle("Scarica solo su Wi-Fi", isOn: $downloadManager.wifiOnly)
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
            .toolbar {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fine") { dismiss() }
                            .buttonStyle(.glassProminent)
                    }
                }
            }
            .alert("Sorgente EPG", isPresented: $showEPGTest) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(appSettings.epgURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "Inserisci prima un URL XMLTV."
                     : "La sorgente verrà utilizzata dalle viste Live compatibili con XMLTV.")
            }
        }
    }
}
