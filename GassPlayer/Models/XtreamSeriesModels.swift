import Foundation

struct XtreamSeriesItem: Identifiable, Hashable {
    let seriesId: Int
    let name: String
    let cover: String?
    let categoryId: String?
    var id: Int { seriesId }
}

extension XtreamSeriesItem: Decodable {
    enum CodingKeys: String, CodingKey {
        case seriesId = "series_id", name, cover
        case categoryId = "category_id"
    }

    /// FIX 2026-09-20: `name` e `cover` usavano `try? container.decode(String.self, forKey:)`,
    /// che a differenza di `decodeFlexibleString` NON tollera numeri o
    /// booleani. Una serie il cui titolo arriva come numero JSON (es. una
    /// serie chiamata "1923" inviata come `1923` invece che `"1923"" — non
    /// raro con provider Xtream poco uniformi, lo stesso identico problema
    /// già gestito ovunque altrove in `XtreamModels.swift`) diventava
    /// silenziosamente "Serie senza nome" invece di essere recuperata
    /// correttamente. Ora entrambi i campi usano la decodifica flessibile
    /// già disponibile, coerente con `XtreamStream`/`XtreamCategory`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        seriesId = container.decodeFlexibleInt(forKey: .seriesId) ?? 0

        name = container.decodeFlexibleString(forKey: .name)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
            ?? "Serie senza nome"

        cover = container.decodeFlexibleString(forKey: .cover)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty

        categoryId = container.decodeFlexibleString(forKey: .categoryId)
    }
}

/// Dettaglio completo di una serie (`get_series_info`): oltre alla mappa
/// stagione→episodi (già presente prima), ora include anche `info` (trama,
/// cast, genere, backdrop, rating a livello di serie — la stessa forma
/// dati di `get_vod_info` per i film) e `seasons` (titolo/overview/
/// copertina per singola stagione, quando il provider li fornisce). Ogni
/// episodio porta con sé anche la propria `info` (trama e immagine di
/// anteprima), usata nella lista episodi della scheda dettaglio.
struct XtreamSeriesInfo: Decodable {
    struct SeriesDetails: Decodable {
        let name: String?
        let cover: String?
        let plot: String?
        let cast: String?
        let director: String?
        let genre: String?
        let releaseDate: String?
        let rating: String?
        let backdropPath: [String]?
        let youtubeTrailer: String?

        enum CodingKeys: String, CodingKey {
            case name, cover, plot, cast, director, genre, rating
            case releaseDate = "releaseDate"
            case backdropPath = "backdrop_path"
            case youtubeTrailer = "youtube_trailer"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            name = container.decodeFlexibleString(forKey: .name)?.nonEmpty
            cover = container.decodeFlexibleString(forKey: .cover)?.nonEmpty
            plot = container.decodeFlexibleString(forKey: .plot)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
            cast = container.decodeFlexibleString(forKey: .cast)?.nonEmpty
            director = container.decodeFlexibleString(forKey: .director)?.nonEmpty
            genre = container.decodeFlexibleString(forKey: .genre)?.nonEmpty
            releaseDate = container.decodeFlexibleString(forKey: .releaseDate)?.nonEmpty
            rating = container.decodeFlexibleString(forKey: .rating)?.nonEmpty
            backdropPath = container.decodeFlexibleStringArray(forKey: .backdropPath)
            youtubeTrailer = container.decodeFlexibleString(forKey: .youtubeTrailer)?.nonEmpty
        }
    }

    struct Season: Decodable, Identifiable, Hashable {
        let seasonNumber: Int
        let name: String?
        let overview: String?
        let cover: String?
        let airDate: String?

        var id: Int { seasonNumber }

        enum CodingKeys: String, CodingKey {
            case seasonNumber = "season_number"
            case name, overview, cover
            case airDate = "air_date"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            seasonNumber = container.decodeFlexibleInt(forKey: .seasonNumber) ?? 0
            name = container.decodeFlexibleString(forKey: .name)?.nonEmpty
            overview = container.decodeFlexibleString(forKey: .overview)?.nonEmpty
            cover = container.decodeFlexibleString(forKey: .cover)?.nonEmpty
            airDate = container.decodeFlexibleString(forKey: .airDate)?.nonEmpty
        }
    }

    struct Episode: Identifiable, Hashable {
        let id: String
        let episodeNum: Int
        let title: String
        let containerExtension: String?
        let season: Int?
        let plot: String?
        let stillImageURL: URL?
        let durationSecs: Int?
        /// Data di uscita dell'episodio così come inviata dal provider
        /// (in genere "yyyy-MM-dd"), mostrata sotto la trama nella scheda
        /// dettaglio esattamente come nel video dimostrativo (es. "1
        /// febbraio 2006"). `nil` se il provider non la fornisce.
        let releaseDateRaw: String?

        var streamId: Int { Int(id) ?? 0 }

