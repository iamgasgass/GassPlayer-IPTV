import Foundation

actor XtreamAPIService {
    let credentials: XtreamCredentials
    private let session: URLSession

    init(credentials: XtreamCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    private func endpoint(action: String? = nil, extra: [String: String] = [:], path: String = "/player_api.php") throws -> URL {
        guard var components = URLComponents(string: credentials.host + path) else { throw XtreamError.invalidURL }
        var items = [
            URLQueryItem(name: "username", value: credentials.username),
            URLQueryItem(name: "password", value: credentials.password)
        ]
        if let action { items.append(URLQueryItem(name: "action", value: action)) }
        for (k, v) in extra { items.append(URLQueryItem(name: k, value: v)) }
        components.queryItems = items
        guard let url = components.url else { throw XtreamError.invalidURL }
        return url
    }

    func authenticate() async throws -> XtreamAuthResponse {
        let url = try endpoint()
        let (data, response) = try await session.data(from: url)
        try validate(response)
        do { return try JSONDecoder().decode(XtreamAuthResponse.self, from: data) }
        catch { throw XtreamError.decoding(error) }
    }

    func fetchCategories(kind: XtreamStreamKind) async throws -> [XtreamCategory] {
        let action = "get_\(kind == .live ? "live" : kind == .movie ? "vod" : "series")_categories"
        let url = try endpoint(action: action)
        let (data, response) = try await session.data(from: url)
        try validate(response)
        return try JSONDecoder().decode([XtreamCategory].self, from: data)
    }

    func fetchStreams(kind: XtreamStreamKind, categoryId: String? = nil) async throws -> [XtreamStream] {
        let action = "get_\(kind == .live ? "live" : kind == .movie ? "vod" : "series")_streams"
        var extra: [String: String] = [:]
        if let categoryId { extra["category_id"] = categoryId }
        let url = try endpoint(action: action, extra: extra)
        let (data, response) = try await session.data(from: url)
        try validate(response)
        return try JSONDecoder().decode([XtreamStream].self, from: data)
    }

    func streamURL(for streamId: Int, kind: XtreamStreamKind, ext: String = "m3u8") -> URL? {
        URL(string: "\(credentials.host)/\(kind.pathComponent)/\(credentials.username)/\(credentials.password)/\(streamId).\(ext)")
    }

    func fetchProviderVPNConfig() async throws -> ProviderVPNConfig {
        let candidateActions = ["get_vpn_config", "get_vpn", "vpn_info"]
        for action in candidateActions {
            if let url = try? endpoint(action: action),
               let (data, response) = try? await session.data(from: url),
               let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let config = try? JSONDecoder().decode(ProviderVPNConfig.self, from: data) {
                return config
            }
        }
        let candidatePaths = ["/vpn/config.json", "/panel_api.php"]
        for path in candidatePaths {
            if let url = try? endpoint(action: "get_vpn_config", path: path),
               let (data, response) = try? await session.data(from: url),
               let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let config = try? JSONDecoder().decode(ProviderVPNConfig.self, from: data) {
                return config
            }
        }
        throw XtreamError.noProviderVPN
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw XtreamError.invalidCredentials
        }
    }
}
