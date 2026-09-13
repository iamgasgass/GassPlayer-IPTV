import SwiftUI
import KSPlayer

/// Punto di ingresso unico per la riproduzione: sceglie automaticamente tra il
/// player nativo AVFoundation e KSPlayer (AVPlayer+FFmpeg) per i formati che
/// AVFoundation non supporta nativamente su iOS (MKV, AVI, WMV, FLV, WebM).
///
/// FIX "alcuni titoli di serie TV non partono": il container reale di un
/// episodio non e' sempre noto in anticipo — se "container_extension" manca
/// nella risposta Xtream, il chiamante presume ".mp4", ma il file potrebbe
/// essere MKV. In quel caso isNativelySupported(url:) lascia passare
/// erroneamente il file al player nativo, che esaurisce i retry e si blocca
/// su un errore statico senza mai provare l'alternativa che probabilmente
/// funzionerebbe. Ora, quando SmartReconnectPlayer segnala che ha esaurito
/// tutte le opzioni native (exhaustedAllNativeOptions), questa view passa
/// automaticamente al fallback KSPlayer come ultima risorsa.
struct AdaptivePlayerView: View {
    let url: URL
    let title: String
    @State private var forceFallbackPlayer = false

    var body: some View {
        if forceFallbackPlayer || !SmartReconnectPlayer.isNativelySupported(url: url) {
            KSPlayerFallbackView(url: url, title: title)
        } else {
            PlayerView(url: url, title: title, onExhaustedNativeOptions: {
                DebugLogger.logAsync(.warning, "AdaptivePlayerView: opzioni native esaurite per \(url.absoluteString), passo a KSPlayer come ultima risorsa")
                forceFallbackPlayer = true
            })
        }
    }
}

private struct KSPlayerFallbackView: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            KSVideoPlayerView(url: url, options: KSOptions())
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
