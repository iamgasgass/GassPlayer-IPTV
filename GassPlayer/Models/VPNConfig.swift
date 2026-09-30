import Foundation

enum VPNProtocolType: String, Codable, CaseIterable {
    case ikev2 = "IKEv2"
    case wireGuard = "WireGuard"
    case openVPN = "OpenVPN"

    init(looseRawValue raw: String) {
        let normalized = raw.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        switch normalized {
        case "wireguard": self = .wireGuard
        case "openvpn": self = .openVPN
        case "ikev2", "ipsec", "ike", "ikev2ipsec": self = .ikev2
        default: self = .wireGuard
        }
    }
}
