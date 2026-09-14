import Foundation

/// Cache persistente del catalogo Xtream su disco.
///
/// Conserva categorie e contenuti Live/VOD/Serie tra riavvii dell'app.
/// Ogni snapshot viene separato per sorgente tramite un fingerprint hashato
/// e viene scritto atomicamente, per evitare file parziali in caso di
/// terminazione dell'app durante la persistenza.
actor CatalogDiskCache {
    static let shared = CatalogDiskCache()

    struct Snapshot: Codable {
        let fingerprint: String
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

        let baseURL = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? fileManager.temporaryDirectory

        directoryURL = baseURL
            .appendingPathComponent("GassPlayer", isDirectory: true)
            .appendingPathComponent("CatalogCache", isDirectory: true)
    }

    func load(fingerprint: String) -> Snapshot? {
        let fileURL = snapshotURL(for: fingerprint)

        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard
            let snapshot = try? decoder.decode(Snapshot.self, from: data),
            snapshot.fingerprint == fingerprint
        else {
            return nil
        }

        return snapshot
    }

    func save(_ snapshot: Snapshot) {
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601

            let data = try encoder.encode(snapshot)

            try data.write(
                to: snapshotURL(for: snapshot.fingerprint),
                options: .atomic
            )
        } catch {
            DebugLogger.logAsync(
                .warning,
                "CatalogDiskCache: impossibile salvare la cache su disco: \(error.localizedDescription)"
            )
        }
    }

    func remove(fingerprint: String) {
        try? fileManager.removeItem(at: snapshotURL(for: fingerprint))
    }

    func removeAll() {
        try? fileManager.removeItem(at: directoryURL)
    }

    private func snapshotURL(for fingerprint: String) -> URL {
        directoryURL
            .appendingPathComponent(stableFileName(for: fingerprint))
            .appendingPathExtension("json")
    }

    private func stableFileName(for input: String) -> String {
        let hash = input.utf8.reduce(
            UInt64(14_695_981_039_346_656_037)
        ) { value, byte in
            (value ^ UInt64(byte)) &* UInt64(1_099_511_628_211)
        }

        return "catalog-\(String(hash, radix: 16))"
    }
}
