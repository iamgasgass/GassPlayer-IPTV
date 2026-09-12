import NetworkExtension
import WireGuardKit
import os.log

/// Packet Tunnel Provider con integrazione REALE di WireGuardKit
/// (https://github.com/WireGuard/wireguard-apple), non piu' uno scheletro
/// che dichiarava falso successo. IKEv2 non passa da qui: usa lo stack
/// nativo NEVPNProtocolIKEv2 di iOS, gia' cifrato dal sistema operativo.
///
/// NOTA DI ONESTA' SULLA VERIFICA: l'API di WireGuardKit (TunnelConfiguration,
/// InterfaceConfiguration, PeerConfiguration, WireGuardAdapter) e' quella
/// documentata nel repo ufficiale, ma questa dipendenza NON e' ancora stata
/// aggiunta a project.yml (serve il contenuto di quel file per farlo senza
/// rischiare di rompere la build) e va verificata con una build reale prima
/// di considerarla definitiva — esattamente come successo con KSPlayer in
/// questo stesso progetto.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = OSLog(subsystem: "com.iamgasgass.gassPlayer.PacketTunnel", category: "tunnel")
    private var adapter: WireGuardAdapter?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let config = proto.providerConfiguration else {
            completionHandler(NEVPNError(.configurationInvalid))
            return
        }

        let protocolName = (config["protocol"] as? String ?? "").lowercased()
        os_log("Richiesta avvio tunnel, protocollo: %{public}@", log: log, protocolName)

        switch protocolName {
        case "wireguard":
            startWireGuard(config: config, completionHandler: completionHandler)
        default:
            os_log("Protocollo %{public}@ non ha una implementazione in questo target", log: log, type: .error, protocolName)
            completionHandler(PacketTunnelError.encryptionNotImplemented(protocolName))
        }
    }

    private func startWireGuard(config: [String: Any], completionHandler: @escaping (Error?) -> Void) {
        guard let tunnelConfiguration = Self.buildWireGuardConfiguration(from: config) else {
            os_log("Configurazione WireGuard incompleta o non valida: chiave privata client, chiave pubblica server o endpoint mancanti", log: log, type: .error)
            completionHandler(PacketTunnelError.invalidWireGuardConfiguration)
            return
        }

        let newAdapter = WireGuardAdapter(with: self, logHandler: { [weak self] level, message in
            guard let self else { return }
            os_log("WireGuard[%{public}@]: %{public}@", log: self.log, String(describing: level), message)
        })
        adapter = newAdapter

        newAdapter.start(tunnelConfiguration: tunnelConfiguration) { [weak self] error in
            if let error {
                os_log("Avvio WireGuard fallito: %{public}@", log: self?.log ?? .default, type: .error, "\(error)")
                completionHandler(error)
                return
            }
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("Tunnel arrestato, motivo: %{public}d", log: log, reason.rawValue)
        guard let adapter else {
            completionHandler()
            return
        }
        adapter.stop { _ in completionHandler() }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        completionHandler?(messageData)
    }

    private static func buildWireGuardConfiguration(from config: [String: Any]) -> TunnelConfiguration? {
        guard
            let privateKeyRef = config["clientPrivateKeyKeychainKey"] as? String,
            let privateKeyString = TunnelKeychainHelper.readSecret(forKey: privateKeyRef),
            let privateKey = PrivateKey(base64Key: privateKeyString)
        else { return nil }

        guard
            let serverPublicKeyString = config["serverPublicKey"] as? String,
            let serverPublicKey = PublicKey(base64Key: serverPublicKeyString)
        else { return nil }

        guard
            let endpointString = config["endpoint"] as? String,
            let endpoint = Endpoint(from: endpointString)
        else { return nil }

        let addressCandidates = (config["clientAddress"] as? String) ?? "10.66.66.2/32"
        let addresses = addressCandidates
            .split(separator: ",")
            .compactMap { IPAddressRange(from: $0.trimmingCharacters(in: .whitespaces)) }

        let dnsCandidates = (config["dns"] as? String) ?? "1.1.1.1"
        let dnsServers = dnsCandidates
            .split(separator: ",")
            .compactMap { DNSServer(from: $0.trimmingCharacters(in: .whitespaces)) }

        var interface = InterfaceConfiguration(privateKey: privateKey)
        interface.addresses = addresses
        interface.dns = dnsServers
        interface.mtu = 1400

        var peer = PeerConfiguration(publicKey: serverPublicKey)
        peer.endpoint = endpoint
        let allowedIPsString = (config["allowedIPs"] as? String) ?? "0.0.0.0/0"
        peer.allowedIPs = allowedIPsString
            .split(separator: ",")
            .compactMap { IPAddressRange(from: $0.trimmingCharacters(in: .whitespaces)) }

        if let pskRef = config["presharedKeyKeychainKey"] as? String,
           let pskString = TunnelKeychainHelper.readSecret(forKey: pskRef),
           let psk = PreSharedKey(base64Key: pskString) {
            peer.preSharedKey = psk
        }

        guard !addresses.isEmpty, !peer.allowedIPs.isEmpty else { return nil }
        return TunnelConfiguration(name: "GassPlayer", interface: interface, peers: [peer])
    }
}

enum PacketTunnelError: LocalizedError {
    case encryptionNotImplemented(String)
    case invalidWireGuardConfiguration

    var errorDescription: String? {
        switch self {
        case .encryptionNotImplemented(let protocolName):
            return "\(protocolName) non e' ancora cifrato in questa build dell'app: manca la libreria crittografica integrata. Nessun traffico verra' instradato per evitare una falsa sensazione di protezione."
        case .invalidWireGuardConfiguration:
            return "Configurazione WireGuard incompleta: manca la chiave privata del client, la chiave pubblica del server o l'endpoint. Verifica che il provider fornisca tutti i dati necessari."
        }
    }
}
