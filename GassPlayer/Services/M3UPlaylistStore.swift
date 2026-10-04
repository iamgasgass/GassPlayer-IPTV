import Foundation
import Combine

/// Stato della playlist M3U attiva, con cache a due livelli per rendere
/// istantaneo il cambio di playlist:
/// 1. memoria (ultime 3 playlist già indicizzate): tornare a una playlist
///    appena usata è immediato, senza rete né parsing;
/// 2. disco (`M3UPlaylistService`): al primo accesso dopo un riavvio si
///    mostra subito la copia salvata e si aggiorna in background solo se
///    ha più di 6 ore.
/// Più la guida programmi XMLTV (`M3UEPGService`) per i canali live.
@MainActor
final class M3UPlaylistStore: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var snapshot = M3UPlaylistSnapshot.empty
    /// Incrementato quando arriva una nuova guida: le righe che mostrano il
    /// programma in onda si rileggono.
    @Published private(set) var epgRevision = 0
    @Published private(set) var isLoadingEPG = false

    /// Compatibilità con le viste esistenti.
    var channelsByKind: [XtreamStreamKind: [M3UChannel]] { snapshot.channelsByKind }

    private(set) var loadedURL: URL?

    private struct Entry {
        let snapshot: M3UPlaylistSnapshot
        var loadedAt: Date
    }

    private static let staleInterval: TimeInterval = 6 * 60 * 60
    private static let memoryLimit = 3

    private var memory: [URL: Entry] = [:]
    private var memoryOrder: [URL] = []

    private var loadTask: Task<Void, Never>?
    private var loadingURL: URL?
    private var loadGeneration = 0

    private var epgTask: Task<Void, Never>?
    private var guide = M3UEPGService.Guide()
    private var epgCancellable: AnyCancellable?

    init() {
        // Una fonte EPG esterna aggiunta/rimossa/abilitata in "Gestisci EPG"
        // si riflette subito sulle playlist M3U.
        epgCancellable = EPGManager.shared.$externalSources
            .dropFirst()
            .debounce(for: .seconds(0.6), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.loadedURL != nil else { return }
                self.startEPGLoad(forceRefresh: false)
            }
    }

    // MARK: - Caricamento

    func loadIfNeeded(url: URL) async {
        // Già mostrata e senza errori: niente da fare (al massimo un
        // aggiornamento silenzioso se la copia è vecchia).
        if loadedURL == url, errorMessage == nil, !snapshot.channelsByKind.isEmpty {
            refreshInBackgroundIfStale(url)
            return
        }

        // Già in caricamento per questo URL: attendi lo stesso lavoro
        // (ContentView e la vista possono chiamare quasi insieme).
        if loadingURL == url, let loadTask {
            await loadTask.value
            return
        }

        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration

        // Cambio playlist: memoria = istantaneo.
        if let entry = memory[url] {
            touch(url)
            apply(entry.snapshot, url: url)
            loadingURL = nil
            isLoading = false
            errorMessage = nil

            if Date().timeIntervalSince(entry.loadedAt) > Self.staleInterval {
                refreshInBackgroundIfStale(url)
            }
            return
        }

        // Svuota subito il contenuto della playlist precedente: non va
        // mostrata sotto il titolo/stato della nuova.
        snapshot = .empty
        loadedURL = nil
        guide = M3UEPGService.Guide()
        epgRevision += 1
        errorMessage = nil
        isLoading = true
        loadingURL = url

        // `guard let self` (e non `self?.`): con la catena opzionale il
        // task restituirebbe `()?` e non sarebbe assegnabile a
        // `Task<Void, Never>`.
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.loadFromDiskThenNetwork(url: url, generation: generation)
        }
        loadTask = task
        await task.value
    }

    func reload(url: URL) async {
        loadTask?.cancel()
        memory[url] = nil
        memoryOrder.removeAll { $0 == url }
        loadedURL = nil
        await M3UPlaylistService.shared.removeCache(for: url)
        await loadIfNeeded(url: url)
    }

    private func loadFromDiskThenNetwork(url: URL, generation: Int) async {
        let service = M3UPlaylistService.shared
        var appliedFromDisk = false
        var diskIsFresh = false

        if let cached = await service.cachedText(for: url) {
            let parsed = await service.snapshot(fromText: cached.text)

            guard generation == loadGeneration, !Task.isCancelled else { return }

            if !parsed.channelsByKind.isEmpty {
                remember(parsed, for: url, loadedAt: cached.savedAt)
                apply(parsed, url: url)
                isLoading = false
                appliedFromDisk = true
                diskIsFresh = Date().timeIntervalSince(cached.savedAt) < Self.staleInterval
            }
        }

        if appliedFromDisk && diskIsFresh {
            loadingURL = nil
            return
        }

        do {
            let loaded = try await service.load(from: url)

            guard generation == loadGeneration, !Task.isCancelled else { return }

            guard !loaded.channelsByKind.isEmpty else {
                if !appliedFromDisk {
                    errorMessage = "La playlist è stata scaricata ma non contiene canali validi."
                }
                isLoading = false
                loadingURL = nil
                return
            }

            remember(loaded, for: url, loadedAt: Date())
            apply(loaded, url: url)
            errorMessage = nil
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }

            // Con una copia già mostrata un errore di rete non deve
            // sostituirla con una schermata di errore.
            if !appliedFromDisk {
                errorMessage = "Errore nel caricamento della playlist: \(error.localizedDescription)"
            }
        }

        isLoading = false
        loadingURL = nil
    }

    /// Aggiornamento silenzioso: non tocca `isLoading`, sostituisce i dati
    /// solo a download riuscito e solo se la playlist è ancora quella attiva.
    private func refreshInBackgroundIfStale(_ url: URL) {
        guard let entry = memory[url],
              Date().timeIntervalSince(entry.loadedAt) > Self.staleInterval,
              loadingURL != url else { return }

        // Evita richieste ripetute mentre quella in corso non è finita.
        memory[url]?.loadedAt = Date()

        Task { [weak self] in
            guard let loaded = try? await M3UPlaylistService.shared.load(from: url),
                  !loaded.channelsByKind.isEmpty,
                  let self else { return }

            self.remember(loaded, for: url, loadedAt: Date())

            if self.loadedURL == url {
                self.apply(loaded, url: url)
            }
        }
    }

    private func apply(_ newSnapshot: M3UPlaylistSnapshot, url: URL) {
        snapshot = newSnapshot
        loadedURL = url
        startEPGLoad(forceRefresh: false)
    }

    private func remember(_ newSnapshot: M3UPlaylistSnapshot, for url: URL, loadedAt: Date) {
        memory[url] = Entry(snapshot: newSnapshot, loadedAt: loadedAt)
        touch(url)

        while memoryOrder.count > Self.memoryLimit, let oldest = memoryOrder.first {
            memoryOrder.removeFirst()
            memory[oldest] = nil
        }
    }

    private func touch(_ url: URL) {
        memoryOrder.removeAll { $0 == url }
        memoryOrder.append(url)
    }

    // MARK: - Letture per le viste

    func groups(for kind: XtreamStreamKind) -> [String] {
        snapshot.groupsByKind[kind] ?? []
    }

    func channels(for kind: XtreamStreamKind, group: String) -> [M3UChannel] {
        snapshot.channelsByGroup[kind]?[group] ?? []
    }

    func channelCount(for kind: XtreamStreamKind, group: String) -> Int {
        snapshot.channelsByGroup[kind]?[group]?.count ?? 0
    }

    func totalCount(for kind: XtreamStreamKind) -> Int {
        snapshot.channelsByKind[kind]?.count ?? 0
    }

    func groupIcon(for kind: XtreamStreamKind, group: String) -> String? {
        snapshot.iconsByGroup[kind]?[group]
    }

    // MARK: - EPG

    /// Indirizzi XMLTV da usare: quelli dichiarati dalla playlist più le
    /// fonti EPG esterne abilitate in "Gestisci EPG".
    private var epgURLs: [URL] {
        var urls: [URL] = []
        var seen = Set<String>()

        let candidates = snapshot.epgURLs
            + EPGManager.shared.externalSources.filter(\.isEnabled).map(\.urlString)

        for string in candidates {
            guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  seen.insert(url.absoluteString).inserted else { continue }
            urls.append(url)
        }

        return urls
    }

    var hasEPGSource: Bool { !epgURLs.isEmpty }

    func refreshEPG() {
        startEPGLoad(forceRefresh: true)
    }

    private func startEPGLoad(forceRefresh: Bool) {
        epgTask?.cancel()

        let live = snapshot.channelsByKind[.live] ?? []
        let urls = epgURLs

        guard !live.isEmpty, !urls.isEmpty else {
            guide = M3UEPGService.Guide()
            isLoadingEPG = false
            epgRevision += 1
            return
        }

        isLoadingEPG = true

        epgTask = Task { [weak self] in
            // I canali sono già mostrati: la guida non deve contendere la
            // CPU al primo rendering.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }

            let wanted = await Task.detached(priority: .utility) {
                var ids = Set<String>()
                var names = Set<String>()

                for channel in live {
                    if let tvgId = channel.tvgId, !tvgId.isEmpty { ids.insert(tvgId.lowercased()) }
                    if let tvgName = channel.tvgName { names.insert(M3UEPGService.normalizedName(tvgName)) }
                    names.insert(M3UEPGService.normalizedName(channel.title))
                }

                names.remove("")
                return (ids, names)
            }.value

            let loaded = await M3UEPGService.shared.guide(
                urls: urls,
                wantedIDs: wanted.0,
                wantedNames: wanted.1,
                forceRefresh: forceRefresh
            )

            guard !Task.isCancelled, let self else { return }

            self.guide = loaded
            self.isLoadingEPG = false
            self.epgRevision += 1
        }
    }

    /// Programmi del canale (ordinati per orario), `[]` se la guida non lo
    /// copre. Abbinamento: `tvg-id` → nome XMLTV uguale a `tvg-name` → al
    /// titolo del canale.
    func programs(for channel: M3UChannel) -> [EPGProgram] {
        guard !guide.isEmpty else { return [] }

        if let tvgId = channel.tvgId?.lowercased(), let programs = guide.programsByChannelID[tvgId] {
            return programs
        }

        var names: [String] = []
        if let tvgName = channel.tvgName { names.append(tvgName) }
        names.append(channel.title)

        for name in names {
            let normalized = M3UEPGService.normalizedName(name)
            if let id = guide.channelIDByName[normalized], let programs = guide.programsByChannelID[id] {
                return programs
            }
        }

        return []
    }

    /// Programma in onda (o il prossimo, se non ce n'è uno corrente).
    func currentProgram(for channel: M3UChannel, at date: Date = Date()) -> EPGProgram? {
        let programs = programs(for: channel)
        return programs.first { $0.isCurrent(at: date) } ?? programs.first { $0.isUpcoming(at: date) }
    }
}
