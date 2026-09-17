import Foundation

/// Verifica delle credenziali Xtream, centralizzata in un unico punto.
///
/// Prima di questo file la stessa identica logica ("per ogni sorgente
/// Xtream, autentica e registra l'esito su `SourceManager`") viveva
/// duplicata in `SourcesView` (sezione Backup → "Verifica tutte le sorgenti
/// Xtream") e sarebbe stata ri-duplicata da `EPGManager` ("Aggiorna fonti")
/// e dalle nuove azioni rapide di Impostazioni/Home. Con questo servizio
/// tutti quei punti chiamano la stessa implementazione.
@MainActor
enum SourceVerificationService {
    /// Verifica una singola sorgente Xtream. Ritorna `false` senza
    /// modificare nulla se la sorgente non ha credenziali Xtream valide.
    @discardableResult
    static func verify(_ source: MediaSourceConfig, using sourceManager: SourceManager) async -> Bool {
        guard let credentials = source.xtreamCredentials else {
            return false
        }

        do {
            _ = try await XtreamAPIService(credentials: credentials).authenticate()
            sourceManager.recordVerification(for: source, succeeded: true)
            return true
        } catch {
            sourceManager.recordVerification(for: source, succeeded: false)
            return false
        }
    }

    /// Verifica tutte le sorgenti Xtream configurate. Ritorna quante hanno
    /// risposto correttamente sul totale verificato (0/0 se non ce n'è
    /// nessuna configurata).
    @discardableResult
    static func verifyAllXtreamSources(using sourceManager: SourceManager) async -> (succeeded: Int, total: Int) {
        let xtreamSources = sourceManager.sources.filter { $0.type == .xtream }
        guard !xtreamSources.isEmpty else { return (0, 0) }

        var succeeded = 0
        for source in xtreamSources where source.xtreamCredentials != nil {
            if await verify(source, using: sourceManager) {
                succeeded += 1
            }
        }

        return (succeeded, xtreamSources.count)
    }
}
