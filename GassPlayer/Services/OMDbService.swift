import Foundation

/// Un singolo voto restituito da OMDb (es. "Rotten Tomatoes" → "87%",
/// "Metacritic" → "52/100", "Internet Movie Database" → "7.5/10").
struct OMDbRating: Decodable {
    let source: String
    let value: String

    enum CodingKeys: String, CodingKey {
        case source = "Source"
        case value = "Value"
    }
}

struct OMDbRatingsResult: Decodable {
    let imdbRating: String?
    let ratings: [OMDbRating]
    let metascore: String?
    let response: String

    enum CodingKeys: String, CodingKey {
        case imdbRating = "imdbRating"
        case ratings = "Ratings"
        case metascore = "Metascore"
        case response = "Response"
    }
}

extension OMDbRatingsResult {
    /// Voto IMDb su base 10 (es. 7.5), `nil` se assente o "N/A".
    var imdbRatingValue: Double? {
        guard let imdbRating, imdbRating != "N/A" else { return nil }
        return Double(imdbRating)
    }

    /// Percentuale "Rotten Tomatoes" (critica), come mostrata nella
    /// sezione "VALUTAZIONI" del video (es. 87 da "87%").
    var rottenTomatoesPercent: Int? {
        guard let value = ratings.first(where: { $0.source == "Rotten Tomatoes" })?.value else {
            return nil
        }
        return Int(value.replacingOccurrences(of: "%", with: ""))
    }

    /// Punteggio Metacritic su base 100 (es. 52 da "52/100").
    var metacriticScore: Int? {
        if let metascore, metascore != "N/A", let value = Int(metascore) {
            return value
        }

        guard let raw = ratings.first(where: { $0.source == "Metacritic" })?.value else {
            return nil
        }

        return Int(raw.split(separator: "/").first ?? "")
    }
}

enum OMDbError: LocalizedError {
    case missingAPIKey
    case notFound
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Nessuna API key OMDb configurata. Aggiungine una gratuita nelle Impostazioni per vedere Rotten Tomatoes, Metacritic e il voto IMDb."
        case .notFound:
            return "Nessuna corrispondenza trovata su OMDb per questo titolo."
        case .network(let error):
            return "Errore di rete OMDb: \(error.localizedDescription)"
        }
    }
}

/// Servizio di arricchimento voti via OMDb (https://www.omdbapi.com),
/// usato per completare la sezione "VALUTAZIONI" con le fonti che TMDB non
/// fornisce (IMDb, Rotten Tomatoes, Metacritic), esattamente come nel video
/// dimostrativo. Richiede una API key personale gratuita, salvata in
/// UserDefaults sotto "omdbAPIKey" (impostabile da Impostazioni). Nessuna
/// chiamata viene fatta se la chiave è assente: degradazione controllata,
/// la sezione valutazioni mostra semplicemente le sole fonti disponibili.
actor OMDbService {
    static let apiKeyDefaultsKey = "omdbAPIKey"
    static let shared = OMDbService()

    private let session: URLSession
    private var cache: [String: OMDbRatingsResult] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated static var hasAPIKey: Bool {
        !(UserDefaults.standard.string(forKey: apiKeyDefaultsKey) ?? "").isEmpty
    }

    /// Valutazioni per un titolo identificato dal suo IMDb id (es.
    /// "tt0117951"), ottenuto in genere da `TMDBDetails.externalIds`.
    func ratings(imdbId: String) async throws -> OMDbRatingsResult {
        guard let apiKey = UserDefaults.standard.string(forKey: Self.apiKeyDefaultsKey), !apiKey.isEmpty else {
            throw OMDbError.missingAPIKey
        }

        if let cached = cache[imdbId] { return cached }

        var components = URLComponents(string: "https://www.omdbapi.com/")!
        components.queryItems = [
            URLQueryItem(name: "i", value: imdbId),
            URLQueryItem(name: "apikey", value: apiKey)
        ]
        guard let url = components.url else { throw OMDbError.notFound }

        do {
            let (data, _) = try await session.data(from: url)
            let decoded = try JSONDecoder().decode(OMDbRatingsResult.self, from: data)

            guard decoded.response.lowercased() == "true" else {
                throw OMDbError.notFound
            }

            cache[imdbId] = decoded
            return decoded
        } catch let error as OMDbError {
            throw error
        } catch {
            throw OMDbError.network(error)
        }
    }
}
