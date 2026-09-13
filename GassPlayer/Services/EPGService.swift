import Foundation

/// Cache EPG condivisa tra griglia Live, timeline e dettagli.
/// La cache è isolata da un actor per evitare data race e non viene ricreata
/// ogni volta che una view istanzia EPGService.
actor EPGCache {
    static let shared = EPGCache()

    private struct Entry {
        let programs: [EPGProgram]
        let expiresAt: Date
    }

    private var entries: [String: Entry] = [:]

    func value(for key: String) -> [EPGProgram]? {
        guard let entry = entries[key], entry.expiresAt > Date() else {
            entries[key] = nil
            return nil
        }
        return entry.programs
    }

    func set(_ programs: [EPGProgram], for key: String, ttl: TimeInterval) {
        entries[key] = Entry(
            programs: programs,
            expiresAt: Date().addingTimeInterval(ttl)
        )
    }

    func invalidate(prefix: String) {
        let keys = entries.keys.filter { $0.hasPrefix(prefix) }
        for key in keys {
            entries[key] = nil
        }
    }
}

struct EPGService {
    let credentials: XtreamCredentials
    private let session: URLSession

    init(credentials: XtreamCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    /// Carica e memorizza in cache il palinsesto breve di un canale.
    /// Il TTL di cinque minuti evita richieste duplicate mentre l'utente
    /// naviga fra la griglia, la guida TV e il player.
    func shortEPG(
        streamId: Int,
        limit: Int = 10,
        ttl: TimeInterval = 300
    ) async throws -> [EPGProgram] {
        let cacheKey = "\(credentials.host)|\(credentials.username)|\(streamId)|\(limit)"

        if let cached = await EPGCache.shared.value(for: cacheKey) {
            return cached
        }

        let host = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines)

        guard var components = URLComponents(
            string: host + "/player_api.php"
        ) else {
            throw XtreamError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "username", value: credentials.username),
            URLQueryItem(name: "password", value: credentials.password),
            URLQueryItem(name: "action", value: "get_short_epg"),
            URLQueryItem(name: "stream_id", value: String(streamId)),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        guard let url = components.url else {
            throw XtreamError.invalidURL
        }

        let (data, response) = try await session.data(from: url)

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw XtreamError.wrongCredentials
            }

            guard (200..<300).contains(http.statusCode) else {
                throw XtreamError.httpStatus(http.statusCode)
            }
        }

        struct RawEPGResponse: Decodable {
            struct RawItem: Decodable {
                let id: String?
                let title: String?
                let description: String?
                let start: String?
                let end: String?
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

        let raw: RawEPGResponse

        do {
            raw = try JSONDecoder().decode(RawEPGResponse.self, from: data)
        } catch {
            DebugLogger.logAsync(
                .warning,
                "EPG non decodificabile per stream \(streamId): \(error.localizedDescription)"
            )
            throw XtreamError.decoding(error)
        }

        let programs = raw.epgListings.compactMap { item -> EPGProgram? in
            guard
                let rawStart = item.start,
                let rawEnd = item.end,
                let start = Self.parseDate(rawStart),
                let end = Self.parseDate(rawEnd),
                end > start
            else {
                return nil
            }

            let decodedTitle = Self.decodeIfBase64(
                item.title ?? "Programma senza titolo"
            )

            return EPGProgram(
                id: item.id ?? "\(streamId)-\(rawStart)-\(rawEnd)",
                title: decodedTitle.isEmpty
                    ? "Programma senza titolo"
                    : decodedTitle,
                description: item.description.map(Self.decodeIfBase64),
                start: start,
                end: end,
                hasArchive: (item.hasArchive ?? 0) == 1
            )
        }
        .sorted { $0.start < $1.start }

        await EPGCache.shared.set(
            programs,
            for: cacheKey,
            ttl: ttl
        )

        return programs
    }

    /// Invalida l'intera guida della sorgente corrente.
    func invalidateCache() async {
        let prefix = "\(credentials.host)|\(credentials.username)|"
        await EPGCache.shared.invalidate(prefix: prefix)
    }

    private static let utcFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static func parseDate(_ value: String) -> Date? {
        if let date = utcFormatter.date(from: value) {
            return date
        }

        return ISO8601DateFormatter().date(from: value)
    }

    private static func decodeIfBase64(_ value: String) -> String {
        guard
            let data = Data(base64Encoded: value),
            let decoded = String(data: data, encoding: .utf8)
        else {
            return value
        }

        return decoded
    }

    func catchupURL(for request: CatchupRequest) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd:HH-mm"

        let startString = formatter.string(from: request.start)

        return URL(
            string: "\(credentials.host)/timeshift/" +
                "\(credentials.username)/" +
                "\(credentials.password)/" +
                "\(request.durationMinutes)/" +
                "\(startString)/" +
                "\(request.streamId).ts"
        )
    }
}
