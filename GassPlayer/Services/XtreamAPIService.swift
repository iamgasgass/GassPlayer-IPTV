import Foundation

actor XtreamAPIService {
    let credentials: XtreamCredentials
    private let session: URLSession

    init(credentials: XtreamCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    private func endpoint(action: String? = nil, extra: [String: String] = [:], path: String = "/player_api.php") throws -> URL {
        let cleanedHost = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = URL(string: cleanedHost)?.scheme, scheme == "http" || scheme == "https" else {
            throw XtreamError.malformedHost(cleanedHost)
        }
        guard var components = URLComponents(string: cleanedHost + path) else {
            throw XtreamError.malformedHost(cleanedHost)
        }
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
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(from: url)
        } catch let urlError as URLError {
            if urlError.code == .timedOut { throw XtreamError.timeout }
            throw XtreamError.unreachable(underlying: urlError)
        } catch {
            throw XtreamError.unreachable(underlying: error)
        }
        try validate(response)
        do {
            let decoded = try JSONDecoder().decode(XtreamAuthResponse.self, from: data)
            if decoded.userInfo.status.lowercased() != "active" {
                throw XtreamError.wrongCredentials
            }
            return decoded
        } catch let xtreamError as XtreamError {
            throw xtreamError
        } catch {
            throw XtreamError.decoding(error)
        }
    }

    func fetchCategories(kind: XtreamStreamKind) async throws -> [XtreamCategory] {
        let action = "get_\(kind == .live ? "live" : kind == .movie ? "vod" : "series")_categories"
        let url = try endpoint(action: action)
        let (data, response) = try await session.data(from: url)
        try validate(response)
        return FlexibleArrayDecoder.decode([XtreamCategory].self, from: data)
    }

    func fetchStreams(kind: XtreamStreamKind, categoryId: String? = nil) async throws -> [XtreamStream] {
        guard kind != .series else {
            throw XtreamError.invalidURL
        }
        let action = "get_\(kind == .live ? "live" : "vod")_streams"
        var extra: [String: String] = [:]
        if let categoryId { extra["category_id"] = categoryId }
        let url = try endpoint(action: action, extra: extra)
        let (data, response) = try await session.data(from: url)
        try validate(response)
        return FlexibleArrayDecoder.decode([XtreamStream].self, from: data)
    }

    func fetchSeriesList(categoryId: String? = nil) async throws -> [XtreamSeriesItem] {
        var extra: [String: String] = [:]
        if let categoryId { extra["category_id"] = categoryId }
        let url = try endpoint(action: "get_series", extra: extra)
        let (data, response) = try await session.data(from: url)
        try validate(response)
        return FlexibleArrayDecoder.decode([XtreamSeriesItem].self, from: data)
    }

    func fetchSeriesInfo(seriesId: Int) async throws -> XtreamSeriesInfo {
        let url = try endpoint(action: "get_series_info", extra: ["series_id": String(seriesId)])
        let (data, response) = try await session.data(from: url)
        try validate(response)
        do {
            return try JSONDecoder().decode(XtreamSeriesInfo.self, from: data)
        } catch {
            throw XtreamError.decoding(error)
        }
    }

    nonisolated private func safePathSegment(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw
    }

    nonisolated private func buildStreamingURL(pathComponent: String, idAndExtension: String) -> URL? {
        var host = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasSuffix("/") { host.removeLast() }
        let user = safePathSegment(credentials.username)
        let pass = safePathSegment(credentials.password)
        return URL(string: "\(host)/\(pathComponent)/\(user)/\(pass)/\(idAndExtension)")
    }

    nonisolated func streamURL(for stream: XtreamStream, kind: XtreamStreamKind) -> URL? {
        let ext = stream.containerExtension?.isEmpty == false ? stream.containerExtension! : kind.defaultExtension
        return buildStreamingURL(pathComponent: kind.pathComponent, idAndExtension: "\(stream.streamId).\(ext)")
    }

    nonisolated func streamURL(for streamId: Int, kind: XtreamStreamKind, ext: String? = nil) -> URL? {
        let resolvedExt = ext ?? kind.defaultExtension
        return buildStreamingURL(pathComponent: kind.pathComponent, idAndExtension: "\(streamId).\(resolvedExt)")
    }

    nonisolated func episodeStreamURL(episodeId: Int, ext: String) -> URL? {
        buildStreamingURL(pathComponent: "series", idAndExtension: "\(episodeId).\(ext)")
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 { throw XtreamError.wrongCredentials }
        guard (200..<300).contains(http.statusCode) else { throw XtreamError.httpStatus(http.statusCode) }
    }
}
