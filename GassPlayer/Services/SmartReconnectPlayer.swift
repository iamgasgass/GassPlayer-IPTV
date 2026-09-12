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
    private let originalURL: URL
    private let candidateURLs: [URL]
    private var candidateIndex = 0
    private let maxAttemptsPerCandidate = 3
    private var statusObserver: NSKeyValueObservation?
    private var timeControlObserver: NSKeyValueObservation?
    private var stallObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?

    private var currentURL: URL { candidateURLs[candidateIndex] }

    init(url: URL) {
        self.originalURL = url
        self.candidateURLs = Self.buildCandidateURLs(from: url)
        self.player = AVPlayer(url: url)
        super.init()
        Self.configureAudioSession()

        player.automaticallyWaitsToMinimizeStalling = false
        player.currentItem?.preferredForwardBufferDuration = preferredBufferSeconds
        player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = false

        DebugLogger.logAsync(.info, "SmartReconnectPlayer: avvio riproduzione URL = \(url.absoluteString), candidati disponibili: \(candidateURLs.map(\.absoluteString))")

        observe()
    }

    private static func buildCandidateURLs(from url: URL) -> [URL] {
        let pathComponents = url.pathComponents
        let extensionsToTry: [String]
        if pathComponents.contains("live") {
            extensionsToTry = ["m3u8", "ts"]
        } else if pathComponents.contains("movie") || pathComponents.contains("series") {
            extensionsToTry = ["mp4", "mkv", "ts", "avi", "m3u8"]
        } else {
            return [url]
        }

        let currentExt = url.pathExtension.lowercased()
        let base = url.deletingPathExtension()
        var seen = Set<String>()
        var result: [URL] = [url]
        seen.insert(url.absoluteString)

        for ext in extensionsToTry where ext != currentExt {
            let candidate = base.appendingPathExtension(ext)
            if !seen.contains(candidate.absoluteString) {
                result.append(candidate)
                seen.insert(candidate.absoluteString)
            }
        }
        return result
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
                DebugLogger.logAsync(.error, "AVPlayerItem fallito per URL \(self?.currentURL.absoluteString ?? "?"): \(underlying)")
                Task { @MainActor in self?.handleFailure(lastKnownError: underlying) }
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

    private func handleFailure(lastKnownError: String?) {
        if candidateIndex < candidateURLs.count - 1 {
            candidateIndex += 1
            DebugLogger.logAsync(.warning, "URL fallita, provo estensione alternativa: \(currentURL.absoluteString)")
            let newItem = AVPlayerItem(url: currentURL)
            newItem.preferredForwardBufferDuration = preferredBufferSeconds
            newItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
            player.replaceCurrentItem(with: newItem)
            player.play()
            return
        }
        reconnect(lastKnownError: lastKnownError)
    }

    private func reconnect(lastKnownError: String?) {
        guard reconnectAttempts < maxAttemptsPerCandidate else {
            let triedURLs = candidateURLs.map(\.absoluteString).joined(separator: ", ")
            let message = lastKnownError.map { "Impossibile riprodurre il flusso: \($0). URL tentate: \(triedURLs)" }
                ?? "Impossibile riprodurre il flusso dopo aver provato tutte le estensioni disponibili."
            DebugLogger.logAsync(.error, message)
            lastError = message
            isBuffering = false
            return
        }
        reconnectAttempts += 1
        let delay = pow(2.0, Double(reconnectAttempts))
        DebugLogger.logAsync(.warning, "Tentativo di riconnessione \(reconnectAttempts)/\(maxAttemptsPerCandidate) su \(currentURL.absoluteString)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let newItem = AVPlayerItem(url: self.currentURL)
            newItem.preferredForwardBufferDuration = self.preferredBufferSeconds
            newItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
            self.player.replaceCurrentItem(with: newItem)
            self.player.play()
            self.isBuffering = false
        }
    }

    func resetAttempts() {
        reconnectAttempts = 0
        candidateIndex = 0
        lastError = nil
        let newItem = AVPlayerItem(url: originalURL)
        newItem.preferredForwardBufferDuration = preferredBufferSeconds
        newItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        player.replaceCurrentItem(with: newItem)
    }
}
