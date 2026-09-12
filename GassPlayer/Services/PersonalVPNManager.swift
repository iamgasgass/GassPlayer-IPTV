import Foundation
@preconcurrency import NetworkExtension
import Combine

enum VPNManagerError: LocalizedError {
    case noManagerLoaded
    case missingWireGuardKeys
    case saveFailed(Error)
    case startFailed(Error)
    case unsupportedProtocolNotYetEncrypted(VPNProtocolType)
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .noManagerLoaded:
            return "Nessun profilo VPN configurato. Inseriscine uno per attivare la VPN."
        case .missingWireGuardKeys:
            return "Configurazione WireGuard incompleta: servono chiave pubblica del server e chiave privata del client."
        case .saveFailed(let error):
            return "Impossibile salvare il profilo VPN: \(error.localizedDescription)"
        case .startFailed(let error):
            return "Impossibile avviare la VPN: \(error.localizedDescription)"
        case .unsupportedProtocolNotYetEncrypted(let type):
            return "\(type.rawValue) non e' ancora cifrato in questa build (manca la libreria crittografica). Usa IKEv2 o WireGuard."
        case .invalidConfiguration:
            return "Configurazione VPN incompleta: controlla i campi obbligatori."
        }
    }
}

@MainActor
final class PersonalVPNManager: ObservableObject {
    @Published var status: NEVPNStatus = .invalid
    @Published var isConnecting = false
    @Published var hasSavedProfile = false
    @Published var lastError: String?
    @Published var autoConnectOnLaunch = false
    @Published var autoDisconnectOnExit = false
    @Published var activeProtocolIsEncrypted = true
    @Published var watchdogReconnectAttempts = 0
    @Published private(set) var savedProfileSummary: PersonalVPNConfig?

    private var nativeIKEv2Manager: NEVPNManager?
    private var tunnelManager: NETunnelProviderManager?
    private var activeProtocol: VPNProtocolType = .wireGuard

    private var statusObserver: NSObjectProtocol?
    private let providerBundleId = "com.iamgasgass.gassPlayer.PacketTunnel"

    private var loadManagersTask: Task<Void, Never>?
    private var userExpectsConnection = false
    private var watchdogTask: Task<Void, Never>?
    private let maxWatchdogAttempts = 5

    private static let profileName = "personalVPN"
    private static let autoConnectDefaultsKey = "vpn.autoConnectOnLaunch"
    private static let autoDisconnectDefaultsKey = "vpn.autoDisconnectOnExit"
    private static let profileMetadataDefaultsKey = "vpn.personalProfile.metadata"

    init() {
        autoConnectOnLaunch = UserDefaults.standard.bool(forKey: Self.autoConnectDefaultsKey)
        autoDisconnectOnExit = UserDefaults.standard.bool(forKey: Self.autoDisconnectDefaultsKey)
        loadManagersTask = Task {
            await loadManagers()
            loadSavedProfileMetadata()
        }
    }

    private func persistTogglePreferences() {
        UserDefaults.standard.set(autoConnectOnLaunch, forKey: Self.autoConnectDefaultsKey)
        UserDefaults.standard.set(autoDisconnectOnExit, forKey: Self.autoDisconnectDefaultsKey)
    }

    func setAutoConnectOnLaunch(_ value: Bool) {
        autoConnectOnLaunch = value
        persistTogglePreferences()
    }

    func setAutoDisconnectOnExit(_ value: Bool) {
        autoDisconnectOnExit = value
        persistTogglePreferences()
    }

    private func ensureManagersLoaded() async {
        if let loadManagersTask {
            await loadManagersTask.value
        }
    }

