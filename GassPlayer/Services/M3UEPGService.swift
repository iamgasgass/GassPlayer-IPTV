import Foundation
import CryptoKit

/// Guida programmi (XMLTV) per le playlist M3U.
///
/// Le playlist M3U non hanno un'API di guida come Xtream, ma di solito
/// dichiarano un file XMLTV nell'intestazione (`#EXTM3U x-tvg-url="..."`) e
/// i canali un `tvg-id`. Questo servizio:
/// 1. scarica i file XMLTV dell'intestazione + le fonti EPG esterne abilitate
///    in "Gestisci EPG" (anche `.xml.gz`), con copia su disco valida 6 ore;
/// 2. li analizza in streaming (`XMLParser`) fuori dal main thread,
///    conservando SOLO i programmi dei canali della playlist (per `tvg-id`
///    oppure per nome) e solo la finestra utile (da 1 ora fa a 36 ore avanti):
///    un XMLTV completo può pesare decine di MB;
/// 3. restituisce i programmi per canale.
actor M3UEPGService {
    static let shared = M3UEPGService()

    /// Validità della copia su disco: stessa cadenza dell'aggiornamento
    /// pianificato dell'EPG Xtream (`EPGManager`).
    private static let cacheLifetime: TimeInterval = 6 * 60 * 60

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// Programmi per canale XMLTV (chiave = id minuscolo) + mappa
    /// nome-normalizzato → id per i canali senza `tvg-id`.
    struct Guide: Sendable {
        var programsByChannelID: [String: [EPGProgram]] = [:]
        var channelIDByName: [String: String] = [:]

        var isEmpty: Bool { programsByChannelID.isEmpty }
    }

    func guide(
        urls: [URL],
        wantedIDs: Set<String>,
        wantedNames: Set<String>,
        forceRefresh: Bool
    ) async -> Guide {
        var merged = Guide()

        for url in urls {
            guard !Task.isCancelled else { return merged }

            guard let data = await xmltvData(for: url, forceRefresh: forceRefresh) else { continue }

            let parsed = XMLTVParser.parse(
                data: data,
                wantedIDs: wantedIDs,
                wantedNames: wantedNames
            )

            for (channel, programs) in parsed.programsByChannelID {
                merged.programsByChannelID[channel, default: []].append(contentsOf: programs)
            }

            merged.channelIDByName.merge(parsed.channelIDByName) { current, _ in current }
        }

        for key in merged.programsByChannelID.keys {
            merged.programsByChannelID[key]?.sort { $0.start < $1.start }
        }

        return merged
    }

    // MARK: - Download + cache

    private func xmltvData(for url: URL, forceRefresh: Bool) async -> Data? {
        let file = Self.cacheFile(for: url)

        if !forceRefresh,
           let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(date) < Self.cacheLifetime,
           let cached = try? Data(contentsOf: file, options: .mappedIfSafe) {
            return cached
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue(StreamUserAgents.vlc, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)

            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }

            // Si salva GIÀ decompresso: la prossima lettura non deve
            // inflare di nuovo decine di MB.
            let payload = GzipDecoder.decompressedIfNeeded(data)

            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? payload.write(to: file, options: .atomic)

            return payload
        } catch {
            // Rete assente o fonte non raggiungibile: meglio una guida
            // vecchia della cache che nessuna guida.
            return try? Data(contentsOf: file, options: .mappedIfSafe)
        }
    }

    func clearCache() {
        let directory = Self.cacheDirectory
        try? FileManager.default.removeItem(at: directory)
    }

    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("GassPlayerXMLTV", isDirectory: true)
    }

    private static func cacheFile(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(name + ".xml")
    }

    // MARK: - Normalizzazione nomi

    /// Minuscolo, senza accenti, solo lettere/numeri: "Rai 1 HD" e
    /// "RAI1 hd" si equivalgono.
    static func normalizedName(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}

// MARK: - Parser XMLTV

/// Parser SAX di XMLTV. Non conserva nulla che non serva: vedi
/// `M3UEPGService`.
private final class XMLTVParser: NSObject, XMLParserDelegate {
    static func parse(data: Data, wantedIDs: Set<String>, wantedNames: Set<String>) -> M3UEPGService.Guide {
        let delegate = XMLTVParser(wantedIDs: wantedIDs, wantedNames: wantedNames)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.parse()
        return delegate.guide
    }

    private let wantedIDs: Set<String>
    private let wantedNames: Set<String>

