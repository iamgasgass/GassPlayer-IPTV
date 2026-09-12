import Foundation
import AVFoundation
import Combine

@MainActor
final class SmartReconnectPlayer: NSObject, ObservableObject {
    @Published var isBuffering = false
    @Published var reconnectAttempts = 0
    @Published var lastError: String?
    @Published var preferredBufferSeconds: Double = 5.0 {
        didSet { player.currentItem?.preferredForwardBufferDuration = preferredBufferSeconds }
    }

    let player: AVPlayer
    private let url: URL
    private let maxAttempts = 5
    private var statusObserver: NSKeyValueObservation?
    private var timeControlObserver: NSKeyValueObservation?
    private var stallObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?

    init(url: URL) {
        self.url = url
        self.player = AVPlayer(url: url)
        super.init()
        Self.configureAudioSession()

        player.automaticallyWaitsToMinimizeStalling = false
        player.currentItem?.preferredForwardBufferDuration = preferredBufferSeconds
        player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = false

        DebugLogger.logAsync(.info, "SmartReconnectPlayer: avvio riproduzione URL = \(url.absoluteString)")

        observe()
    }

    private static func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            DebugLogger.logAsync(.warning, "Impossibile configurare AVAudioSession: \(error.localizedDescription)")
        }
    }

    private func observe() {
        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: player.currentItem, queue: nil
        ) { [weak self] _ in
            DebugLogger.logAsync(.warning, "Playback stalled")
            Task { @MainActor in self?.handleStall() }
        }

        statusObserver = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed {
                let underlying = item.error?.localizedDescription ?? "errore sconosciuto"
                DebugLogger.logAsync(.error, "AVPlayerItem fallito per URL \(self?.url.absoluteString ?? "?"): \(underlying)")
                Task { @MainActor in self?.reconnect(lastKnownError: underlying) }
            }
        }

        timeControlObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            if type == .ended {
                Task { @MainActor in self?.player.play() }
            }
        }
    }

    private func handleStall() { isBuffering = true; reconnect(lastKnownError: nil) }

    private func reconnect(lastKnownError: String?) {
        guard reconnectAttempts < maxAttempts else {
            let message = lastKnownError.map { "Impossibile riprodurre il flusso dopo \(maxAttempts) tentativi: \($0)" }
                ?? "Impossibile riprodurre il flusso dopo \(maxAttempts) tentativi."
            DebugLogger.logAsync(.error, message)
            lastError = message
            isBuffering = false
            return
        }
        reconnectAttempts += 1
        let delay = pow(2.0, Double(reconnectAttempts))
        DebugLogger.logAsync(.warning, "Tentativo di riconnessione \(reconnectAttempts)/\(maxAttempts) su \(url.absoluteString)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let newItem = AVPlayerItem(url: self.url)
            newItem.preferredForwardBufferDuration = self.preferredBufferSeconds
            newItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
            self.player.replaceCurrentItem(with: newItem)
            self.player.play()
            self.isBuffering = false
        }
    }
    func resetAttempts() { reconnectAttempts = 0; lastError = nil }
}
