import SwiftUI
import KSPlayer

/// Punto di ingresso unico per la riproduzione: sceglie automaticamente tra il
/// player nativo AVFoundation (gia' verificato, con tutte le funzioni: lock
/// screen, watchdog, fallback estensioni, controlli unificati) e KSPlayer
/// (AVPlayer+FFmpeg) per i formati che AVFoundation non supporta nativamente
/// su iOS (MKV, AVI, WMV, FLV, WebM).
///
/// NOTA IMPORTANTE: l'inizializzatore KSVideoPlayerView(url:) e' basato sulla
/// documentazione pubblica e sull'uso nella demo ufficiale di KSPlayer, non
/// verificato a compilazione (dipendenza pinnata al branch "main", API non
/// garantita stabile). Se il primo build fallisce su questo file, manda il
/// log esatto: la correzione e' immediata una volta visto l'errore reale.
struct AdaptivePlayerView: View {
    let url: URL
    let title: String

    var body: some View {
        if SmartReconnectPlayer.isNativelySupported(url: url) {
            PlayerView(url: url, title: title)
        } else {
            KSPlayerFallbackView(url: url, title: title)
        }
    }
}

/// Player di riserva per contenitori non supportati da AVFoundation.
/// Usa i controlli nativi di KSPlayer (non quelli custom di PlayerView):
/// integrazione isolata e a basso rischio, non entangled con la pipeline
/// AVPlayer gia' verificata.
private struct KSPlayerFallbackView: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            KSVideoPlayerView(url: url)
                .ignoresSafeArea()

            HStack {
                GlassIconButton(systemImage: "xmark") { dismiss() }
                Spacer()
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(radius: 4)
                Spacer()
            }
            .padding()
        }
        .statusBarHidden(true)
    }
}
