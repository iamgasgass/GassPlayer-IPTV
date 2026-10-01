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

// MARK: - Dettaglio arricchito (scheda "locandina" con cast, loghi, voti)

struct TMDBGenre: Decodable, Hashable {
    let id: Int
    let name: String
}

struct TMDBCastMember: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let character: String?
    let profilePath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, character
        case profilePath = "profile_path"
    }

    var profileURL: URL? {
        guard let profilePath, !profilePath.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w185\(profilePath)")
    }
}

struct TMDBCredits: Decodable {
    let cast: [TMDBCastMember]
}

struct TMDBImageLogo: Decodable {
    let filePath: String
    let iso6391: String?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case iso6391 = "iso_639_1"
    }
}

struct TMDBImages: Decodable {
    let logos: [TMDBImageLogo]
}

struct TMDBExternalIDs: Decodable {
    let imdbId: String?

    enum CodingKeys: String, CodingKey {
        case imdbId = "imdb_id"
    }
}

/// Dettaglio completo di un titolo (film o serie), ottenuto con una sola
/// richiesta grazie a `append_to_response=credits,images,external_ids`:
/// evita 3-4 chiamate separate per ogni scheda aperta dall'utente.
struct TMDBDetails: Decodable {
    let id: Int
    let overview: String?
    let genres: [TMDBGenre]?
    /// Presente solo per i film.
    let runtime: Int?
    /// Presente solo per le serie (durata media per episodio).
    let episodeRunTime: [Int]?
    let voteAverage: Double?
    let backdropPath: String?
    let posterPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let credits: TMDBCredits?
    let images: TMDBImages?
    let externalIds: TMDBExternalIDs?

    enum CodingKeys: String, CodingKey {
        case id, overview, genres, runtime, credits, images
        case episodeRunTime = "episode_run_time"
        case voteAverage = "vote_average"
        case backdropPath = "backdrop_path"
        case posterPath = "poster_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case externalIds = "external_ids"
    }

    var year: String? {
        let date = releaseDate ?? firstAirDate
        guard let date, date.count >= 4 else { return nil }
        return String(date.prefix(4))
    }

    var runtimeMinutes: Int? {
        runtime ?? episodeRunTime?.first
    }

    var backdropURL: URL? {
        guard let backdropPath, !backdropPath.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w1280\(backdropPath)")
    }

    var posterURL: URL? {
        guard let posterPath, !posterPath.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500\(posterPath)")
    }

    /// Logo del titolo (immagine "wordmark" trasparente, come mostrata
    /// sopra il backdrop nelle schede stile streaming): si preferisce
    /// l'italiano, poi l'inglese, poi il primo logo disponibile in
    /// qualunque lingua (spesso senza testo, es. un simbolo).
    var logoURL: URL? {
        guard let logos = images?.logos, !logos.isEmpty else { return nil }

        let preferred = logos.first { $0.iso6391 == "it" }
            ?? logos.first { $0.iso6391 == "en" }
            ?? logos.first

        guard let filePath = preferred?.filePath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500\(filePath)")
    }

    var genreNames: [String] {
        (genres ?? []).map(\.name)
    }

    func topCast(_ limit: Int = 12) -> [TMDBCastMember] {
        Array((credits?.cast ?? []).prefix(limit))
    }
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
    /// Cache dei dettagli completi (cast/loghi/external id), separata da
    /// quella di `lookup`: stessa vita dell'istanza condivisa, evita di
    /// rifare `append_to_response` ad ogni riapertura della stessa scheda
    /// nella stessa sessione dell'app.
    private var detailsCache: [String: TMDBDetails] = [:]
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

    /// Dettaglio completo per un id TMDB già noto (cast, loghi, external
    /// id IMDb, genere, durata). Una sola richiesta HTTP grazie a
    /// `append_to_response`.
    func details(id: Int, isSeries: Bool) async throws -> TMDBDetails {
        guard let apiKey = UserDefaults.standard.string(forKey: Self.apiKeyDefaultsKey), !apiKey.isEmpty else {
            throw TMDBError.missingAPIKey
        }

        let cacheKey = "\(isSeries ? "tv" : "movie")::\(id)"
        if let cached = detailsCache[cacheKey] { return cached }

        let endpoint = isSeries ? "tv/\(id)" : "movie/\(id)"
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(endpoint)")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "language", value: "it-IT"),
            URLQueryItem(name: "append_to_response", value: "credits,images,external_ids"),
            URLQueryItem(name: "include_image_language", value: "it,en,null")
        ]
        guard let url = components.url else { throw TMDBError.noResults }

        do {
            let (data, _) = try await session.data(from: url)
            let decoded = try JSONDecoder().decode(TMDBDetails.self, from: data)
            detailsCache[cacheKey] = decoded
            return decoded
        } catch let error as TMDBError {
            throw error
        } catch {
            throw TMDBError.network(error)
        }
    }

    /// Scorciatoia usata dalle schede dettaglio: cerca il titolo su TMDB e,
    /// se trovato, ne recupera subito anche il dettaglio completo.
    func fullDetails(title: String, isSeries: Bool) async throws -> TMDBDetails {
        let found = try await lookup(title: title, isSeries: isSeries)
        return try await details(id: found.id, isSeries: isSeries)
    }
}
