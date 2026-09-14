import Foundation

/// Client EPG per provider Xtream.
///
/// Caratteristiche:
/// - Richiede il breve palinsesto per canale con limite validato.
/// - Mantiene una cache in memoria per canale/giorno/limite.
/// - Decodifica i campi Base64 diffusi nelle risposte Xtream.
/// - Costruisce URL catch-up senza lasciare che username/password contenenti
///   slash o caratteri riservati alterino la struttura del path.
/// - Riconosce timeout, credenziali errate e status HTTP non riusciti.
struct EPGService {
    let credentials: XtreamCredentials

    private let session: URLSession
    private let cachePrefix: String

    init(credentials: XtreamCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
        self.cachePrefix = Self.makeCachePrefix(credentials: credentials)
    }

    func shortEPG(
        streamId: Int,
        limit: Int = 10,
        forceRefresh: Bool = false
    ) async throws -> [EPGProgram] {
        guard streamId > 0 else {
            throw XtreamError.invalidURL
        }

        let boundedLimit = min(max(limit, 1), 100)
        let dayKey = Self.dayFormatter.string(from: Date())
        let key = "\(cachePrefix).short.\(streamId).\(dayKey).\(boundedLimit)"

        if !forceRefresh,
           let cached: [EPGProgram] = await CacheService.shared.value(for: key) {
            return cached
        }

        let payload = try await RetryPolicy.withRetry(
            maxAttempts: 3,
            shouldRetry: Self.shouldRetry
        ) {
            try await performRequest(
                action: "get_short_epg",
                extra: [
                    "stream_id": String(streamId),
                    "limit": String(boundedLimit)
                ]
            )
        }

        let programs = try decodePrograms(from: payload)
        await CacheService.shared.set(programs, for: key, ttl: 15 * 60)
        return programs
    }

    /// Restituisce l'URL catch-up soltanto per richieste valide.
    /// Il chiamante deve inoltre verificare `EPGProgram.hasArchive` prima di
    /// presentare l'azione di riproduzione catch-up all'utente.
    func catchupURL(for request: CatchupRequest) -> URL? {
        guard request.streamId > 0, request.durationMinutes > 0 else {
            return nil
        }

        guard let baseURL = normalizedBaseURL() else {
            return nil
        }

        let duration = min(max(request.durationMinutes, 1), 24 * 60)
        let start = Self.catchupDateFormatter.string(from: request.start)

        return appendingPathComponents(
            [
                "timeshift",
                credentials.username,
                credentials.password,
                String(duration),
                start,
                String(request.streamId) + ".ts"
            ],
            to: baseURL
        )
    }

