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
    /// Immagine della scheda dettaglio (backdrop TMDB o, in mancanza,
    /// quella del provider): la stessa mostrata nell'hero di
    /// `MovieDetailView`/`SeriesEpisodesView`. Opzionale: gli elementi
    /// salvati prima di questo campo si decodificano con `nil` e mostrano
    /// il segnaposto a icona finché non vengono riaperti.
    var imageURLString: String? = nil
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
    func record(id: String, title: String, kind: String, streamURL: URL, imageURLString: String? = nil) {
        // Se l'elemento esisteva già e questa chiamata non porta un'immagine,
        // si conserva quella precedente invece di perderla.
        let previousImage = items.first { $0.id == id }?.imageURLString

        items.removeAll { $0.id == id }
        items.insert(
            RecentlyWatchedItem(
                id: id,
                title: title,
                kind: kind,
                streamURL: streamURL,
                openedAt: Date(),
                imageURLString: imageURLString ?? previousImage
            ),
            at: 0
        )

        if items.count > maxItems {
            items.removeLast(items.count - maxItems)
        }

        persist()
        warmImageCache(for: items.first?.imageURLString)
    }

    func remove(_ item: RecentlyWatchedItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    /// Svuota solo gli elementi di un tipo ("live"/"movie"/"series"):
    /// usato da "Continua a guardare" nelle schede dettaglio, che mostrano
    /// soltanto i contenuti della propria sezione.
    func clear(kind: String) {
        items.removeAll { $0.kind == kind }
        persist()
    }

    /// Aggiorna l'immagine degli elementi che corrispondono, senza
    /// cambiarne l'ordine. Chiamata dalle schede dettaglio appena caricato
    /// il backdrop, così anche i titoli guardati prima dell'introduzione
    /// del campo mostrano in `HomeView` la stessa immagine della scheda.
    func updateImage(_ urlString: String, where matches: (RecentlyWatchedItem) -> Bool) {
        var changed = false
        for index in items.indices where matches(items[index]) && items[index].imageURLString != urlString {
            items[index].imageURLString = urlString
            changed = true
        }
        if changed {
            persist()
            warmImageCache(for: urlString)
        }
    }

    /// Scarica subito l'immagine della card nella cache condivisa: quando
    /// `HomeView` o `ChannelGridView` mostrano "Continua a guardare" il
    /// poster è già pronto e compare al primo frame.
    private func warmImageCache(for urlString: String?) {
        guard let url = ImageURLNormalizer.url(from: urlString) else { return }
        ImageLoader.shared.prefetch([url], maxPixel: ContinueWatchingSection.imagePixels)
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

        // Riscalda le immagini delle card già salvate (le prime visibili).
        let urls = decoded.prefix(12).compactMap { ImageURLNormalizer.url(from: $0.imageURLString) }
        ImageLoader.shared.prefetch(urls, maxPixel: ContinueWatchingSection.imagePixels)
    }
}
