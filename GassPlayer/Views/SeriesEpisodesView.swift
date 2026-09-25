import SwiftUI

// FIX 2026-09-25 (episodio successivo "senza uscire e riaprire il
// player"): `PlayerView` espone `onPrevious`/`onNext` opzionali. Qui
// vengono calcolati a partire dall'`Episode` selezionato (già
// `Identifiable`) e collegati al `fullScreenCover`. Nessun `.id()`
// esplicito sulla vista presentata: il controller carica il nuovo
// episodio in-place nella stessa `PlayerView`, senza mai ricrearla.
//
// FIX 2026-09-26 (episodio successivo che scavalca la fine stagione):
// `adjacentEpisode` cercava l'episodio adiacente SOLO dentro
// `selectedSeason`, quindi il pulsante "successivo" spariva
// silenziosamente all'ultimo episodio di ogni stagione, interrompendo il
// binge-watching esattamente nel punto in cui l'utente se lo aspetta di
// meno. Ora la ricerca avviene su una lista "appiattita" di TUTTE le
// stagioni in ordine (`flattenedEpisodes`), quindi precedente/successivo
// attraversano naturalmente il confine di stagione. L'aggiornamento di
// `selectedSeason` (per tenere coerente l'evidenziazione nella `List`)
// avviene SOLO al momento del tap, dentro `selectEpisode(_:)` — mai
// durante il calcolo di `body`/`onPrevious`/`onNext`, per evitare il
// classico "Modifying state during view update" di SwiftUI: calcolare
// quale episodio sia adiacente (per decidere se il pulsante deve esistere)
// è un'operazione pura, senza effetti collaterali.
struct SeriesEpisodesView: View {
    let credentials: XtreamCredentials
    let seriesId: Int
    let seriesName: String

    @EnvironmentObject private var recentlyWatched: RecentlyWatchedStore

    @State private var seriesInfo: XtreamSeriesInfo?
    @State private var selectedSeason: Int?
    @State private var isLoading = true
    @State private var errorMessage: String?

