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
    /// Campi usati SOLO dal matching di precisione (titolo originale,
    /// popolarita', numero di voti): non cambiano nulla per i chiamanti.
    let originalTitle: String?
    let originalName: String?
    let popularity: Double?
    let voteCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview, popularity
        case posterPath = "poster_path"
        case voteAverage = "vote_average"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case originalTitle = "original_title"
        case originalName = "original_name"
        case voteCount = "vote_count"
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
    let title: String?
    let name: String?
    let originalTitle: String?
    let originalName: String?
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
        case id, title, name, overview, genres, runtime, credits, images
        case originalTitle = "original_title"
        case originalName = "original_name"
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
    /// deallocano/ricreano scorrendo (didAttemptLookup e' uno @State per
    /// istanza di view, azzerato ad ogni ricomparsa), un titolo senza
    /// corrispondenza su TMDB veniva ri-interrogato in rete ad ogni singolo
    /// passaggio in vista, inutilmente. Ora anche i "nessun risultato" sono
    /// cachati (con un marcatore) cosi' non si ripete la richiesta a vuoto.
    private var noResultCache: Set<String> = []
    /// Cache degli episodi per stagione (chiave "tvId::stagione").
    private var seasonCache: [String: [TMDBEpisode]] = [:]
    /// Cache del risultato finale di `fullDetails` (dopo matching e verifica).
    private var fullDetailsCache: [String: TMDBDetails] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated static var hasAPIKey: Bool {
        !(UserDefaults.standard.string(forKey: apiKeyDefaultsKey) ?? "").isEmpty
    }

    // MARK: - Pulizia titolo e matching di precisione

    /// Titolo del provider scomposto in query pulita + anno (se presente).
    private struct ParsedTitle {
        /// Titolo ripulito da tag di qualita'/lingua/prefissi del provider.
        let query: String
        /// Anno esplicito `(2001)` / `[2001]`: indizio forte.
        let year: String?
        /// Anno "nudo" in coda (`Titolo 2001`): indizio debole, il titolo
        /// resta intatto perche' potrebbe farne parte (es. "1917").
        let trailingYear: String?
    }

    private static let noiseWords = [
        "4K", "UHD", "HD", "FHD", "SD", "HDR", "HDR10", "DV", "ITA", "ENG", "SUB", "SUBITA",
        "DUAL", "MULTI", "BLURAY", "BDRIP", "WEBRIP", "WEB-DL", "WEBDL", "H264", "H265", "HEVC", "X264", "X265"
    ]
    private static let providerPrefixCodes: Set<String> = [
        "IT", "ITA", "EN", "ENG", "FR", "DE", "ES", "UK", "US", "PT", "NL", "TR", "AR",
        "MULTI", "SUB", "VOD", "4K", "UHD", "NF", "AMZN", "DSNP", "SKY", "NOW"
    ]

    /// FIX CRITICO (storico): rimozione dei tag solo come PAROLE intere
    /// (`\b`), mai come sottostringhe — cosi' "Suburbicon", "Vengeance",
    /// "Italian Job", "Multiverse" o "Wednesday" non vengono storpiati.
    ///
    /// Ora estrae anche l'anno dal titolo del provider (indizio fondamentale
    /// per distinguere "Blow" (2001) da "Blow Out" (1981)) e toglie i
    /// prefissi di lingua/provider tipo "IT - ", "|IT|", "[ITA]".
    private func parseTitle(_ rawTitle: String) -> ParsedTitle {
        var working = rawTitle

        // Anno esplicito tra parentesi: prima di rimuovere le parentesi.
        var explicitYear: String?
        if let range = working.range(of: #"[\(\[]\s*((?:19|20)\d{2})\s*[\)\]]"#, options: .regularExpression) {
            let match = String(working[range])
            explicitYear = match.range(of: #"(?:19|20)\d{2}"#, options: .regularExpression).map { String(match[$0]) }
        }

        // Prefissi provider noti: "IT - Titolo", "|IT| Titolo", "[ITA] Titolo".
        let prefixPatterns = [
            #"^\s*[\|\[]\s*([A-Za-z0-9]{2,5})\s*[\|\]]\s*"#,
            #"^\s*([A-Za-z0-9]{2,5})\s+[-–—]\s+"#
        ]
        for pattern in prefixPatterns {
            if let range = working.range(of: pattern, options: .regularExpression) {
                let matched = String(working[range])
                let code = matched.trimmingCharacters(in: CharacterSet(charactersIn: "|[]-–— \t")).uppercased()
                if Self.providerPrefixCodes.contains(code) {
                    working.removeSubrange(range)
                    break
                }
            }
        }

        for pattern in [#"\(.*?\)"#, #"\[.*?\]"#, #"\{.*?\}"#] {
            working = working.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        for word in Self.noiseWords {
            let escaped = NSRegularExpression.escapedPattern(for: word)
            working = working.replacingOccurrences(
                of: "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        working = working
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—|:._")))

        var trailingYear: String?
        if let range = working.range(of: #"\s+((?:19|20)\d{2})$"#, options: .regularExpression) {
            let candidate = String(working[range]).trimmingCharacters(in: .whitespaces)
            // Solo se resta comunque un titolo vero davanti.
            if working[..<range.lowerBound].trimmingCharacters(in: .whitespaces).count >= 2 {
                trailingYear = candidate
            }
        }

        return ParsedTitle(query: working, year: explicitYear, trailingYear: trailingYear)
    }

    /// Normalizzazione per il confronto: minuscolo, senza accenti, solo
    /// lettere/numeri separati da singoli spazi ("Penélope" -> "penelope",
    /// "Spider-Man" -> "spider man").
    private static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        var result = ""
        result.reserveCapacity(folded.count)
        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                result.append(" ")
                lastWasSpace = true
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Somiglianza 0...1 fra due titoli gia' normalizzati: 1 solo se
    /// identici. Per titoli diversi usa il coefficiente di Dice sui token,
    /// quindi "blow" vs "blow out" vale ~0.67 (mai un match pieno).
    private static func titleSimilarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }

        let tokensA = Set(a.split(separator: " ").map(String.init))
        let tokensB = Set(b.split(separator: " ").map(String.init))
        guard !tokensA.isEmpty, !tokensB.isEmpty else { return 0 }

        let common = Double(tokensA.intersection(tokensB).count)
        let dice = 2 * common / Double(tokensA.count + tokensB.count)
        // Mai 1.0 se non identici, cosi' l'uguaglianza esatta vince sempre.
        return min(dice, 0.95)
    }

    private static func yearScore(candidate: String?, hint: String?) -> (score: Double, penalty: Double) {
        guard let hint, let hintValue = Int(hint) else { return (0.5, 0) }
        guard let candidate, let candidateValue = Int(candidate) else { return (0.35, 0) }

        switch abs(candidateValue - hintValue) {
        case 0: return (1, 0)
        case 1: return (0.7, 0)
        default: return (0, 0.2)
        }
    }

    private struct ScoredCandidate {
        let result: TMDBSearchResult
        let titleScore: Double
        let total: Double
    }

    /// Soglia minima di somiglianza del titolo: sotto questa, meglio NESSUN
    /// poster (placeholder Xtream) che il poster di un altro film.
    private static let minimumTitleScore = 0.6
    private static let minimumTotalScore = 0.62
    private static let confidentTotalScore = 0.88

    private func score(_ result: TMDBSearchResult, query: String, yearHint: String?) -> ScoredCandidate {
        let normalizedQuery = Self.normalize(query)
        let names = [result.title, result.name, result.originalTitle, result.originalName]
            .compactMap { $0 }
            .map(Self.normalize)
            .filter { !$0.isEmpty }

        let titleScore = names.map { Self.titleSimilarity(normalizedQuery, $0) }.max() ?? 0
        let year = Self.yearScore(candidate: result.year, hint: yearHint)

        // Peso della "notorieta'": solo spareggio fra omonimi (remake).
        let votes = Double(result.voteCount ?? 0)
        let popularity = min(log10(1 + votes) / 4, 1)

        let total = titleScore * 0.7 + year.score * 0.2 + popularity * 0.1 - year.penalty
        return ScoredCandidate(result: result, titleScore: titleScore, total: total)
    }

    private func search(query: String, isSeries: Bool, year: String?, apiKey: String) async throws -> [TMDBSearchResult] {
        let endpoint = isSeries ? "search/tv" : "search/movie"
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(endpoint)")!
        var items = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "language", value: "it-IT"),
            URLQueryItem(name: "include_adult", value: "false")
        ]
        if let year {
            items.append(URLQueryItem(name: isSeries ? "first_air_date_year" : "year", value: year))
        }
        components.queryItems = items
        guard let url = components.url else { throw TMDBError.noResults }

        do {
            let (data, _) = try await session.data(from: url)
            return try JSONDecoder().decode(TMDBSearchResponse.self, from: data).results
        } catch {
            throw TMDBError.network(error)
        }
    }

    /// Tentativi di ricerca, dal piu' specifico al piu' permissivo.
    private func searchAttempts(for parsed: ParsedTitle, yearOverride: String?) -> [(query: String, year: String?)] {
        let hint = parsed.year ?? yearOverride
        var attempts: [(String, String?)] = []

        if let hint { attempts.append((parsed.query, hint)) }
        attempts.append((parsed.query, nil))

        if let trailing = parsed.trailingYear {
            let withoutYear = parsed.query
                .replacingOccurrences(of: #"\s+(?:19|20)\d{2}$"#, with: "", options: .regularExpression)
            attempts.append((withoutYear, hint ?? trailing))
            attempts.append((withoutYear, nil))
        }

        // Titoli composti ("Titolo: sottotitolo", "Titolo - sottotitolo"):
        // ultimo tentativo sulla sola parte principale.
        for separator in [":", " - "] {
            if let head = parsed.query.components(separatedBy: separator).first,
               head.count >= 3, head != parsed.query {
                attempts.append((head.trimmingCharacters(in: .whitespaces), hint))
            }
        }

        var seen = Set<String>()
        return attempts.filter { seen.insert("\($0.0.lowercased())|\($0.1 ?? "")").inserted }
    }

    /// Candidati ordinati per punteggio (decrescente), gia' filtrati dalle
    /// soglie minime.
    private func rankedCandidates(
        title rawTitle: String,
        isSeries: Bool,
        yearHint: String?,
        apiKey: String
    ) async throws -> [ScoredCandidate] {
        let parsed = parseTitle(rawTitle)
        guard !parsed.query.isEmpty else { throw TMDBError.noResults }

        var pool: [Int: ScoredCandidate] = [:]
        var lastNetworkError: TMDBError?
        var anySuccessfulRequest = false

        for attempt in searchAttempts(for: parsed, yearOverride: yearHint) {
            // Cella uscita dallo schermo: interrompe subito, senza
            // memorizzare un falso "nessun risultato".
            try Task.checkCancellation()

            let results: [TMDBSearchResult]
            do {
                results = try await search(query: attempt.query, isSeries: isSeries, year: attempt.year, apiKey: apiKey)
                anySuccessfulRequest = true
            } catch let error as TMDBError {
                lastNetworkError = error
                continue
            }

            let hint = parsed.year ?? yearHint ?? attempt.year ?? parsed.trailingYear
            for result in results.prefix(10) {
                let scored = score(result, query: attempt.query, yearHint: hint)
                if let existing = pool[result.id], existing.total >= scored.total { continue }
                pool[result.id] = scored
            }

            let best = pool.values.max { $0.total < $1.total }
            if let best, best.titleScore >= 1, best.total >= Self.confidentTotalScore { break }
        }

        try Task.checkCancellation()

        if !anySuccessfulRequest, let lastNetworkError { throw lastNetworkError }

        return pool.values
            .filter { $0.titleScore >= Self.minimumTitleScore && $0.total >= Self.minimumTotalScore }
            .sorted { $0.total > $1.total }
    }

    private func cacheKey(isSeries: Bool, title: String, year: String?) -> String {
        "\(isSeries ? "tv" : "movie")::\(Self.normalize(parseTitle(title).query))::\(year ?? parseTitle(title).year ?? "")"
    }

    /// Ricerca di precisione di un titolo del provider su TMDB. Se non c'e'
    /// una corrispondenza sufficientemente sicura lancia `.noResults`:
    /// mai piu' il primo risultato "a caso" (es. "Blow Out" per "Blow").
    func lookup(title rawTitle: String, isSeries: Bool, year: String? = nil) async throws -> TMDBSearchResult {
        guard let apiKey = UserDefaults.standard.string(forKey: Self.apiKeyDefaultsKey), !apiKey.isEmpty else {
            throw TMDBError.missingAPIKey
        }

        let key = cacheKey(isSeries: isSeries, title: rawTitle, year: year)
        if let cached = cache[key] { return cached }
        if noResultCache.contains(key) { throw TMDBError.noResults }

        let ranked = try await rankedCandidates(title: rawTitle, isSeries: isSeries, yearHint: year, apiKey: apiKey)

        guard let best = ranked.first else {
            noResultCache.insert(key)
            throw TMDBError.noResults
        }

        cache[key] = best.result
        return best.result
    }

    private static func castOverlap(_ names: [String], with credits: [TMDBCastMember]) -> Int {
        let wanted = Set(names.map(normalize).filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return 0 }
        return credits.prefix(15).filter { wanted.contains(normalize($0.name)) }.count
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

    /// Scorciatoia usata dalle schede dettaglio. Ordine di affidabilita':
    /// 1. id TMDB fornito dal pannello Xtream (`tmdb_id`), verificato;
    /// 2. ricerca per titolo + anno con punteggio;
    /// 3. spareggio fra candidati vicini tramite sovrapposizione del cast
    ///    (gli attori del provider, es. Johnny Depp / Penelope Cruz).
    func fullDetails(
        title: String,
        isSeries: Bool,
        year: String? = nil,
        tmdbId: Int? = nil,
        castNames: [String] = []
    ) async throws -> TMDBDetails {
        guard let apiKey = UserDefaults.standard.string(forKey: Self.apiKeyDefaultsKey), !apiKey.isEmpty else {
            throw TMDBError.missingAPIKey
        }

        let key = "full::\(cacheKey(isSeries: isSeries, title: title, year: year))::\(tmdbId ?? 0)"
        if let cached = fullDetailsCache[key] { return cached }

        var providerIdDetails: TMDBDetails?
        if let tmdbId, tmdbId > 0, let byId = try? await details(id: tmdbId, isSeries: isSeries) {
            if isTrustworthy(byId, forTitle: title, castNames: castNames) {
                fullDetailsCache[key] = byId
                return byId
            }
            providerIdDetails = byId
        }

        let ranked: [ScoredCandidate]
        do {
            ranked = try await rankedCandidates(title: title, isSeries: isSeries, yearHint: year, apiKey: apiKey)
        } catch {
            if let providerIdDetails { return providerIdDetails }
            throw error
        }

        guard let best = ranked.first else {
            if let providerIdDetails { return providerIdDetails }
            throw TMDBError.noResults
        }

        var chosen = best
        var chosenDetails: TMDBDetails?

        let nearTies = ranked.filter { best.total - $0.total <= 0.15 }.prefix(3)
        if !castNames.isEmpty, nearTies.count > 1 {
            var bestOverlap = -1
            for candidate in nearTies {
                guard let candidateDetails = try? await details(id: candidate.result.id, isSeries: isSeries) else { continue }
                let overlap = Self.castOverlap(castNames, with: candidateDetails.credits?.cast ?? [])
                if overlap > bestOverlap || (overlap == bestOverlap && candidate.total > chosen.total) {
                    bestOverlap = overlap
                    chosen = candidate
                    chosenDetails = candidateDetails
                }
            }
        }

        let result: TMDBDetails
        if let chosenDetails {
            result = chosenDetails
        } else {
            result = try await details(id: chosen.result.id, isSeries: isSeries)
        }

        cache[cacheKey(isSeries: isSeries, title: title, year: year)] = chosen.result
        fullDetailsCache[key] = result
        return result
    }

    /// L'id del pannello e' attendibile se il titolo coincide abbastanza o
    /// se almeno un attore dichiarato dal provider compare nel cast TMDB.
    private func isTrustworthy(_ details: TMDBDetails, forTitle rawTitle: String, castNames: [String]) -> Bool {
        let query = Self.normalize(parseTitle(rawTitle).query)
        let names = [details.title, details.name, details.originalTitle, details.originalName]
            .compactMap { $0 }
            .map(Self.normalize)
        let similarity = names.map { Self.titleSimilarity(query, $0) }.max() ?? 0

        if similarity >= 0.6 { return true }
        return Self.castOverlap(castNames, with: details.credits?.cast ?? []) > 0
    }
}
