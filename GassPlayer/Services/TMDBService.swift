import Foundation

struct TMDBSearchResult: Codable {
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

// MARK: - Cache sincrona e persistente delle ricerche

/// Cache dei risultati di `lookup`, leggibile in modo SINCRONO dalle celle.
///
/// FIX sfarfallio con chiave TMDB: prima il risultato viveva solo dentro
/// l'actor, raggiungibile solo in modo asincrono. Ogni cella ricreata dalla
/// `LazyVGrid` partiva quindi senza risultato (segnaposto/icona del provider)
/// e solo dopo un giro asincrono passava al poster TMDB: per ogni cella, ad
/// ogni scroll, si vedeva il cambio. Ora la cella legge qui il risultato già
/// noto nel `init` e mostra subito il poster finale. La cache è salvata su
/// disco: dopo un riavvio i poster compaiono senza nuove richieste di rete.
final class TMDBLookupCache: @unchecked Sendable {
    static let shared = TMDBLookupCache()

    private struct Snapshot: Codable {
        var results: [String: TMDBSearchResult] = [:]
        var order: [String] = []
        var misses: [String: Date] = [:]
    }

    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var saveScheduled = false
    private let fileURL: URL
    private let maxResults = 6000
    private let missLifetime: TimeInterval = 3 * 24 * 3600

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = base.appendingPathComponent("GassTMDBLookupCache.json")

        if let data = try? Data(contentsOf: fileURL),
           var decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            let now = Date()
            decoded.misses = decoded.misses.filter { now.timeIntervalSince($0.value) < missLifetime }
            snapshot = decoded
        }
    }

    func result(forKey key: String) -> TMDBSearchResult? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.results[key]
    }

    func isMiss(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let date = snapshot.misses[key] else { return false }
        return Date().timeIntervalSince(date) < missLifetime
    }

    func store(_ result: TMDBSearchResult, forKey key: String) {
        lock.lock()
        if snapshot.results[key] == nil { snapshot.order.append(key) }
        snapshot.results[key] = result
        snapshot.misses[key] = nil
        if snapshot.order.count > maxResults {
            let overflow = snapshot.order.count - maxResults
            for old in snapshot.order.prefix(overflow) { snapshot.results[old] = nil }
            snapshot.order.removeFirst(overflow)
        }
        lock.unlock()
        scheduleSave()
    }

    func storeMiss(forKey key: String) {
        lock.lock()
        snapshot.misses[key] = Date()
        lock.unlock()
        scheduleSave()
    }

    private func scheduleSave() {
        lock.lock()
        if saveScheduled { lock.unlock(); return }
        saveScheduled = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.saveScheduled = false
            let copy = self.snapshot
            self.lock.unlock()
            if let data = try? JSONEncoder().encode(copy) {
                try? data.write(to: self.fileURL, options: .atomic)
            }
        }
    }
}