    /// Episodio attualmente in riproduzione. Da questo si derivano URL,
    /// titolo e adiacenza (anche cross-stagione) allo stesso modo.
    @State private var selectedEpisode: XtreamSeriesInfo.Episode?

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Caricamento episodi...").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    Text(errorMessage).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Riprova") { Task { await loadSeriesInfo() } }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let info = seriesInfo {
                List {
                    Section("Stagioni") {
                        ForEach(info.sortedSeasonNumbers, id: \.self) { season in
                            Button("Stagione \(season)") { selectedSeason = season }
                        }
                    }

                    if let selectedSeason {
                        Section("Episodi — Stagione \(selectedSeason)") {
                            ForEach(info.episodes(forSeason: selectedSeason)) { episode in
                                Button {
                                    selectedEpisode = episode
                                } label: {
                                    HStack {
                                        Text("\(episode.episodeNum).")
                                            .foregroundStyle(.secondary)
                                        Text(episode.title)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(seriesName)
        .task { await loadSeriesInfo() }
        .fullScreenCover(item: $selectedEpisode) { episode in
            if let url = episodeStreamURL(for: episode) {
                AdaptivePlayerView(
                    url: url,
                    title: episode.title,
                    onPrevious: adjacentEpisode(to: episode, offset: -1).map { target in
                        { selectEpisode(target) }
                    },
                    onNext: adjacentEpisode(to: episode, offset: 1).map { target in
                        { selectEpisode(target) }
                    }
                )
                // FIX (episodio successivo "senza uscire e riaprire il
                // player"): nessun `.id(episode.id)` — il controller carica
                // il nuovo episodio in-place nella stessa `PlayerView`.
                // `.task(id: episode.id)` al posto di `.onAppear` per
                // registrare ogni episodio nei "visti di recente", incluso
                // il primo, dato che la vista non viene più ricreata ad
                // ogni avanzamento.
                .task(id: episode.id) {
                    recordRecentlyWatched(episode: episode, url: url)
                }
            } else {
                ContentUnavailableView(
                    "URL dell'episodio non valido",
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
    }

    private func episodeStreamURL(for episode: XtreamSeriesInfo.Episode) -> URL? {
        let service = XtreamAPIService(credentials: credentials)
        let ext = episode.containerExtension?.isEmpty == false ? episode.containerExtension! : "mp4"
        return service.episodeStreamURL(episodeId: episode.streamId, ext: ext)
    }

    /// Lista di tutti gli episodi di TUTTE le stagioni, appiattita
    /// nell'ordine mostrato in `List` (stagioni ordinate, episodi
    /// ordinati come restituiti da `episodes(forSeason:)`). Base per il
    /// calcolo di adiacenza che attraversa il confine di stagione.
    private func flattenedEpisodes(_ info: XtreamSeriesInfo) -> [(season: Int, episode: XtreamSeriesInfo.Episode)] {
        info.sortedSeasonNumbers.flatMap { season in
            info.episodes(forSeason: season).map { (season: season, episode: $0) }
        }
    }

    /// FEATURE 2026-09-26: episodio adiacente calcolato sull'intero
    /// catalogo della serie (tutte le stagioni), non più limitato alla
    /// sola `selectedSeason`: raggiunto l'ultimo episodio di una stagione,
    /// "successivo" propone il primo episodio della stagione seguente
    /// (e viceversa per "precedente"), come un servizio di streaming
    /// vero. `nil` solo ai bordi ASSOLUTI del catalogo (primo episodio
    /// della prima stagione / ultimo dell'ultima), così i pulsanti
    /// corrispondenti in `PlayerView` si nascondono automaticamente.
    /// Funzione pura: nessun effetto collaterale, sicura da chiamare
    /// durante il calcolo di `body`.
    private func adjacentEpisode(
        to episode: XtreamSeriesInfo.Episode,
        offset: Int
    ) -> (season: Int, episode: XtreamSeriesInfo.Episode)? {
        guard let info = seriesInfo else { return nil }

        let flattened = flattenedEpisodes(info)
        guard let currentIndex = flattened.firstIndex(where: { $0.episode.id == episode.id }) else { return nil }

        let targetIndex = currentIndex + offset
        guard flattened.indices.contains(targetIndex) else { return nil }

        return flattened[targetIndex]
    }

    /// Applica la selezione di un episodio adiacente (eventualmente in
    /// un'altra stagione): SOLO qui, al momento del tap sul pulsante
    /// precedente/successivo, si aggiorna anche `selectedSeason` per
    /// tenere coerente l'evidenziazione nella `List` — mai durante il
    /// calcolo di `body`, per evitare mutazioni di stato durante
    /// l'aggiornamento della vista.
    private func selectEpisode(_ target: (season: Int, episode: XtreamSeriesInfo.Episode)) {
        if target.season != selectedSeason {
            selectedSeason = target.season
        }
        selectedEpisode = target.episode
    }

    private func recordRecentlyWatched(episode: XtreamSeriesInfo.Episode, url: URL) {
        recentlyWatched.record(
            id: [
                credentials.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                credentials.username,
                "series",
                String(seriesId),
                String(episode.streamId)
            ].joined(separator: "|"),
            title: "\(seriesName) · \(episode.title)",
            kind: "series",
            streamURL: url
        )
    }

    private func loadSeriesInfo() async {
        isLoading = true
        errorMessage = nil
        let repository = CachedXtreamRepository(credentials: credentials)
        do {
            let info = try await repository.seriesInfo(seriesId: seriesId)
            seriesInfo = info
            selectedSeason = info.sortedSeasonNumbers.first
            if info.sortedSeasonNumbers.isEmpty {
                errorMessage = "Nessun episodio trovato per questa serie."
            }
        } catch let error as XtreamError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Errore imprevisto: \(error.localizedDescription)"
        }
        isLoading = false
    }
}
