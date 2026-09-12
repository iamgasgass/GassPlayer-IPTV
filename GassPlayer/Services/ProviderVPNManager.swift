import Foundation
import NetworkExtension
import Combine

@MainActor
final class ProviderVPNManager: ObservableObject {
    @Published var status: NEVPNStatus = .invalid
    @Published var isConnecting = false
    @Published var providerOffersVPN = false
    @Published var lastError: String?
    @Published var autoConnectOnLaunch = true
    @Published var autoDisconnectOnExit = true

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private let providerBundleId = "com.iamgasgass.gassPlayer.PacketTunnel"

    init() { Task { await loadManager() } }

    func loadManager() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first ?? NETunnelProviderManager()
            observeStatus()
        } catch { lastError = "Impossibile caricare il profilo VPN: \\(error.localizedDescription)" }
    }

    private func observeStatus() {
        guard let connection = manager?.connection else { return }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: connection, queue: .main
        ) { [weak self] _ in
            self?.status = connection.status
            self?.isConnecting = connection.status == .connecting
        }
        status = connection.status
    }

    func syncFromIPTVProvider(credentials: XtreamCredentials) async {
        lastError = nil
        let api = XtreamAPIService(credentials: credentials)
        do {
            let vpnConfig = try await api.fetchProviderVPNConfig()
            try await apply(vpnConfig, sourceName: credentials.host)
            providerOffersVPN = true
            DebugLogger.shared.log(.info, "VPN configurata dal provider \\(credentials.host)")
        } catch XtreamError.noProviderVPN {
            providerOffersVPN = false
            lastError = "Questo fornitore IPTV non pubblica una configurazione VPN propria."
        } catch {
            providerOffersVPN = false
            lastError = "Errore nel recupero della VPN dal provider: \\(error.localizedDescription)"
        }
    }

    private func apply(_ config: ProviderVPNConfig, sourceName: String) async throws {
        let m = manager ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.serverAddress = config.serverEndpoint
        proto.providerBundleIdentifier = providerBundleId
        var providerConfig: [String: Any] = [
            "protocol": config.protocolType.rawValue,
            "allowedIPs": config.allowedIPs ?? "0.0.0.0/0",
            "dns": config.dns ?? "1.1.1.1"
        ]
        if let key = config.serverPublicKey { providerConfig["serverPublicKey"] = key }
        if let psk = config.presharedKey { providerConfig["presharedKey"] = psk }
        if let user = config.username { providerConfig["username"] = user }
        if let pass = config.password { providerConfig["password"] = pass }
        proto.providerConfiguration = providerConfig
        m.protocolConfiguration = proto
        m.localizedDescription = "VPN — \\(sourceName)"
        m.isEnabled = true
        try await m.saveToPreferences()
        try await m.loadFromPreferences()
        manager = m
        observeStatus()
    }

    func connect() throws { try manager?.connection.startVPNTunnel() }
    func disconnect() { manager?.connection.stopVPNTunnel() }
    func toggle() throws {
        if status == .connected || status == .connecting { disconnect() } else { try connect() }
    }
}
