import Foundation

struct TMDBSearchResult: Decodable {
    let id: Int
    let title: String?
    let name: String?
    let overview: String?
    let posterPath: String?
    let voteAverage: Double?
    let releaseDate: String?
    let firstAirDate: String?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview
        case posterPath = "poster_path"
        case voteAverage = "vote_average"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
    }

    var displayTitle: String { title ?? name ?? "" }
    var year: String? {
        let date = releaseDate ?? firstAirDate
        guard let date, date.count >= 4 else { return nil }
        return String(date.prefix(4))
    }
    var posterURL: URL? {
        guard let posterPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w342\(posterPath)")
    }
}

private struct TMDBSearchResponse: Decodable {
    let results: [TMDBSearchResult]
}

enum TMDBError: LocalizedError {
    case missingAPIKey
    case noResults
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Nessuna API key TMDB configurata. Aggiungine una gratuita nelle Impostazioni per vedere poster, trame e valutazioni."
        case .noResults:
            return "Nessuna corrispondenza trovata su TMDB per questo titolo."
        case .network(let error):
            return "Errore di rete TMDB: \(error.localizedDescription)"
        }
    }
}

/// Servizio di arricchimento metadata via TMDB (The Movie Database).
/// Richiede una API key personale gratuita (https://www.themoviedb.org/settings/api),
/// salvata in UserDefaults sotto la chiave "tmdbAPIKey" (impostabile da Settings).
/// Nessuna chiamata viene fatta se la chiave e' assente: degradazione controllata,
/// mai un crash o un blocco della UI principale.
actor TMDBService {
    static let apiKeyDefaultsKey = "tmdbAPIKey"
    /// Istanza condivisa: la cache in-memory dei risultati ha senso solo se
    /// riutilizzata tra tile diverse della stessa griglia, altrimenti ogni
    /// TMDBService() nuovo azzererebbe la cache e rifarebbe le stesse richieste.
    static let shared = TMDBService()

    private let session: URLSession
    private var cache: [String: TMDBSearchResult] = [:]
    /// FIX: le ricerche fallite (nessuna corrispondenza) non venivano mai
    /// memorizzate — solo i successi. Con le celle di LazyVGrid che si
    /// deallocano/ricreano scorrendo (didAttemptLookup e' uno @State per
    /// istanza di view, azzerato ad ogni ricomparsa), un titolo senza
    /// corrispondenza su TMDB veniva ri-interrogato in rete ad ogni singolo
    /// passaggio in vista, inutilmente. Ora anche i "nessun risultato" sono
    /// cachati (con un marcatore) cosi' non si ripete la richiesta a vuoto.
    private var noResultCache: Set<String> = []

    init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated static var hasAPIKey: Bool {
        !(UserDefaults.standard.string(forKey: apiKeyDefaultsKey) ?? "").isEmpty
    }

    /// FIX CRITICO: la versione precedente usava
    /// `replacingOccurrences(of: word, ...)` senza confini di parola, quindi
    /// cercava la SOTTOSTRINGA "HD", "SD", "ITA", "ENG", "SUB", "MULTI" ecc.
    /// ovunque comparisse — anche dentro parole completamente diverse.
    /// Risultato: titoli come "Suburbicon" (contiene "SUB"), "Vengeance"
    /// (contiene "ENG"), "Italian Job" (contiene "ITA"), "Multiverse"
    /// (contiene "MULTI") o "Wednesday" (contiene "SD") venivano storpiati
    /// prima ancora di essere inviati a TMDB, la ricerca falliva o
    /// restituiva un match sbagliato, e la card VOD restava con
    /// l'icona placeholder o un poster errato — esattamente il sintomo "i
    /// VOD non vengono visualizzati tutti correttamente", per un
    /// sottoinsieme di titoli che sembrava casuale ma era deterministico.
    /// Ora si usano confini di parola (\b) per rimuovere solo le
    /// occorrenze isolate (es. "Movie HD 2024" -> "Movie 2024"), lasciando
    /// intatte le parole che le contengono solo come sottostringa.
    private func cleanedQuery(from rawTitle: String) -> String {
        var cleaned = rawTitle
        for pattern in [#"\(.*?\)"#, #"\[.*?\]"#, #"\{.*?\}"#] {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        let noiseWords = ["4K", "HD", "FHD", "SD", "HDR", "ITA", "ENG", "SUB", "DUAL", "MULTI"]
        for word in noiseWords {
            let escaped = NSRegularExpression.escapedPattern(for: word)
            let pattern = "\\b\(escaped)\\b"
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func lookup(title rawTitle: String, isSeries: Bool) async throws -> TMDBSearchResult {
        guard let apiKey = UserDefaults.standard.string(forKey: Self.apiKeyDefaultsKey), !apiKey.isEmpty else {
            throw TMDBError.missingAPIKey
        }
        let query = cleanedQuery(from: rawTitle)
        let cacheKey = "\(isSeries ? "tv" : "movie")::\(query.lowercased())"
        if let cached = cache[cacheKey] { return cached }
        if noResultCache.contains(cacheKey) { throw TMDBError.noResults }

        let endpoint = isSeries ? "search/tv" : "search/movie"
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(endpoint)")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "language", value: "it-IT")
        ]
        guard let url = components.url else { throw TMDBError.noResults }

        do {
            let (data, _) = try await session.data(from: url)
            let decoded = try JSONDecoder().decode(TMDBSearchResponse.self, from: data)
            guard let first = decoded.results.first else {
                noResultCache.insert(cacheKey)
                throw TMDBError.noResults
            }
            cache[cacheKey] = first
            return first
        } catch let error as TMDBError {
            throw error
        } catch {
            throw TMDBError.network(error)
        }
    }
}
