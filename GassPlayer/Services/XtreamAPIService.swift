import Foundation

actor XtreamAPIService {
    let credentials: XtreamCredentials
    private let session: URLSession
    private let requestTimeout: TimeInterval

    init(
        credentials: XtreamCredentials,
        session: URLSession = .shared,
        requestTimeout: TimeInterval = 30
    ) {
        self.credentials = credentials
        self.session = session
        self.requestTimeout = requestTimeout
    }

    // MARK: - Endpoint construction

    private func endpoint(
        action: String? = nil,
        extra: [String: String] = [:],
        path: String = "/player_api.php"
    ) throws -> URL {
        var host = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty,
              let parsedHost = URL(string: host),
              let scheme = parsedHost.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              parsedHost.host != nil else {
            throw XtreamError.malformedHost(host)
        }

        while host.hasSuffix("/") {
            host.removeLast()
        }

        guard var endpointComponents = URLComponents(string: host + path) else {
            throw XtreamError.malformedHost(host)
        }

        var items = [
            URLQueryItem(name: "username", value: credentials.username),
            URLQueryItem(name: "password", value: credentials.password)
        ]
        if let action {
            items.append(URLQueryItem(name: "action", value: action))
        }
        for (key, value) in extra.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: key, value: value))
        }
        endpointComponents.queryItems = items

        guard let url = endpointComponents.url else {
            throw XtreamError.invalidURL
        }
        return url
    }

    private func request(
        action: String? = nil,
        extra: [String: String] = [:],
        path: String = "/player_api.php"
    ) throws -> URLRequest {
        let url = try endpoint(action: action, extra: extra, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        return request
    }

    private func data(
        action: String? = nil,
        extra: [String: String] = [:],
        path: String = "/player_api.php"
    ) async throws -> Data {
        let urlRequest = try request(action: action, extra: extra, path: path)
        do {
            let (data, response) = try await session.data(for: urlRequest)
            try validate(response)
            return data
        } catch let error as XtreamError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw XtreamError.timeout
        } catch let error as URLError {
            throw XtreamError.unreachable(underlying: error)
        } catch {
            throw XtreamError.unreachable(underlying: error)
        }
    }

    // MARK: - Authentication

    func authenticate() async throws -> XtreamAuthResponse {
        let payload = try await data()
        do {
            let decoded = try JSONDecoder().decode(XtreamAuthResponse.self, from: payload)
            guard decoded.userInfo.status.lowercased() == "active" else {
                throw XtreamError.wrongCredentials
            }
            return decoded
        } catch let error as XtreamError {
            throw error
        } catch {
            throw XtreamError.decoding(error)
        }
    }

    // MARK: - Categories

    func fetchCategories(kind: XtreamStreamKind) async throws -> [XtreamCategory] {
        let action: String
        switch kind {
        case .live:
            action = "get_live_categories"
        case .movie:
            action = "get_vod_categories"
        case .series:
            action = "get_series_categories"
        }
        return FlexibleArrayDecoder.decode([XtreamCategory].self, from: try await data(action: action))
    }

    // MARK: - Streams (Live / VOD)

    func fetchStreams(kind: XtreamStreamKind, categoryId: String? = nil) async throws -> [XtreamStream] {
        guard kind != .series else {
            throw XtreamError.invalidURL
        }

        let action = kind == .live ? "get_live_streams" : "get_vod_streams"
        let normalizedCategoryId = categoryId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let extra = (normalizedCategoryId?.isEmpty == false)
            ? ["category_id": normalizedCategoryId!]
            : [:]

        return FlexibleArrayDecoder.decode(
            [XtreamStream].self,
            from: try await data(action: action, extra: extra)
        )
    }

    /// Recupera l'intero catalogo evitando che categorie vuote, mancanti o
    /// anomale facciano sparire i VOD/canali. La risposta globale del provider
    /// e' considerata la base autorevole; le risposte per categoria vengono
    /// unite come recupero aggiuntivo, non come sostituzione, cosi' un
    /// provider che pubblica un elenco globale incompleto non fa comunque
    /// perdere i titoli reperibili solo per categoria, e viceversa.
    func fetchAllStreams(kind: XtreamStreamKind) async throws -> [XtreamStream] {
        guard kind != .series else {
            throw XtreamError.invalidURL
        }

        let globalStreams = try await fetchStreams(kind: kind)

        let categories: [XtreamCategory]
        do {
            categories = try await fetchCategories(kind: kind)
        } catch {
            // Nessuna categoria disponibile: la risposta globale resta l'unica fonte valida.
            return stableDeduplicated(globalStreams)
        }

        let categoryIDs = Array(
            Set(
                categories
                    .map(\.categoryId)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        )

        guard !categoryIDs.isEmpty else {
            return stableDeduplicated(globalStreams)
        }

        let streamsByCategory: [[XtreamStream]] = await withTaskGroup(
            of: [XtreamStream].self,
            returning: [[XtreamStream]].self
        ) { group in
            for categoryID in categoryIDs {
                group.addTask {
                    (try? await self.fetchStreams(kind: kind, categoryId: categoryID)) ?? []
                }
            }

            var results: [[XtreamStream]] = []
            for await streams in group {
                results.append(streams)
            }
            return results
        }

        return stableDeduplicated(globalStreams + streamsByCategory.flatMap { $0 })
    }

    // MARK: - Series

    func fetchSeriesList(categoryId: String? = nil) async throws -> [XtreamSeriesItem] {
        let normalizedCategoryId = categoryId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let extra = (normalizedCategoryId?.isEmpty == false)
            ? ["category_id": normalizedCategoryId!]
            : [:]
        return FlexibleArrayDecoder.decode(
            [XtreamSeriesItem].self,
            from: try await data(action: "get_series", extra: extra)
        )
    }

    func fetchSeriesInfo(seriesId: Int) async throws -> XtreamSeriesInfo {
        do {
            return try JSONDecoder().decode(
                XtreamSeriesInfo.self,
                from: try await data(action: "get_series_info", extra: ["series_id": String(seriesId)])
            )
        } catch let error as XtreamError {
            throw error
        } catch {
            throw XtreamError.decoding(error)
        }
    }

    // MARK: - Streaming URL construction

    nonisolated private func safePathSegment(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw
    }

    nonisolated private func buildStreamingURL(pathComponent: String, idAndExtension: String) -> URL? {
        var host = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines)
        while host.hasSuffix("/") {
            host.removeLast()
        }
        let user = safePathSegment(credentials.username)
        let password = safePathSegment(credentials.password)
        return URL(string: "\(host)/\(pathComponent)/\(user)/\(password)/\(idAndExtension)")
    }

    nonisolated func streamURL(for stream: XtreamStream, kind: XtreamStreamKind) -> URL? {
        let ext = stream.containerExtension?.isEmpty == false
            ? stream.containerExtension!
            : kind.defaultExtension
        return buildStreamingURL(
            pathComponent: kind.pathComponent,
            idAndExtension: "\(stream.streamId).\(ext)"
        )
    }

    nonisolated func streamURL(for streamId: Int, kind: XtreamStreamKind, ext: String? = nil) -> URL? {
        buildStreamingURL(
            pathComponent: kind.pathComponent,
            idAndExtension: "\(streamId).\(ext ?? kind.defaultExtension)"
        )
    }

    nonisolated func episodeStreamURL(episodeId: Int, ext: String) -> URL? {
        buildStreamingURL(pathComponent: "series", idAndExtension: "\(episodeId).\(ext)")
    }

    // MARK: - Helpers

    private func stableDeduplicated(_ streams: [XtreamStream]) -> [XtreamStream] {
        var seen = Set<Int>()
        return streams.filter { seen.insert($0.streamId).inserted }
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            return
        }
        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw XtreamError.wrongCredentials
        default:
            throw XtreamError.httpStatus(http.statusCode)
        }
    }
}
