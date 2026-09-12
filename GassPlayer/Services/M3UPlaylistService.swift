import Foundation

/// Parser riscritto dopo ricerca sulle specifiche reali usate dai
/// provider IPTV (tag tvg-*, group-title, EXTGRP, EXTVLCOPT, KODIPROP,
/// catchup — vedi iptv-parser/iptv-m3u-playlist-parser). Il parser
/// precedente si limitava a #EXTINF + riga URL e falliva silenziosamente
/// su file con BOM, CRLF, o titoli contenenti virgole.
actor M3UPlaylistService {
    func load(from url: URL) async throws -> [M3UChannel] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw XtreamError.httpStatus(http.statusCode)
        }
        guard let text = decodeText(from: data) else {
            throw XtreamError.decoding(NSError(domain: "GassPlayer", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Impossibile decodificare la playlist (encoding non riconosciuto)."]))
        }
        let channels = parse(text)
        if channels.isEmpty {
            DebugLogger.logAsync(.warning, "Playlist M3U caricata ma senza canali validi (controllare il formato)")
        }
        return channels
    }

    /// Gestisce BOM UTF-8 e fallback a Latin-1 per playlist mal codificate
    /// (problema comune con provider più vecchi, segnalato spesso nei forum IPTV).
    private func decodeText(from data: Data) -> String? {
        var cleaned = data
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        if cleaned.starts(with: bom) { cleaned.removeFirst(3) }
        return String(data: cleaned, encoding: .utf8) ?? String(data: cleaned, encoding: .isoLatin1)
    }

    func parse(_ content: String) -> [M3UChannel] {
        guard content.contains("#EXTM3U") else {
            DebugLogger.logAsync(.error, "File non è una playlist M3U valida (manca #EXTM3U)")
            return []
        }

        var channels: [M3UChannel] = []
        var pendingTitle: String?
        var pendingLogo: String?
        var pendingGroup: String?
        var pendingTvgId: String?
        var pendingCatchupDays: Int?

        // Normalizza CRLF/CR in LF prima dello split, altrimenti righe con
        // solo \r finale non vengono riconosciute come vuote/URL valide.
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
                                 .replacingOccurrences(of: "\r", with: "\n")

        for rawLine in normalized.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#EXTINF") {
                pendingTitle = extractTitle(from: line)
                pendingLogo = extractAttribute("tvg-logo", from: line)
                pendingGroup = extractAttribute("group-title", from: line) ?? extractAttribute("EXTGRP", from: line)
                pendingTvgId = extractAttribute("tvg-id", from: line)
                if let catchupValue = extractAttribute("catchup-days", from: line) {
                    pendingCatchupDays = Int(catchupValue)
                }
            } else if line.hasPrefix("#EXTGRP:") {
                pendingGroup = String(line.dropFirst("#EXTGRP:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("#EXTVLCOPT") || line.hasPrefix("#KODIPROP") || line.hasPrefix("#EXT-X-") {
                // Tag di metadata riconosciuti ma non necessari alla riproduzione
                // base: li ignoriamo esplicitamente invece di lasciarli rompere
                // il parsing (comportamento del parser precedente).
                continue
            } else if line.hasPrefix("#") {
                continue
            } else if let url = URL(string: line), url.scheme != nil {
                channels.append(M3UChannel(
                    title: pendingTitle ?? url.lastPathComponent,
                    logoURL: pendingLogo, groupTitle: pendingGroup, tvgId: pendingTvgId,
                    catchupDays: pendingCatchupDays, streamURL: url
                ))
                pendingTitle = nil; pendingLogo = nil; pendingGroup = nil
                pendingTvgId = nil; pendingCatchupDays = nil
            }
        }
        return channels
    }

    /// Il titolo è tutto ciò che segue l'ULTIMA virgola prima di fine riga,
    /// ma solo se non è dentro un attributo tra virgolette: usiamo la virgola
    /// dopo l'ultima chiusura `"` per evitare di troncare titoli che
    /// contengono virgole (es. "Canale, Edizione Serale").
    private func extractTitle(from line: String) -> String? {
        guard let lastQuote = line.lastIndex(of: "\"") else {
            return line.components(separatedBy: ",").last?.trimmingCharacters(in: .whitespaces)
        }
        let afterAttributes = line[line.index(after: lastQuote)...]
        guard let commaIndex = afterAttributes.firstIndex(of: ",") else { return nil }
        let title = afterAttributes[afterAttributes.index(after: commaIndex)...]
        return title.trimmingCharacters(in: .whitespaces)
    }

    private func extractAttribute(_ key: String, from line: String) -> String? {
        guard let range = line.range(of: "\(key)=\"") else { return nil }
        let after = line[range.upperBound...]
        guard let end = after.firstIndex(of: "\"") else { return nil }
        return String(after[..<end])
    }
}
