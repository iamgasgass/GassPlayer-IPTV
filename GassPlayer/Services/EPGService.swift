import Foundation

struct EPGService {
    let credentials: XtreamCredentials
    private let session: URLSession
    private let cachePrefix: String

    init(credentials: XtreamCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
        self.cachePrefix = Self.makeCachePrefix(credentials: credentials)
    }

    func shortEPG(streamId: Int, limit: Int = 10, forceRefresh: Bool = false) async throws -> [EPGProgram] {
        let boundedLimit = min(max(limit, 1), 100)
        let dayKey = Self.dayFormatter.string(from: Date())
        let key = "\(cachePrefix).short.\(streamId).\(dayKey).\(boundedLimit)"

        if !forceRefresh, let cached: [EPGProgram] = await CacheService.shared.value(for: key) {
            return cached
        }

        let data = try await performRequest(
            action: "get_short_epg",
            extra: [
                "stream_id": String(streamId),
                "limit": String(boundedLimit)
            ]
        )
        let programs = try decodePrograms(from: data)
        await CacheService.shared.set(programs, for: key, ttl: 900)
        return programs
    }

    func catchupURL(for request: CatchupRequest) -> URL? {
        var host = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines)
        while host.hasSuffix("/") { host.removeLast() }
        guard !host.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd:HH-mm"

        let user = safePathSegment(credentials.username)
        let password = safePathSegment(credentials.password)
        let start = safePathSegment(formatter.string(from: request.start))
        return URL(string: "\(host)/timeshift/\(user)/\(password)/\(max(1, request.durationMinutes))/\(start)/\(request.streamId).ts")
    }

    private func performRequest(action: String, extra: [String: String]) async throws -> Data {
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
        } catch let error as URLError where error.code == .timedOut {
            throw XtreamError.timeout
        } catch let error as URLError {
            throw XtreamError.unreachable(underlying: error)
        } catch {
            throw XtreamError.unreachable(underlying: error)
        }
    }

    private func endpoint(action: String, extra: [String: String]) throws -> URL {
        var host = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty,
              let parsed = URL(string: host),
              let scheme = parsed.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              parsed.host != nil else {
            throw XtreamError.malformedHost(host)
        }

        while host.hasSuffix("/") { host.removeLast() }
        guard var components = URLComponents(string: host + "/player_api.php") else {
            throw XtreamError.invalidURL
        }

        var items = [
            URLQueryItem(name: "username", value: credentials.username),
            URLQueryItem(name: "password", value: credentials.password),
            URLQueryItem(name: "action", value: action)
        ]
        for (key, value) in extra.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = items
        guard let url = components.url else { throw XtreamError.invalidURL }
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
                    case id, title, description, start, end
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
               let dictionary = object as? [String: Any], dictionary.isEmpty {
                return []
            }
            throw XtreamError.decoding(error)
        }

        let programs = response.epgListings.compactMap { item -> EPGProgram? in
            guard let start = Self.parseDate(item.start), let end = Self.parseDate(item.end), end > start else {
                DebugLogger.logAsync(.warning, "EPG: programma scartato per data non valida sul canale richiesto")
                return nil
            }
            return EPGProgram(
                id: item.id,
                title: Self.decodeIfBase64(item.title),
                description: item.description.map(Self.decodeIfBase64),
                start: start,
                end: end,
                hasArchive: (item.hasArchive ?? 0) == 1
            )
        }

        return programs.sorted { $0.start < $1.start }
    }

    private static func parseDate(_ value: String) -> Date? {
        for formatter in dateFormatters where formatter.date(from: value) != nil {
            return formatter.date(from: value)
        }
        return nil
    }

    private static func decodeIfBase64(_ value: String) -> String {
        guard let data = Data(base64Encoded: value, options: .ignoreUnknownCharacters),
              let decoded = String(data: data, encoding: .utf8),
              !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return value
        }
        return decoded
    }

    private func safePathSegment(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw XtreamError.wrongCredentials
        default:
            throw XtreamError.httpStatus(http.statusCode)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
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

    private static func makeCachePrefix(credentials: XtreamCredentials) -> String {
        let host = credentials.host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        let stableInput = "\(host)|\(credentials.username)"
        let digest = stableInput.utf8.reduce(UInt64(14695981039346656037)) { partial, byte in
            (partial ^ UInt64(byte)) &* UInt64(1099511628211)
        }
        return "epg.\(String(digest, radix: 16))"
    }
}