    private func performRequest(
        action: String,
        extra: [String: String]
    ) async throws -> Data {
        let url = try endpoint(action: action, extra: extra)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            try validate(response)
            return data
        } catch let error as XtreamError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw XtreamError.timeout
        } catch let error as URLError {
            throw XtreamError.unreachable(underlying: error)
        } catch {
            throw XtreamError.unreachable(underlying: error)
        }
    }

    private func endpoint(
        action: String,
        extra: [String: String]
    ) throws -> URL {
        guard var components = normalizedBaseComponents() else {
            throw XtreamError.malformedHost(credentials.host)
        }

        let existingPath = components.path.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        components.path = existingPath.isEmpty
            ? "/player_api.php"
            : "/\(existingPath)/player_api.php"
        components.fragment = nil

        var queryItems = [
            URLQueryItem(name: "username", value: credentials.username),
            URLQueryItem(name: "password", value: credentials.password),
            URLQueryItem(name: "action", value: action)
        ]

        for (key, value) in extra.sorted(by: { $0.key < $1.key }) {
            queryItems.append(URLQueryItem(name: key, value: value))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw XtreamError.invalidURL
        }

        return url
    }

    private func normalizedBaseURL() -> URL? {
        normalizedBaseComponents()?.url
    }

    private func normalizedBaseComponents() -> URLComponents? {
        let rawHost = credentials.host.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !rawHost.isEmpty,
              var components = URLComponents(string: rawHost),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }

        components.scheme = scheme
        components.path = components.path.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        components.query = nil
        components.fragment = nil
        return components
    }

    private func appendingPathComponents(
        _ components: [String],
        to baseURL: URL
    ) -> URL? {
        var url = baseURL

        for component in components {
            let encoded = Self.encodePathSegment(component)
            guard !encoded.isEmpty else {
                return nil
            }
            url.appendPathComponent(encoded)
        }

        return url
    }

    private func decodePrograms(from data: Data) throws -> [EPGProgram] {
        struct RawEPGResponse: Decodable {
            struct RawItem: Decodable {
                let id: String
                let title: String
                let description: String?
                let start: String
                let end: String
                let hasArchive: Int?

                enum CodingKeys: String, CodingKey {
                    case id
                    case title
                    case description
                    case start
                    case end
                    case hasArchive = "has_archive"
                }
            }

            let epgListings: [RawItem]

            enum CodingKeys: String, CodingKey {
                case epgListings = "epg_listings"
            }
        }

        let response: RawEPGResponse

        do {
            response = try JSONDecoder().decode(RawEPGResponse.self, from: data)
        } catch {
            if let object = try? JSONSerialization.jsonObject(with: data),
               let dictionary = object as? [String: Any],
               dictionary.isEmpty {
                return []
            }
            throw XtreamError.decoding(error)
        }

        let programs = response.epgListings.compactMap { item -> EPGProgram? in
            guard let start = Self.parseDate(item.start),
                  let end = Self.parseDate(item.end),
                  end > start else {
                DebugLogger.logAsync(
                    .warning,
                    "EPG: programma scartato per date non valide sul canale richiesto"
                )
                return nil
            }

            let title = Self.decodeIfBase64(item.title)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !title.isEmpty else {
                return nil
            }

            return EPGProgram(
                id: item.id,
                title: title,
                description: item.description.map(Self.decodeIfBase64),
                start: start,
                end: end,
                hasArchive: (item.hasArchive ?? 0) == 1
            )
        }

        return stableDeduplicated(programs.sorted { $0.start < $1.start })
    }

    private static func stableDeduplicated(
        _ programs: [EPGProgram]
    ) -> [EPGProgram] {
        var seen = Set<String>()

        return programs.filter { program in
            let key = "\(program.id)|\(program.start.timeIntervalSince1970)|\(program.end.timeIntervalSince1970)"
            return seen.insert(key).inserted
        }
    }

    private static func parseDate(_ rawValue: String) -> Date? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !value.isEmpty else {
            return nil
        }

        for formatter in dateFormatters {
            if let date = formatter.date(from: value) {
                return date
            }
        }

        return nil
    }

    private static func decodeIfBase64(_ value: String) -> String {
        guard let data = Data(
            base64Encoded: value,
            options: .ignoreUnknownCharacters
        ),
        let decoded = String(data: data, encoding: .utf8),
        !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return value
        }

        return decoded
    }

    private func validate(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw XtreamError.unreachable(
                underlying: URLError(.badServerResponse)
            )
        }

        switch httpResponse.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw XtreamError.wrongCredentials
        default:
            throw XtreamError.httpStatus(httpResponse.statusCode)
        }
    }

    private static func shouldRetry(_ error: Error) -> Bool {
        guard let xtreamError = error as? XtreamError else {
            return !(error is CancellationError)
        }

        switch xtreamError {
        case .wrongCredentials,
             .malformedHost,
             .invalidURL,
             .decoding:
            return false

        case .unreachable,
             .timeout,
             .httpStatus,
             .noProviderVPN:
            return true
        }
    }

    /// Codifica un singolo componente path, non un URL completo.
    /// `.urlPathAllowed` non è adatto a username/password perché include `/`.
    private static func encodePathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")

        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let catchupDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd:HH-mm"
        return formatter
    }()

    private static let dateFormatters: [DateFormatter] = [
        makeDateFormatter("yyyy-MM-dd HH:mm:ss"),
        makeDateFormatter("yyyy-MM-dd'T'HH:mm:ssZ"),
        makeDateFormatter("yyyy-MM-dd'T'HH:mm:ss.SSSZ")
    ]

    private static func makeDateFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.autoupdatingCurrent
        formatter.dateFormat = format
        return formatter
    }

    private static func makeCachePrefix(
        credentials: XtreamCredentials
    ) -> String {
        let host = credentials.host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()

        let stableInput = "\(host)|\(credentials.username)"
        let digest = stableInput.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            partial,
            byte in
            (partial ^ UInt64(byte)) &* UInt64(1_099_511_628_211)
        }

        return "epg.\(String(digest, radix: 16))"
    }
}
