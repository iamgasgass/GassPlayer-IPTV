import Foundation

/// Posizione di riproduzione salvata per film ed episodi (mai per la Live).
///
/// Chiave = host + tipo + id, NON l'URL completo: cosi' la posizione
/// resta valida anche se il player passa a un'estensione alternativa
/// (`.mkv` -> `.mp4`) o cambia user-agent.
enum PlaybackPositionStore {
    private struct Entry: Codable {
        var time: Double
        var updatedAt: Date
    }

    private static let storageKey = "gassplayer.playback.positions.v1"
    private static let maxEntries = 300

    /// `host|movie|123` oppure `nil` per Live/URL non Xtream.
    static func identity(for url: URL) -> String? {
        let comps = url.pathComponents
        guard comps.count >= 5, let host = url.host?.lowercased() else { return nil }
        let kind = comps[comps.count - 4].lowercased()
        guard kind == "movie" || kind == "series" else { return nil }
        let id = (comps[comps.count - 1] as NSString).deletingPathExtension
        guard !id.isEmpty else { return nil }
        return "\(host)|\(kind)|\(id)"
    }

    static func position(for url: URL) -> TimeInterval? {
        guard let key = identity(for: url), let entry = load()[key], entry.time > 5 else { return nil }
        return entry.time
    }

    /// Salva solo se ha senso riprendere: oltre i primi secondi e prima
    /// dei titoli di coda. Se il contenuto e' quasi finito, azzera.
    static func record(time: TimeInterval, duration: TimeInterval, for url: URL) {
        guard let key = identity(for: url), duration > 120 else { return }
        var all = load()
        if time > 15 && time < duration - 45 {
            all[key] = Entry(time: time, updatedAt: Date())
            if all.count > maxEntries {
                let overflow = all.count - maxEntries
                for oldest in all.sorted(by: { $0.value.updatedAt < $1.value.updatedAt }).prefix(overflow) {
                    all.removeValue(forKey: oldest.key)
                }
            }
        } else if time >= duration - 45 {
            all.removeValue(forKey: key)
        } else {
            return
        }
        save(all)
    }

    static func clear(for url: URL) {
        guard let key = identity(for: url) else { return }
        var all = load()
        guard all.removeValue(forKey: key) != nil else { return }
        save(all)
    }

    private static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func save(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
