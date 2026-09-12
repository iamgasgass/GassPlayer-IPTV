import Foundation

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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeFlexibleString(forKey: .id) ?? UUID().uuidString
        episodeNum = container.decodeFlexibleInt(forKey: .episodeNum) ?? 0
        title = (try? container.decode(String.self, forKey: .title)) ?? "Episodio senza titolo"
        containerExtension = try? container.decode(String.self, forKey: .containerExtension)
    }
}
