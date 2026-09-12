import SwiftUI
import NetworkExtension

struct PersonalVPNView: View {
    @EnvironmentObject private var vpnManager: PersonalVPNManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var protocolType: VPNProtocolType = .wireGuard
    @State private var serverEndpoint = ""
    @State private var username = ""
    @State private var password = ""
    @State private var serverPublicKey = ""
    @State private var clientPrivateKey = ""
    @State private var presharedKey = ""
    @State private var clientAddress = ""
    @State private var allowedIPs = "0.0.0.0/0"
    @State private var dns = "1.1.1.1"

    @State private var isSaving = false
    @State private var showToggleErrorAlert = false
    @State private var showRemoveConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                if vpnManager.hasSavedProfile {
                    Section("Stato") {
                        if !vpnManager.activeProtocolIsEncrypted {
                            Label("Questo protocollo non è ancora cifrato in questa build: la connessione è bloccata per non darti un falso senso di sicurezza.", systemImage: "exclamationmark.shield")
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
                    }

                    Section("Comportamento") {
                        Toggle("Connetti VPN all'avvio app", isOn: Binding(
                            get: { vpnManager.autoConnectOnLaunch },
                            set: { vpnManager.setAutoConnectOnLaunch($0) }
                        ))
                        Toggle("Disconnetti VPN uscendo dall'app", isOn: Binding(
                            get: { vpnManager.autoDisconnectOnExit },
                            set: { vpnManager.setAutoDisconnectOnExit($0) }
                        ))
                    }
                }

                Section(vpnManager.hasSavedProfile ? "Modifica profilo" : "Nuovo profilo VPN") {
                    Picker("Protocollo", selection: $protocolType) {
                        Text("WireGuard").tag(VPNProtocolType.wireGuard)
                        Text("IKEv2").tag(VPNProtocolType.ikev2)
                        Text("OpenVPN (non cifrato in questa build)").tag(VPNProtocolType.openVPN)
                    }
                    TextField("Server (es. vpn.miofornitore.com:51820)", text: $serverEndpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Username (opzionale)", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password (opzionale)", text: $password)
                }

                if protocolType == .wireGuard {
                    Section("Chiavi WireGuard") {
                        SecureField("Chiave privata del client", text: $clientPrivateKey)
                        TextField("Chiave pubblica del server", text: $serverPublicKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Preshared key (opzionale)", text: $presharedKey)
                        TextField("Indirizzo client (es. 10.66.66.5/32)", text: $clientAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                if protocolType != .ikev2 {
                    Section("Rete") {
                        TextField("Allowed IPs", text: $allowedIPs)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("DNS", text: $dns)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                Section {
                    Button {
                        Task { await saveProfile() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text(vpnManager.hasSavedProfile ? "Aggiorna profilo" : "Salva e connetti")
                        }
                    }
                    .disabled(isSaving || serverEndpoint.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("VPN personale")
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
                    Task { await vpnManager.removeProfile() }
                }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text("Il profilo e le credenziali salvate verranno eliminati dal dispositivo.")
            }
        }
    }

    private func saveProfile() async {
        isSaving = true
        defer { isSaving = false }
        let config = PersonalVPNConfig(
            protocolType: protocolType,
            serverEndpoint: serverEndpoint.trimmingCharacters(in: .whitespaces),
            serverPublicKey: serverPublicKey.isEmpty ? nil : serverPublicKey,
            presharedKey: presharedKey.isEmpty ? nil : presharedKey,
            allowedIPs: allowedIPs.isEmpty ? nil : allowedIPs,
            dns: dns.isEmpty ? nil : dns,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            clientPrivateKey: clientPrivateKey.isEmpty ? nil : clientPrivateKey,
            clientAddress: clientAddress.isEmpty ? nil : clientAddress
        )
        do {
            try await vpnManager.saveProfile(config)
            try? vpnManager.connect()
        } catch {
            showToggleErrorAlert = true
        }
    }

    private func toggleConnection() {
        do {
            try vpnManager.toggle()
        } catch {
            showToggleErrorAlert = true
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
