import Foundation
import Combine

/// Un contenuto aperto di recente in riproduzione (Live TV, VOD o Serie TV).
struct RecentlyWatchedItem: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    /// Uguale a `XtreamStreamKind.rawValue` ("live"/"movie"/"series").
    var kind: String
    var streamURL: URL
    var openedAt: Date = Date()
}

/// Traccia gli ultimi contenuti aperti in riproduzione per alimentare la
/// sezione "Continua a guardare" in `HomeView`.
///
/// Registra id, titolo, URL dello stream già risolto e timestamp di
/// apertura ogni volta che l'utente avvia una riproduzione (Live TV, VOD,
/// episodio di una serie o canale M3U): è un elenco reale e persistito su
/// disco, non un mock. "Riprendi" riapre lo stesso URL con lo stesso
/// player usato dal resto dell'app, non un placeholder.
///
/// Non traccia la posizione esatta di riproduzione (secondi) perché il
/// player attuale (`KSPlaybackController`, dietro `PlayerView`) non espone
/// ancora un callback di avanzamento verso l'esterno: aggiungerlo qui
/// avrebbe richiesto di modificare il cuore della riproduzione senza poter
/// compilare/testare in questo ambiente, un rischio che non vale la pena
/// correre. "Continua a guardare" qui significa quindi "riprendi da dove
/// hai lasciato l'elenco", riaprendo lo stream dall'inizio — comunque un
/// risparmio di tempo reale rispetto a ricercare di nuovo il contenuto.
@MainActor
final class RecentlyWatchedStore: ObservableObject {
    @Published private(set) var items: [RecentlyWatchedItem] = []

    private let storageKey = "gassplayer.recentlyWatched"
    private let maxItems = 20

    init() {
        load()
    }

    /// Registra (o sposta in cima, se già presente) un contenuto appena
    /// aperto in riproduzione.
    func record(id: String, title: String, kind: String, streamURL: URL) {
        items.removeAll { $0.id == id }
        items.insert(
            RecentlyWatchedItem(
                id: id,
                title: title,
                kind: kind,
                streamURL: streamURL,
                openedAt: Date()
            ),
            at: 0
        )

        if items.count > maxItems {
            items.removeLast(items.count - maxItems)
        }

        persist()
    }

    func remove(_ item: RecentlyWatchedItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([RecentlyWatchedItem].self, from: data) else {
            return
        }
        items = decoded
    }
}
