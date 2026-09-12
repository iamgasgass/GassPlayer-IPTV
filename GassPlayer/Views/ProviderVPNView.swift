import SwiftUI
import NetworkExtension

struct ProviderVPNView: View {
    let credentials: XtreamCredentials?
    @EnvironmentObject private var vpnManager: ProviderVPNManager
    @State private var isChecking = false
    @State private var showToggleErrorAlert = false
    @State private var showRemoveConfirmation = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                Section("Sorgente VPN") {
                    if let credentials {
                        HStack {
                            Image(systemName: "server.rack")
                            VStack(alignment: .leading) {
                                Text(credentials.host).font(.headline)
                                Text("La VPN viene richiesta a questo stesso server IPTV").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("Nessuna sorgente Xtream attiva: la VPN del provider richiede credenziali Xtream.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Comportamento") {
                    Toggle("Connetti VPN all'avvio app", isOn: $vpnManager.autoConnectOnLaunch)
                    Toggle("Disconnetti VPN uscendo dall'app", isOn: $vpnManager.autoDisconnectOnExit)
                }
                Section("Stato") {
                    if isChecking {
                        HStack { ProgressView(); Text("Verifica configurazione VPN del provider...") }
                    } else if vpnManager.providerOffersVPN {
                        if !vpnManager.activeProtocolIsEncrypted {
                            Label("Questo protocollo non è ancora cifrato in questa versione dell'app: la connessione è bloccata per non darti un falso senso di sicurezza. Chiedi al provider se offre anche IKEv2.", systemImage: "exclamationmark.shield")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        HStack {
                            Text(statusText)
                            if vpnManager.watchdogReconnectAttempts > 0 {
                                Text("· tentativo \(vpnManager.watchdogReconnectAttempts)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            GlassIconButton(
                                systemImage: vpnManager.status == .connected ? "lock.fill" : "lock.open.fill",
                                tint: vpnManager.status == .connected ? .green : .gray
                            ) { toggleConnection() }
                            .disabled(!vpnManager.activeProtocolIsEncrypted)
                        }
                        if let error = vpnManager.lastError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                        Button("Rimuovi profilo VPN", role: .destructive) { showRemoveConfirmation = true }
                            .font(.caption)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Nessuna VPN pubblicata da questo provider", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            if let error = vpnManager.lastError { Text(error).font(.caption).foregroundStyle(.secondary) }
                            if credentials != nil { Button("Riprova") { Task { await refresh() } } }
                        }
                    }
                }
            }
            .navigationTitle("VPN del provider")
            .toolbar {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .navigationBarTrailing) { GlassSearchButton() }
                    ToolbarSpacer(.fixed, placement: .navigationBarTrailing)
                    ToolbarItem(placement: .navigationBarTrailing) { GlassSettingsButton() }
                } else {
                    ToolbarItem(placement: .navigationBarTrailing) { GlassSearchButton() }
                    ToolbarItem(placement: .navigationBarTrailing) { GlassSettingsButton() }
                }
            }
            .task {
                if !vpnManager.providerOffersVPN, vpnManager.lastError == nil {
                    await refresh()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active: vpnManager.handleAppBecameActive()
                case .background: vpnManager.handleAppWillResignActive()
                default: break
                }
            }
            .alert("Impossibile modificare la connessione VPN", isPresented: $showToggleErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(vpnManager.lastError ?? "Errore sconosciuto durante l'avvio della VPN.")
            }
            .confirmationDialog("Rimuovere il profilo VPN?", isPresented: $showRemoveConfirmation, titleVisibility: .visible) {
                Button("Rimuovi", role: .destructive) {
                    Task {
                        guard let credentials else { return }
                        await vpnManager.removeCurrentProfile(sourceName: credentials.host)
                    }
                }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text("Il profilo e le credenziali salvate per questo provider verranno eliminati dal dispositivo.")
            }
        }
    }

    private func toggleConnection() {
        do {
            try vpnManager.toggle()
        } catch {
            showToggleErrorAlert = true
        }
    }

    private func refresh() async {
        guard let credentials else { return }
        isChecking = true
        await vpnManager.syncFromIPTVProvider(credentials: credentials)
        isChecking = false
        if vpnManager.providerOffersVPN, vpnManager.autoConnectOnLaunch, vpnManager.activeProtocolIsEncrypted {
            try? vpnManager.connect()
        }
    }

    private var statusText: String {
        switch vpnManager.status {
        case .connected: return "Connesso"
        case .connecting: return "Connessione in corso..."
        case .reasserting: return "Riconnessione in corso..."
        case .disconnecting: return "Disconnessione..."
        default: return "Disconnesso"
        }
    }
}
