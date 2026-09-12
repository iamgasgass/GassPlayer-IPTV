import Foundation

struct ProviderVPNConfig: Equatable {
    var protocolType: VPNProtocolType
    var serverEndpoint: String
    var serverPublicKey: String?
    var presharedKey: String?
    var allowedIPs: String?
    var dns: String?
    var username: String?
    var password: String?
    /// Chiave privata WireGuard del CLIENT (non del server). WireGuard non
    /// negozia le chiavi come IKEv2/OpenVPN: il client deve gia' possedere
    /// una keypair il cui pubblico e' stato registrato lato server. Per un
    /// addon VPN di un pannello Xtream, il modo realistico in cui questo
    /// arriva e' che il provider la generi e la includa nella risposta API
    /// (esattamente come un file wg-quick scaricabile), non che la generi
    /// il client. Il nome esatto del campo JSON e' un'assunzione ragionevole
    /// (allineata alle convenzioni piu' comuni), non verificata contro
    /// nessuna API reale: se il tuo provider usa un nome diverso, va
    /// aggiornato in CodingKeys qui sotto.
    var clientPrivateKey: String?
    /// Indirizzo IP assegnato al client dentro la subnet del tunnel
    /// (es. "10.66.66.5/32"). Se il provider non lo fornisce, si usa un
    /// indirizzo di fallback plausibile ma non garantito funzionante.
    var clientAddress: String?

    init(protocolType: VPNProtocolType, serverEndpoint: String, serverPublicKey: String? = nil,
         presharedKey: String? = nil, allowedIPs: String? = nil, dns: String? = nil,
         username: String? = nil, password: String? = nil, clientPrivateKey: String? = nil,
         clientAddress: String? = nil) {
        self.protocolType = protocolType
        self.serverEndpoint = serverEndpoint
        self.serverPublicKey = serverPublicKey
        self.presharedKey = presharedKey
        self.allowedIPs = allowedIPs
        self.dns = dns
        self.username = username
        self.password = password
        self.clientPrivateKey = clientPrivateKey
        self.clientAddress = clientAddress
    }
}

extension ProviderVPNConfig: Decodable {
    enum CodingKeys: String, CodingKey {
        case protocolType = "protocol"
        case serverEndpoint = "endpoint"
        case serverPublicKey = "public_key"
        case presharedKey = "preshared_key"
        case allowedIPs = "allowed_ips"
        case dns, username, password
        case clientPrivateKey = "private_key"
        case clientPrivateKeyAlt = "client_private_key"
        case clientAddress = "address"
        case clientAddressAlt = "client_address"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawProtocol = (try? container.decode(String.self, forKey: .protocolType)) ?? "WireGuard"
        protocolType = VPNProtocolType(looseRawValue: rawProtocol)
        serverEndpoint = try container.decode(String.self, forKey: .serverEndpoint)
        serverPublicKey = try? container.decode(String.self, forKey: .serverPublicKey)
        presharedKey = try? container.decode(String.self, forKey: .presharedKey)
        allowedIPs = try? container.decode(String.self, forKey: .allowedIPs)
        dns = try? container.decode(String.self, forKey: .dns)
        username = try? container.decode(String.self, forKey: .username)
        password = try? container.decode(String.self, forKey: .password)
        clientPrivateKey = (try? container.decode(String.self, forKey: .clientPrivateKey))
            ?? (try? container.decode(String.self, forKey: .clientPrivateKeyAlt))
        clientAddress = (try? container.decode(String.self, forKey: .clientAddress))
            ?? (try? container.decode(String.self, forKey: .clientAddressAlt))
    }
}
