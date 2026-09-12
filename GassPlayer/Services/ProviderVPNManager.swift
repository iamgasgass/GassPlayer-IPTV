import Foundation
@preconcurrency import NetworkExtension
import Combine

enum VPNManagerError: LocalizedError {
    case noManagerLoaded
    case missingWireGuardKeys
    case saveFailed(Error)
    case startFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noManagerLoaded: return "Profilo VPN non caricato. Riprova a sincronizzare con il provider."
        case .missingWireGuardKeys: return "Configurazione WireGuard incompleta: manca la chiave pubblica del server."
        case .saveFailed(let error): return "Impossibile salvare il profilo VPN: \(error.localizedDescription)"
        case .startFailed(let error): return "Impossibile avviare la VPN: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class ProviderVPNManager: ObservableObject {
    @Published var status: NEVPNStatus = .invalid
    @Published var isConnecting = false
    @Published var providerOffersVPN = false
    @Published var lastError: String?
    @Published var autoConnectOnLaunch = true
    @Published var autoDisconnectOnExit = true

    private var nativeIKEv2Manager: NEVPNManager?
    private var tunnelManager: NETunnelProviderManager?
    private var activeProtocol: VPNProtocolType = .wireGuard

    private var statusObserver: NSObjectProtocol?
    private let providerBundleId = "com.iamgasgass.gassPlayer.PacketTunnel"

    init() { Task { await loadManagers() } }

    func loadManagers() async {
        nativeIKEv2Manager = NEVPNManager.shared()
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            tunnelManager = managers.first
        } catch {
            lastError = "Impossibile caricare i profili VPN: \(error.localizedDescription)"
        }
    }

    private func currentConnection() -> NEVPNConnection? {
        switch activeProtocol {
        case .ikev2: return nativeIKEv2Manager?.connection
        case .wireGuard, .openVPN: return tunnelManager?.connection
        }
    }

    private func observeStatus() {
        removeStatusObserver()
        guard let connection = currentConnection() else { return }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: connection, queue: nil
        ) { [weak self] notification in
            guard let updatedConnection = notification.object as? NEVPNConnection else { return }
            let newStatus = updatedConnection.status
            Task { @MainActor in
                self?.status = newStatus
                self?.isConnecting = newStatus == .connecting
            }
        }
        status = connection.status
    }

    private func removeStatusObserver() {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        statusObserver = nil
    }

    func syncFromIPTVProvider(credentials: XtreamCredentials) async {
        lastError = nil
        let api = XtreamAPIService(credentials: credentials)
        do {
            let vpnConfig = try await api.fetchProviderVPNConfig()
            try await apply(vpnConfig, sourceName: credentials.host)
            providerOffersVPN = true
            DebugLogger.logAsync(.info, "VPN configurata dal provider \(credentials.host) con protocollo \(vpnConfig.protocolType.rawValue)")
        } catch XtreamError.noProviderVPN {
            providerOffersVPN = false
            lastError = "Questo fornitore IPTV non pubblica una configurazione VPN propria."
        } catch let vpnError as VPNManagerError {
            providerOffersVPN = false
            lastError = vpnError.errorDescription
        } catch {
            providerOffersVPN = false
            lastError = "Errore nel recupero della VPN dal provider: \(error.localizedDescription)"
        }
    }

    private func apply(_ config: ProviderVPNConfig, sourceName: String) async throws {
        activeProtocol = config.protocolType
        switch config.protocolType {
        case .ikev2:
            try await applyIKEv2(config, sourceName: sourceName)
        case .wireGuard, .openVPN:
            try await applyTunnelProvider(config, sourceName: sourceName)
        }
        observeStatus()
    }

    private func applyIKEv2(_ config: ProviderVPNConfig, sourceName: String) async throws {
        let vpnManager = NEVPNManager.shared()
        do {
            try await vpnManager.loadFromPreferences()
        } catch {
            throw VPNManagerError.saveFailed(error)
        }

        let ikeProtocol = NEVPNProtocolIKEv2()
        ikeProtocol.serverAddress = config.serverEndpoint
        ikeProtocol.remoteIdentifier = config.serverEndpoint
        ikeProtocol.username = config.username
        if let password = config.password {
            ikeProtocol.authenticationMethod = .none
            ikeProtocol.passwordReference = KeychainHelper.store(password: password, forKey: "vpn.ikev2.\(sourceName)")
        }
        ikeProtocol.useExtendedAuthentication = true
        ikeProtocol.disconnectOnSleep = false

        vpnManager.protocolConfiguration = ikeProtocol
        vpnManager.localizedDescription = "VPN — \(sourceName)"
        vpnManager.isEnabled = true

        do {
            try await vpnManager.saveToPreferences()
            try await vpnManager.loadFromPreferences()
        } catch {
            throw VPNManagerError.saveFailed(error)
        }
        nativeIKEv2Manager = vpnManager
    }

    private func applyTunnelProvider(_ config: ProviderVPNConfig, sourceName: String) async throws {
        if config.protocolType == .wireGuard && (config.serverPublicKey?.isEmpty ?? true) {
            throw VPNManagerError.missingWireGuardKeys
        }

        let manager = tunnelManager ?? NETunnelProviderManager()
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

        manager.protocolConfiguration = proto
        manager.localizedDescription = "VPN — \(sourceName)"
        manager.isEnabled = true

        do {
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        } catch {
            throw VPNManagerError.saveFailed(error)
        }
        tunnelManager = manager
    }

    func connect() throws {
        guard let connection = currentConnection() else { throw VPNManagerError.noManagerLoaded }
        do {
            try connection.startVPNTunnel()
        } catch {
            lastError = VPNManagerError.startFailed(error).errorDescription
            throw VPNManagerError.startFailed(error)
        }
    }

    func disconnect() {
        currentConnection()?.stopVPNTunnel()
    }

    func toggle() throws {
        if status == .connected || status == .connecting {
            disconnect()
        } else {
            try connect()
        }
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }
}

enum KeychainHelper {
    static func store(password: String, forKey key: String) -> Data? {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { return nil }
        let matchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnPersistentRef as String: true
        ]
        var ref: CFTypeRef?
        guard SecItemCopyMatching(matchQuery as CFDictionary, &ref) == errSecSuccess else { return nil }
        return ref as? Data
    }
}