/// Limita le ricerche TMDB simultanee (il servizio risponde 429 oltre ~40/s).
private actor TMDBRequestLimiter {
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let limit = 4

    func acquire() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let next = waiters.popLast() { next.resume() } else { running -= 1 }
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
    /// Cache degli episodi per stagione (chiave "tvId::stagione").
    private var seasonCache: [String: [TMDBEpisode]] = [:]

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
    private static let bracketRegexes: [NSRegularExpression] = [#"\(.*?\)"#, #"\[.*?\]"#, #"\{.*?\}"#]
        .compactMap { try? NSRegularExpression(pattern: $0) }

    private static let noiseRegexes: [NSRegularExpression] = ["4K", "HD", "FHD", "SD", "HDR", "ITA", "ENG", "SUB", "DUAL", "MULTI"]
        .compactMap { word in
            try? NSRegularExpression(
                pattern: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b",
                options: [.caseInsensitive]
            )
        }

    /// Memo titolo grezzo → query pulita: la pulizia usa regex e viene
    /// richiamata per ogni cella creata, anche solo per leggere la cache.
    private static let cleanedQueryMemo = NSCache<NSString, NSString>()

    private static func strip(_ regex: NSRegularExpression, from text: String) -> String {
        regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
    }

    nonisolated static func cleanedQuery(from rawTitle: String) -> String {
        if let memo = cleanedQueryMemo.object(forKey: rawTitle as NSString) { return memo as String }

        var cleaned = rawTitle
        for regex in bracketRegexes { cleaned = strip(regex, from: cleaned) }
        for regex in noiseRegexes { cleaned = strip(regex, from: cleaned) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        cleanedQueryMemo.setObject(cleaned as NSString, forKey: rawTitle as NSString)
        return cleaned
    }

    nonisolated static func lookupCacheKey(title rawTitle: String, isSeries: Bool) -> String {
        "\(isSeries ? "tv" : "movie")::\(cleanedQuery(from: rawTitle).lowercased())"
    }

    /// Risultato già noto (memoria o disco), senza rete e senza `await`.
    nonisolated static func cachedResult(title: String, isSeries: Bool) -> TMDBSearchResult? {
        TMDBLookupCache.shared.result(forKey: lookupCacheKey(title: title, isSeries: isSeries))
    }

    /// `true` se per questo titolo si sa già che TMDB non ha corrispondenze.
    nonisolated static func isKnownMiss(title: String, isSeries: Bool) -> Bool {
        TMDBLookupCache.shared.isMiss(lookupCacheKey(title: title, isSeries: isSeries))
    }

    private let requestLimiter = TMDBRequestLimiter()
    private var inFlightLookups: [String: Task<TMDBSearchResult, Error>] = [:]

    func lookup(title rawTitle: String, isSeries: Bool) async throws -> TMDBSearchResult {
        guard let apiKey = UserDefaults.standard.string(forKey: Self.apiKeyDefaultsKey), !apiKey.isEmpty else {
            throw TMDBError.missingAPIKey
        }
        let query = Self.cleanedQuery(from: rawTitle)
        let cacheKey = "\(isSeries ? "tv" : "movie")::\(query.lowercased())"

        if let cached = TMDBLookupCache.shared.result(forKey: cacheKey) { return cached }
        if TMDBLookupCache.shared.isMiss(cacheKey) { throw TMDBError.noResults }
        if query.isEmpty { throw TMDBError.noResults }

        // Richieste identiche unificate: una sola chiamata di rete per titolo,
        // anche se molte celle lo chiedono insieme. La richiesta vive in un
        // Task separato: lo scroll (che cancella il chiamante) non la annulla,
        // così il risultato finisce comunque in cache per la prossima volta.
        if let running = inFlightLookups[cacheKey] { return try await running.value }

        let task = Task<TMDBSearchResult, Error> { [self] in
            try await performLookup(query: query, isSeries: isSeries, apiKey: apiKey, cacheKey: cacheKey)
        }
        inFlightLookups[cacheKey] = task
        defer { inFlightLookups[cacheKey] = nil }
        return try await task.value
    }

    private func performLookup(query: String, isSeries: Bool, apiKey: String, cacheKey: String) async throws -> TMDBSearchResult {
        let endpoint = isSeries ? "search/tv" : "search/movie"
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(endpoint)")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "language", value: "it-IT")
        ]
        guard let url = components.url else { throw TMDBError.noResults }

        await requestLimiter.acquire()
        defer { Task { await requestLimiter.release() } }

        var lastError: Error = TMDBError.noResults
        for attempt in 0..<3 {
            do {
                let (data, response) = try await session.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200

                if status == 429 || status >= 500 {
                    // Troppe richieste / errore temporaneo: attesa e nuovo tentativo.
                    let retryAfter = (response as? HTTPURLResponse)?
                        .value(forHTTPHeaderField: "Retry-After")
                        .flatMap(Double.init) ?? Double(attempt + 1)
                    lastError = TMDBError.network(URLError(.resourceUnavailable))
                    try await Task.sleep(nanoseconds: UInt64(min(max(retryAfter, 0.5), 5) * 1_000_000_000))
                    continue
                }

                let decoded = try JSONDecoder().decode(TMDBSearchResponse.self, from: data)
                guard let first = decoded.results.first else {
                    TMDBLookupCache.shared.storeMiss(forKey: cacheKey)
                    throw TMDBError.noResults
                }
                TMDBLookupCache.shared.store(first, forKey: cacheKey)
                return first
            } catch let error as TMDBError {
                throw error
            } catch {
                lastError = TMDBError.network(error)
                if attempt < 2 { try? await Task.sleep(nanoseconds: 600_000_000) }
            }
        }
        throw lastError
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
