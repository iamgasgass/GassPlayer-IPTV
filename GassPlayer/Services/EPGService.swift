import Foundation

/// Servizio EPG (Electronic Program Guide) per sorgenti Xtream.
///
/// Strategia di robustezza:
/// - `shortEPG` tenta prima `get_short_epg` (leggero, limitato); se la
///   risposta e' vuota, malformata o l'azione fallisce, esegue in automatico
///   il fallback su `get_simple_data_table` (guida completa del canale);
/// - il decoder accetta id/flag/numeri sia come stringa sia come numero
///   nativo JSON, perche' i provider Xtream non sono uniformi tra loro;
/// - le date sono lette prioritariamente da `start_timestamp`/
///   `stop_timestamp` (Unix time, senza ambiguita' di timezone); in assenza
///   di timestamp si tenta un parsing testuale su piu' formati comuni;
/// - titoli e descrizioni vengono decodificati da Base64 solo se il
///   risultato e' testo valido non vuoto, altrimenti si mantiene il valore
///   originale cosi' come ricevuto dal provider;
/// - i risultati sono ordinati per orario di inizio e deduplicati per id
///   (o per firma start+end+titolo quando l'id manca).
struct EPGService {
    let credentials: XtreamCredentials

    private let session: URLSession
    private let cachePrefix: String

    private static let shortEPGTTL: TimeInterval = 5 * 60
    private static let fullEPGTTL: TimeInterval = 15 * 60
    private static let maximumShortLimit = 100
    private static let maximumPrograms = 2_000

    init(
        credentials: XtreamCredentials,
        session: URLSession = .shared
    ) {
        self.credentials = credentials
        self.session = session
        self.cachePrefix = Self.makeCachePrefix(credentials: credentials)
    }

    // MARK: - Public API

    /// Programmi imminenti/brevi per un canale. Tenta `get_short_epg`;
    /// se vuoto o fallito, usa `fullEPG` come fallback e ne restituisce
    /// solo i primi `limit` elementi utili.
    func shortEPG(
        streamId: Int,
        limit: Int = 10,
        forceRefresh: Bool = false
    ) async throws -> [EPGProgram] {
        let boundedLimit = min(max(limit, 1), Self.maximumShortLimit)
        let key = shortCacheKey(streamId: streamId, limit: boundedLimit)

        if !forceRefresh,
           let cached: [EPGProgram] = await CacheService.shared.value(for: key) {
            return cached
        }

        let result: [EPGProgram]

        do {
            let payload = try await performRequest(
                action: "get_short_epg",
                extra: [
                    "stream_id": String(streamId),
                    "limit": String(boundedLimit)
                ]
            )

            let decoded = normalize(try decodePrograms(from: payload))

            if decoded.isEmpty {
                DebugLogger.logAsync(
                    .warning,
                    "EPG: get_short_epg vuoto per stream \(streamId), fallback a get_simple_data_table"
                )

                let fallback = try await fullEPG(
                    streamId: streamId,
                    forceRefresh: forceRefresh
                )

                result = Array(fallback.prefix(boundedLimit))
            } else {
                result = Array(decoded.prefix(boundedLimit))
            }
        } catch {
            DebugLogger.logAsync(
                .warning,
                "EPG: get_short_epg fallito per stream \(streamId): \(error.localizedDescription). Fallback a get_simple_data_table"
            )

            let fallback = try await fullEPG(
                streamId: streamId,
                forceRefresh: forceRefresh
            )

            result = Array(fallback.prefix(boundedLimit))
        }

        await CacheService.shared.set(result, for: key, ttl: Self.shortEPGTTL)
        return result
    }

    /// Guida completa disponibile per un canale, tramite
    /// `get_simple_data_table`. E' il fallback autorevole quando la short
    /// EPG e' assente o insufficiente per popolare una griglia temporale.
    func fullEPG(
        streamId: Int,
        forceRefresh: Bool = false
    ) async throws -> [EPGProgram] {
        let key = fullCacheKey(streamId: streamId)

        if !forceRefresh,
           let cached: [EPGProgram] = await CacheService.shared.value(for: key) {
            return cached
        }

        let payload = try await performRequest(
            action: "get_simple_data_table",
            extra: ["stream_id": String(streamId)]
        )

        let result = Array(
            normalize(try decodePrograms(from: payload)).prefix(Self.maximumPrograms)
        )

        await CacheService.shared.set(result, for: key, ttl: Self.fullEPGTTL)
        return result
    }

    /// Invalida tutte le voci di cache EPG (breve e completa) relative a
    /// un singolo canale, senza toccare la cache di altri canali o del
    /// catalogo Xtream.
    func invalidateEPG(streamId: Int) async {
        await CacheService.shared.invalidate(
            prefix: "\(cachePrefix).short.\(streamId)."
        )

        await CacheService.shared.removeValue(
            for: fullCacheKey(streamId: streamId)
        )
    }

