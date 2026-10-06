import SwiftUI

/// KSPlayerLayer (usato tramite KSPlaybackController in PlayerView) gestisce
/// ora da solo tutti i formati, con switch automatico incorporato nella
/// libreria stessa (AVPlayer nativo <-> FFmpeg via KSMEPlayer) su qualunque
/// errore. Questa view resta solo come punto di ingresso stabile per non
/// dover toccare tutti i chiamanti esistenti.
struct AdaptivePlayerView: View {
    let url: URL
    let title: String

    /// Rigo sopra il titolo ("Stagione 1 Episodio 3") e contesto canale live
    /// (logo, nome, programma in onda): opzionali, i chiamanti che non li
    /// passano vedono solo titolo e badge. DICHIARATI PRIMA di
    /// `onPrevious`/`onNext`: l'inizializzatore memberwise vuole gli
    /// argomenti nell'ordine delle proprietà, e tutti i chiamanti passano
    /// `subtitle`/`liveInfo` prima dello zapping.
    var subtitle: String? = nil
    var liveInfo: PlayerLiveInfo? = nil

    /// Precedente/successivo, inoltrati opzionalmente dal chiamante (es.
    /// ChannelGridView per lo zapping canali, SeriesEpisodesView per
    /// l'episodio successivo). `nil` di default: i chiamanti che non li
    /// passano continuano a funzionare senza i pulsanti.
    var onPrevious: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil

    var body: some View {
        PlayerView(
            url: url,
            title: title,
            subtitle: subtitle,
            liveInfo: liveInfo,
            onPrevious: onPrevious,
            onNext: onNext
        )
    }
}
