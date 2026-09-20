import Foundation

// MARK: - Credentials

struct XtreamCredentials: Codable, Equatable {
    var host: String
    var username: String
    var password: String
}

// MARK: - Authentication response

struct XtreamAuthResponse: Codable {
    struct UserInfo: Codable {
        let username: String
        let status: String
        let expDate: String?
        /// Numero di connessioni simultanee attualmente in uso (campo Xtream `active_cons`).
        let activeConnections: String?
        /// Numero massimo di connessioni simultanee consentite (campo Xtream `max_connections`).
        let maxConnections: String?

        enum CodingKeys: String, CodingKey {
            case username
            case status
            case expDate = "exp_date"
            case activeConnections = "active_cons"
            case maxConnections = "max_connections"
        }

        // Init personalizzato: i pannelli Xtream non sono coerenti nel tipo
        // usato per questi campi (a volte stringa, a volte numero), quindi
        // si usa la decodifica "flessibile" già impiegata altrove nel file
        // per evitare che l'intera autenticazione fallisca per un tipo
        // inatteso su un campo puramente informativo.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            username = container.decodeFlexibleString(forKey: .username) ?? ""
            status = container.decodeFlexibleString(forKey: .status) ?? "unknown"
            expDate = container.decodeFlexibleString(forKey: .expDate)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
            activeConnections = container.decodeFlexibleString(forKey: .activeConnections)
            maxConnections = container.decodeFlexibleString(forKey: .maxConnections)
        }
    }

    /// FIX 2026-09-20: prima `ServerInfo` usava la sintetizzazione
    /// automatica di `Decodable` con `url`/`port` come `String` rigide.
    /// Esattamente come `UserInfo` sopra (e per lo stesso identico motivo
    /// documentato nel suo commento), alcuni pannelli Xtream inviano
    /// `port` come numero JSON invece che come stringa: con la
    /// sintetizzazione automatica questo faceva fallire l'INTERA
    /// `XtreamAuthResponse` — bloccando login e la schermata "Gestisci
    /// sorgente" — per un campo che ha senso recuperare in modo tollerante
    /// come già avviene ovunque altrove in questo file.
    struct ServerInfo: Codable {
        let url: String
        let port: String

        enum CodingKeys: String, CodingKey {
            case url
            case port
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            url = container.decodeFlexibleString(forKey: .url) ?? ""
            port = container.decodeFlexibleString(forKey: .port) ?? ""
        }
    }

    let userInfo: UserInfo
    let serverInfo: ServerInfo

    enum CodingKeys: String, CodingKey {
        case userInfo = "user_info"
        case serverInfo = "server_info"
    }
}

// MARK: - Categories

struct XtreamCategory: Identifiable, Hashable {
    let categoryId: String
    let categoryName: String

    var id: String {
        categoryId
    }
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

// MARK: - Live and VOD streams

struct XtreamStream: Identifiable, Hashable {
    let streamId: Int
    let name: String
    let streamIcon: String?
    let categoryId: String?
    let containerExtension: String?

    var id: Int {
        streamId
    }
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

        containerExtension = container.decodeFlexibleString(
            forKey: .containerExtension
        )?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .nonEmpty
    }
}

// MARK: - Stream kind

enum XtreamStreamKind: String, CaseIterable, Identifiable {
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

// MARK: - Errors

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

// MARK: - Flexible decoding

/// Decodifica difensiva per provider Xtream non uniformi.
///
/// Esiste una sola estensione `KeyedDecodingContainer` in questo file e una
/// sola definizione per ogni metodo. Non aggiungere copie generiche con
/// `<K: CodingKey> where K == Key`: dopo la specializzazione sarebbero
/// equivalenti a queste firme e Swift produrrebbe `invalid redeclaration`.
extension KeyedDecodingContainer {
    /// Legge un valore come stringa, tollerando String, Int, Double, Bool o
    /// null. I provider Xtream spesso restituiscono lo stesso campo con tipi
    /// diversi tra endpoint e categorie.
    func decodeFlexibleString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }

        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }

        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value.rounded() == value
                ? String(Int(value))
                : String(value)
        }

        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value ? "1" : "0"
        }

        return nil
    }

    /// Legge un valore come intero, tollerando Int, Double e stringhe
    /// numeriche. Un valore non interpretabile restituisce nil senza
    /// far fallire l'intera decodifica della playlist.
    func decodeFlexibleInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }

        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }

        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let normalized = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            return Int(normalized)
        }

        return nil
    }

    /// Legge un booleano, tollerando Bool, numeri 0/1 e le rappresentazioni
    /// testuali piu' comuni restituite da pannelli Xtream incompatibili.
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
            switch value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            .lowercased() {
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

// MARK: - String utilities

extension String {
    /// Trasforma una stringa vuota in nil; evita URL, categorie e titoli
    /// semanticamente assenti ma tecnicamente non opzionali.
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
