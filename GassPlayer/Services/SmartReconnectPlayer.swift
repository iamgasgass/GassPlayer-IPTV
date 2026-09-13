import Foundation
import AVFoundation
import MediaPlayer
import Network
import Combine

@MainActor
final class SmartReconnectPlayer: NSObject, ObservableObject {
    @Published var isBuffering = false
    @Published var reconnectAttempts = 0
    @Published var lastError: String?
    @Published var exhaustedAllNativeOptions = false
    @Published var preferredBufferSeconds: Double = 5.0 {
        didSet { player.currentItem?.preferredForwardBufferDuration = preferredBufferSeconds }
    }

    let player: AVPlayer
    private let originalURL: URL
    private let candidateURLs: [URL]
    private var candidateIndex = 0
    private let maxAttemptsPerCandidate = 3
    private let title: String
    private var statusObserver: NSKeyValueObservation?
    private var timeControlObserver: NSKeyValueObservation?
    private var stallObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.gassplayer.network-monitor")
    private var isNetworkAvailable = true
    private var watchdogTask: Task<Void, Never>?
    private var autoplayAssertTask: Task<Void, Never>?
    private var hasEverStartedPlaying = false

    private static let playableExtensions: Set<String> = ["mp4", "m4v", "mov", "ts", "m3u8"]
    static let knownUnsupportedContainers: Set<String> = ["mkv", "avi", "wmv", "flv", "webm"]

    static func isNativelySupported(url: URL) -> Bool {
        !knownUnsupportedContainers.contains(url.pathExtension.lowercased())
    }

    private var currentURL: URL { candidateURLs[candidateIndex] }

    init(url: URL, title: String = "") {
        self.originalURL = url
        self.title = title
        self.candidateURLs = Self.buildCandidateURLs(from: url)
        self.player = AVPlayer(url: candidateURLs.first ?? url)
        super.init()
        Self.configureAudioSession()

        player.automaticallyWaitsToMinimizeStalling = false
        player.currentItem?.preferredForwardBufferDuration = preferredBufferSeconds
        player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = false

        DebugLogger.logAsync(.info, "SmartReconnectPlayer: avvio riproduzione URL = \(url.absoluteString), candidati disponibili: \(candidateURLs.map(\.absoluteString))")

        let originalExt = url.pathExtension.lowercased()
        if Self.knownUnsupportedContainers.contains(originalExt) {
            DebugLogger.logAsync(.error, "Formato contenitore .\(originalExt) non supportato nativamente da AVPlayer su iOS")
            lastError = "Questo contenuto e' in formato .\(originalExt.uppercased()), non supportato dal player nativo di iOS (AVPlayer supporta solo MP4, MOV e flussi HLS). Il fornitore dovrebbe offrire una versione MP4 di questo contenuto."
        }

        observePlayerLevelEvents()
        if let item = player.currentItem {
            attachItemObservers(to: item)
        }
        observeNetwork()
        configureRemoteCommandCenter()
        updateNowPlayingInfo()
        startWatchdog()

        requestPlay()
    }

    private static func buildCandidateURLs(from url: URL) -> [URL] {
        let pathComponents = url.pathComponents
        let extensionsToTry: [String]
        if pathComponents.contains("live") {
            extensionsToTry = ["m3u8", "ts"]
        } else if pathComponents.contains("movie") || pathComponents.contains("series") {
            extensionsToTry = ["mp4", "m4v", "mov", "ts", "m3u8"]
        } else {
            return [url]
        }

        let currentExt = url.pathExtension.lowercased()
        let base = url.deletingPathExtension()
        var seen = Set<String>()
        var result: [URL] = []
        if playableExtensions.contains(currentExt) {
            result.append(url)
            seen.insert(url.absoluteString)
        }

        for ext in extensionsToTry where ext != currentExt {
            let candidate = base.appendingPathExtension(ext)
            if !seen.contains(candidate.absoluteString) {
                result.append(candidate)
                seen.insert(candidate.absoluteString)
            }
        }
        return result.isEmpty ? [url] : result
    }

