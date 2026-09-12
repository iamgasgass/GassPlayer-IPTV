import Foundation
@preconcurrency import NetworkExtension
import Combine

enum VPNManagerError: LocalizedError {
    case noManagerLoaded
    case missingWireGuardKeys
    case saveFailed(Error)
    case startFailed(Error)
    case unsupportedProtocolNotYetEncrypted(VPNProtocolType)

    var errorDescription: String? {
        switch self {
        case .noManagerLoaded:
            return "Profilo VPN non caricato. Riprova a sincronizzare con il provider."
        case .missingWireGuardKeys:
            return "Configurazione WireGuard incompleta: manca la chiave pubblica del server o la chiave privata del client."
        case .saveFailed(let error):
            return "Impossibile salvare il profilo VPN: \(error.localizedDescription)"
        case .startFailed(let error):
            return "Impossibile avviare la VPN: \(error.localizedDescription)"
        case .unsupportedProtocolNotYetEncrypted(let type):
            return "\(type.rawValue) non e' ancora cifrato in questa build (manca la libreria crittografica). Usa IKEv2 o WireGuard se il provider li offre."
        }
    }
}

/// Snapshot leggero usato solo per capire se la configurazione e' cambiata
/// rispetto all'ultima applicata, evitando di salvare/ricreare il profilo
/// VPN (e quindi forzare una disconnessione) quando il provider risponde
/// con dati identici a quelli gia' attivi.
private struct AppliedConfigFingerprint: Equatable {
    let protocolType: VPNProtocolType
    let serverEndpoint: String
    let serverPublicKey: String?
    let allowedIPs: String?
    let dns: String?
    let username: String?
    let clientAddress: String?
    let hasPassword: Bool
    let hasPresharedKey: Bool
    let hasClientPrivateKey: Bool

    init(_ config: ProviderVPNConfig) {
        protocolType = config.protocolType
        serverEndpoint = config.serverEndpoint
        serverPublicKey = config.serverPublicKey
        allowedIPs = config.allowedIPs
        dns = config.dns
        username = config.username
        clientAddress = config.clientAddress
        hasPassword = config.password != nil
        hasPresharedKey = config.presharedKey != nil
        hasClientPrivateKey = config.clientPrivateKey != nil
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
    @Published var activeProtocolIsEncrypted = true
    @Published var watchdogReconnectAttempts = 0

    private var nativeIKEv2Manager: NEVPNManager?
    private var tunnelManager: NETunnelProviderManager?
    private var activeProtocol: VPNProtocolType = .wireGuard
    private var lastAppliedFingerprint: AppliedConfigFingerprint?
    private var lastAppliedSourceName: String?

    private var statusObserver: NSObjectProtocol?
    private let providerBundleId = "com.iamgasgass.gassPlayer.PacketTunnel"

    private var loadManagersTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?

    private var userExpectsConnection = false
    private var watchdogTask: Task<Void, Never>?
    private let maxWatchdogAttempts = 5

    init() {
        loadManagersTask = Task { await loadManagers() }
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
            lastError = "La VPN del provider continua a disconnettersi: verifica lo stato del server o disattiva la VPN per usare la connessione diretta."
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

    func syncFromIPTVProvider(credentials: XtreamCredentials) async {
        if let syncTask {
            await syncTask.value
        }
        let task = Task { await performSync(credentials: credentials) }
        syncTask = task
        await task.value
        syncTask = nil
    }

    private func performSync(credentials: XtreamCredentials) async {
        await ensureManagersLoaded()
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
        activeProtocolIsEncrypted = (config.protocolType == .ikev2 || config.protocolType == .wireGuard)

        let fingerprint = AppliedConfigFingerprint(config)
        if fingerprint == lastAppliedFingerprint && sourceName == lastAppliedSourceName && currentConnection() != nil {
            observeStatus()
            return
        }

        switch config.protocolType {
        case .ikev2:
            try await applyIKEv2(config, sourceName: sourceName)
        case .wireGuard, .openVPN:
            try await applyTunnelProvider(config, sourceName: sourceName)
        }

        lastAppliedFingerprint = fingerprint
        lastAppliedSourceName = sourceName
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
            ikeProtocol.passwordReference = KeychainHelper.storeOrUpdate(secret: password, forKey: "vpn.ikev2.\(sourceName)")
        }
        ikeProtocol.useExtendedAuthentication = true
        ikeProtocol.disconnectOnSleep = false
        // NOTA: non forziamo qui algoritmi di cifratura/DH group specifici.
        // La cifratura IKEv2 viene negoziata con il server del provider, che
        // non controlliamo: imporre parametri non supportati romperebbe la
        // connessione per tutti gli utenti di quel provider. Lasciamo che
        // sia iOS a negoziare i parametri piu' forti supportati da entrambe
        // le parti (comportamento di default e sicuro).

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
        if config.protocolType == .wireGuard {
            guard !(config.serverPublicKey?.isEmpty ?? true) else {
                throw VPNManagerError.missingWireGuardKeys
            }
            guard !(config.clientPrivateKey?.isEmpty ?? true) else {
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
            let key = "vpn.tunnel.password.\(sourceName)"
            proto.passwordReference = KeychainHelper.storeOrUpdate(secret: password, forKey: key)
            secretKeys["passwordKeychainKey"] = key
        }
        if let psk = config.presharedKey {
            let key = "vpn.tunnel.psk.\(sourceName)"
            _ = KeychainHelper.storeOrUpdate(secret: psk, forKey: key)
            secretKeys["presharedKeyKeychainKey"] = key
        }
        if let clientPrivateKey = config.clientPrivateKey {
            let key = "vpn.tunnel.wgPrivateKey.\(sourceName)"
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

    func removeCurrentProfile(sourceName: String) async {
        disconnect()
        removeStatusObserver()
        do {
            switch activeProtocol {
            case .ikev2:
                nativeIKEv2Manager?.protocolConfiguration = nil
                try await nativeIKEv2Manager?.removeFromPreferences()
                KeychainHelper.delete(forKey: "vpn.ikev2.\(sourceName)")
            case .wireGuard, .openVPN:
                try await tunnelManager?.removeFromPreferences()
                KeychainHelper.delete(forKey: "vpn.tunnel.password.\(sourceName)")
                KeychainHelper.delete(forKey: "vpn.tunnel.psk.\(sourceName)")
                KeychainHelper.delete(forKey: "vpn.tunnel.wgPrivateKey.\(sourceName)")
                tunnelManager = nil
            }
        } catch {
            lastError = "Impossibile rimuovere il profilo VPN: \(error.localizedDescription)"
        }
        lastAppliedFingerprint = nil
        lastAppliedSourceName = nil
        providerOffersVPN = false
        status = .invalid
    }

    func handleAppBecameActive() {
        guard autoConnectOnLaunch, providerOffersVPN, status != .connected, status != .connecting else { return }
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
        syncTask?.cancel()
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
