import NetworkExtension
import os.log

/// Scheletro reale di Packet Tunnel Provider per il tunnel VPN.
///
/// QUESTO E' IL PEZZO CHE MANCAVA DAVVERO: finora `ProviderVPNManager`
/// impostava `providerBundleIdentifier` puntando a un target che non
/// esisteva nel progetto. Senza un target Network Extension reale con
/// una classe che eredita da `NEPacketTunnelProvider`, iOS non ha nulla
/// da avviare quando chiami `startVPNTunnel()`: la chiamata fallisce con
/// `NEVPNError.configurationInvalid` o resta bloccata su "Connecting...".
///
/// Questo file fornisce la struttura corretta (lifecycle, gestione
/// configurazione, tunnel settings IPv4/DNS). La parte che NON e'
/// implementabile da zero in modo responsabile e' la crittografia del
/// protocollo VPN stesso (WireGuard/IKEv2/OpenVPN): quella richiede una
/// libreria dedicata already-audited, tipicamente WireGuardKit
/// (https://github.com/WireGuard/wireguard-apple) aggiunta via Swift
/// Package Manager al target `PacketTunnel`. Implementare un protocollo
/// crittografico VPN a mano, senza audit di sicurezza, sarebbe irresponsabile
/// e piu' pericoloso che utile.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = OSLog(subsystem: "com.iamgasgass.gassPlayer.PacketTunnel", category: "tunnel")

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let config = proto.providerConfiguration else {
            completionHandler(NEVPNError(.configurationInvalid))
            return
        }

        let protocolName = config["protocol"] as? String ?? "unknown"
        os_log("Avvio tunnel con protocollo: %{public}@", log: log, protocolName)

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
                os_log("Errore impostazione network settings: %{public}@", log: self?.log ?? .default, error.localizedDescription)
                completionHandler(error)
                return
            }
            // TODO: qui va inizializzato il tunnel crittografico reale.
            // Esempio con WireGuardKit (dopo averlo aggiunto come dipendenza SPM):
            //
            //   let wireGuardAdapter = WireGuardAdapter(with: self, logHandler: ...)
            //   wireGuardAdapter.start(tunnelConfiguration: ..., completionHandler: completionHandler)
            //
            // Senza questa parte il tunnel instrada il traffico verso
            // un'interfaccia virtuale che pero' non cifra/decifra nulla:
            // NON usare questo scheletro in produzione senza completarlo.
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
