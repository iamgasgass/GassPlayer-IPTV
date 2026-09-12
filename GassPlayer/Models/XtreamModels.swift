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
        enum CodingKeys: String, CodingKey { case username, status; case expDate = "exp_date" }
    }
    struct ServerInfo: Codable { let url: String; let port: String }
    let userInfo: UserInfo
    let serverInfo: ServerInfo
    enum CodingKeys: String, CodingKey { case userInfo = "user_info"; case serverInfo = "server_info" }
}

struct XtreamCategory: Codable, Identifiable, Hashable {
    let categoryId: String
    let categoryName: String
    var id: String { categoryId }
    enum CodingKeys: String, CodingKey { case categoryId = "category_id"; case categoryName = "category_name" }
}

/// Aggiunto `containerExtension`: Xtream Codes lo restituisce per i
/// contenuti VOD/Serie (es. "mp4", "mkv", "avi") ed e' necessario per
/// costruire l'URL di streaming corretto — prima l'app assumeva sempre
/// "m3u8"/"mp4" fissi, il che rompeva la riproduzione su molti pannelli
/// che servono VOD in mkv/avi.
struct XtreamStream: Codable, Identifiable, Hashable {
    let streamId: Int
    let name: String
    let streamIcon: String?
    let categoryId: String?
    let containerExtension: String?
    var id: Int { streamId }
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
    /// Estensione di default se il pannello non fornisce container_extension.
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
