import Foundation

/// Snapshot persistente del catalogo Xtream.
///
/// Salva solo metadati di catalogo (categorie, ID, titoli, icone e
/// classificazione) cosi' che l'app possa mostrare live, VOD e serie
/// istantaneamente ad ogni avvio, senza attendere una nuova chiamata di
/// rete. Password, token e URL di streaming autenticati non vengono mai
/// scritti su disco: il modello Xtream viene convertito in DTO interni
/// privi di quei campi prima della serializzazione.
actor PersistentCatalogStore {
    static let shared = PersistentCatalogStore()

    struct Snapshot {
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

    private struct CategoryDTO: Codable {
        let categoryId: String
        let categoryName: String
    }

    private struct StreamDTO: Codable {
        let streamId: Int
        let name: String
        let streamIcon: String?
        let categoryId: String?
        let containerExtension: String?
    }

    private struct SeriesItemDTO: Codable {
        let seriesId: Int
        let name: String
        let cover: String?
        let categoryId: String?
    }

    private struct SnapshotDTO: Codable {
        let schemaVersion: Int
        let sourceFingerprint: String
        let savedAt: Date
        let liveCategories: [CategoryDTO]
        let vodCategories: [CategoryDTO]
        let seriesCategories: [CategoryDTO]
        let liveStreams: [StreamDTO]
        let vodStreams: [StreamDTO]
        let seriesItems: [SeriesItemDTO]
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
              let dto = try? decoder.decode(SnapshotDTO.self, from: data),
              dto.schemaVersion == 1,
              dto.sourceFingerprint == sourceFingerprint else {
            return nil
        }

        return Snapshot(
            schemaVersion: dto.schemaVersion,
            sourceFingerprint: dto.sourceFingerprint,
            savedAt: dto.savedAt,
            liveCategories: dto.liveCategories.map(Self.category),
            vodCategories: dto.vodCategories.map(Self.category),
            seriesCategories: dto.seriesCategories.map(Self.category),
            liveStreams: dto.liveStreams.map(Self.stream),
            vodStreams: dto.vodStreams.map(Self.stream),
            seriesItems: dto.seriesItems.map(Self.seriesItem)
        )
    }

    func save(_ snapshot: Snapshot) {
        let dto = SnapshotDTO(
            schemaVersion: snapshot.schemaVersion,
            sourceFingerprint: snapshot.sourceFingerprint,
            savedAt: snapshot.savedAt,
            liveCategories: snapshot.liveCategories.map(Self.categoryDTO),
            vodCategories: snapshot.vodCategories.map(Self.categoryDTO),
            seriesCategories: snapshot.seriesCategories.map(Self.categoryDTO),
            liveStreams: snapshot.liveStreams.map(Self.streamDTO),
            vodStreams: snapshot.vodStreams.map(Self.streamDTO),
            seriesItems: snapshot.seriesItems.map(Self.seriesItemDTO)
        )

        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(dto)
            try data.write(
                to: snapshotURL(for: snapshot.sourceFingerprint),
                options: .atomic
            )
        } catch {
            DebugLogger.logAsync(
                .error,
                "PersistentCatalogStore: salvataggio snapshot fallito: \(error.localizedDescription)"
            )
        }
    }

    func remove(sourceFingerprint: String) {
        let url = snapshotURL(for: sourceFingerprint)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    func removeAll() {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        try? fileManager.removeItem(at: directoryURL)
    }

    func snapshotDate(sourceFingerprint: String) -> Date? {
        load(sourceFingerprint: sourceFingerprint)?.savedAt
    }

    private func snapshotURL(for sourceFingerprint: String) -> URL {
        directoryURL.appendingPathComponent(
            "\(stableFileName(for: sourceFingerprint)).json"
        )
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

    private static func category(_ dto: CategoryDTO) -> XtreamCategory {
        XtreamCategory(categoryId: dto.categoryId, categoryName: dto.categoryName)
    }

    private static func categoryDTO(_ category: XtreamCategory) -> CategoryDTO {
        CategoryDTO(categoryId: category.categoryId, categoryName: category.categoryName)
    }

    private static func stream(_ dto: StreamDTO) -> XtreamStream {
        XtreamStream(
            streamId: dto.streamId,
            name: dto.name,
            streamIcon: dto.streamIcon,
            categoryId: dto.categoryId,
            containerExtension: dto.containerExtension
        )
    }

    private static func streamDTO(_ stream: XtreamStream) -> StreamDTO {
        StreamDTO(
            streamId: stream.streamId,
            name: stream.name,
            streamIcon: stream.streamIcon,
            categoryId: stream.categoryId,
            containerExtension: stream.containerExtension
        )
    }

    private static func seriesItem(_ dto: SeriesItemDTO) -> XtreamSeriesItem {
        XtreamSeriesItem(
            seriesId: dto.seriesId,
            name: dto.name,
            cover: dto.cover,
            categoryId: dto.categoryId
        )
    }

    private static func seriesItemDTO(_ item: XtreamSeriesItem) -> SeriesItemDTO {
        SeriesItemDTO(
            seriesId: item.seriesId,
            name: item.name,
            cover: item.cover,
            categoryId: item.categoryId
        )
    }
}