    private var guide = M3UEPGService.Guide()
    private var acceptedIDs = Set<String>()

    private let windowStart = Date().addingTimeInterval(-3600)
    private let windowEnd = Date().addingTimeInterval(36 * 3600)

    // Stato corrente
    private var currentChannelID: String?
    private var currentChannelNames: [String] = []
    private var programme: (channel: String, start: Date, stop: Date)?
    private var programmeTitle = ""
    private var programmeDescription = ""
    private var text = ""
    private var collectingText = false

    private init(wantedIDs: Set<String>, wantedNames: Set<String>) {
        self.wantedIDs = wantedIDs
        self.wantedNames = wantedNames
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "channel":
            currentChannelID = attributeDict["id"]?.lowercased()
            currentChannelNames = []

        case "display-name":
            if currentChannelID != nil { startText() }

        case "programme":
            guard let channel = attributeDict["channel"]?.lowercased(),
                  acceptedIDs.contains(channel) || wantedIDs.contains(channel),
                  let startString = attributeDict["start"],
                  let stopString = attributeDict["stop"],
                  let start = Self.parseDate(startString),
                  let stop = Self.parseDate(stopString),
                  stop > start,
                  stop > windowStart,
                  start < windowEnd else {
                programme = nil
                return
            }

            programme = (channel, start, stop)
            programmeTitle = ""
            programmeDescription = ""

        case "title":
            if programme != nil { startText() }

        case "desc":
            if programme != nil { startText() }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingText { text += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "display-name":
            if collectingText {
                currentChannelNames.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
                collectingText = false
            }

        case "channel":
            if let id = currentChannelID {
                for name in currentChannelNames {
                    let normalized = M3UEPGService.normalizedName(name)
                    guard !normalized.isEmpty else { continue }

                    if wantedNames.contains(normalized) {
                        acceptedIDs.insert(id)
                    }

                    if guide.channelIDByName[normalized] == nil {
                        guide.channelIDByName[normalized] = id
                    }
                }
            }
            currentChannelID = nil
            currentChannelNames = []

        case "title":
            if programme != nil, collectingText {
                programmeTitle = text.trimmingCharacters(in: .whitespacesAndNewlines)
                collectingText = false
            }

        case "desc":
            if programme != nil, collectingText {
                programmeDescription = text.trimmingCharacters(in: .whitespacesAndNewlines)
                collectingText = false
            }

        case "programme":
            if let programme, !programmeTitle.isEmpty {
                let item = EPGProgram(
                    id: "\(programme.channel)-\(Int(programme.start.timeIntervalSince1970))",
                    title: programmeTitle,
                    description: programmeDescription.isEmpty ? nil : programmeDescription,
                    start: programme.start,
                    end: programme.stop,
                    hasArchive: false
                )
                guide.programsByChannelID[programme.channel, default: []].append(item)
            }
            programme = nil

        default:
            break
        }
    }

    private func startText() {
        text = ""
        collectingText = true
    }

    // MARK: Date XMLTV ("20260110180000 +0100")

    /// Parsing a interi, senza `DateFormatter`: con decine di migliaia di
    /// programmi il formatter sarebbe il collo di bottiglia dell'import.
    static func parseDate(_ value: String) -> Date? {
        let bytes = Array(value.utf8)
        guard bytes.count >= 12 else { return nil }

        func number(_ range: Range<Int>) -> Int? {
            var result = 0
            for index in range {
                guard index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 else { return nil }
                result = result * 10 + Int(bytes[index] - 48)
            }
            return result
        }

        guard let year = number(0..<4),
              let month = number(4..<6),
              let day = number(6..<8),
              let hour = number(8..<10),
              let minute = number(10..<12) else {
            return nil
        }

        let second = bytes.count >= 14 ? (number(12..<14) ?? 0) : 0

        // Fuso opzionale: [spazio]±HHMM
        var offsetSeconds = 0
        var index = bytes.count >= 14 ? 14 : 12
        while index < bytes.count, bytes[index] == 32 { index += 1 }

        if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 {
            let sign = bytes[index] == 45 ? -1 : 1
            if let offsetHours = number((index + 1)..<(index + 3)),
               let offsetMinutes = number((index + 3)..<(index + 5)) {
                offsetSeconds = sign * (offsetHours * 3600 + offsetMinutes * 60)
            }
        }

        // Giorni dal 1970-01-01 (algoritmo "days from civil").
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468

        let epoch = days * 86400 + hour * 3600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: TimeInterval(epoch))
    }
}
