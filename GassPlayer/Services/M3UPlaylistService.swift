import Foundation

actor M3UPlaylistService {
    func load(from url: URL) async throws -> [M3UChannel] {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return parse(text)
    }

    func parse(_ content: String) -> [M3UChannel] {
        var channels: [M3UChannel] = []
        var pendingTitle: String?
        var pendingLogo: String?
        var pendingGroup: String?
        var pendingTvgId: String?

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF") {
                pendingTitle = line.components(separatedBy: ",").last
                pendingLogo = extractAttribute("tvg-logo", from: line)
                pendingGroup = extractAttribute("group-title", from: line)
                pendingTvgId = extractAttribute("tvg-id", from: line)
            } else if !line.isEmpty, !line.hasPrefix("#"), let url = URL(string: line) {
                channels.append(M3UChannel(
                    title: pendingTitle ?? url.lastPathComponent,
                    logoURL: pendingLogo, groupTitle: pendingGroup, tvgId: pendingTvgId, streamURL: url
                ))
                pendingTitle = nil; pendingLogo = nil; pendingGroup = nil; pendingTvgId = nil
            }
        }
        return channels
    }

    private func extractAttribute(_ key: String, from line: String) -> String? {
        guard let range = line.range(of: "\(key)=\"") else { return nil }
        let after = line[range.upperBound...]
        guard let end = after.firstIndex(of: "\"") else { return nil }
        return String(after[..<end])
    }
}
