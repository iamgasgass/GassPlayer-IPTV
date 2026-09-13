import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
        var pendingURL: URL?

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if line.hasPrefix("#EXTINF") {
                // Do not split the metadata line by comma: movie titles frequently contain commas.
                pendingTitle = Self.extractEXTINFTitle(from: line)
                pendingLogo = extractAttribute("tvg-logo", from: line)
                pendingGroup = extractAttribute("group-title", from: line)
                pendingTvgId = extractAttribute("tvg-id", from: line)
                pendingTvgType = extractAttribute("tvg-type", from: line)
            } else if !line.isEmpty, !line.hasPrefix("#"), let url = URL(string: line) {
                pendingURL = url
                let title = pendingTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? url.lastPathComponent
                channels.append(M3UChannel(
                    title: title,
                    logoURL: pendingLogo?.nilIfEmpty,
                    groupTitle: pendingGroup?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                    tvgId: pendingTvgId?.nilIfEmpty,
                    streamURL: url,
                    kind: Self.classifyKind(title: title, groupTitle: pendingGroup, tvgType: pendingTvgType, streamURL: pendingURL)
                ))
                pendingTitle = nil
                pendingLogo = nil
                pendingGroup = nil
                pendingTvgId = nil
                pendingTvgType = nil
                pendingURL = nil
            }
        }
        return channels
    }

    static func classifyKind(title: String, groupTitle: String?, tvgType: String?, streamURL: URL? = nil) -> XtreamStreamKind {
        let type = tvgType?.normalizedSearch ?? ""
        if type.containsAny(["movie", "vod", "film"]) { return .movie }
        if type.containsAny(["series", "show", "serie"]) { return .series }
        if type.containsAny(["live", "channel", "tv"]) { return .live }

        let group = groupTitle?.normalizedSearch ?? ""
        if group.containsAny(["vod", "movie", "movies", "film", "films", "cinema", "cinema", "4k movies"]) { return .movie }
        if group.containsAny(["serie", "series", "tv show", "tv shows", "season", "stagioni", "episodi", "episode"]) { return .series }

        let combined = "\(title) \(groupTitle ?? "")".normalizedSearch
        // Common playlist conventions. This is deliberately conservative around Live TV.
        if combined.range(of: #"\b(s\d{1,2}\s*e\d{1,2}|season\s*\d+|stagione\s*\d+|episodio\s*\d+)\b"#, options: .regularExpression) != nil {
            return .series
        }

        // URL/path is often the only reliable signal in M3U exports.
        let path = streamURL?.absoluteString.normalizedSearch ?? ""
        if path.containsAny(["/movie/", "/movies/", "/vod/", "/film/"]) { return .movie }
        if path.containsAny(["/series/", "/serie/", "/tvshows/", "/shows/"]) { return .series }

        // File extensions are a useful secondary signal for VOD exports.
        let ext = streamURL?.pathExtension.lowercased() ?? ""
        if ["mp4", "mkv", "avi", "mov", "m4v", "webm"].contains(ext) { return .movie }

        return .live
    }

    private static func extractEXTINFTitle(from line: String) -> String? {
        guard let comma = line.firstIndex(of: ",") else { return nil }
        return String(line[line.index(after: comma)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractAttribute(_ key: String, from line: String) -> String? {
        // Accept both quoted and unquoted values used by real-world M3U generators.
        if let range = line.range(of: "\(key)=\"", options: .caseInsensitive) {
            let after = line[range.upperBound...]
            if let end = after.firstIndex(of: "\"") { return String(after[..<end]) }
        }
        let pattern = "\\b#?" + key + "\\s*=\\s*([^\\s,]+)"
        if let range = line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            let match = String(line[range])
            if let equal = match.firstIndex(of: "=") {
                return String(match[match.index(after: equal)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

private extension String {
    var normalizedSearch: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }
    func containsAny(_ values: [String]) -> Bool { values.contains { normalizedSearch.contains($0) } }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
