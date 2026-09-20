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

struct XtreamSeriesInfo: Decodable {
    struct Episode: Identifiable, Hashable {
        let id: String
        let episodeNum: Int
        let title: String
        let containerExtension: String?

        var streamId: Int { Int(id) ?? 0 }
    }

    let episodes: [String: [Episode]]

    var sortedSeasonNumbers: [Int] {
        episodes.keys.compactMap { Int($0) }.sorted()
    }

    func episodes(forSeason season: Int) -> [Episode] {
        (episodes[String(season)] ?? []).sorted { $0.episodeNum < $1.episodeNum }
    }
}

extension XtreamSeriesInfo.Episode: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, title
        case episodeNum = "episode_num"
        case containerExtension = "container_extension"
    }

    /// FIX 2026-09-20: `title` e `containerExtension` usavano
    /// `try? container.decode(String.self, forKey:)`, stessa incoerenza
    /// di `XtreamSeriesItem` sopra. Un episodio con titolo numerico (es.
    /// "12" inviato come JSON number) o un'estensione contenitore inviata
    /// in un tipo inatteso finivano scartati/sostituiti dal default invece
    /// di essere recuperati. Ora entrambi usano `decodeFlexibleString`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = container.decodeFlexibleString(forKey: .id) ?? UUID().uuidString
        episodeNum = container.decodeFlexibleInt(forKey: .episodeNum) ?? 0

        title = container.decodeFlexibleString(forKey: .title)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
            ?? "Episodio senza titolo"

        containerExtension = container.decodeFlexibleString(forKey: .containerExtension)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nonEmpty
    }
}
