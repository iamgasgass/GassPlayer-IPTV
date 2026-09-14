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
    /// Aggiunta ai preferiti: le sorgenti fissate vengono mostrate in cima all'elenco.
    var isPinned: Bool = false
    /// Data dell'ultima verifica di connessione riuscita o fallita.
    var lastVerifiedAt: Date?
    /// Esito dell'ultima verifica di connessione ("Verifica" nella lista sorgenti).
    var lastVerificationSucceeded: Bool?
    /// Numero di canali live rilevati durante l'ultima verifica (solo Xtream).
    var lastKnownChannelCount: Int?

    init(
        id: UUID = UUID(),
        name: String,
        type: MediaSourceType,
        host: String,
        username: String? = nil,
        password: String? = nil,
        apiToken: String? = nil,
        isEnabled: Bool = true,
        sortOrder: Int = 0,
        isPinned: Bool = false,
        lastVerifiedAt: Date? = nil,
        lastVerificationSucceeded: Bool? = nil,
        lastKnownChannelCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.host = host
        self.username = username
        self.password = password
        self.apiToken = apiToken
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
        self.isPinned = isPinned
        self.lastVerifiedAt = lastVerifiedAt
        self.lastVerificationSucceeded = lastVerificationSucceeded
        self.lastKnownChannelCount = lastKnownChannelCount
    }

    // Init manuale così le sorgenti salvate prima dell'introduzione dei nuovi
    // campi (isPinned, lastVerifiedAt, ...) continuano a decodificarsi senza
    // perdere i dati già persistiti su disco.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(MediaSourceType.self, forKey: .type)
        host = try container.decode(String.self, forKey: .host)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        password = try container.decodeIfPresent(String.self, forKey: .password)
        apiToken = try container.decodeIfPresent(String.self, forKey: .apiToken)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        lastVerifiedAt = try container.decodeIfPresent(Date.self, forKey: .lastVerifiedAt)
        lastVerificationSucceeded = try container.decodeIfPresent(Bool.self, forKey: .lastVerificationSucceeded)
        lastKnownChannelCount = try container.decodeIfPresent(Int.self, forKey: .lastKnownChannelCount)
    }
}
