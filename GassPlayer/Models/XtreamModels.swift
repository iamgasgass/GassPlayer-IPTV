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

/// Errori granulari: prima c'era un solo caso generico che produceva
/// sempre lo stesso messaggio "Credenziali non valide o server non
/// raggiungibile" indipendentemente dalla causa reale.
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
            return "L'host \"\(host)\" non è un URL valido. Usa il formato http://dominio-o-ip:porta, senza percorsi o caratteri finali extra."
        case .invalidURL:
            return "Impossibile costruire l'URL di richiesta. Controlla host, username e password."
        case .unreachable:
            return "Il server non risponde. Verifica di essere connesso a internet e che l'host/porta siano corretti."
        case .timeout:
            return "Il server ha impiegato troppo tempo a rispondere (timeout). Riprova o verifica lo stato del servizio."
        case .httpStatus(let code):
            return "Il server ha risposto con codice HTTP \(code). Se è 401/403 le credenziali sono probabilmente errate."
        case .wrongCredentials:
            return "Username o password non corretti per questo server."
        case .decoding:
            return "Risposta del server in un formato inatteso: potrebbe non essere un pannello Xtream Codes standard."
        case .noProviderVPN:
            return "Questo fornitore non pubblica una configurazione VPN propria."
        }
    }
}
