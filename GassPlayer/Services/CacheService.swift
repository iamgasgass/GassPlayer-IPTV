import Foundation

/// Cache generica in memoria, con scadenza per voce (TTL) e invalidazione
/// per chiave singola o per prefisso. Usata da `CachedXtreamRepository`
/// (categorie/stream/catalogo) ed `EPGService` (guida breve/completa).
///
/// Tutte le operazioni sono isolate nell'actor: non serve sincronizzazione
/// aggiuntiva lato chiamante.
actor CacheService {
    static let shared = CacheService()

    private struct Entry {
        let value: Any
        let expiresAt: Date
    }

    private var store: [String: Entry] = [:]

    /// Restituisce il valore memorizzato per `key` se presente e non scaduto.
    /// Una voce scaduta viene rimossa immediatamente (lazy eviction).
    func value<T>(for key: String) -> T? {
        guard let entry = store[key] else {
            return nil
        }

        guard entry.expiresAt > Date() else {
            store.removeValue(forKey: key)
            return nil
        }

        return entry.value as? T
    }

    /// Memorizza `value` per `key` con una scadenza a `ttl` secondi da ora.
    /// Un `ttl` <= 0 rimuove immediatamente la chiave, se presente.
    func set<T>(
        _ value: T,
        for key: String,
        ttl: TimeInterval = 300
    ) {
        guard ttl > 0 else {
            store.removeValue(forKey: key)
            return
        }

        store[key] = Entry(
            value: value,
            expiresAt: Date().addingTimeInterval(ttl)
        )
    }

    /// Rimuove una singola chiave, indipendentemente dalla scadenza.
    /// Indispensabile per invalidare l'EPG di un canale specifico senza
    /// distruggere la cache degli altri canali o del catalogo.
    func removeValue(for key: String) {
        store.removeValue(forKey: key)
    }

    /// Rimuove tutte le chiavi che iniziano con `prefix`.
    /// Usata per invalidazioni di gruppo (es. tutte le categorie live,
    /// oppure tutte le varianti di short EPG di un canale).
    func invalidate(prefix: String) {
        let keys = store.keys.filter { $0.hasPrefix(prefix) }

        for key in keys {
            store.removeValue(forKey: key)
        }
    }

    /// Pulizia proattiva delle voci scadute. Non obbligatoria (la lettura
    /// e' gia' lazy), ma utile per contenere la memoria se la cache riceve
    /// molte chiavi effimere (es. EPG di playlist molto grandi).
    func removeExpiredValues() {
        let now = Date()

        store = store.filter { _, entry in
            entry.expiresAt > now
        }
    }

    /// Conteggio voci correnti, opzionalmente filtrate per prefisso.
    /// Utile per diagnostica/debug console.
    func count(prefix: String? = nil) -> Int {
        removeExpiredValues()

        guard let prefix else {
            return store.count
        }

        return store.keys.lazy.filter { $0.hasPrefix(prefix) }.count
    }

    /// Svuota completamente la cache. Usare solo per logout/reset totale.
    func clearAll() {
        store.removeAll(keepingCapacity: false)
    }
}
