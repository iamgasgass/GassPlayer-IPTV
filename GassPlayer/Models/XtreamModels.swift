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
            case username
            case status
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

    var id: String {
        categoryId
    }

    enum CodingKeys: String, CodingKey {
        case categoryId = "category_id"
        case categoryName = "category_name"
    }

    init(
        categoryId: String,
        categoryName: String
    ) {
        self.categoryId = categoryId
        self.categoryName = categoryName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )

        categoryId = container.decodeFlexibleString(
            forKey: .categoryId
        ) ?? UUID().uuidString

        categoryName = (
            try? container.decode(
                String.self,
                forKey: .categoryName
            )
        ) ?? "Categoria senza nome"
    }
}

struct XtreamStream: Codable, Identifiable, Hashable {
    let streamId: Int
    let name: String
    let streamIcon: String?
    let categoryId: String?
    let containerExtension: String?

    var id: Int {
        streamId
    }

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
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )

        guard let decodedStreamId = container.decodeFlexibleInt(
            forKey: .streamId
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .streamId,
                in: container,
                debugDescription: "stream_id assente o non interpretabile."
            )
        }

        streamId = decodedStreamId

        name = (
            try? container.decode(
                String.self,
                forKey: .name
            )
        ) ?? "Senza nome"

        streamIcon = try? container.decode(
            String.self,
            forKey: .streamIcon
        )

        categoryId = container.decodeFlexibleString(
            forKey: .categoryId
        )

        containerExtension = try? container.decode(
            String.self,
            forKey: .containerExtension
        )
    }
}

enum XtreamStreamKind: String, Codable, CaseIterable, Identifiable {
    case live
    case movie
    case series

    var id: String {
        rawValue
    }

    var pathComponent: String {
        switch self {
        case .live:
            return "live"
        case .movie:
            return "movie"
        case .series:
            return "series"
        }
    }

    var displayName: String {
        switch self {
        case .live:
            return "Live TV"
        case .movie:
            return "Film (VOD)"
        case .series:
            return "Serie TV"
        }
    }

    var title: String {
        switch self {
        case .live:
            return "Canali"
        case .movie:
            return "Film"
        case .series:
            return "Serie"
        }
    }

    var systemImage: String {
        switch self {
        case .live:
            return "tv"
        case .movie:
            return "film"
        case .series:
            return "rectangle.stack.fill"
        }
    }

    var defaultExtension: String {
        switch self {
        case .live:
            return "m3u8"
        case .movie, .series:
            return "mp4"
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
            return "Impossibile costruire l'URL di richiesta."
        case .unreachable:
            return "Il server non risponde. Verifica connessione e host/porta."
        case .timeout:
            return "Il server ha impiegato troppo tempo a rispondere."
        case .httpStatus(let code):
            return "Il server ha risposto con codice HTTP \(code)."
        case .wrongCredentials:
            return "Username o password non corretti."
        case .decoding:
            return "Risposta del server in un formato inatteso."
        case .noProviderVPN:
            return "Questo fornitore non pubblica una configurazione VPN propria."
        }
    }
}
