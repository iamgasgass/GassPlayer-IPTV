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

struct XtreamCategory: Identifiable, Hashable {
    let categoryId: String
    let categoryName: String

    var id: String { categoryId }
}

extension XtreamCategory: Decodable {
    enum CodingKeys: String, CodingKey {
        case categoryId = "category_id"
        case categoryName = "category_name"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        categoryId = container.decodeFlexibleString(forKey: .categoryId)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
            ?? UUID().uuidString

        categoryName = container.decodeFlexibleString(forKey: .categoryName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
            ?? "Categoria senza nome"
    }
}

struct XtreamStream: Identifiable, Hashable {
    let streamId: Int
    let name: String
    let streamIcon: String?
    let categoryId: String?
    let containerExtension: String?

    var id: Int { streamId }
}

extension XtreamStream: Decodable {
    enum CodingKeys: String, CodingKey {
        case streamId = "stream_id"
        case name
        case categoryId = "category_id"
        case streamIcon = "stream_icon"
        case containerExtension = "container_extension"
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

        name = container.decodeFlexibleString(forKey: .name)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
            ?? "Senza nome"

        streamIcon = container.decodeFlexibleString(forKey: .streamIcon)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty

        categoryId = container.decodeFlexibleString(forKey: .categoryId)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty

        containerExtension = container.decodeFlexibleString(forKey: .containerExtension)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nonEmpty
    }
}

enum XtreamStreamKind: String, CaseIterable, Identifiable {
    case live, movie, series

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

// MARK: - Flexible decoding helpers

extension KeyedDecodingContainer {
    /// Decodifica una stringa tollerando provider Xtream che restituiscono
    /// lo stesso campo come String, Int, Double, Bool o null. Le firme usano
    /// direttamente `Key` (tipo associato del container) e sono quindi
    /// compatibili con Swift 6: nessun parametro generico ridondante o
    /// shadowing di `Key`.
    func decodeFlexibleString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }

        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }

        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value.rounded() == value ? String(Int(value)) : String(value)
        }

        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value ? "1" : "0"
        }

        return nil
    }

    /// Decodifica un intero tollerando numeri JSON, double e stringhe
    /// numeriche. Un valore non interpretabile restituisce nil anziche'
    /// provocare un errore dell'intera risposta catalogo.
    func decodeFlexibleInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }

        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }

        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return nil
    }

    /// Decodifica booleani da bool nativo, 0/1 numerici o le rappresentazioni
    /// stringa comuni pubblicate da provider Xtream non uniformi.
    func decodeFlexibleBool(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }

        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }

        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value != 0
        }

        if let value = try? decodeIfPresent(String.self, forKey: key) {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "y":
                return true
            case "0", "false", "no", "n", "":
                return false
            default:
                return nil
            }
        }

        return nil
    }
}

extension String {
    /// Converte stringhe vuote in nil per non propagare URL, categorie o
    /// titoli semanticamente assenti come stringhe non opzionali vuote.
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
