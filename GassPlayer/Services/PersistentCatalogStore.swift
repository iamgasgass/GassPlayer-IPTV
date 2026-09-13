import Foundation

/// Snapshot persistente del catalogo Xtream.
/// I dati salvati contengono solo metadati del catalogo (categorie, ID, titoli,
/// icone e classificazione) e non memorizzano password, token o URL streaming
/// autenticati.
actor PersistentCatalogStore {
    static let shared = PersistentCatalogStore()

    struct Snapshot: Codable {
        let schemaVersion: Int
        let sourceFingerprint: String
        let savedAt: Date
        let liveCategories: [XtreamCategory]
        let vodCategories: [XtreamCategory]
        let seriesCategories: [XtreamCategory]
        let liveStreams: [XtreamStream]
        let vodStreams: [XtreamStream]
        let seriesItems: [XtreamSeriesItem]
    }

    private let fileManager: FileManager
    private let directoryURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory

        directoryURL = applicationSupport
            .appendingPathComponent("GassPlayer", isDirectory: true)
            .appendingPathComponent("CatalogSnapshots", isDirectory: true)
    }

    func load(sourceFingerprint: String) -> Snapshot? {
        let url = snapshotURL(for: sourceFingerprint)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? decoder.decode(Snapshot.self, from: data),
              snapshot.schemaVersion == 1,
              snapshot.sourceFingerprint == sourceFingerprint else {
            return nil
        }
        return snapshot
    }

    func save(_ snapshot: Snapshot) throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let data = try encoder.encode(snapshot)
        try data.write(to: snapshotURL(for: snapshot.sourceFingerprint), options: .atomic)
    }

    func remove(sourceFingerprint: String) throws {
        let url = snapshotURL(for: sourceFingerprint)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func removeAll() throws {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        try fileManager.removeItem(at: directoryURL)
    }

    func snapshotDate(sourceFingerprint: String) -> Date? {
        load(sourceFingerprint: sourceFingerprint)?.savedAt
    }

    private func snapshotURL(for sourceFingerprint: String) -> URL {
        directoryURL.appendingPathComponent("\(stableFileName(for: sourceFingerprint)).json")
    }

    private func stableFileName(for input: String) -> String {
        let hash = input.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { value, byte in
            (value ^ UInt64(byte)) &* UInt64(1_099_511_628_211)
        }
        return "catalog-\(String(hash, radix: 16))"
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
