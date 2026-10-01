import Foundation

/// Dettaglio di un contenuto VOD (`get_vod_info`): la maggior parte dei
/// pannelli Xtream restituisce già trama, cast, genere e un backdrop propri
/// (spesso presi da TMDB lato server), utili come base immediata prima/in
/// assenza dell'arricchimento TMDB fatto direttamente dall'app.
struct XtreamVODInfo: Decodable {
    struct Info: Decodable {
        let movieImage: String?
        let backdropPath: [String]?
        let youtubeTrailer: String?
        let plot: String?
        let cast: String?
        let director: String?
        let genre: String?
        let releaseDate: String?
        let rating: String?
        let durationSecs: Int?
        let duration: String?
        let tmdbId: String?

        enum CodingKeys: String, CodingKey {
            case movieImage = "movie_image"
            case backdropPath = "backdrop_path"
            case youtubeTrailer = "youtube_trailer"
            case plot, cast, director, genre, rating, duration
            case releaseDate = "releasedate"
            case durationSecs = "duration_secs"
            case tmdbId = "tmdb_id"
            case tmdb
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            movieImage = container.decodeFlexibleString(forKey: .movieImage)?.nonEmpty
            backdropPath = container.decodeFlexibleStringArray(forKey: .backdropPath)
            youtubeTrailer = container.decodeFlexibleString(forKey: .youtubeTrailer)?.nonEmpty
            plot = container.decodeFlexibleString(forKey: .plot)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
            cast = container.decodeFlexibleString(forKey: .cast)?.nonEmpty
            director = container.decodeFlexibleString(forKey: .director)?.nonEmpty
            genre = container.decodeFlexibleString(forKey: .genre)?.nonEmpty
            releaseDate = container.decodeFlexibleString(forKey: .releaseDate)?.nonEmpty
            rating = container.decodeFlexibleString(forKey: .rating)?.nonEmpty
            durationSecs = container.decodeFlexibleInt(forKey: .durationSecs)
            duration = container.decodeFlexibleString(forKey: .duration)?.nonEmpty
            tmdbId = container.decodeFlexibleString(forKey: .tmdbId)?.nonEmpty
                ?? container.decodeFlexibleString(forKey: .tmdb)?.nonEmpty
        }
    }

    let info: Info?

    enum CodingKeys: String, CodingKey {
        case info
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        info = try? container.decodeIfPresent(Info.self, forKey: .info)
    }

    /// Elenco nomi attori: il campo "cast" del provider arriva quasi sempre
    /// come stringa unica separata da virgole (es. "Attore Uno, Attore
    /// Due"), non come struttura — a differenza di TMDB non ci sono foto
    /// né personaggi, solo nomi.
    var castNames: [String] {
        (info?.cast ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var genreNames: [String] {
        (info?.genre ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var backdropURL: URL? {
        if let first = info?.backdropPath?.first, let url = URL(string: first) {
            return url
        }
        if let movieImage = info?.movieImage, let url = URL(string: movieImage) {
            return url
        }
        return nil
    }

    var year: String? {
        guard let date = info?.releaseDate, date.count >= 4 else { return nil }
        return String(date.prefix(4))
    }

    var runtimeMinutes: Int? {
        if let secs = info?.durationSecs, secs > 0 { return secs / 60 }
        return nil
    }
}

/// Decodifica tollerante per campi che alcuni pannelli Xtream inviano come
/// array di stringhe (`["url1", "url2"]`), altri come stringa singola, e
/// altri ancora come stringa vuota o assenti del tutto. Estende lo stesso
/// `KeyedDecodingContainer` già usato altrove nel progetto: metodo nuovo,
/// nessuna ridichiarazione.
extension KeyedDecodingContainer {
    func decodeFlexibleStringArray(forKey key: Key) -> [String]? {
        if let array = try? decodeIfPresent([String].self, forKey: key) {
            let cleaned = array.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return cleaned.isEmpty ? nil : cleaned
        }

        if let single = decodeFlexibleString(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !single.isEmpty {
            return [single]
        }

        return nil
    }
}
