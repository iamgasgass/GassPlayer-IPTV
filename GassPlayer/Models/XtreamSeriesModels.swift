import Foundation

struct XtreamSeriesInfo: Codable {
    struct Episode: Codable, Identifiable, Hashable {
        let id: String
        let episodeNum: Int
        let title: String
        let containerExtension: String?

        var identifiableId: String { id }
        var streamId: Int { Int(id) ?? 0 }

        enum CodingKeys: String, CodingKey {
            case id, title
            case episodeNum = "episode_num"
            case containerExtension = "container_extension"
        }
    }

    let episodes: [String: [Episode]]

    var sortedSeasonNumbers: [Int] {
        episodes.keys.compactMap { Int($0) }.sorted()
    }

    func episodes(forSeason season: Int) -> [Episode] {
        (episodes[String(season)] ?? []).sorted { $0.episodeNum < $1.episodeNum }
    }
}