        /// Codice "S01E03" mostrato nella lista episodi, come nel video.
        func code(seasonFallback: Int) -> String {
            let seasonNumber = season ?? seasonFallback
            return String(format: "S%02dE%02d", seasonNumber, episodeNum)
        }

        /// Data di uscita formattata in italiano esteso ("1 febbraio
        /// 2006"), come mostrato nel video dimostrativo sotto la trama di
        /// ogni episodio. Se il formato non è quello atteso ("yyyy-MM-dd")
        /// ma il campo è comunque presente, ricade sul testo grezzo
        /// piuttosto che nasconderlo.
        var formattedReleaseDate: String? {
            guard let raw = releaseDateRaw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return nil
            }

            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.calendar = Calendar(identifier: .gregorian)
            parser.timeZone = .autoupdatingCurrent
            parser.dateFormat = "yyyy-MM-dd"

            guard let date = parser.date(from: raw) else { return raw }

            let display = DateFormatter()
            display.locale = Locale(identifier: "it_IT")
            display.dateFormat = "d MMMM yyyy"
            return display.string(from: date)
        }
    }

    let details: SeriesDetails?
    let seasons: [Season]
    let episodes: [String: [Episode]]

    enum CodingKeys: String, CodingKey {
        case info, seasons, episodes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        details = try? container.decodeIfPresent(SeriesDetails.self, forKey: .info)
        seasons = (try? container.decodeIfPresent([Season].self, forKey: .seasons)) ?? nil ?? []
        episodes = try container.decode([String: [Episode]].self, forKey: .episodes)
    }

    var sortedSeasonNumbers: [Int] {
        episodes.keys.compactMap { Int($0) }.sorted()
    }

    func episodes(forSeason season: Int) -> [Episode] {
        (episodes[String(season)] ?? []).sorted { $0.episodeNum < $1.episodeNum }
    }

    func seasonInfo(for season: Int) -> Season? {
        seasons.first { $0.seasonNumber == season }
    }

    var castNames: [String] {
        (details?.cast ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var genreNames: [String] {
        (details?.genre ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var backdropURL: URL? {
        if let first = details?.backdropPath?.first, let url = URL(string: first) {
            return url
        }
        if let cover = details?.cover, let url = URL(string: cover) {
            return url
        }
        return nil
    }

    var year: String? {
        guard let date = details?.releaseDate, date.count >= 4 else { return nil }
        return String(date.prefix(4))
    }
}

extension XtreamSeriesInfo.Episode: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, title, info
        case episodeNum = "episode_num"
        case containerExtension = "container_extension"
        case season
    }

    private enum InfoKeys: String, CodingKey {
        case plot
        case movieImage = "movie_image"
        case durationSecs = "duration_secs"
        case releaseDate = "releasedate"
        case airDate = "air_date"
    }

    /// FIX 2026-09-20: `title` e `containerExtension` usavano
    /// `try? container.decode(String.self, forKey:)`, stessa incoerenza
    /// di `XtreamSeriesItem` sopra. Un episodio con titolo numerico (es.
    /// "12" inviato come JSON number) o un'estensione contenitore inviata
    /// in un tipo inatteso finivano scartati/sostituiti dal default invece
    /// di essere recuperati. Ora entrambi usano `decodeFlexibleString`.
    ///
    /// Aggiunta: decodifica anche il blocco annidato `info` (trama,
    /// immagine still, durata in secondi dell'episodio), quando presente.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = container.decodeFlexibleString(forKey: .id) ?? UUID().uuidString
        episodeNum = container.decodeFlexibleInt(forKey: .episodeNum) ?? 0
        season = container.decodeFlexibleInt(forKey: .season)

        title = container.decodeFlexibleString(forKey: .title)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
            ?? "Episodio senza titolo"

        containerExtension = container.decodeFlexibleString(forKey: .containerExtension)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nonEmpty

        if let infoContainer = try? container.nestedContainer(keyedBy: InfoKeys.self, forKey: .info) {
            plot = infoContainer.decodeFlexibleString(forKey: .plot)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty

            if let imageString = infoContainer.decodeFlexibleString(forKey: .movieImage)?.nonEmpty {
                stillImageURL = URL(string: imageString)
            } else {
                stillImageURL = nil
            }

            durationSecs = infoContainer.decodeFlexibleInt(forKey: .durationSecs)

            // Diversi pannelli Xtream chiamano il campo "releasedate" (tutto
            // attaccato, il più comune) oppure "air_date": proviamo entrambi,
            // il primo che risponde con un valore non vuoto vince.
            releaseDateRaw = infoContainer.decodeFlexibleString(forKey: .releaseDate)?.nonEmpty
                ?? infoContainer.decodeFlexibleString(forKey: .airDate)?.nonEmpty
        } else {
            plot = nil
            stillImageURL = nil
            durationSecs = nil
            releaseDateRaw = nil
        }
    }
}
