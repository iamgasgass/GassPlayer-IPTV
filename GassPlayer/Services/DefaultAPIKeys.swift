import Foundation

/// Chiavi API predefinite, le stesse del progetto Android
/// (`DEFAULT_TMDB_API_KEY` / `DEFAULT_OMDB_API_KEY` in Models.kt).
/// Come su Android (`ifBlank { DEFAULT_… }`): se in Impostazioni la chiave è
/// vuota si usa quella predefinita; una chiave personale inserita resta.
enum DefaultAPIKeys {
    static let tmdb = "8baba8ab6b8bbe247645bcae7df63d0d"
    static let omdb = "fa3a396f"

    /// Da chiamare all'avvio dell'app (prima di qualsiasi richiesta).
    static func apply(to defaults: UserDefaults = .standard) {
        fill(TMDBService.apiKeyDefaultsKey, with: tmdb, in: defaults)
        fill(OMDbService.apiKeyDefaultsKey, with: omdb, in: defaults)
    }

    private static func fill(_ key: String, with value: String, in defaults: UserDefaults) {
        let current = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if current.isEmpty { defaults.set(value, forKey: key) }
    }
}
