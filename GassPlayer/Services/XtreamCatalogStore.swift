import Foundation
import Combine

@MainActor
final class XtreamCatalogStore: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loadingFromDisk
        case loadingFromNetwork
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
    @Published private(set) var lastRefreshDate: Date?

    private let settings = CatalogSettings.shared
    private let persistentStore: PersistentCatalogStore
    private var loadedFingerprint: String?
    private var loadingTask: Task<Void, Never>?

    init(persistentStore: PersistentCatalogStore = .shared) {
        self.persistentStore = persistentStore
    }

    deinit { loadingTask?.cancel() }

    func loadIfNeeded(credentials: XtreamCredentials) async {
        let fingerprint = Self.fingerprint(credentials)
        if loadedFingerprint == fingerprint, state == .loaded {
            if settings.needsScheduledRefresh() { await refresh(credentials: credentials) }
            return
        }
        if let loadingTask { await loadingTask.value; return }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.restoreThenLoad(credentials: credentials, fingerprint: fingerprint)
        }
        loadingTask = task
        await task.value
        loadingTask = nil
    }

    func refresh(credentials: XtreamCredentials, kind: XtreamStreamKind? = nil) async {
        if let loadingTask { await loadingTask.value; return }
        let fingerprint = Self.fingerprint(credentials)
        let task = Task { [weak self] in
            guard let self else { return }
            let repository = CachedXtreamRepository(credentials: credentials)
            await repository.invalidate(kind: kind)
            if let kind {
                await self.loadSection(kind, credentials: credentials, forceRefresh: true)
                if case .loaded = self.state {
                    self.loadedFingerprint = fingerprint
                    self.settings.markRefreshed()
                    self.lastRefreshDate = self.settings.lastRefreshDate
                    await self.saveSnapshot(fingerprint: fingerprint)
                }
            } else {
                await self.loadNetwork(credentials: credentials, fingerprint: fingerprint, forceRefresh: true)
            }
        }
        loadingTask = task
        await task.value
        loadingTask = nil
    }

    func clearPersistedCache(credentials: XtreamCredentials? = nil) async {
        if let credentials {
            try? await persistentStore.remove(sourceFingerprint: Self.fingerprint(credentials))
        } else {
            try? await persistentStore.removeAll()
        }
    }

    func reset() {
        loadingTask?.cancel()
        loadingTask = nil
        loadedFingerprint = nil
        liveCategories = []
        vodCategories = []
        seriesCategories = []
        liveStreams = []
        vodStreams = []
        seriesItems = []
        lastRefreshDate = nil
        state = .idle
    }

    func categories(for kind: XtreamStreamKind) -> [XtreamCategory] {
        switch kind {
        case .live: return liveCategories
        case .movie: return vodCategories
        case .series: return seriesCategories
        }
    }

    func streams(for kind: XtreamStreamKind) -> [XtreamStream] {
        switch kind {
        case .live: return liveStreams
        case .movie: return vodStreams
        case .series: return []
        }
    }

    private func restoreThenLoad(credentials: XtreamCredentials, fingerprint: String) async {
        state = .loadingFromDisk
        if let snapshot = await persistentStore.load(sourceFingerprint: fingerprint) {
            liveCategories = snapshot.liveCategories
            vodCategories = snapshot.vodCategories
            seriesCategories = snapshot.seriesCategories
            liveStreams = snapshot.liveStreams
            vodStreams = snapshot.vodStreams
            seriesItems = snapshot.seriesItems
            lastRefreshDate = snapshot.savedAt
            loadedFingerprint = fingerprint
            state = .loaded
        }

        let shouldRefresh = settings.refreshOnLaunch || settings.needsScheduledRefresh() || lastRefreshDate == nil
        if shouldRefresh {
            await loadNetwork(credentials: credentials, fingerprint: fingerprint, forceRefresh: true)
        }
    }

    private func loadNetwork(credentials: XtreamCredentials, fingerprint: String, forceRefresh: Bool) async {
        state = .loadingFromNetwork
        let repository = CachedXtreamRepository(credentials: credentials)
        let api = XtreamAPIService(credentials: credentials)
        let hadContent = !liveStreams.isEmpty || !vodStreams.isEmpty || !seriesItems.isEmpty

        do {
            async let live: Void = loadStreamSection(.live, repository: repository, forceRefresh: forceRefresh)
            async let vod: Void = loadStreamSection(.movie, repository: repository, forceRefresh: forceRefresh)
            async let series: Void = loadSeriesSection(repository: repository, api: api, forceRefresh: forceRefresh)
            _ = try await (live, vod, series)
            guard !Task.isCancelled else { return }
            loadedFingerprint = fingerprint
            settings.markRefreshed()
            lastRefreshDate = settings.lastRefreshDate
            state = .loaded
            await saveSnapshot(fingerprint: fingerprint)
        } catch let error as XtreamError {
            state = hadContent ? .loaded : .failed(error.errorDescription ?? "Errore Xtream non specificato.")
        } catch {
            state = hadContent ? .loaded : .failed("Errore imprevisto: \(error.localizedDescription)")
        }
    }

    private func loadSection(_ kind: XtreamStreamKind, credentials: XtreamCredentials, forceRefresh: Bool) async {
        state = .loadingFromNetwork
        let repository = CachedXtreamRepository(credentials: credentials)
        let api = XtreamAPIService(credentials: credentials)
        do {
            switch kind {
            case .live, .movie:
                try await loadStreamSection(kind, repository: repository, forceRefresh: forceRefresh)
            case .series:
                try await loadSeriesSection(repository: repository, api: api, forceRefresh: forceRefresh)
            }
            state = .loaded
        } catch let error as XtreamError {
            state = .failed(error.errorDescription ?? "Errore Xtream non specificato.")
        } catch {
            state = .failed("Errore imprevisto: \(error.localizedDescription)")
        }
    }

    private func loadStreamSection(_ kind: XtreamStreamKind, repository: CachedXtreamRepository, forceRefresh: Bool) async throws {
        async let categories = repository.categories(kind: kind, forceRefresh: forceRefresh)
        async let streams = repository.allStreams(kind: kind, forceRefresh: forceRefresh)
        let (loadedCategories, loadedStreams) = try await (categories, streams)
        switch kind {
        case .live:
            liveCategories = loadedCategories
            liveStreams = loadedStreams
        case .movie:
            vodCategories = loadedCategories
            vodStreams = loadedStreams
        case .series:
            break
        }
    }

    private func loadSeriesSection(repository: CachedXtreamRepository, api: XtreamAPIService, forceRefresh: Bool) async throws {
        async let categories = repository.categories(kind: .series, forceRefresh: forceRefresh)
        async let series = api.fetchSeriesList()
        let (loadedCategories, loadedSeries) = try await (categories, series)
        seriesCategories = loadedCategories
        var seen = Set<Int>()
        seriesItems = loadedSeries.filter { $0.seriesId > 0 && seen.insert($0.seriesId).inserted }
    }

    private func saveSnapshot(fingerprint: String) async {
        let snapshot = PersistentCatalogStore.Snapshot(
            schemaVersion: 1,
            sourceFingerprint: fingerprint,
            savedAt: Date(),
            liveCategories: liveCategories,
            vodCategories: vodCategories,
            seriesCategories: seriesCategories,
            liveStreams: liveStreams,
            vodStreams: vodStreams,
            seriesItems: seriesItems
        )
        try? await persistentStore.save(snapshot)
    }

    private static func fingerprint(_ credentials: XtreamCredentials) -> String {
        let host = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        return "\(host)|\(credentials.username)"
    }
}