    private static func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            DebugLogger.logAsync(.warning, "Impossibile configurare AVAudioSession: \(error.localizedDescription)")
        }
    }

    private func observeNetwork() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let available = path.status == .satisfied
                if self.isNetworkAvailable && !available {
                    DebugLogger.logAsync(.error, "Rete non disponibile, riproduzione sospesa")
                    self.lastError = "Nessuna connessione di rete disponibile."
                } else if !self.isNetworkAvailable && available && self.lastError != nil {
                    DebugLogger.logAsync(.info, "Rete tornata disponibile, ritento la riproduzione")
                    self.resetAttempts()
                }
                self.isNetworkAvailable = available
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if !self.hasEverStartedPlaying && self.lastError == nil {
                DebugLogger.logAsync(.error, "Watchdog: nessuna riproduzione avviata dopo 15s per \(self.currentURL.absoluteString), nessun errore esplicito da AVPlayer")
                self.handleFailure(lastKnownError: "Il flusso non si e' avviato entro 15 secondi. Il formato potrebbe non essere supportato o il server non risponde correttamente.")
            }
        }
    }

    private func observePlayerLevelEvents() {
        timeControlObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                if player.timeControlStatus == .playing {
                    self?.hasEverStartedPlaying = true
                    self?.watchdogTask?.cancel()
                    self?.autoplayAssertTask?.cancel()
                }
                self?.updateNowPlayingInfo()
            }
        }

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            if type == .ended {
                Task { @MainActor in self?.requestPlay() }
            }
        }
    }

    private func attachItemObservers(to item: AVPlayerItem) {
        statusObserver?.invalidate()
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }

        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: nil
        ) { [weak self] _ in
            DebugLogger.logAsync(.warning, "Playback stalled")
            Task { @MainActor in self?.handleStall() }
        }

        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed {
                let underlying = item.error?.localizedDescription ?? "errore sconosciuto"
                Task { @MainActor in
                    guard let self else { return }
                    DebugLogger.logAsync(.error, "AVPlayerItem fallito per URL \(self.currentURL.absoluteString): \(underlying)")
                    self.handleFailure(lastKnownError: underlying)
                }
            } else if item.status == .readyToPlay {
                Task { @MainActor in
                    guard let self else { return }
                    self.updateNowPlayingInfo()
                    if self.player.rate == 0, self.player.timeControlStatus != .playing {
                        self.requestPlay()
                    }
                }
            }
        }
    }

    private func replaceItem(with url: URL) {
        let newItem = AVPlayerItem(url: url)
        newItem.preferredForwardBufferDuration = preferredBufferSeconds
        newItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        player.replaceCurrentItem(with: newItem)
        attachItemObservers(to: newItem)
    }

    private func requestPlay() {
        player.play()
        assertPlaybackReallyStarts()
    }

    private func assertPlaybackReallyStarts() {
        autoplayAssertTask?.cancel()
        autoplayAssertTask = Task { [weak self] in
            for delayMs in [400, 900, 1800, 3000] {
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.lastError == nil else { return }
                let alreadyPlaying = self.player.rate != 0 || self.player.timeControlStatus == .playing
                let isLegitimatelyBuffering = self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    && self.player.currentItem?.status != .failed
                if alreadyPlaying || isLegitimatelyBuffering { return }
                DebugLogger.logAsync(.warning, "Autoplay non confermato dopo \(delayMs)ms (rate=0, timeControlStatus=\(self.player.timeControlStatus.rawValue)): forzo ciclo pausa->play")
                self.player.pause()
                self.player.play()
            }
        }
    }

    private func configureRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.requestPlay()
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.player.pause()
            return .success
        }
        commandCenter.stopCommand.addTarget { [weak self] _ in
            self?.player.pause()
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.player.timeControlStatus == .paused {
                self.requestPlay()
            } else {
                self.player.pause()
            }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title.isEmpty ? "GassPlayer" : title,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: player.timeControlStatus == .playing ? 1.0 : 0.0
        ]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func handleStall() { isBuffering = true; reconnect(lastKnownError: nil) }

    private func handleFailure(lastKnownError: String?) {
        if candidateIndex < candidateURLs.count - 1 {
            candidateIndex += 1
            DebugLogger.logAsync(.warning, "URL fallita, provo estensione alternativa: \(currentURL.absoluteString)")
            replaceItem(with: currentURL)
            requestPlay()
            startWatchdog()
            return
        }
        reconnect(lastKnownError: lastKnownError)
    }

    private func reconnect(lastKnownError: String?) {
        guard isNetworkAvailable else {
            lastError = "Nessuna connessione di rete disponibile."
            isBuffering = false
            return
        }
        guard reconnectAttempts < maxAttemptsPerCandidate else {
            let triedURLs = candidateURLs.map(\.absoluteString).joined(separator: ", ")
            let message = lastKnownError.map { "Impossibile riprodurre il flusso: \($0). URL tentate: \(triedURLs)" }
                ?? "Impossibile riprodurre il flusso dopo aver provato tutte le estensioni disponibili."
            DebugLogger.logAsync(.error, message)
            lastError = message
            isBuffering = false
            exhaustedAllNativeOptions = true
            return
        }
        reconnectAttempts += 1
        let delay = pow(2.0, Double(reconnectAttempts))
        DebugLogger.logAsync(.warning, "Tentativo di riconnessione \(reconnectAttempts)/\(maxAttemptsPerCandidate) su \(currentURL.absoluteString)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.replaceItem(with: self.currentURL)
            self.requestPlay()
            self.isBuffering = false
            self.startWatchdog()
        }
    }

    func resetAttempts() {
        reconnectAttempts = 0
        candidateIndex = 0
        lastError = nil
        hasEverStartedPlaying = false
        replaceItem(with: originalURL)
        requestPlay()
        startWatchdog()
    }

    deinit {
        watchdogTask?.cancel()
        autoplayAssertTask?.cancel()
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        statusObserver?.invalidate()
        timeControlObserver?.invalidate()
        pathMonitor.cancel()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