    /// URL di riproduzione in differita (timeshift) per un programma.
    /// Restituisce `nil` se l'host non e' un URL http/https valido.
    func catchupURL(for request: CatchupRequest) -> URL? {
        guard let baseURL = normalizedHostURL() else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd:HH-mm"

        return appendPath(
            to: baseURL,
            components: [
                "timeshift",
                credentials.username,
                credentials.password,
                String(max(1, request.durationMinutes)),
                formatter.string(from: request.start),
                "\(request.streamId).ts"
            ]
        )
    }

    // MARK: - Network

    private func performRequest(
        action: String,
        extra: [String: String]
    ) async throws -> Data {
        let url = try endpoint(action: action, extra: extra)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "application/json, text/plain, */*",
            forHTTPHeaderField: "Accept"
        )

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

    private func endpoint(
        action: String,
        extra: [String: String]
    ) throws -> URL {
        guard let host = normalizedHostURL(),
              var components = URLComponents(
                url: host.appendingPathComponent("player_api.php"),
                resolvingAgainstBaseURL: false
              ) else {
            throw XtreamError.malformedHost(credentials.host)
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

        guard let url = components.url else {
            throw XtreamError.invalidURL
        }

        return url
    }

    // MARK: - Decoding

    private func decodePrograms(from data: Data) throws -> [EPGProgram] {
        if isEmptyPayload(data) {
            return []
        }

        do {
            return try JSONDecoder()
                .decode(RawResponse.self, from: data)
                .items
                .compactMap(makeProgram)
        } catch {
            throw XtreamError.decoding(error)
        }
    }

    private func makeProgram(from item: RawProgram) -> EPGProgram? {
        guard let start = item.startDate,
              let end = item.endDate,
              end > start else {
            return nil
        }

        let title = Self.decodeBase64IfNeeded(item.title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !title.isEmpty else {
            return nil
        }

        let description = item.programDescription
            .map {
                Self.decodeBase64IfNeeded($0)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .flatMap { $0.isEmpty ? nil : $0 }

        let fallbackID = [
            String(Int(start.timeIntervalSince1970)),
            String(Int(end.timeIntervalSince1970)),
            title
        ]
        .joined(separator: "|")

        return EPGProgram(
            id: item.id ?? item.epgID ?? fallbackID,
            title: title,
            description: description,
            start: start,
            end: end,
            hasArchive: item.hasArchive
        )
    }

    private func normalize(_ programs: [EPGProgram]) -> [EPGProgram] {
        var seen = Set<String>()

        return programs
            .sorted {
                if $0.start == $1.start {
                    return $0.end < $1.end
                }

                return $0.start < $1.start
            }
            .filter { program in
                let key = program.id.isEmpty
                    ? "\(program.start.timeIntervalSince1970)|\(program.end.timeIntervalSince1970)|\(program.title)"
                    : program.id

                return seen.insert(key).inserted
            }
    }

    private struct RawResponse: Decodable {
        let items: [RawProgram]

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(),
               let array = try? single.decode([RawProgram].self) {
                items = array
                return
            }

            let container = try decoder.container(keyedBy: DynamicCodingKey.self)

            for name in ["epg_listings", "epgListings", "listings", "programs", "data"] {
                let key = DynamicCodingKey(stringValue: name)

                if let array = try? container.decode([RawProgram].self, forKey: key) {
                    items = array
                    return
                }
            }

            items = []
        }
    }

    private struct RawProgram: Decodable {
        let id: String?
        let epgID: String?
        let title: String?
        let programDescription: String?
        let start: String?
        let end: String?
        let startTimestamp: Int?
        let stopTimestamp: Int?
        let hasArchive: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case epgID = "epg_id"
            case title
            case programDescription = "description"
            case start
            case end
            case startTimestamp = "start_timestamp"
            case stopTimestamp = "stop_timestamp"
            case hasArchive = "has_archive"
        }

        var startDate: Date? {
            if let startTimestamp, startTimestamp > 0 {
                return Date(timeIntervalSince1970: TimeInterval(startTimestamp))
            }

            return start.flatMap(EPGService.parseDate)
        }

        var endDate: Date? {
            if let stopTimestamp, stopTimestamp > 0 {
                return Date(timeIntervalSince1970: TimeInterval(stopTimestamp))
            }

            return end.flatMap(EPGService.parseDate)
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            id = container.flexibleString(forKey: .id)
            epgID = container.flexibleString(forKey: .epgID)
            title = container.flexibleString(forKey: .title)
            programDescription = container.flexibleString(forKey: .programDescription)
            start = container.flexibleString(forKey: .start)
            end = container.flexibleString(forKey: .end)
            startTimestamp = container.flexibleInt(forKey: .startTimestamp)
            stopTimestamp = container.flexibleInt(forKey: .stopTimestamp)
            hasArchive = container.flexibleBool(forKey: .hasArchive) ?? false
        }
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    // MARK: - Date handling

    private static func parseDate(_ value: String) -> Date? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return nil
        }

        if let timestamp = TimeInterval(normalized), timestamp > 0 {
            return Date(timeIntervalSince1970: timestamp)
        }

        for formatter in dateFormatters {
            if let date = formatter.date(from: normalized) {
                return date
            }
        }

        return iso8601.date(from: normalized) ?? iso8601Fractional.date(from: normalized)
    }

