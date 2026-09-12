import Foundation

struct XtreamCredentials: Codable, Equatable {
    var host: String
    var username: String
    var password: String
}

extension KeyedDecodingContainer {
    func decodeFlexibleString(forKey key: Key) -> String? {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(Int(value)) }
        if let value = try? decode(Bool.self, forKey: key) { return value ? "1" : "0" }
        return nil
    }

    func decodeFlexibleInt(forKey key: Key) -> Int? {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) { return Int(value) ?? Int(Double(value) ?? .nan) }
        if let value = try? decode(Double.self, forKey: key) { return Int(value) }
        return nil
    }
}

struct XtreamAuthResponse: Codable {
    struct UserInfo: Codable {
        let username: String
        let status: String
        let expDate: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            username = container.decodeFlexibleString(forKey: .username) ?? ""
            status = container.decodeFlexibleString(forKey: .status) ?? "unknown"
            expDate = container.decodeFlexibleString(forKey: .expDate)
        }

        enum CodingKeys: String, CodingKey { case username, status; case expDate = "exp_date" }
    }
    struct ServerInfo: Codable {
        let url: String
        let port: String

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            url = container.decodeFlexibleString(forKey: .url) ?? ""
            port = container.decodeFlexibleString(forKey: .port) ?? "80"
        }
        enum CodingKeys: String, CodingKey { case url, port }
    }
    let userInfo: UserInfo
    let serverInfo: ServerInfo
    enum CodingKeys: String, CodingKey { case userInfo = "user_info"; case serverInfo = "server_info" }
}

struct XtreamCategory: Codable, Identifiable, Hashable {
    let categoryId: String
    let categoryName: String
    var id: String { categoryId }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        categoryId = container.decodeFlexibleString(forKey: .categoryId) ?? UUID().uuidString
        categoryName = container.decodeFlexibleString(forKey: .categoryName) ?? "Senza nome"
    }
    enum CodingKeys: String, CodingKey { case categoryId = "category_id"; case categoryName = "category_name" }
}

struct XtreamStream: Codable, Identifiable, Hashable {
    let streamId: Int
    let name: String
    let streamIcon: String?
    let categoryId: String?
    let containerExtension: String?
    var id: Int { streamId }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streamId = container.decodeFlexibleInt(forKey: .streamId) ?? 0
        name = container.decodeFlexibleString(forKey: .name) ?? "Senza nome"
        streamIcon = container.decodeFlexibleString(forKey: .streamIcon)
        categoryId = container.decodeFlexibleString(forKey: .categoryId)
        containerExtension = container.decodeFlexibleString(forKey: .containerExtension)
    }

    enum CodingKeys: String, CodingKey {
        case streamId = "stream_id", name, categoryId = "category_id"
        case streamIcon = "stream_icon"
        case containerExtension = "container_extension"
    }
}

enum XtreamStreamKind: String, CaseIterable, Identifiable {
    case live, movie, series
    var id: String { rawValue }
    var pathComponent: String {
        switch self { case .live: return "live"; case .movie: return "movie"; case .series: return "series" }
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
        switch self { case .live: return "m3u8"; case .movie, .series: return "mp4" }
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
    case unexpectedResponseShape

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
        case .unexpectedResponseShape:
            return "Il pannello ha risposto con una struttura dati non riconosciuta."
        }
    }
}
