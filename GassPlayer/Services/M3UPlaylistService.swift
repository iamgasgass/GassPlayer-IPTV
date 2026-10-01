import Foundation

actor M3UPlaylistService {
    func load(from url: URL) async throws -> [M3UChannel] {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return []
        }
        return parse(text)
    }

    func parse(_ content: String) -> [M3UChannel] {
        var channels: [M3UChannel] = []
        var pendingTitle: String?
        var pendingLogo: String?
        var pendingGroup: String?
        var pendingTvgId: String?
        var pendingTvgType: String?

        // BOM iniziale: senza toglierlo la prima riga "#EXTM3U" non è riconosciuta.
        let text = content.hasPrefix("\u{FEFF}") ? String(content.dropFirst()) : content

        text.enumerateLines { rawLine, _ in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { return }

            if line.hasPrefix("#EXTINF") {
                pendingTitle = Self.extractTitle(from: line)
                // Il logo può avere nomi diversi a seconda del generatore di playlist.
                pendingLogo = Self.firstAttribute(["tvg-logo", "tvg_logo", "logo", "tvg-icon"], in: line)
                pendingGroup = Self.extractAttribute("group-title", from: line)
                pendingTvgId = Self.extractAttribute("tvg-id", from: line)
                pendingTvgType = Self.extractAttribute("tvg-type", from: line)
            } else if !line.hasPrefix("#"), let url = Self.streamURL(from: line) {
                let title = pendingTitle?.nonEmptyTrimmed ?? url.lastPathComponent
                channels.append(M3UChannel(
                    title: title,
                    logoURL: ImageURLNormalizer.normalizedString(pendingLogo),
                    groupTitle: pendingGroup,
                    tvgId: pendingTvgId,
                    streamURL: url,
                    kind: Self.classifyKind(title: title, groupTitle: pendingGroup, tvgType: pendingTvgType)
                ))
                pendingTitle = nil; pendingLogo = nil; pendingGroup = nil; pendingTvgId = nil; pendingTvgType = nil
            }
        }
        return channels
    }

    /// URL dello stream: alcune playlist contengono spazi o caratteri non
    /// ASCII non codificati, per cui `URL(string:)` restituiva `nil` e il
    /// canale spariva dall'elenco.
    private static func streamURL(from line: String) -> URL? {
        if let url = URL(string: line), url.scheme != nil { return url }
        if let encoded = line.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.urlQueryAllowed.union(.urlPathAllowed).union(CharacterSet(charactersIn: "%#"))
        ), let url = URL(string: encoded), url.scheme != nil {
            return url
        }
        return nil
    }

    /// Titolo = testo dopo l'ULTIMA virgola fuori dalle virgolette (le
    /// virgole dentro `tvg-name="..."` o nel titolo stesso non lo troncano).
    private static func extractTitle(from line: String) -> String? {
        var insideQuotes = false
        var lastComma: String.Index?
        for index in line.indices {
            let character = line[index]
            if character == "\"" { insideQuotes.toggle() }
            else if character == "," && !insideQuotes { lastComma = index }
        }
        guard let lastComma else { return nil }
        return String(line[line.index(after: lastComma)...])
    }

    private static func firstAttribute(_ keys: [String], in line: String) -> String? {
        for key in keys {
            if let value = extractAttribute(key, from: line), !value.isEmpty { return value }
        }
        return nil
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

    private static func extractAttribute(_ key: String, from line: String) -> String? {
        for quote in ["\"", "'"] {
            guard let range = line.range(of: "\(key)=\(quote)", options: .caseInsensitive) else { continue }
            let after = line[range.upperBound...]
            guard let end = after.firstIndex(of: Character(quote)) else { continue }
            let value = String(after[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
