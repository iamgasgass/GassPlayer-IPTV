import Foundation

/// Formato di export/import per il backup delle sorgenti configurate.
/// Non include mai password o token in chiaro su disco esterno alla UI:
/// il payload viene generato solo su richiesta esplicita dell'utente
/// tramite lo ShareLink di sistema, mai salvato automaticamente.
enum SourceBackupCodec {
    struct Payload: Codable {
        let version: Int
        let exportedAt: Date
        let sources: [MediaSourceConfig]
    }

    enum CodecError: LocalizedError {
        case invalidText

        var errorDescription: String? {
            switch self {
            case .invalidText:
                return "Il testo del backup non e' in un formato UTF-8 valido."
            }
        }
    }

    static func encode(_ sources: [MediaSourceConfig]) throws -> Data {
        let payload = Payload(version: 1, exportedAt: Date(), sources: sources)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    static func encodeAsString(_ sources: [MediaSourceConfig]) throws -> String {
        let data = try encode(sources)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CodecError.invalidText
        }
        return string
    }

    static func decode(_ data: Data) throws -> [MediaSourceConfig] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Payload.self, from: data).sources
    }

    static func decode(fromString string: String) throws -> [MediaSourceConfig] {
        guard let data = string.data(using: .utf8) else {
            throw CodecError.invalidText
        }
        return try decode(data)
    }
}
