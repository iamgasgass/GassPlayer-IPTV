import Foundation

struct XtreamSeriesItem: Codable, Identifiable, Hashable {
    let seriesId: Int
    let name: String
    let cover: String?
    let categoryId: String?

    var id: Int {
        seriesId
    }

    enum CodingKeys: String, CodingKey {
        case seriesId = "series_id"
        case name
        case cover
        case categoryId = "category_id"
    }

    init(
        seriesId: Int,
        name: String,
        cover: String? = nil,
        categoryId: String? = nil
    ) {
        self.seriesId = seriesId
        self.name = name
        self.cover = cover
        self.categoryId = categoryId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )

        seriesId = container.decodeFlexibleInt(
            forKey: .seriesId
        ) ?? 0

        name = (
            try? container.decode(
                String.self,
                forKey: .name
            )
        ) ?? "Serie senza nome"

        cover = try? container.decode(
            String.self,
            forKey: .cover
        )

        categoryId = container.decodeFlexibleString(
            forKey: .categoryId
        )
    }
}

struct XtreamSeriesInfo: Decodable {
    struct Episode: Identifiable, Hashable {
        let id: String
        let episodeNum: Int
        let title: String
        let containerExtension: String?

        var streamId: Int {
            Int(id) ?? 0
        }
    }

    let episodes: [String: [Episode]]

    var sortedSeasonNumbers: [Int] {
        episodes.keys
            .compactMap(Int.init)
            .sorted()
    }

    func episodes(forSeason season: Int) -> [Episode] {
        (episodes[String(season)] ?? [])
            .sorted {
                $0.episodeNum < $1.episodeNum
            }
    }
}

extension XtreamSeriesInfo.Episode: Decodable {
    enum CodingKeys: String, CodingKey {
        case id
        case title
        case episodeNum = "episode_num"
        case containerExtension = "container_extension"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )

        id = container.decodeFlexibleString(
            forKey: .id
        ) ?? UUID().uuidString

        episodeNum = container.decodeFlexibleInt(
            forKey: .episodeNum
        ) ?? 0

        title = (
            try? container.decode(
                String.self,
                forKey: .title
            )
        ) ?? "Episodio senza titolo"

        containerExtension = try? container.decode(
            String.self,
            forKey: .containerExtension
        )
    }
}
