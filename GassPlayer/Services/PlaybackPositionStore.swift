import Foundation

/// Posizione di riproduzione salvata per film ed episodi (mai per la Live).
///
/// Chiave = host + tipo + id, NON l'URL completo: cosi' la posizione
/// resta valida anche se il player passa a un'estensione alternativa
/// (`.mkv` -> `.mp4`) o cambia user-agent.
enum PlaybackPositionStore {
    /// Interruttore "Riprendi la visione" in Impostazioni → Riproduzione.
    /// Se disattivato: non si legge né si scrive più alcuna posizione, e
    /// l'alert di ripresa nel player non compare mai (comportamento
    /// prima solo apparente: il toggle esisteva ma non veniva letto).
    private static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: "gassplayer.playback.resumePlayback") as? Bool) ?? true
    }

    private struct Entry: Codable {
        var time: Double
        /// Durata del contenuto al momento del salvataggio. Serve solo a
        /// calcolare la frazione per la barra di avanzamento nelle liste
        /// episodi: non è usata per decidere se riprendere.
        var duration: Double
        /// `true` = visto fino in fondo (o fino agli ultimi ~45s, come chi
        /// guarda i titoli di coda saltandoli). Un episodio completato non
        /// propone più "riprendi da qui" ma la sua barra resta piena,
        /// perché è comunque un episodio già visto.
        var isCompleted: Bool
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

    /// Solo per l'alert "Riprendi la visione?": `nil` se il contenuto non è
    /// mai stato aperto O se è già stato completato (niente da riprendere).
    static func position(for url: URL) -> TimeInterval? {
        guard isEnabled else { return nil }
        guard let key = identity(for: url), let entry = load()[key],
              !entry.isCompleted, entry.time > 5 else { return nil }
        return entry.time
    }

    /// Frazione 0...1 di quanto è stato visto, per la barra di avanzamento
    /// sulle miniature degli episodi. A differenza di `position(for:)`,
    /// include ANCHE i contenuti completati (frazione 1) e non è legata
    /// all'interruttore "Riprendi la visione" se non nel senso che, se
    /// disattivato, qui non viene mai scritto nulla da `record`/
    /// `markCompleted` e quindi non c'è nulla da leggere.
    static func watchFraction(for url: URL) -> Double? {
        guard let key = identity(for: url), let entry = load()[key], entry.duration > 0 else { return nil }
        if entry.isCompleted { return 1 }
        let fraction = entry.time / entry.duration
        guard fraction.isFinite else { return nil }
        return min(max(fraction, 0), 1)
    }

    /// Salva solo se ha senso riprendere: oltre i primi secondi. Vicino ai
    /// titoli di coda (o oltre) segna come completato invece di cancellare,
    /// cosi' la barra sulla miniatura resta piena invece di sparire.
    static func record(time: TimeInterval, duration: TimeInterval, for url: URL) {
        guard isEnabled else { return }
        guard let key = identity(for: url), duration > 120 else { return }
        var all = load()
        if time >= duration - 45 {
            all[key] = Entry(time: duration, duration: duration, isCompleted: true, updatedAt: Date())
        } else if time > 15 {
            all[key] = Entry(time: time, duration: duration, isCompleted: false, updatedAt: Date())
        } else {
            return
        }
        trim(&all)
        save(all)
    }

    /// Fine naturale della riproduzione (`.playedToTheEnd`): come sopra ma
    /// senza bisogno di conoscere il tempo esatto raggiunto.
    static func markCompleted(for url: URL, duration: TimeInterval) {
        guard isEnabled else { return }
        guard let key = identity(for: url), duration > 0 else { return }
        var all = load()
        all[key] = Entry(time: duration, duration: duration, isCompleted: true, updatedAt: Date())
        trim(&all)
        save(all)
    }

    private static func trim(_ all: inout [String: Entry]) {
        guard all.count > maxEntries else { return }
        let overflow = all.count - maxEntries
        for oldest in all.sorted(by: { $0.value.updatedAt < $1.value.updatedAt }).prefix(overflow) {
            all.removeValue(forKey: oldest.key)
        }
    }

    /// Cancella qualunque traccia (posizione E completamento): usato da
    /// "Ricomincia da capo" nell'alert di ripresa, dove l'utente sceglie
    /// esplicitamente di ripartire come se non avesse mai visto nulla.
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
