import NetworkExtension
import os.log

/// Scheletro reale di Packet Tunnel Provider per il tunnel VPN.
///
/// SICUREZZA — PERCHE' QUESTO FILE RIFIUTA WIREGUARD E OPENVPN:
/// la versione precedente impostava i network settings (routing, DNS) e poi
/// chiamava sempre `completionHandler(nil)`, cioe' dichiarava "tunnel
/// connesso e funzionante" anche per WireGuard/OpenVPN, per cui NON esiste
/// ancora una libreria di cifratura integrata in questo target. Risultato:
/// l'app avrebbe mostrato "Connesso" con il lucchetto verde mentre il
/// traffico continuava a viaggiare in chiaro sulla rete normale. E'
/// esattamente il tipo di falso senso di sicurezza che va evitato a ogni
/// costo in un componente VPN: meglio fallire in modo esplicito e visibile
/// (l'utente vede un errore chiaro in ProviderVPNView) che fingere una
/// protezione che non c'e'.
///
/// Per attivare davvero WireGuard: aggiungere WireGuardKit
/// (https://github.com/WireGuard/wireguard-apple) come dipendenza SPM del
/// target PacketTunnel, poi sostituire il blocco "protocollo non
/// supportato" qui sotto con l'inizializzazione di un WireGuardAdapter
/// reale, leggendo i segreti da Keychain con KeychainHelper.readSecret
/// (mai da providerConfiguration in chiaro: qui arrivano solo i
/// riferimenti alle voci Keychain, per costruzione di ProviderVPNManager).
///
/// IKEv2 non passa da questo file: usa lo stack nativo NEVPNProtocolIKEv2
/// di iOS, gia' cifrato e verificato da Apple, quindi resta pienamente
/// funzionante e sicuro con questo codice.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = OSLog(subsystem: "com.iamgasgass.gassPlayer.PacketTunnel", category: "tunnel")

    private static let encryptedProtocols: Set<String> = []

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let config = proto.providerConfiguration else {
            completionHandler(NEVPNError(.configurationInvalid))
            return
        }

        let protocolName = config["protocol"] as? String ?? "unknown"
        os_log("Richiesta avvio tunnel, protocollo: %{public}@", log: log, protocolName)

        guard Self.encryptedProtocols.contains(protocolName.lowercased()) else {
            os_log("Protocollo %{public}@ non ha una implementazione crittografica in questo target: connessione rifiutata invece di fingere successo", log: log, type: .error, protocolName)
            completionHandler(PacketTunnelError.encryptionNotImplemented(protocolName))
            return
        }

        let tunnelRemoteAddress = proto.serverAddress ?? "0.0.0.0"
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelRemoteAddress)

        let ipv4Settings = NEIPv4Settings(addresses: ["10.10.10.2"], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4Settings

        let dns = config["dns"] as? String ?? "1.1.1.1"
        settings.dnsSettings = NEDNSSettings(servers: [dns])
        settings.mtu = 1400

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                os_log("Errore impostazione network settings: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
                completionHandler(error)
                return
            }
            // Questo punto verra' raggiunto solo per protocolli presenti in
            // encryptedProtocols, cioe' quando la cifratura reale sara'
            // stata integrata: a quel punto qui va avviato l'adapter
            // crittografico (es. WireGuardAdapter.start(...)) e passato il
            // suo completionHandler, non chiamare completionHandler(nil)
            // direttamente come si faceva prima.
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("Tunnel arrestato, motivo: %{public}d", log: log, reason.rawValue)
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        completionHandler?(messageData)
    }
}

enum PacketTunnelError: LocalizedError {
    case encryptionNotImplemented(String)

    var errorDescription: String? {
        switch self {
        case .encryptionNotImplemented(let protocolName):
            return "\(protocolName) non e' ancora cifrato in questa build dell'app: manca la libreria crittografica integrata. Nessun traffico verra' instradato per evitare una falsa sensazione di protezione."
        }
    }
}
