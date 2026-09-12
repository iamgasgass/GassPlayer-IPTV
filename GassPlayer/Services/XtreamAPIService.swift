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

    /// Costruisce l'URL di streaming usando il `container_extension` reale
    /// dello stream quando disponibile (fondamentale per VOD/Serie, che
    /// spesso sono mkv/avi e non mp4), con fallback all'estensione di
    /// default del kind solo se il pannello non la fornisce.
    nonisolated func streamURL(for stream: XtreamStream, kind: XtreamStreamKind) -> URL? {
        let ext = stream.containerExtension?.isEmpty == false ? stream.containerExtension! : kind.defaultExtension
        return URL(string: "\(credentials.host)/\(kind.pathComponent)/\(credentials.username)/\(credentials.password)/\(stream.streamId).\(ext)")
    }

    /// Overload di compatibilità per i call site che hanno solo l'id
    /// (es. costruzione manuale senza l'oggetto XtreamStream completo).
    nonisolated func streamURL(for streamId: Int, kind: XtreamStreamKind, ext: String? = nil) -> URL? {
        let resolvedExt = ext ?? kind.defaultExtension
        return URL(string: "\(credentials.host)/\(kind.pathComponent)/\(credentials.username)/\(credentials.password)/\(streamId).\(resolvedExt)")
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
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 { throw XtreamError.wrongCredentials }
        guard (200..<300).contains(http.statusCode) else { throw XtreamError.httpStatus(http.statusCode) }
    }
}
