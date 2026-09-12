import Foundation

enum MediaSourceType: String, Codable, CaseIterable, Identifiable {
    case xtream = "Xtream Codes"
    case m3u8 = "M3U / M3U8 Playlist"
    case plex = "Plex"
    case jellyfin = "Jellyfin"
    case emby = "Emby"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .xtream: return "antenna.radiowaves.left.and.right"
        case .m3u8: return "list.bullet.rectangle"
        case .plex: return "play.tv"
        case .jellyfin: return "server.rack"
        case .emby: return "externaldrive.connected.to.line.below"
        }
    }
}

struct MediaSourceConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var type: MediaSourceType
    var host: String
    var username: String?
    var password: String?
    var apiToken: String?
    var isEnabled: Bool = true
    var sortOrder: Int = 0
}
