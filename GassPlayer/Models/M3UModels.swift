import Foundation

struct M3UChannel: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let logoURL: String?
    let groupTitle: String?
    let tvgId: String?
    let streamURL: URL
    let kind: XtreamStreamKind

    static func == (l: M3UChannel, r: M3UChannel) -> Bool { l.id == r.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
