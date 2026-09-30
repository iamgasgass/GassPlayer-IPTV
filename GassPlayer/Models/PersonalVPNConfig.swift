import Foundation

struct PersonalVPNConfig: Equatable {
    var protocolType: VPNProtocolType
    var serverEndpoint: String
    var serverPublicKey: String?
    var presharedKey: String?
    var allowedIPs: String?
    var dns: String?
    var username: String?
    var password: String?
    var clientPrivateKey: String?
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

    var isValid: Bool {
        guard !serverEndpoint.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch protocolType {
        case .ikev2:
            return true
        case .wireGuard:
            return !(serverPublicKey?.isEmpty ?? true) && !(clientPrivateKey?.isEmpty ?? true)
        case .openVPN:
            return true
        }
    }
}