    private static let dateFormatters: [DateFormatter] = [
        makeFormatter("yyyy-MM-dd HH:mm:ss", timeZone: .autoupdatingCurrent),
        makeFormatter("yyyy-MM-dd HH:mm", timeZone: .autoupdatingCurrent),
        makeFormatter("yyyy-MM-dd'T'HH:mm:ss", timeZone: .autoupdatingCurrent),
        makeFormatter("yyyy-MM-dd'T'HH:mm:ssZ", timeZone: TimeZone(secondsFromGMT: 0) ?? .gmt),
        makeFormatter("yyyy-MM-dd'T'HH:mm:ss.SSSZ", timeZone: TimeZone(secondsFromGMT: 0) ?? .gmt)
    ]

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter
    }()

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
            .withColonSeparatorInTimeZone
        ]
        return formatter
    }()

    private static func makeFormatter(
        _ format: String,
        timeZone: TimeZone
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    // MARK: - Cache keys

    private func shortCacheKey(streamId: Int, limit: Int) -> String {
        "\(cachePrefix).short.\(streamId).\(limit)"
    }

    private func fullCacheKey(streamId: Int) -> String {
        "\(cachePrefix).full.\(streamId)"
    }

    // MARK: - URL helpers

    private func normalizedHostURL() -> URL? {
        let raw = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines)

        guard var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            return nil
        }

        components.query = nil
        components.fragment = nil

        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }

        return components.url
    }

    private func appendPath(
        to baseURL: URL,
        components: [String]
    ) -> URL? {
        guard var urlComponents = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }

        let encoded = components.map {
            $0.addingPercentEncoding(withAllowedCharacters: .epgPathSegmentAllowed) ?? $0
        }

        let existingPath = urlComponents.percentEncodedPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let pathComponents = existingPath.isEmpty ? encoded : [existingPath] + encoded

        urlComponents.percentEncodedPath = "/" + pathComponents.joined(separator: "/")

        return urlComponents.url
    }

    // MARK: - Validation

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

    // MARK: - Payload handling

    private func isEmptyPayload(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }

        if let array = object as? [Any] {
            return array.isEmpty
        }

        if let dictionary = object as? [String: Any] {
            return dictionary.isEmpty
        }

        return false
    }

    private static func decodeBase64IfNeeded(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return value
        }

        let standard = trimmed
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padded = standard + String(
            repeating: "=",
            count: (4 - standard.count % 4) % 4
        )

        guard let data = Data(base64Encoded: padded, options: [.ignoreUnknownCharacters]),
              let decoded = String(data: data, encoding: .utf8) else {
            return value
        }

        let result = decoded.trimmingCharacters(in: .whitespacesAndNewlines)

        return result.isEmpty ? value : result
    }

    private static func makeCachePrefix(credentials: XtreamCredentials) -> String {
        let host = credentials.host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()

        let input = "\(host)|\(credentials.username)"

        let digest = input.utf8.reduce(
            UInt64(14_695_981_039_346_656_037)
        ) { partial, byte in
            (partial ^ UInt64(byte)) &* UInt64(1_099_511_628_211)
        }

        return "epg.\(String(digest, radix: 16))"
    }
}

// MARK: - Flexible JSON decoding helpers

private extension KeyedDecodingContainer {
    func flexibleString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }

        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }

        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value.rounded() == value ? String(Int(value)) : String(value)
        }

        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value ? "1" : "0"
        }

        return nil
    }

    func flexibleInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }

        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }

        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return nil
    }

    func flexibleBool(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }

        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }

        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value != 0
        }

        if let value = try? decodeIfPresent(String.self, forKey: key) {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "y":
                return true
            case "0", "false", "no", "n", "":
                return false
            default:
                return nil
            }
        }

        return nil
    }
}

private extension CharacterSet {
    static let epgPathSegmentAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return allowed
    }()
}
