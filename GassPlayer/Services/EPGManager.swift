import Foundation
import Combine

/// Stato e preferenze globali della guida TV (EPG), condivisi da tutte le
/// sorgenti. Segue la stessa convenzione di `CatalogSettings`: singleton
/// `@MainActor`, backed da `UserDefaults`, esposto tramite `@Published`.
///
/// Alimenta la schermata "Gestisci guida TV" (`EPGManageView`), raggiungibile
/// da Impostazioni → Connessioni → "Gestisci EPG":
/// - `autoUpdateEnabled` — interruttore "Aggiorna automaticamente";
/// - `refreshSources` — azione "Aggiorna fonti" (riverifica le credenziali
///   Xtream di tutte le sorgenti che forniscono una guida programmi);
/// - `EPGService.clearAllCache()` — azione "Cancella cache";
/// - `externalSources` — le fonti XMLTV aggiunte manualmente con
///   "Aggiungi fonte EPG".
@MainActor
final class EPGManager: ObservableObject {
    static let shared = EPGManager()

    /// Intervallo minimo tra due aggiornamenti automatici pianificati.
    private static let scheduledRefreshInterval: TimeInterval = 6 * 60 * 60

    @Published var autoUpdateEnabled: Bool {
        didSet { defaults.set(autoUpdateEnabled, forKey: Keys.autoUpdateEnabled) }
    }

    @Published private(set) var lastSourcesRefreshDate: Date? {
        didSet {
            if let lastSourcesRefreshDate {
                defaults.set(lastSourcesRefreshDate, forKey: Keys.lastRefreshDate)
            } else {
                defaults.removeObject(forKey: Keys.lastRefreshDate)
            }
        }
    }

    @Published private(set) var externalSources: [EPGExternalSource]

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoUpdateEnabled = defaults.object(forKey: Keys.autoUpdateEnabled) as? Bool ?? true
        lastSourcesRefreshDate = defaults.object(forKey: Keys.lastRefreshDate) as? Date
        externalSources = Self.loadExternalSources(from: defaults)
    }

    // MARK: - Aggiornamento fonti

    func markSourcesRefreshed(at date: Date = Date()) {
        lastSourcesRefreshDate = date
    }

    /// `true` se l'aggiornamento automatico è attivo e l'ultima verifica è
    /// più vecchia dell'intervallo pianificato (o non è mai avvenuta).
    /// Non pianifica nulla da sola: sono le viste (es. `EPGManageView`) a
    /// interrogarla e a eseguire l'aggiornamento vero e proprio, così la
    /// logica di rete resta in un solo punto.
    func needsScheduledRefresh(now: Date = Date()) -> Bool {
        guard autoUpdateEnabled else { return false }
        guard let lastSourcesRefreshDate else { return true }
        return now.timeIntervalSince(lastSourcesRefreshDate) >= Self.scheduledRefreshInterval
    }

    /// Riverifica tutte le sorgenti Xtream (le uniche che possono fornire una
    /// guida programmi) e registra l'esito su `SourceManager`, così la lista
    /// sorgenti mostra credenziali aggiornate anche dopo un "Aggiorna fonti"
    /// lanciato da qui. Ritorna quante sorgenti hanno risposto correttamente
    /// sul totale verificato.
    @discardableResult
    func refreshSources(using sourceManager: SourceManager) async -> (succeeded: Int, total: Int) {
        let xtreamSources = sourceManager.sources.compactMap { source in
            source.xtreamCredentials.map { (source, $0) }
        }

        guard !xtreamSources.isEmpty else {
            markSourcesRefreshed()
            return (0, 0)
        }

        var succeeded = 0

        for (source, credentials) in xtreamSources {
            let service = XtreamAPIService(credentials: credentials)
            do {
                _ = try await service.authenticate()
                sourceManager.recordVerification(for: source, succeeded: true)
                succeeded += 1
            } catch {
                sourceManager.recordVerification(for: source, succeeded: false)
            }
        }

        markSourcesRefreshed()
        return (succeeded, xtreamSources.count)
    }

    // MARK: - Fonti EPG esterne (XMLTV)

    /// Aggiunge una fonte XMLTV esterna. Ritorna `false` (senza modificare lo
    /// stato) se il nome è vuoto o l'URL non è un http/https valido.
    @discardableResult
    func addExternalSource(name: String, urlString: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty,
              let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return false
        }

        externalSources.append(EPGExternalSource(name: trimmedName, urlString: trimmedURL))
        persistExternalSources()
        return true
    }

    func removeExternalSource(_ source: EPGExternalSource) {
        externalSources.removeAll { $0.id == source.id }
        persistExternalSources()
    }

    func removeExternalSources(at offsets: IndexSet) {
        externalSources.remove(atOffsets: offsets)
        persistExternalSources()
    }

    func setExternalSource(_ source: EPGExternalSource, isEnabled: Bool) {
        guard let index = externalSources.firstIndex(where: { $0.id == source.id }) else { return }
        externalSources[index].isEnabled = isEnabled
        persistExternalSources()
    }

    private func persistExternalSources() {
        guard let data = try? JSONEncoder().encode(externalSources) else { return }
        defaults.set(data, forKey: Keys.externalSources)
    }

    private static func loadExternalSources(from defaults: UserDefaults) -> [EPGExternalSource] {
        guard let data = defaults.data(forKey: Keys.externalSources),
              let decoded = try? JSONDecoder().decode([EPGExternalSource].self, from: data) else {
            return []
        }
        return decoded
    }

    private enum Keys {
        static let autoUpdateEnabled = "gassplayer.epg.autoUpdateEnabled"
        static let lastRefreshDate = "gassplayer.epg.lastSourcesRefreshDate"
        static let externalSources = "gassplayer.epg.externalSources"
    }
}
