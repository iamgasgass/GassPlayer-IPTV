import SwiftUI

/// KSPlayerLayer (usato tramite KSPlaybackController in PlayerView) gestisce
/// ora da solo tutti i formati, con switch automatico incorporato nella
/// libreria stessa (AVPlayer nativo <-> FFmpeg via KSMEPlayer) su qualunque
/// errore. Questa view resta solo come punto di ingresso stabile per non
/// dover toccare i chiamanti esistenti (ChannelGridView, SeriesEpisodesView).
struct AdaptivePlayerView: View {
    let url: URL
    let title: String

    var body: some View {
        PlayerView(url: url, title: title)
    }
}
