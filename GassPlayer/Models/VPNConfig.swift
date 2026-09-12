import Foundation

enum VPNProtocolType: String, Codable, CaseIterable {
    case ikev2 = "IKEv2"
    case wireGuard = "WireGuard"
    case openVPN = "OpenVPN"
}
