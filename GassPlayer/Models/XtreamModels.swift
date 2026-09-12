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
        let maxConnections: String?
        let activeConnections: String?
        enum CodingKeys: String, CodingKey {
            case username, status
            case expDate = "exp_date"
            case maxConnections = "max_connections"
            case activeConnections = "active_cons"
        }
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

struct XtreamStream: Codable, Identifiable, Hashable {
    let streamId: Int
    let name: String
    let streamIcon: String?
    let categoryId: String?
    var id: Int { streamId }
    enum CodingKeys: String, CodingKey {
        case streamId = "stream_id", name, categoryId = "category_id"
        case streamIcon = "stream_icon"
    }
}

enum XtreamStreamKind {
    case live, movie, series
    var pathComponent: String {
        switch self { case .live: return "live"; case .movie: return "movie"; case .series: return "series" }
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
            return "Il server non risponde. Verifica connessione e host/porta (provato anche lo schema alternativo http/https)."
        case .timeout:
            return "Il server ha impiegato troppo tempo a rispondere (timeout)."
        case .httpStatus(let code) where code == 429:
            return "Troppe connessioni simultanee su questo account (\"max connections reached\"). Chiudi altre sessioni attive o aggiorna il piano."
        case .httpStatus(let code):
            return "Il server ha risposto con codice HTTP \(code)."
        case .wrongCredentials:
            return "Username o password non corretti, oppure l'account non è più attivo (scaduto/disabilitato)."
        case .decoding(let underlying):
            return "Risposta del server in un formato inatteso: \(underlying.localizedDescription)"
        case .noProviderVPN:
            return "Questo fornitore non pubblica una configurazione VPN propria."
        }
    }
}
