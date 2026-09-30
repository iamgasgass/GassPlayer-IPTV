import SwiftUI

/// KSPlayerLayer (usato tramite KSPlaybackController in PlayerView) gestisce
/// ora da solo tutti i formati, con switch automatico incorporato nella
/// libreria stessa (AVPlayer nativo <-> FFmpeg via KSMEPlayer) su qualunque
/// errore. Questa view resta solo come punto di ingresso stabile per non
/// dover toccare tutti i chiamanti esistenti.
struct AdaptivePlayerView: View {
    let url: URL
    let title: String

    /// FEATURE MANCANTE aggiunta: precedente/successivo, inoltrati opzionalmente
    /// dal chiamante (es. ChannelGridView per lo zapping canali, SeriesEpisodesView
    /// per l'episodio successivo). `nil` di default: i chiamanti esistenti che non
    /// li passano continuano a funzionare esattamente come prima, senza i pulsanti.
    var onPrevious: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil

    var body: some View {
        PlayerView(url: url, title: title, onPrevious: onPrevious, onNext: onNext)
    }
}
