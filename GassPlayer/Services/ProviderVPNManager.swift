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
            return "Configurazione WireGuard incompleta: manca la chiave pubblica del server."
        case .saveFailed(let error):
            return "Impossibile salvare il profilo VPN: \(error.localizedDescription)"
        case .startFailed(let error):
            return "Impossibile avviare la VPN: \(error.localizedDescription)"
        case .unsupportedProtocolNotYetEncrypted(let type):
            return "\(type.rawValue) non e' ancora cifrato in questa build (manca la libreria crittografica). Usa IKEv2 se il provider lo offre: e' gestito nativamente da iOS con cifratura reale."
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
    /// La password non entra nel fingerprint: cambiare password non deve
    /// mai essere "silenziosamente ignorato" per un falso match cache.
    let hasPassword: Bool
    let hasPresharedKey: Bool

    init(_ config: ProviderVPNConfig) {
        protocolType = config.protocolType
        serverEndpoint = config.serverEndpoint
        serverPublicKey = config.serverPublicKey
        allowedIPs = config.allowedIPs
        dns = config.dns
        username = config.username
        hasPassword = config.password != nil
        hasPresharedKey = config.presharedKey != nil
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
    /// True se il protocollo attivo e' realmente cifrato end-to-end in questa
    /// build. IKEv2 lo e' sempre (stack nativo iOS). WireGuard/OpenVPN lo
    /// saranno solo dopo l'integrazione di una libreria crittografica
    /// audited nel target PacketTunnel: finche' non lo e', il tentativo di
    /// connessione fallisce esplicitamente invece di fingere un successo.
    @Published var activeProtocolIsEncrypted = true
    /// Numero di riconnessioni automatiche tentate dal watchdog dopo una
    /// caduta imprevista del tunnel (visibile in UI per trasparenza).
    @Published var watchdogReconnectAttempts = 0

    private var nativeIKEv2Manager: NEVPNManager?
    private var tunnelManager: NETunnelProviderManager?
    private var activeProtocol: VPNProtocolType = .wireGuard
    private var lastAppliedFingerprint: AppliedConfigFingerprint?
    private var lastAppliedSourceName: String?

    private var statusObserver: NSObjectProtocol?
    private let providerBundleId = "com.iamgasgass.gassPlayer.PacketTunnel"

    /// Serializza loadManagers()/syncFromIPTVProvider() cosi' due chiamate
    /// concorrenti (es. app che torna in foreground mentre una sync e' gia'
    /// in corso) non si accavallano creando due NETunnelProviderManager
    /// diversi per lo stesso provider.
    private var loadManagersTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?

    /// True quando l'utente si aspetta la VPN attiva (connessa o in fase di
    /// connessione volontaria): distingue una disconnessione voluta da una
    /// caduta imprevista che il watchdog deve provare a recuperare.
    private var userExpectsConnection = false
    private var watchdogTask: Task<Void, Never>?
    private let maxWatchdogAttempts = 5

    init() {
        loadManagersTask = Task { await loadManagers() }
    }

    /// Attende che il caricamento iniziale dei profili sia completato prima
    /// di procedere: elimina la race in cui syncFromIPTVProvider() partiva
    /// prima che loadManagers() avesse finito, rischiando di creare un
    /// NETunnelProviderManager duplicato invece di riusare quello esistente.
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

    /// Riconnessione automatica con backoff esponenziale (1s, 2s, 4s, 8s,
    /// 16s) quando il tunnel cade mentre l'utente lo aspettava attivo — ad
    /// esempio a meta' di una sessione di streaming IPTV. Si arresta dopo
    /// maxWatchdogAttempts per non tentare all'infinito con un server VPN
    /// del provider che e' semplicemente offline.
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

    /// Sincronizza la configurazione VPN dal provider IPTV. Se una sync e'
    /// gia' in corso, la nuova richiesta ne attende il completamento invece
    /// di lanciarne una seconda in parallelo.
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
        activeProtocolIsEncrypted = (config.protocolType == .ikev2)

        let fingerprint = AppliedConfigFingerprint(config)
        if fingerprint == lastAppliedFingerprint && sourceName == lastAppliedSourceName && currentConnection() != nil {
            // Config identica alla precedente e profilo gia' presente: non
            // ri-salvare le preferenze, altrimenti iOS puo' interrompere un
            // tunnel gia' attivo e funzionante senza alcun motivo reale.
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
        proto.username = config.username

        // Segreti (password/preshared key) SOLO in Keychain, mai in chiaro
        // nel dizionario providerConfiguration: quel dizionario finisce
        // scritto nelle preferenze di sistema (leggibile con accesso al
        // profilo), non e' un vault. passwordReference e' l'unico canale
        // pensato per credenziali sensibili con NETunnelProviderProtocol,
        // ed e' leggibile dall'estensione PacketTunnel via Keychain.
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

        var providerConfig: [String: Any] = [
            "protocol": config.protocolType.rawValue,
            "allowedIPs": config.allowedIPs ?? "0.0.0.0/0",
            "dns": config.dns ?? "1.1.1.1"
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
        if activeProtocol != .ikev2 && !activeProtocolIsEncrypted {
            // Non chiamare startVPNTunnel(): l'estensione PacketTunnel
            // rifiuterebbe comunque la richiesta, ma e' meglio dare
            // all'utente un errore chiaro e immediato via UI piuttosto che
            // un tentativo che finisce in "Connecting..." indefinito.
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

    /// Rimuove completamente il profilo VPN attivo e le credenziali
    /// associate dal Keychain. Utile quando l'utente cambia sorgente IPTV
    /// (evita di lasciare profili e password orfani sul dispositivo) o
    /// vuole semplicemente "ripartire da zero" in caso di problemi.
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

    /// Da chiamare quando l'app torna in foreground, se autoConnectOnLaunch
    /// e' attivo e il provider offre una VPN propria.
    func handleAppBecameActive() {
        guard autoConnectOnLaunch, providerOffersVPN, status != .connected, status != .connecting else { return }
        try? connect()
    }

    /// Da chiamare quando l'app va in background, se autoDisconnectOnExit
    /// e' attivo.
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

/// Wrapper Keychain per segreti VPN (password IKEv2/tunnel, preshared key).
/// Usa kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly: l'estensione
/// PacketTunnel deve poter leggere il segreto anche se l'app principale non
/// e' in esecuzione (es. riconnessione in background dopo un riavvio), ma
/// il dato resta illeggibile prima del primo unlock e non e' incluso nei
/// backup iCloud/iTunes di altri dispositivi.
enum KeychainHelper {
    /// Crea o aggiorna un segreto, restituendo il persistent reference da
    /// assegnare a NEVPNProtocol.passwordReference. Sovrascrive sempre il
    /// valore precedente per la stessa key: evita voci Keychain duplicate
    /// quando l'utente aggiorna le proprie credenziali IPTV.
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

    /// Letto dall'estensione PacketTunnel per recuperare il segreto reale a
    /// partire dal persistent reference salvato in providerConfiguration.
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
