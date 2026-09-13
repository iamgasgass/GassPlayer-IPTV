import Foundation

struct XtreamCredentials: Codable, Equatable {
    var host: String
    var username: String
    var password: String
}

struct XtreamAuthResponse: Codable {
    struct UserInfo: Codable {
        let username: String
        let status: String
        let expDate: String?

        enum CodingKeys: String, CodingKey {
            case username, status
            case expDate = "exp_date"
        }
    }

    struct ServerInfo: Codable {
        let url: String
        let port: String
    }

    let userInfo: UserInfo
    let serverInfo: ServerInfo

    enum CodingKeys: String, CodingKey {
        case userInfo = "user_info"
        case serverInfo = "server_info"
    }
}

struct XtreamCategory: Codable, Identifiable, Hashable {
    let categoryId: String
    let categoryName: String

    var id: String { categoryId }

    enum CodingKeys: String, CodingKey {
        case categoryId = "category_id"
        case categoryName = "category_name"
    }

    init(categoryId: String, categoryName: String) {
        self.categoryId = categoryId
        self.categoryName = categoryName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        categoryId = container.decodeFlexibleString(forKey: .categoryId) ?? UUID().uuidString
        categoryName = (try? container.decode(String.self, forKey: .categoryName)) ?? "Categoria senza nome"
    }
}

struct XtreamStream: Codable, Identifiable, Hashable {
    let streamId: Int
    let name: String
    let streamIcon: String?
    let categoryId: String?
    let containerExtension: String?

    var id: Int { streamId }

    enum CodingKeys: String, CodingKey {
        case streamId = "stream_id"
        case name
        case streamIcon = "stream_icon"
        case categoryId = "category_id"
        case containerExtension = "container_extension"
    }

    init(
        streamId: Int,
        name: String,
        streamIcon: String? = nil,
        categoryId: String? = nil,
        containerExtension: String? = nil
    ) {
        self.streamId = streamId
        self.name = name
        self.streamIcon = streamIcon
        self.categoryId = categoryId
        self.containerExtension = containerExtension
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let decodedStreamId = container.decodeFlexibleInt(forKey: .streamId) else {
            throw DecodingError.dataCorruptedError(
                forKey: .streamId,
                in: container,
                debugDescription: "stream_id assente o non interpretabile: la voce non e' riproducibile e viene scartata"
            )
        }
        streamId = decodedStreamId
        name = (try? container.decode(String.self, forKey: .name)) ?? "Senza nome"
        streamIcon = try? container.decode(String.self, forKey: .streamIcon)
        categoryId = container.decodeFlexibleString(forKey: .categoryId)
        containerExtension = try? container.decode(String.self, forKey: .containerExtension)
    }
}

enum XtreamStreamKind: String, Codable, CaseIterable, Identifiable {
    case live
    case movie
    case series

    var id: String { rawValue }

    var pathComponent: String {
        switch self {
        case .live: return "live"
        case .movie: return "movie"
        case .series: return "series"
        }
    }

    var displayName: String {
        switch self {
        case .live: return "Live TV"
        case .movie: return "Film (VOD)"
        case .series: return "Serie TV"
        }
    }

    var systemImage: String {
        switch self {
        case .live: return "tv"
        case .movie: return "film"
        case .series: return "rectangle.stack.fill"
        }
    }

    var defaultExtension: String {
        switch self {
        case .live: return "m3u8"
        case .movie, .series: return "mp4"
        }
    }
}

enum XtreamError: LocalizedError {
    case malformedHost(String)
    case invalidURL
    case unreachable(underlying: Error)
    case timeout
    case httpStatus(Int)
    case wrongCredentials
    case decoding(Error)
    case noProviderVPN

    var errorDescription: String? {
        switch self {
        case .malformedHost(let host):
            return "L'host \"\(host)\" non è un URL valido. Usa il formato http://dominio-o-ip:porta."
        case .invalidURL:
            return "Impossibile costruire l'URL di richiesta. Controlla host, username e password."
        case .unreachable:
            return "Il server non risponde. Verifica connessione e host/porta."
        case .timeout:
            return "Il server ha impiegato troppo tempo a rispondere (timeout)."
        case .httpStatus(let code):
            return "Il server ha risposto con codice HTTP \(code)."
        case .wrongCredentials:
            return "Username o password non corretti per questo server."
        case .decoding:
            return "Risposta del server in un formato inatteso."
        case .noProviderVPN:
            return "Questo fornitore non pubblica una configurazione VPN propria."
        }
    }
}

struct XtreamSeriesItem: Codable, Identifiable, Hashable {
    let seriesId: Int
    let name: String
    let cover: String?
    let categoryId: String?

    var id: Int { seriesId }

    enum CodingKeys: String, CodingKey {
        case seriesId = "series_id"
        case name
        case cover
        case categoryId = "category_id"
    }

    init(seriesId: Int, name: String, cover: String? = nil, categoryId: String? = nil) {
        self.seriesId = seriesId
        self.name = name
        self.cover = cover
        self.categoryId = categoryId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seriesId = container.decodeFlexibleInt(forKey: .seriesId) ?? 0
        name = (try? container.decode(String.self, forKey: .name)) ?? "Serie senza nome"
        cover = try? container.decode(String.self, forKey: .cover)
        categoryId = container.decodeFlexibleString(forKey: .categoryId)
    }
}

struct XtreamSeriesInfo: Decodable {
    struct Episode: Identifiable, Hashable {
        let id: String
        let episodeNum: Int
        let title: String
        let containerExtension: String?

        var streamId: Int { Int(id) ?? 0 }
    }

    let episodes: [String: [Episode]]

    var sortedSeasonNumbers: [Int] {
        episodes.keys.compactMap(Int.init).sorted()
    }

    func episodes(forSeason season: Int) -> [Episode] {
        (episodes[String(season)] ?? []).sorted { $0.episodeNum < $1.episodeNum }
    }
}

extension XtreamSeriesInfo.Episode: Decodable {
    enum CodingKeys: String, CodingKey {
        case id
        case title
        case episodeNum = "episode_num"
        case containerExtension = "container_extension"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeFlexibleString(forKey: .id) ?? UUID().uuidString
        episodeNum = container.decodeFlexibleInt(forKey: .episodeNum) ?? 0
        title = (try? container.decode(String.self, forKey: .title)) ?? "Episodio senza titolo"
        containerExtension = try? container.decode(String.self, forKey: .containerExtension)
    }
}
