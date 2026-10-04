import Foundation
import CryptoKit

/// Scarica, decodifica e analizza le playlist M3U/M3U8, con cache su disco.
///
/// OTTIMIZZAZIONI (cambio playlist e avvio):
/// - copia su disco del testo della playlist (`Caches`): al cambio sorgente
///   o al riavvio la playlist si mostra subito dalla copia locale e si
///   aggiorna in background solo se è "vecchia";
/// - download con User-Agent VLC (o quello dell'utente), accettato dalla
///   maggior parte dei provider, e supporto ai file `.gz`;
/// - parser a passata singola su `Substring` (nessuna copia per riga, nessun
///   `components(separatedBy:)` sull'intero file), con titolo corretto anche
///   quando contiene virgole.
actor M3UPlaylistService {
    static let shared = M3UPlaylistService()

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 180
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    // MARK: - Rete + cache

    struct CachedPlaylist: Sendable {
        let text: String
        let savedAt: Date
    }

    /// Testo della playlist salvato su disco (se c'è), con la data di salvataggio.
    func cachedText(for url: URL) -> CachedPlaylist? {
        let file = Self.cacheFile(for: url)

        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast

        return CachedPlaylist(text: text, savedAt: date)
    }

    func downloadText(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.setValue(StreamUserAgents.vlc, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        let payload = GzipDecoder.decompressedIfNeeded(data)

        guard let text = String(data: payload, encoding: .utf8)
                ?? String(data: payload, encoding: .isoLatin1) else {
            throw URLError(.cannotDecodeContentData)
        }

        saveToCache(text, for: url)
        return text
    }

    func removeCache(for url: URL) {
        try? FileManager.default.removeItem(at: Self.cacheFile(for: url))
    }

    private func saveToCache(_ text: String, for url: URL) {
        let file = Self.cacheFile(for: url)
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data(text.utf8).write(to: file, options: .atomic)
    }

    private static func cacheFile(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()

        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory

        return base
            .appendingPathComponent("GassPlayerM3U", isDirectory: true)
            .appendingPathComponent(name + ".m3u")
    }

    // MARK: - Parsing

    /// Scarica (o legge) e indicizza una playlist.
    func load(from url: URL) async throws -> M3UPlaylistSnapshot {
        M3UPlaylistSnapshot(parse(try await downloadText(from: url)))
    }

    func snapshot(fromText text: String) -> M3UPlaylistSnapshot {
        M3UPlaylistSnapshot(parse(text))
    }

    func parse(_ content: String) -> M3UParseResult {
        var channels: [M3UChannel] = []
        channels.reserveCapacity(content.utf8.count / 140)

        var epgURLs: [String] = []

        var pendingTitle: String?
        var pendingLogo: String?
        var pendingGroup: String?
        var pendingTvgId: String?
        var pendingTvgName: String?
        var pendingTvgType: String?

        var idCounts: [String: Int] = [:]

        content.enumerateLines { rawLine, _ in
            var line = Substring(rawLine)
            while let first = line.first, first.isWhitespace || first == "\u{FEFF}" { line.removeFirst() }
            while let last = line.last, last.isWhitespace { line.removeLast() }

            guard !line.isEmpty else { return }

            if line.hasPrefix("#") {
                if line.hasPrefix("#EXTINF") {
                    let (attributes, title) = Self.splitExtinf(line)

                    pendingTitle = title.isEmpty ? nil : title
                    pendingLogo = Self.attribute("tvg-logo", in: attributes)
                    pendingGroup = Self.attribute("group-title", in: attributes)
                    pendingTvgId = Self.attribute("tvg-id", in: attributes)
                    pendingTvgName = Self.attribute("tvg-name", in: attributes)
                    pendingTvgType = Self.attribute("tvg-type", in: attributes)
                } else if line.hasPrefix("#EXTGRP:") {
                    if pendingGroup == nil {
                        let group = line.dropFirst("#EXTGRP:".count).trimmingCharacters(in: .whitespaces)
                        if !group.isEmpty { pendingGroup = group }
                    }
                } else if line.hasPrefix("#EXTM3U") {
                    let header = String(line)
                    for key in ["x-tvg-url", "url-tvg", "tvg-url"] {
                        if let value = Self.attribute(key, in: header) {
                            epgURLs.append(contentsOf: value
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty })
                        }
                    }
                }
                return
            }

            guard let url = Self.makeURL(String(line)) else {
                pendingTitle = nil; pendingLogo = nil; pendingGroup = nil
                pendingTvgId = nil; pendingTvgName = nil; pendingTvgType = nil
                return
            }

            let title = pendingTitle ?? pendingTvgName ?? url.lastPathComponent

            var id = url.absoluteString
            let count = idCounts[id, default: 0]
            idCounts[id] = count + 1
            if count > 0 { id += "#\(count + 1)" }

            channels.append(M3UChannel(
                id: id,
                title: title,
                logoURL: pendingLogo,
                groupTitle: pendingGroup,
                tvgId: pendingTvgId,
                tvgName: pendingTvgName,
                streamURL: url,
                kind: Self.classifyKind(title: title, groupTitle: pendingGroup, tvgType: pendingTvgType)
            ))

            pendingTitle = nil; pendingLogo = nil; pendingGroup = nil
            pendingTvgId = nil; pendingTvgName = nil; pendingTvgType = nil
        }

        var seen = Set<String>()
        epgURLs = epgURLs.filter { seen.insert($0).inserted }

        return M3UParseResult(channels: channels, epgURLs: epgURLs)
    }

    /// Divide `#EXTINF:-1 tvg-id="x" group-title="A, B",Titolo` in
    /// (attributi, titolo): la virgola che separa il titolo è l'ULTIMA fuori
    /// dalle virgolette (prima si prendeva l'ultimo pezzo dopo ogni virgola,
    /// quindi un titolo come "Rai 1, HD" veniva troncato a "HD").
    private static func splitExtinf(_ line: Substring) -> (attributes: String, title: String) {
        var inQuotes = false
        var lastComma: Substring.Index?

        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" { inQuotes.toggle() }
            else if character == ",", !inQuotes { lastComma = index }
            index = line.index(after: index)
        }

        guard let lastComma else { return (String(line), "") }

        let attributes = String(line[..<lastComma])
        let title = line[line.index(after: lastComma)...].trimmingCharacters(in: .whitespaces)
        return (attributes, title)
    }

    private static func makeURL(_ string: String) -> URL? {
        if let url = URL(string: string) { return url }

        var allowed = CharacterSet.urlQueryAllowed
        allowed.formUnion(CharacterSet(charactersIn: "#%"))
        return string.addingPercentEncoding(withAllowedCharacters: allowed).flatMap(URL.init(string:))
    }

    /// Le playlist M3U non hanno un campo "tipo contenuto" standard come
    /// Xtream Codes (`get_vod_streams` vs `get_live_streams`). Deduciamo
    /// il tipo con priorità decrescente:
    /// 1. `tvg-type` esplicito, se il provider lo fornisce (non standard
    ///    ma usato da alcuni: "movie", "series", "live")
    /// 2. parole chiave nel `group-title` (es. "VOD", "Movies", "Series")
    /// 3. pattern SxxExx nel titolo (tipico delle serie TV: "S01E02")
    /// 4. fallback: Live TV (comportamento sicuro, la maggior parte delle
    ///    playlist pubbliche come Free-TV/IPTV sono canali live)
    static func classifyKind(title: String, groupTitle: String?, tvgType: String?) -> XtreamStreamKind {
        if let tvgType {
            let normalized = tvgType.lowercased()
            if normalized.contains("movie") || normalized.contains("vod") { return .movie }
            if normalized.contains("series") || normalized.contains("show") { return .series }
            if normalized.contains("live") || normalized.contains("channel") { return .live }
        }

        if let groupTitle {
            let normalized = groupTitle.lowercased()
            let movieKeywords = ["vod", "movie", "film", "cinema"]
            let seriesKeywords = ["serie", "series", "tv show", "show"]
            if movieKeywords.contains(where: normalized.contains) { return .movie }
            if seriesKeywords.contains(where: normalized.contains) { return .series }
        }

        if title.range(of: #"S\d{1,2}E\d{1,2}"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .series
        }

        return .live
    }

    private static func attribute(_ key: String, in line: String) -> String? {
        guard let range = line.range(of: "\(key)=\"") else { return nil }
        let after = line[range.upperBound...]
        guard let end = after.firstIndex(of: "\"") else { return nil }

        let value = after[..<end].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
