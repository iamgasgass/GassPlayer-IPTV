import Foundation
import Combine

/// Catalogo Xtream condiviso per l'intera sessione applicativa.
///
/// Il catalogo viene caricato una sola volta per la coppia host + username
/// della sorgente attiva. Live, VOD e Serie leggono gli stessi dati in memoria:
/// cambiare tab o categoria non causa ulteriori richieste di playlist.
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

    deinit {
        loadingTask?.cancel()
    }

    /// Esegue un bootstrap soltanto se la sorgente attiva non e' ancora stata
    /// caricata in questa sessione. Chiamate simultanee attendono lo stesso task.
    func loadIfNeeded(credentials: XtreamCredentials) async {
        let fingerprint = Self.sourceFingerprint(credentials)

        if loadedSourceFingerprint == fingerprint, state == .loaded {
            return
        }

        if let loadingTask {
            await loadingTask.value
            return
        }

        let task = Task { [weak self] in
            await self?.loadAll(credentials: credentials, fingerprint: fingerprint, forceRefresh: false)
        }

        loadingTask = task
        await task.value
        loadingTask = nil
    }

    /// Refresh esplicito. Se `kind` e' nil aggiorna l'intero catalogo;
    /// altrimenti ricarica soltanto la sezione richiesta.
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
                if self.state != .failed("") {
                    self.loadedSourceFingerprint = fingerprint
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

    /// Cancella il catalogo in memoria. Va chiamato soltanto in caso di logout,
    /// rimozione sorgente o cambio effettivo di host/username.
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

    private func loadAll(
        credentials: XtreamCredentials,
        fingerprint: String,
        forceRefresh: Bool
    ) async {
        guard !Task.isCancelled else { return }

        state = .loading
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
            state = .loaded
        } catch let error as XtreamError {
            state = .failed(error.errorDescription ?? "Errore Xtream non specificato.")
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed("Errore imprevisto: \(error.localizedDescription)")
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

    /// Il fingerprint separa account diversi sullo stesso host senza includere
    /// la password nella memoria applicativa, nella cache o nei log.
    private static func sourceFingerprint(_ credentials: XtreamCredentials) -> String {
        let host = credentials.host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        return "\(host)|\(credentials.username)"
    }
}
