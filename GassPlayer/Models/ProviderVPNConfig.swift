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

    init(protocolType: VPNProtocolType, serverEndpoint: String, serverPublicKey: String? = nil,
         presharedKey: String? = nil, allowedIPs: String? = nil, dns: String? = nil,
         username: String? = nil, password: String? = nil) {
        self.protocolType = protocolType
        self.serverEndpoint = serverEndpoint
        self.serverPublicKey = serverPublicKey
        self.presharedKey = presharedKey
        self.allowedIPs = allowedIPs
        self.dns = dns
        self.username = username
        self.password = password
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
    }
}
