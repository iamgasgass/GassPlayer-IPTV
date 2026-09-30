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

/// Episodio di una stagione (`tv/{id}/season/{n}`): fonte di riserva per
/// trama, immagine e data quando il provider Xtream non le fornisce.
struct TMDBEpisode: Decodable, Hashable {
    let episodeNumber: Int
    let name: String?
    let overview: String?
    let stillPath: String?
    let airDate: String?

    enum CodingKeys: String, CodingKey {
        case name, overview
        case episodeNumber = "episode_number"
        case stillPath = "still_path"
        case airDate = "air_date"
    }

    var stillURL: URL? {
        guard let stillPath, !stillPath.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500\(stillPath)")
    }
}

private struct TMDBSeasonResponse: Decodable {
    let episodes: [TMDBEpisode]
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
    /// deallocano/ricreano scorrendo, un titolo senza
    /// corrispondenza su TMDB veniva ri-interrogato in rete ad ogni singolo
    /// passaggio in vista, inutilmente. Ora anche i "nessun risultato" sono
    /// cachati (con un marcatore) cosi' non si ripete la richiesta a vuoto.
    private var noResultCache: Set<String> = []
    /// Deduplica delle ricerche simultanee: durante l'apertura/scroll di una
    /// griglia lo stesso titolo puo' entrare in piu' istanze di cella.
    /// Tutte aspettano una sola richiesta HTTP.
    private var lookupInFlight: [String: Task<TMDBSearchResult, Error>] = [:]
    /// Cache degli episodi per stagione (chiave "tvId::stagione").
    private var seasonCache: [String: [TMDBEpisode]] = [:]

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.requestCachePolicy = .returnCacheDataElseLoad
            configuration.urlCache = URLCache(
                memoryCapacity: 8 * 1024 * 1024,
                diskCapacity: 32 * 1024 * 1024,
                diskPath: "gassplayer.tmdb"
            )
            configuration.httpMaximumConnectionsPerHost = 6
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 20
            self.session = URLSession(configuration: configuration)
        }
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

        if let task = lookupInFlight[cacheKey] {
            return try await task.value
        }

        let endpoint = isSeries ? "search/tv" : "search/movie"
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(endpoint)")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "language", value: "it-IT")
        ]
        guard let url = components.url else { throw TMDBError.noResults }

        let session = session
        let task = Task<TMDBSearchResult, Error> {
            do {
                let (data, response) = try await session.data(from: url)

                if let http = response as? HTTPURLResponse,
                   !(200...299).contains(http.statusCode) {
                    throw TMDBError.network(URLError(.badServerResponse))
                }

                let decoded = try JSONDecoder().decode(TMDBSearchResponse.self, from: data)
                guard !decoded.results.isEmpty else {
                    throw TMDBError.noResults
                }

                // Preferisce una corrispondenza esatta e, a parita', un
                // risultato che abbia davvero una locandina. Questo evita che
                // il primo risultato TMDB senza `poster_path` lasci la card
                // con il solo fallback Xtream quando una corrispondenza utile
                // e' gia' presente nella stessa risposta.
                let normalizedQuery = query
                    .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let best = decoded.results.enumerated().max { lhs, rhs in
                    func score(_ result: TMDBSearchResult, index: Int) -> Int {
                        let normalizedTitle = result.displayTitle
                            .folding(
                                options: [.diacriticInsensitive, .caseInsensitive],
                                locale: .current
                            )
                            .trimmingCharacters(in: .whitespacesAndNewlines)

                        var value = 0
                        if normalizedTitle == normalizedQuery {
                            value += 100
                        }
                        if result.posterPath != nil {
                            value += 20
                        }
                        if (result.voteAverage ?? 0) > 0 {
                            value += 1
                        }
                        return value - index
                    }

                    return score(lhs.element, index: lhs.offset)
                        < score(rhs.element, index: rhs.offset)
                }!.element

                return best
            } catch let error as TMDBError {
                throw error
            } catch {
                throw TMDBError.network(error)
            }
        }

        lookupInFlight[cacheKey] = task

        do {
            let result = try await task.value
            cache[cacheKey] = result
            lookupInFlight[cacheKey] = nil
            return result
        } catch {
            lookupInFlight[cacheKey] = nil

            if case TMDBError.noResults = error {
                noResultCache.insert(cacheKey)
            }

            throw error
        }
    }

    /// Precarica i metadata per le prime card della sezione senza bloccare
    /// il rendering. Le richieste sono limitate a piccoli batch e condividono
    /// la stessa cache/in-flight map di `lookup`, quindi le card che entrano
    /// subito nella viewport non generano una seconda richiesta.
    func prefetch(
        titles: [(title: String, isSeries: Bool)],
        limit: Int = 72
    ) async {
        let items = Array(titles.prefix(limit))

        for start in stride(from: 0, to: items.count, by: 6) {
            guard !Task.isCancelled else { return }

            let end = min(start + 6, items.count)
            let batch = Array(items[start..<end])

            var results: [TMDBSearchResult] = []
            results.reserveCapacity(batch.count)

            await withTaskGroup(of: TMDBSearchResult?.self) { group in
                for item in batch {
                    group.addTask { [self] in
                        try? await self.lookup(
                            title: item.title,
                            isSeries: item.isSeries
                        )
                    }
                }

                for await result in group {
                    if let result {
                        results.append(result)
                    }
                }
            }

            let posterURLs = results.compactMap(\.posterURL)
            if !posterURLs.isEmpty {
                await RemoteImagePipeline.shared.prefetch(
                    posterURLs,
                    maxPixelSize: 480
                )
            }
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

    /// Episodi di una stagione con trama (`overview`), immagine e data.
    /// Le trame mancanti in italiano vengono completate con la versione
    /// inglese (TMDB lascia spesso vuoto `overview` in it-IT), così ogni
    /// episodio ha una descrizione quando ne esiste una in qualunque lingua.
    func seasonEpisodes(tvId: Int, season: Int) async throws -> [TMDBEpisode] {
        guard let apiKey = UserDefaults.standard.string(forKey: Self.apiKeyDefaultsKey), !apiKey.isEmpty else {
            throw TMDBError.missingAPIKey
        }

        let cacheKey = "\(tvId)::\(season)"
        if let cached = seasonCache[cacheKey] { return cached }

        func fetch(language: String) async throws -> [TMDBEpisode] {
            var components = URLComponents(string: "https://api.themoviedb.org/3/tv/\(tvId)/season/\(season)")!
            components.queryItems = [
                URLQueryItem(name: "api_key", value: apiKey),
                URLQueryItem(name: "language", value: language)
            ]
            guard let url = components.url else { throw TMDBError.noResults }
            let (data, _) = try await session.data(from: url)
            return try JSONDecoder().decode(TMDBSeasonResponse.self, from: data).episodes
        }

        do {
            var episodes = try await fetch(language: "it-IT")

            if episodes.contains(where: { ($0.overview ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
               let english = try? await fetch(language: "en-US") {
                let englishByNumber = Dictionary(
                    english.map { ($0.episodeNumber, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                episodes = episodes.map { episode in
                    guard (episode.overview ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let fallback = englishByNumber[episode.episodeNumber],
                          let overview = fallback.overview,
                          !overview.isEmpty else { return episode }
                    return TMDBEpisode(
                        episodeNumber: episode.episodeNumber,
                        name: episode.name,
                        overview: overview,
                        stillPath: episode.stillPath ?? fallback.stillPath,
                        airDate: episode.airDate ?? fallback.airDate
                    )
                }
            }

            seasonCache[cacheKey] = episodes
            return episodes
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
