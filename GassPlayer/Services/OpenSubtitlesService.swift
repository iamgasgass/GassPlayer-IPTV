import Foundation

struct SubtitleResult: Identifiable, Codable {
    let id: String, language: String, releaseName: String, downloadURL: String
}

actor OpenSubtitlesService {
    private let apiKey: String
    private let baseURL = URL(string: "https://api.opensubtitles.com/api/v1")!

    init(apiKey: String) { self.apiKey = apiKey }

    func search(query: String, language: String = "it") async throws -> [SubtitleResult] {
        var components = URLComponents(url: baseURL.appendingPathComponent("subtitles"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "query", value: query), .init(name: "languages", value: language)]
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        let (data, _) = try await URLSession.shared.data(for: request)

        struct Response: Decodable {
            struct Attributes: Decodable { let language: String; let release: String }
            struct Item: Decodable { let id: String; let attributes: Attributes }
            let data: [Item]
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.data.map { SubtitleResult(id: $0.id, language: $0.attributes.language, releaseName: $0.attributes.release, downloadURL: "") }
    }
}
