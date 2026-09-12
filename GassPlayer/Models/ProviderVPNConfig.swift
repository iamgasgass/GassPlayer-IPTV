import Foundation

struct ProviderVPNConfig: Codable, Equatable {
    var protocolType: VPNProtocolType
    var serverEndpoint: String
    var serverPublicKey: String?
    var presharedKey: String?
    var allowedIPs: String?
    var dns: String?
    var username: String?
    var password: String?

    enum CodingKeys: String, CodingKey {
        case protocolType = "protocol"
        case serverEndpoint = "endpoint"
        case serverPublicKey = "public_key"
        case presharedKey = "preshared_key"
        case allowedIPs = "allowed_ips"
        case dns, username, password
    }
}