    func loadManagers() async {
        nativeIKEv2Manager = NEVPNManager.shared()
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            tunnelManager = managers.first
        } catch {
            lastError = "Impossibile caricare i profili VPN: \(error.localizedDescription)"
        }
    }

    private func loadSavedProfileMetadata() {
        guard let data = UserDefaults.standard.data(forKey: Self.profileMetadataDefaultsKey),
              let metadata = try? JSONDecoder().decode(SavedProfileMetadata.self, from: data) else {
            hasSavedProfile = (nativeIKEv2Manager?.protocolConfiguration != nil) || (tunnelManager != nil)
            return
        }
        activeProtocol = metadata.protocolType
        activeProtocolIsEncrypted = (metadata.protocolType == .ikev2 || metadata.protocolType == .wireGuard)
        hasSavedProfile = true
        observeStatus()
    }

    private struct SavedProfileMetadata: Codable {
        let protocolType: VPNProtocolType
        let serverEndpoint: String
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
                self?.handleStatusChange(newStatus)
            }
        }
        status = connection.status
    }

    private func handleStatusChange(_ newStatus: NEVPNStatus) {
        status = newStatus
        isConnecting = newStatus == .connecting || newStatus == .reasserting

        switch newStatus {
        case .connected:
            watchdogReconnectAttempts = 0
            watchdogTask?.cancel()
        case .disconnected:
            if userExpectsConnection {
                scheduleWatchdogReconnect()
            }
        default:
            break
        }
    }

    private func scheduleWatchdogReconnect() {
        guard watchdogReconnectAttempts < maxWatchdogAttempts else {
            lastError = "Il profilo VPN continua a disconnettersi: verifica le credenziali o il server."
            return
        }
        watchdogTask?.cancel()
        let attempt = watchdogReconnectAttempts
        let delaySeconds = min(pow(2.0, Double(attempt)), 16.0)
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.watchdogReconnectAttempts += 1
            DebugLogger.logAsync(.warning, "Watchdog VPN: tentativo di riconnessione #\(self.watchdogReconnectAttempts) dopo caduta imprevista del tunnel")
            try? self.connect()
        }
    }

    private func removeStatusObserver() {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        statusObserver = nil
    }

    func saveProfile(_ config: PersonalVPNConfig) async throws {
        guard config.isValid else { throw VPNManagerError.invalidConfiguration }
        await ensureManagersLoaded()
        lastError = nil

        activeProtocol = config.protocolType
        activeProtocolIsEncrypted = (config.protocolType == .ikev2 || config.protocolType == .wireGuard)

        switch config.protocolType {
        case .ikev2:
            try await applyIKEv2(config)
        case .wireGuard, .openVPN:
            try await applyTunnelProvider(config)
        }

        let metadata = SavedProfileMetadata(protocolType: config.protocolType, serverEndpoint: config.serverEndpoint)
        if let encoded = try? JSONEncoder().encode(metadata) {
            UserDefaults.standard.set(encoded, forKey: Self.profileMetadataDefaultsKey)
        }
        hasSavedProfile = true
        observeStatus()
    }

    private func applyIKEv2(_ config: PersonalVPNConfig) async throws {
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
            ikeProtocol.passwordReference = KeychainHelper.storeOrUpdate(secret: password, forKey: "vpn.ikev2.\(Self.profileName)")
        }
        ikeProtocol.useExtendedAuthentication = true
        ikeProtocol.disconnectOnSleep = false

        vpnManager.protocolConfiguration = ikeProtocol
        vpnManager.localizedDescription = "VPN personale"
        vpnManager.isEnabled = true

        do {
            try await vpnManager.saveToPreferences()
            try await vpnManager.loadFromPreferences()
        } catch {
            throw VPNManagerError.saveFailed(error)
        }
        nativeIKEv2Manager = vpnManager
    }

    private func applyTunnelProvider(_ config: PersonalVPNConfig) async throws {
        if config.protocolType == .wireGuard {
            guard !(config.serverPublicKey?.isEmpty ?? true), !(config.clientPrivateKey?.isEmpty ?? true) else {
                throw VPNManagerError.missingWireGuardKeys
            }
        }

        let manager = tunnelManager ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.serverAddress = config.serverEndpoint
        proto.providerBundleIdentifier = providerBundleId
        proto.username = config.username

        var secretKeys: [String: String] = [:]
        if let password = config.password {
            let key = "vpn.tunnel.password.\(Self.profileName)"
            proto.passwordReference = KeychainHelper.storeOrUpdate(secret: password, forKey: key)
            secretKeys["passwordKeychainKey"] = key
        }
        if let psk = config.presharedKey {
            let key = "vpn.tunnel.psk.\(Self.profileName)"
            _ = KeychainHelper.storeOrUpdate(secret: psk, forKey: key)
            secretKeys["presharedKeyKeychainKey"] = key
        }
        if let clientPrivateKey = config.clientPrivateKey {
            let key = "vpn.tunnel.wgPrivateKey.\(Self.profileName)"
            _ = KeychainHelper.storeOrUpdate(secret: clientPrivateKey, forKey: key)
            secretKeys["clientPrivateKeyKeychainKey"] = key
        }

        var providerConfig: [String: Any] = [
            "protocol": config.protocolType.rawValue,
            "endpoint": config.serverEndpoint,
            "allowedIPs": config.allowedIPs ?? "0.0.0.0/0",
            "dns": config.dns ?? "1.1.1.1",
            "clientAddress": config.clientAddress ?? "10.66.66.2/32"
        ]
        if let key = config.serverPublicKey { providerConfig["serverPublicKey"] = key }
        providerConfig.merge(secretKeys) { current, _ in current }
        proto.providerConfiguration = providerConfig

        manager.protocolConfiguration = proto
        manager.localizedDescription = "VPN personale"
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
        if !activeProtocolIsEncrypted {
            let error = VPNManagerError.unsupportedProtocolNotYetEncrypted(activeProtocol)
            lastError = error.errorDescription
            throw error
        }
        userExpectsConnection = true
        do {
            try connection.startVPNTunnel()
        } catch {
            lastError = VPNManagerError.startFailed(error).errorDescription
            throw VPNManagerError.startFailed(error)
        }
    }

    func disconnect() {
        userExpectsConnection = false
        watchdogTask?.cancel()
        watchdogReconnectAttempts = 0
        currentConnection()?.stopVPNTunnel()
    }

    func toggle() throws {
        if status == .connected || status == .connecting {
            disconnect()
        } else {
            try connect()
        }
    }

    func removeProfile() async {
        disconnect()
        removeStatusObserver()
        do {
            switch activeProtocol {
            case .ikev2:
                nativeIKEv2Manager?.protocolConfiguration = nil
                try await nativeIKEv2Manager?.removeFromPreferences()
                KeychainHelper.delete(forKey: "vpn.ikev2.\(Self.profileName)")
            case .wireGuard, .openVPN:
                try await tunnelManager?.removeFromPreferences()
                KeychainHelper.delete(forKey: "vpn.tunnel.password.\(Self.profileName)")
                KeychainHelper.delete(forKey: "vpn.tunnel.psk.\(Self.profileName)")
                KeychainHelper.delete(forKey: "vpn.tunnel.wgPrivateKey.\(Self.profileName)")
                tunnelManager = nil
            }
        } catch {
            lastError = "Impossibile rimuovere il profilo VPN: \(error.localizedDescription)"
        }
        UserDefaults.standard.removeObject(forKey: Self.profileMetadataDefaultsKey)
        hasSavedProfile = false
        status = .invalid
    }

    func handleAppBecameActive() {
        guard autoConnectOnLaunch, hasSavedProfile, status != .connected, status != .connecting else { return }
        try? connect()
    }

    func handleAppWillResignActive() {
        guard autoDisconnectOnExit else { return }
        disconnect()
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        watchdogTask?.cancel()
        loadManagersTask?.cancel()
    }
}

enum KeychainHelper {
    static func storeOrUpdate(secret: String, forKey key: String) -> Data? {
        let data = Data(secret.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(baseQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else { return nil }

        var matchQuery = baseQuery
        matchQuery[kSecReturnPersistentRef as String] = true
        var ref: CFTypeRef?
        guard SecItemCopyMatching(matchQuery as CFDictionary, &ref) == errSecSuccess else { return nil }
        return ref as? Data
    }

    static func readSecret(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
