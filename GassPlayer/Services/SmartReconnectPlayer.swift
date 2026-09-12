import Foundation
import AVFoundation
import Combine

@MainActor
final class SmartReconnectPlayer: NSObject, ObservableObject {
    @Published var isBuffering = false
    @Published var reconnectAttempts = 0
    @Published var preferredBufferSeconds: Double = 5.0 {
        didSet { player.currentItem?.preferredForwardBufferDuration = preferredBufferSeconds }
    }

    let player: AVPlayer
    private let url: URL
    private let maxAttempts = 5
    private var statusObserver: NSKeyValueObservation?
    private var stallObserver: NSObjectProtocol?

    init(url: URL) {
        self.url = url
        self.player = AVPlayer(url: url)
        super.init()
        player.currentItem?.preferredForwardBufferDuration = preferredBufferSeconds
        observe()
    }

    private func observe() {
        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: player.currentItem, queue: .main
        ) { [weak self] _ in
            DebugLogger.shared.log(.warning, "Playback stalled")
            Task { @MainActor in self?.handleStall() }
        }
        statusObserver = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed { Task { @MainActor in self?.reconnect() } }
        }
    }

    private func handleStall() { isBuffering = true; reconnect() }

    private func reconnect() {
        guard reconnectAttempts < maxAttempts else { return }
        reconnectAttempts += 1
        let delay = pow(2.0, Double(reconnectAttempts))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let newItem = AVPlayerItem(url: self.url)
            newItem.preferredForwardBufferDuration = self.preferredBufferSeconds
            self.player.replaceCurrentItem(with: newItem)
            self.player.play()
            self.isBuffering = false
        }
    }
    func resetAttempts() { reconnectAttempts = 0 }
}
