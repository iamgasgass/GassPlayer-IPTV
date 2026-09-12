import Foundation

struct M3UChannel: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let logoURL: String?
    let groupTitle: String?
    let tvgId: String?
    let catchupDays: Int?
    let streamURL: URL
}
