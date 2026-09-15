import Foundation
import Combine

/// Repository con cache per l'API Xtream: aggiunge TTL, retry selettivo e
/// invalidazione granulare sopra `XtreamAPIService`, che resta senza stato.
actor CachedXtreamRepository {
    private let api: XtreamAPIService
    private let cachePrefix: String

    init(credentials: XtreamCredentials) {
        api = XtreamAPIService(credentials: credentials)
        cachePrefix = Self.makeCachePrefix(credentials: credentials)
    }

    func categories(
        kind: XtreamStreamKind,
        forceRefresh: Bool = false
    ) async throws -> [XtreamCategory] {
        let key = "\(cachePrefix).categories.\(kind.rawValue)"

        if !forceRefresh,
           let cached: [XtreamCategory] = await CacheService.shared.value(for: key) {
            return cached
        }

        let result = try await RetryPolicy.withRetry(shouldRetry: Self.shouldRetry) {
            try await self.api.fetchCategories(kind: kind)
        }

        await CacheService.shared.set(result, for: key, ttl: 600)
        return result
    }

    func streams(
        kind: XtreamStreamKind,
        categoryId: String?,
        forceRefresh: Bool = false
    ) async throws -> [XtreamStream] {
        let categoryKey = categoryId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
            ? categoryId!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "all"

        let key = "\(cachePrefix).streams.\(kind.rawValue).\(categoryKey)"

        if !forceRefresh,
           let cached: [XtreamStream] = await CacheService.shared.value(for: key) {
            return cached
        }

        let result = try await RetryPolicy.withRetry(shouldRetry: Self.shouldRetry) {
            try await self.api.fetchStreams(kind: kind, categoryId: categoryId)
        }

        await CacheService.shared.set(result, for: key, ttl: 300)
        return result
    }

    func allStreams(
        kind: XtreamStreamKind,
        forceRefresh: Bool = false
    ) async throws -> [XtreamStream] {
        let key = "\(cachePrefix).catalog.\(kind.rawValue)"

        if !forceRefresh,
           let cached: [XtreamStream] = await CacheService.shared.value(for: key) {
            return cached
        }

        let result = try await RetryPolicy.withRetry(shouldRetry: Self.shouldRetry) {
            try await self.api.fetchAllStreams(kind: kind)
        }

        let ttl: TimeInterval = kind == .movie ? 900 : 300
        await CacheService.shared.set(result, for: key, ttl: ttl)
        return result
    }

    func seriesList(forceRefresh: Bool = false) async throws -> [XtreamSeriesItem] {
        let key = "\(cachePrefix).series.list"

        if !forceRefresh,
           let cached: [XtreamSeriesItem] = await CacheService.shared.value(for: key) {
            return cached
        }

        let result = try await RetryPolicy.withRetry(shouldRetry: Self.shouldRetry) {
            try await self.api.fetchSeriesList()
        }

        await CacheService.shared.set(result, for: key, ttl: 300)
        return result
    }

    /// Invalida la cache relativa a un tipo di contenuto specifico, oppure
    /// l'intera sorgente se `kind` e' `nil`. A differenza di una versione
    /// precedente, un `kind` esplicito NON invalida piu' l'intera sorgente:
    /// solo le voci di categorie/stream/catalogo pertinenti a quel tipo.
    func invalidate(kind: XtreamStreamKind? = nil) async {
        guard let kind else {
            await CacheService.shared.invalidate(prefix: cachePrefix)
            return
        }

        let prefix = "\(cachePrefix)."

        switch kind {
        case .live:
            await CacheService.shared.invalidate(prefix: "\(prefix)categories.live")
            await CacheService.shared.invalidate(prefix: "\(prefix)streams.live.")
            await CacheService.shared.invalidate(prefix: "\(prefix)catalog.live")

        case .movie:
            await CacheService.shared.invalidate(prefix: "\(prefix)categories.movie")
            await CacheService.shared.invalidate(prefix: "\(prefix)streams.movie.")
            await CacheService.shared.invalidate(prefix: "\(prefix)catalog.movie")

        case .series:
            await CacheService.shared.invalidate(prefix: "\(prefix)categories.series")
            await CacheService.shared.removeValue(for: "\(prefix)series.list")
        }
    }

    func streamURL(
        for stream: XtreamStream,
        kind: XtreamStreamKind
    ) -> URL? {
        api.streamURL(for: stream, kind: kind)
    }

    private static func shouldRetry(_ error: Error) -> Bool {
        guard let error = error as? XtreamError else {
            return true
        }

        switch error {
        case .wrongCredentials, .malformedHost, .invalidURL, .decoding:
            return false
        case .unreachable, .timeout, .httpStatus, .noProviderVPN:
            return true
        }
    }

    private static func makeCachePrefix(credentials: XtreamCredentials) -> String {
        let host = credentials.host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()

        let input = "\(host)|\(credentials.username)"

        let hash = input.utf8.reduce(
            UInt64(14_695_981_039_346_656_037)
        ) { value, byte in
            (value ^ UInt64(byte)) &* UInt64(1_099_511_628_211)
        }

        return "xtream.\(String(hash, radix: 16))"
    }
}

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
///   categoria non causa ulteriori richieste di playlist;
/// - Live, VOD e Serie sono trattate come sezioni indipendenti: un errore
///   in una sola sezione non invalida piu' lo stato delle altre sezioni
///   gia' caricate con successo.
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

    /// Carica Live, VOD e Serie come operazioni indipendenti. Un fallimento
    /// isolato (es. Serie non disponibili) non deve azzerare o marcare come
    /// fallito lo stato di sezioni gia' caricate con successo (es. Live TV),
    /// perche' altrimenti l'apertura della guida TV puo' risultare bloccata
    /// anche quando i canali live sono perfettamente disponibili.
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

        async let liveResult: Result<Void, Error> = loadResult {
            try await self.loadStreamSection(
                kind: .live,
                repository: repository,
                forceRefresh: forceRefresh
            )
        }

        async let vodResult: Result<Void, Error> = loadResult {
            try await self.loadStreamSection(
                kind: .movie,
                repository: repository,
                forceRefresh: forceRefresh
            )
        }

        async let seriesResult: Result<Void, Error> = loadResult {
            try await self.loadSeriesSection(
                repository: repository,
                api: api,
                forceRefresh: forceRefresh
            )
        }

        let (live, vod, series) = await (liveResult, vodResult, seriesResult)

        guard !Task.isCancelled else { return }

        let failures = [live, vod, series].compactMap { result -> Error? in
            guard case .failure(let error) = result else { return nil }
            return error
        }

        let hasContentNow = !liveStreams.isEmpty || !vodStreams.isEmpty || !seriesItems.isEmpty

        if hasContentNow {
            loadedSourceFingerprint = fingerprint
            settings.markRefreshed()
            lastRefreshDate = settings.lastRefreshDate
            state = .loaded

            await persistSnapshot(fingerprint: fingerprint)

            for failure in failures {
                DebugLogger.logAsync(
                    .warning,
                    "Catalogo: sezione non aggiornata: \(failure.localizedDescription)"
                )
            }
        } else if let firstFailure = failures.first as? XtreamError {
            state = .failed(firstFailure.errorDescription ?? "Errore Xtream non specificato.")
        } else if let firstFailure = failures.first {
            state = .failed("Errore imprevisto: \(firstFailure.localizedDescription)")
        } else {
            state = .loaded
        }
    }

    private func loadResult(
        _ operation: @escaping @MainActor () async throws -> Void
    ) async -> Result<Void, Error> {
        do {
            try await operation()
            return .success(())
        } catch is CancellationError {
            return .failure(CancellationError())
        } catch {
            return .failure(error)
        }
    }

    private func loadSection(
        kind: XtreamStreamKind,
        credentials: XtreamCredentials,
        forceRefresh: Bool
    ) async {
        guard !Task.isCancelled else { return }

        let hadContent: Bool

        switch kind {
        case .live:
            hadContent = !liveStreams.isEmpty
        case .movie:
            hadContent = !vodStreams.isEmpty
        case .series:
            hadContent = !seriesItems.isEmpty
        }

        if !hadContent {
            state = .loading
        }

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
            state = hadContent ? .loaded : .failed(error.errorDescription ?? "Errore Xtream non specificato.")

            DebugLogger.logAsync(
                .warning,
                "Catalogo: sezione \(kind.rawValue) non aggiornata: \(error.localizedDescription)"
            )
        } catch is CancellationError {
            if !hadContent { state = .idle }
        } catch {
            state = hadContent ? .loaded : .failed("Errore imprevisto: \(error.localizedDescription)")
        }
    }

    private func loadStreamSection(
        kind: XtreamStreamKind,
        repository: CachedXtreamRepository,
        forceRefresh: Bool
    ) async throws {
        async let categories = repository.categories(kind: kind, forceRefresh: forceRefresh)
        async let catalog = repository.allStreams(kind: kind, forceRefresh: forceRefresh)

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
        async let categories = repository.categories(kind: .series, forceRefresh: forceRefresh)
        async let series = repository.seriesList(forceRefresh: forceRefresh)

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
