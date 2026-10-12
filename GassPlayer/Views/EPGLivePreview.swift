import SwiftUI
import UIKit
import KSPlayer

/// Anteprima video MUTA del canale selezionato nella guida "Categorie TV"
/// della Live TV, come il riquadro `TvEpgPreviewPanel` Android (ExoPlayer a
/// volume 0): stesso motore del player (KSPlayer/FFmpeg, quindi anche i
/// flussi `.ts` Xtream), ma senza controlli, Now Playing né PiP.
///
/// - `url == nil` ferma e chiude davvero il flusso (player aperto, schermata
///   non visibile, nessun canale): i provider accettano spesso 1-2
///   connessioni e l'anteprima non deve mai occuparne una mentre si guarda.
/// - Cambi rapidi di canale sono assorbiti da un ritardo di 180 ms (come
///   Android): si apre solo il flusso del canale scelto per ultimo.
struct EPGLivePreviewPlayer: UIViewRepresentable {
    let url: URL?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        container.isUserInteractionEnabled = false
        container.clipsToBounds = true
        context.coordinator.container = container
        context.coordinator.load(url)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.load(url)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.load(nil)
    }

    final class Coordinator: NSObject, KSPlayerLayerDelegate {
        weak var container: UIView?
        private var currentURL: URL?
        private var layer: KSPlayerLayer?
        private weak var playerView: UIView?
        private var pendingStart: DispatchWorkItem?

        func load(_ url: URL?) {
            guard url != currentURL else { return }
            currentURL = url
            pendingStart?.cancel()
            pendingStart = nil
            teardown()

            guard let url else { return }
            let work = DispatchWorkItem { [weak self] in self?.start(url) }
            pendingStart = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }

        private func start(_ url: URL) {
            guard currentURL == url, let container else { return }
            pendingStart = nil

            let userAgent = PlaybackProfileStore.userAgent(for: url) ?? StreamUserAgents.vlc
            let options = KSOptions()
            options.userAgent = userAgent
            // Anteprima: niente comandi remoti/Now Playing né PiP automatico.
            options.registerRemoteControll = false
            options.canStartPictureInPictureAutomaticallyFromInline = false
            if url.scheme == "http" || url.scheme == "https" {
                options.formatContextOptions["user_agent"] = userAgent
                options.formatContextOptions["reconnect"] = 1
                options.formatContextOptions["reconnect_streamed"] = 1
                options.formatContextOptions["reconnect_delay_max"] = 2
                options.formatContextOptions["timeout"] = 15_000_000
                options.formatContextOptions["rw_timeout"] = 15_000_000
            }

            let newLayer = KSPlayerLayer(url: url, isAutoPlay: true, options: options, delegate: nil)
            newLayer.delegate = self
            newLayer.player.isMuted = true
            newLayer.player.contentMode = .scaleAspectFit
            layer = newLayer

            if let view = newLayer.player.view {
                // Trasparente finché non arrivano fotogrammi: sotto resta il
                // logo del canale, come lo shutter trasparente di Android.
                view.alpha = 0
                view.backgroundColor = .clear
                view.isUserInteractionEnabled = false
                view.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(view)
                NSLayoutConstraint.activate([
                    view.topAnchor.constraint(equalTo: container.topAnchor),
                    view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                    view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                ])
                playerView = view
            }
            newLayer.play()
        }

        /// Chiude davvero la connessione (pause -> shutdown, come
        /// `KSPlaybackController.teardown`).
        private func teardown() {
            guard let old = layer else { return }
            layer = nil
            old.delegate = nil
            old.pause()
            old.player.shutdown()
            playerView?.removeFromSuperview()
            playerView = nil
        }

        // MARK: KSPlayerLayerDelegate

        func player(layer: KSPlayerLayer, state: KSPlayerState) {
            guard layer === self.layer else { return }
            // Sempre muta, anche dopo che il motore ha aperto l'audio.
            layer.player.isMuted = true
            if state == .readyToPlay || state == .bufferFinished, let view = playerView, view.alpha < 1 {
                UIView.animate(withDuration: 0.15) { view.alpha = 1 }
            }
        }

        func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {}

        func player(layer: KSPlayerLayer, finish error: Error?) {
            guard layer === self.layer else { return }
            playerView?.alpha = 0
        }

        func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {}
    }
}
