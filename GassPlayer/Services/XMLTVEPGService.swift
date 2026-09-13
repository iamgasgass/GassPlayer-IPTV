import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct XMLTVEPGService {
    func load(from url: URL) async throws -> [String: [EPGProgram]] {
        let (data, _) = try await URLSession.shared.data(from: url)
        let parser = XMLTVParser(data: data)
        return try parser.parse()
    }
}

private final class XMLTVParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var buffer = ""
    private var currentChannelID: String?
    private var programmeChannelID: String?
    private var programmeID = ""
    private var programmeStart: Date?
    private var programmeEnd: Date?
    private var title = ""
    private var desc = ""
    private var programs: [String: [EPGProgram]] = [:]

    init(data: Data) { self.data = data }

    func parse() throws -> [String: [EPGProgram]] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { throw parser.parserError ?? NSError(domain: "XMLTV", code: 1) }
        return programs
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        buffer = ""
        switch elementName {
        case "channel":
            currentChannelID = attributeDict["id"]
        case "programme":
            programmeChannelID = attributeDict["channel"]
            programmeID = attributeDict["id"] ?? UUID().uuidString
            programmeStart = Self.parseDate(attributeDict["start"])
            programmeEnd = Self.parseDate(attributeDict["stop"])
            title = ""
            desc = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "title": title = value
        case "desc": desc = value
        case "programme":
            if let channel = programmeChannelID, let start = programmeStart, let end = programmeEnd,
               end > start, !title.isEmpty {
                programs[channel, default: []].append(EPGProgram(
                    id: programmeID, title: title, description: desc.isEmpty ? nil : desc,
                    start: start, end: end, hasArchive: false
                ))
            }
            programmeChannelID = nil
        case "channel":
            currentChannelID = nil
        default:
            break
        }
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(trimmed.prefix(14))
        let offset = trimmed.dropFirst(14).trimmingCharacters(in: .whitespaces).split(separator: " ").first
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        if let offset, offset.count == 5 {
            let sign = offset.first == "-" ? -1 : 1
            let digits = offset.dropFirst()
            if let hh = Int(digits.prefix(2)), let mm = Int(digits.suffix(2)) {
                f.timeZone = TimeZone(secondsFromGMT: sign * (hh * 3600 + mm * 60))
            }
        } else {
            f.timeZone = .current
        }
        return f.date(from: value)
    }
}
