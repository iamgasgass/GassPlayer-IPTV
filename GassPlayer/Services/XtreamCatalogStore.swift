import Foundation
import Combine

/// Catalogo Xtream condiviso per l'intera sessione dell'app.
///
/// Strategia:
/// - cache in memoria durante l'esecuzione;
/// - snapshot persistente per sorgente fra i riavvii;
/// - nessuna richiesta di rete automatica se lo snapshot ha meno di sei ore;
/// - aggiornamento solo esplicito tramite reload o pull-to-refresh.
@MainActor
final class XtreamCatalogStore: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var liveCategories: [XtreamCategory] = []
    @Published private(set) var vodCategories: [XtreamCategory] = []
    @Published private(set) var seriesCategories: [XtreamCategory] = []

    @Published private(set) var liveStreams: [XtreamStream] = []
    @Published private(set) var vodStreams: [XtreamStream] = []
    @Published private(set) var seriesItems: [XtreamSeriesItem] = []
    @Published private(set) var state: LoadState = .idle

    private var loadedSourceFingerprint: String?
    private var loadingTask: Task<Void, Never>?

    /// Entro questa durata il riavvio usa solo il catalogo locale.
    private static let diskCacheTTL: TimeInterval = 6 * 60 * 60

    deinit {
        loadingTask?.cancel()
    }

    func loadIfNeeded(credentials: XtreamCredentials) async {
        let fingerprint = Self.sourceFingerprint(credentials)

        if loadedSourceFingerprint == fingerprint, state == .loaded {
            return
        }

        if let loadingTask {
            await loadingTask.value
            return
        }

        if let savedAt = await hydrateFromDisk(fingerprint: fingerprint),
           Date().timeIntervalSince(savedAt) < Self.diskCacheTTL {
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }

            await self.loadAll(
                credentials: credentials,
                fingerprint: fingerprint,
                forceRefresh: false
            )
        }

        loadingTask = task
        await task.value
        loadingTask = nil
    }

    /// Refresh esplicito dell'intero catalogo o della sola sezione indicata.
    func refresh(
        credentials: XtreamCredentials,
        kind: XtreamStreamKind? = nil
    ) async {
        if let loadingTask {
            await loadingTask.value
            return
        }

        let fingerprint = Self.sourceFingerprint(credentials)

        let task = Task { [weak self] in
            guard let self else { return }

            let repository = CachedXtreamRepository(
                credentials: credentials
            )

            await repository.invalidate(kind: kind)

            if let kind {
                await self.loadSection(
                    kind: kind,
                    credentials: credentials,
                    forceRefresh: true
                )

                if case .loaded = self.state {
                    self.loadedSourceFingerprint = fingerprint
                    await self.persistSnapshot(fingerprint: fingerprint)
                }
            } else {
                await self.loadAll(
                    credentials: credentials,
                    fingerprint: fingerprint,
                    forceRefresh: true
                )
            }
        }

        loadingTask = task
        await task.value
        loadingTask = nil
    }

    /// Svuota soltanto lo stato in memoria.
    ///
    /// Gli snapshot su disco restano disponibili: se l'utente passa a
    /// un'altra sorgente e poi ritorna a quella precedente, il catalogo
    /// può tornare immediatamente senza nuova rete.
    func reset() {
        loadingTask?.cancel()
        loadingTask = nil

        loadedSourceFingerprint = nil

        liveCategories = []
        vodCategories = []
        seriesCategories = []

        liveStreams = []
        vodStreams = []
        seriesItems = []

        state = .idle
    }

    func categories(for kind: XtreamStreamKind) -> [XtreamCategory] {
        switch kind {
        case .live:
            return liveCategories
        case .movie:
            return vodCategories
        case .series:
            return seriesCategories
        }
    }

    func streams(for kind: XtreamStreamKind) -> [XtreamStream] {
        switch kind {
        case .live:
            return liveStreams
        case .movie:
            return vodStreams
        case .series:
            return []
        }
    }

    @discardableResult
    private func hydrateFromDisk(
        fingerprint: String
    ) async -> Date? {
        guard let snapshot = await CatalogDiskCache.shared.load(
            fingerprint: fingerprint
        ) else {
            return nil
        }

        liveCategories = snapshot.liveCategories
        vodCategories = snapshot.vodCategories
        seriesCategories = snapshot.seriesCategories

        liveStreams = snapshot.liveStreams
        vodStreams = snapshot.vodStreams
        seriesItems = snapshot.seriesItems

        loadedSourceFingerprint = fingerprint
        state = .loaded

        return snapshot.savedAt
    }

    private func persistSnapshot(fingerprint: String) async {
        let snapshot = CatalogDiskCache.Snapshot(
            fingerprint: fingerprint,
            savedAt: Date(),
            liveCategories: liveCategories,
            vodCategories: vodCategories,
            seriesCategories: seriesCategories,
            liveStreams: liveStreams,
            vodStreams: vodStreams,
            seriesItems: seriesItems
        )

        await CatalogDiskCache.shared.save(snapshot)
    }

    private func loadAll(
        credentials: XtreamCredentials,
        fingerprint: String,
        forceRefresh: Bool
    ) async {
        guard !Task.isCancelled else { return }

        state = .loading

        let repository = CachedXtreamRepository(
            credentials: credentials
        )

        let api = XtreamAPIService(credentials: credentials)

        do {
            async let live: Void = loadStreamSection(
                kind: .live,
                repository: repository,
                forceRefresh: forceRefresh
            )

            async let vod: Void = loadStreamSection(
                kind: .movie,
                repository: repository,
                forceRefresh: forceRefresh
            )

            async let series: Void = loadSeriesSection(
                repository: repository,
                api: api,
                forceRefresh: forceRefresh
            )

            _ = try await (live, vod, series)

            guard !Task.isCancelled else { return }

            loadedSourceFingerprint = fingerprint
            state = .loaded

            await persistSnapshot(fingerprint: fingerprint)
        } catch let error as XtreamError {
            state = .failed(
                error.errorDescription
                ?? "Errore Xtream non specificato."
            )
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(
                "Errore imprevisto: \(error.localizedDescription)"
            )
        }
    }

    private func loadSection(
        kind: XtreamStreamKind,
        credentials: XtreamCredentials,
        forceRefresh: Bool
    ) async {
        guard !Task.isCancelled else { return }

        state = .loading

        let repository = CachedXtreamRepository(
            credentials: credentials
        )

        let api = XtreamAPIService(credentials: credentials)

        do {
            switch kind {
            case .live, .movie:
                try await loadStreamSection(
                    kind: kind,
                    repository: repository,
                    forceRefresh: forceRefresh
                )

            case .series:
                try await loadSeriesSection(
                    repository: repository,
                    api: api,
                    forceRefresh: forceRefresh
                )
            }

            guard !Task.isCancelled else { return }

            state = .loaded
        } catch let error as XtreamError {
            state = .failed(
                error.errorDescription
                ?? "Errore Xtream non specificato."
            )
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(
                "Errore imprevisto: \(error.localizedDescription)"
            )
        }
    }

    private func loadStreamSection(
        kind: XtreamStreamKind,
        repository: CachedXtreamRepository,
        forceRefresh: Bool
    ) async throws {
        async let categories = repository.categories(
            kind: kind,
            forceRefresh: forceRefresh
        )

        async let catalog = repository.allStreams(
            kind: kind,
            forceRefresh: forceRefresh
        )

        let (loadedCategories, loadedStreams) = try await (
            categories,
            catalog
        )

        guard !Task.isCancelled else { return }

        switch kind {
        case .live:
            liveCategories = loadedCategories
            liveStreams = loadedStreams

        case .movie:
            vodCategories = loadedCategories
            vodStreams = loadedStreams

        case .series:
            return
        }
    }

    private func loadSeriesSection(
        repository: CachedXtreamRepository,
        api: XtreamAPIService,
        forceRefresh: Bool
    ) async throws {
        async let categories = repository.categories(
            kind: .series,
            forceRefresh: forceRefresh
        )

        async let series = api.fetchSeriesList()

        let (loadedCategories, loadedSeries) = try await (
            categories,
            series
        )

        guard !Task.isCancelled else { return }

        seriesCategories = loadedCategories
        seriesItems = stableDeduplicated(loadedSeries)
    }

    private func stableDeduplicated(
        _ items: [XtreamSeriesItem]
    ) -> [XtreamSeriesItem] {
        var seen = Set<Int>()

        return items.filter { item in
            item.seriesId > 0
                && seen.insert(item.seriesId).inserted
        }
    }

    private static func sourceFingerprint(
        _ credentials: XtreamCredentials
    ) -> String {
        let host = credentials.host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
            .lowercased()

        return "\(host)|\(credentials.username)"
    }
}
