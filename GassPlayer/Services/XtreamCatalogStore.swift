import Foundation
import Combine

/// Catalogo Xtream condiviso per l'intera sessione applicativa.
///
/// Strategia:
/// - ad ogni avvio il catalogo viene ripristinato istantaneamente dalla
///   cache su disco (nessuna attesa di rete, nessun caricamento a vuoto);
/// - una nuova richiesta di rete parte solo se l'utente la richiede
///   esplicitamente (pulsante "Aggiorna" o pull-to-refresh), oppure se
///   l'intervallo di aggiornamento configurato in Impostazioni e' scaduto,
///   oppure se non esiste ancora nessuna cache per questa sorgente;
/// - live, VOD e serie leggono gli stessi dati in memoria: cambiare tab o
///   categoria non causa ulteriori richieste di playlist.
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
    @Published private(set) var lastRefreshDate: Date?

    private let settings = CatalogSettings.shared
    private let persistentStore = PersistentCatalogStore.shared

    private var loadedSourceFingerprint: String?
    private var loadingTask: Task<Void, Never>?

    deinit {
        loadingTask?.cancel()
    }

    /// Ripristina la cache su disco e valuta, in base alle impostazioni
    /// dell'utente, se serve anche un aggiornamento di rete. Chiamate
    /// simultanee attendono lo stesso task.
    func loadIfNeeded(credentials: XtreamCredentials) async {
        let fingerprint = Self.sourceFingerprint(credentials)

        if loadedSourceFingerprint == fingerprint, state == .loaded {
            if settings.needsScheduledRefresh() {
                await refresh(credentials: credentials)
            }
            return
        }

        if let loadingTask {
            await loadingTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.restoreThenLoad(credentials: credentials, fingerprint: fingerprint)
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

            let repository = CachedXtreamRepository(credentials: credentials)
            await repository.invalidate(kind: kind)

            if let kind {
                await self.loadSection(
                    kind: kind,
                    credentials: credentials,
                    forceRefresh: true
                )

                if case .loaded = self.state {
                    self.loadedSourceFingerprint = fingerprint
                    self.settings.markRefreshed()
                    self.lastRefreshDate = self.settings.lastRefreshDate
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

    /// Elimina lo snapshot su disco. Usare per "Cancella cache catalogo" in
    /// Impostazioni oppure per rimuovere completamente la sorgente.
    func clearPersistedCache(credentials: XtreamCredentials? = nil) async {
        if let credentials {
            await persistentStore.remove(sourceFingerprint: Self.sourceFingerprint(credentials))
        } else {
            await persistentStore.removeAll()
        }
    }

    /// Svuota soltanto lo stato in memoria (logout, rimozione sorgente o
    /// cambio di host/username). Lo snapshot su disco resta disponibile.
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

        lastRefreshDate = nil
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

    private func restoreThenLoad(
        credentials: XtreamCredentials,
        fingerprint: String
    ) async {
        if let snapshot = await persistentStore.load(sourceFingerprint: fingerprint) {
            liveCategories = snapshot.liveCategories
            vodCategories = snapshot.vodCategories
            seriesCategories = snapshot.seriesCategories

            liveStreams = snapshot.liveStreams
            vodStreams = snapshot.vodStreams
            seriesItems = snapshot.seriesItems

            lastRefreshDate = snapshot.savedAt
            loadedSourceFingerprint = fingerprint
            state = .loaded
        }

        let shouldRefreshNow = settings.refreshOnLaunch
            || settings.needsScheduledRefresh()
            || lastRefreshDate == nil

        guard shouldRefreshNow else { return }

        await loadAll(
            credentials: credentials,
            fingerprint: fingerprint,
            forceRefresh: true
        )
    }

    private func loadAll(
        credentials: XtreamCredentials,
        fingerprint: String,
        forceRefresh: Bool
    ) async {
        guard !Task.isCancelled else { return }

        let hadContent = !liveStreams.isEmpty || !vodStreams.isEmpty || !seriesItems.isEmpty
        if !hadContent {
            state = .loading
        }

        let repository = CachedXtreamRepository(credentials: credentials)
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
            settings.markRefreshed()
            lastRefreshDate = settings.lastRefreshDate
            state = .loaded

            await persistSnapshot(fingerprint: fingerprint)
        } catch let error as XtreamError {
            state = hadContent ? .loaded : .failed(error.errorDescription ?? "Errore Xtream non specificato.")
        } catch is CancellationError {
            if !hadContent { state = .idle }
        } catch {
            state = hadContent ? .loaded : .failed("Errore imprevisto: \(error.localizedDescription)")
        }
    }

    private func loadSection(
        kind: XtreamStreamKind,
        credentials: XtreamCredentials,
        forceRefresh: Bool
    ) async {
        guard !Task.isCancelled else { return }

        state = .loading
        let repository = CachedXtreamRepository(credentials: credentials)
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
            state = .failed(error.errorDescription ?? "Errore Xtream non specificato.")
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed("Errore imprevisto: \(error.localizedDescription)")
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

        let (loadedCategories, loadedStreams) = try await (categories, catalog)
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

        let (loadedCategories, loadedSeries) = try await (categories, series)
        guard !Task.isCancelled else { return }

        seriesCategories = loadedCategories
        seriesItems = stableDeduplicated(loadedSeries)
    }

    private func stableDeduplicated(_ items: [XtreamSeriesItem]) -> [XtreamSeriesItem] {
        var seen = Set<Int>()
        return items.filter { item in
            item.seriesId > 0 && seen.insert(item.seriesId).inserted
        }
    }

    private func persistSnapshot(fingerprint: String) async {
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

        await persistentStore.save(snapshot)
    }

    private static func sourceFingerprint(_ credentials: XtreamCredentials) -> String {
        let host = credentials.host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        return "\(host)|\(credentials.username)"
    }
}
