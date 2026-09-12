import Foundation

actor EPGService {
    private let credentials: XtreamCredentials
    private let session: URLSession

    init(credentials: XtreamCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    func shortEPG(streamId: Int, limit: Int = 10) async throws -> [EPGProgram] {
        guard var components = URLComponents(string: credentials.host + "/player_api.php") else { throw XtreamError.invalidURL }
        components.queryItems = [
            .init(name: "username", value: credentials.username),
            .init(name: "password", value: credentials.password),
            .init(name: "action", value: "get_short_epg"),
            .init(name: "stream_id", value: String(streamId)),
            .init(name: "limit", value: String(limit))
        ]
        guard let url = components.url else { throw XtreamError.invalidURL }
        let (data, _) = try await session.data(from: url)

        struct RawEPGResponse: Decodable {
            struct RawItem: Decodable {
                let id: String, title: String, description: String?
                let start: String, end: String, hasArchive: Int?
                enum CodingKeys: String, CodingKey {
                    case id, title, description, start, end
                    case hasArchive = "has_archive"
                }
            }
            let epgListings: [RawItem]
            enum CodingKeys: String, CodingKey { case epgListings = "epg_listings" }
        }

        let raw = try JSONDecoder().decode(RawEPGResponse.self, from: data)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return raw.epgListings.compactMap { item in
            guard let start = formatter.date(from: item.start), let end = formatter.date(from: item.end) else { return nil }
            return EPGProgram(id: item.id, title: item.title, description: item.description,
                               start: start, end: end, hasArchive: (item.hasArchive ?? 0) == 1)
        }
    }

    func catchupURL(for request: CatchupRequest) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd:HH-mm"
        let startString = formatter.string(from: request.start)
        return URL(string: "\(credentials.host)/timeshift/\(credentials.username)/\(credentials.password)/\(request.durationMinutes)/\(startString)/\(request.streamId).ts")
    }
}
