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

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF") {
                pendingTitle = line.components(separatedBy: ",").last
                pendingLogo = extractAttribute("tvg-logo", from: line)
                pendingGroup = extractAttribute("group-title", from: line)
                pendingTvgId = extractAttribute("tvg-id", from: line)
                pendingTvgType = extractAttribute("tvg-type", from: line)
            } else if !line.isEmpty, !line.hasPrefix("#"), let url = URL(string: line) {
                let title = pendingTitle ?? url.lastPathComponent
                channels.append(M3UChannel(
                    title: title,
                    logoURL: pendingLogo,
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

    private func extractAttribute(_ key: String, from line: String) -> String? {
        guard let range = line.range(of: "\(key)=\"") else { return nil }
        let after = line[range.upperBound...]
        guard let end = after.firstIndex(of: "\"") else { return nil }
        return String(after[..<end])
    }
}
