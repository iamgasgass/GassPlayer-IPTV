import SwiftUI
import NetworkExtension

struct ProviderVPNView: View {
    let credentials: XtreamCredentials?
    @StateObject private var vpnManager = ProviderVPNManager()
    @State private var isChecking = false

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
                        HStack {
                            Text(statusText)
                            Spacer()
                            GlassIconButton(
                                systemImage: vpnManager.status == .connected ? "lock.fill" : "lock.open.fill",
                                tint: vpnManager.status == .connected ? .green : .gray
                            ) { try? vpnManager.toggle() }
                        }
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
            .task { await refresh() }
        }
    }

    private func refresh() async {
        guard let credentials else { return }
        isChecking = true
        await vpnManager.syncFromIPTVProvider(credentials: credentials)
        isChecking = false
    }

    private var statusText: String {
        switch vpnManager.status {
        case .connected: return "Connesso"
        case .connecting: return "Connessione in corso..."
        case .disconnecting: return "Disconnessione..."
        default: return "Disconnesso"
        }
    }
}
