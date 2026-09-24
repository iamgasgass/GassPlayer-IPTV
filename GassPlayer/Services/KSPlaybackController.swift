import Foundation
import AVFoundation
import MediaPlayer
import KSPlayer

/// Bridge SwiftUI-friendly per KSPlayerLayer, ora l'UNICO motore di
/// riproduzione dell'app (AVPlayer nativo + FFmpeg via KSMEPlayer, con
/// switch automatico incorporato nella libreria stessa — vedi
/// KSPlayerLayer.finish(player:error:), che ritenta con
/// KSOptions.secondPlayerType su qualunque errore prima di arrendersi).
@MainActor
final class KSPlaybackController: NSObject, ObservableObject {
    @Published var state: KSPlayerState = .initialized
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var lastError: String?
    @Published var bufferingProgress: Int = 0
    @Published var isPipActive = false {
        didSet { layer.isPipActive = isPipActive }
    }

    let layer: KSPlayerLayer
    private let originalURL: URL
    private let title: String
    private var watchdogTask: Task<Void, Never>?
    private var hasEverStartedPlaying = false

    /// OTTIMIZZAZIONE FLUIDITÀ: KSPlayer invoca il delegate di avanzamento
    /// molto più spesso di quanto la UI necessiti per apparire fluida
    /// (spesso più volte al secondo). Senza throttling, ogni singolo tick
    /// pubblica una modifica su `currentTime` che rivaluta l'intera
    /// `PlayerView.body` — pulsanti Liquid Glass inclusi — molte più volte
    /// al secondo di quanto un occhio umano possa percepire, sprecando CPU/
    /// GPU e potendo introdurre micro-scatti. Pubblichiamo un aggiornamento
    /// solo se la variazione percepita è reale (>= 200ms) o se la durata
    /// totale è cambiata (es. aggiornamento del DVR live).
    private var lastPublishedTime: TimeInterval = -1

    var isPlaying: Bool { state.isPlaying }
    var isBuffering: Bool { state == .preparing || state == .buffering }

    var supportsPictureInPicture: Bool {
        if #available(iOS 14.0, tvOS 14.0, *) {
            return layer.player.pipController != nil
        }
        return false
    }

    init(url: URL, title: String) {
        self.originalURL = url
        self.title = title
        let options = KSOptions()
        options.preferredForwardBufferDuration = 5
        options.registerRemoteControll = true
        options.canStartPictureInPictureAutomaticallyFromInline = true
        options.userAgent = "GassPlayer/1.0"
        self.layer = KSPlayerLayer(url: url, isAutoPlay: true, options: options, delegate: nil)
        super.init()
        layer.delegate = self
        startWatchdog()
    }

    func togglePlayPause() {
        if isPlaying {
            layer.pause()
        } else {
            layer.play()
        }
    }

    func seek(to time: TimeInterval) {
        layer.seek(time: time, autoPlay: true) { _ in }
    }

    func skip(by interval: TimeInterval) {
        // BUG FIX: su flussi live (duration == 0) il vecchio codice calcolava
        // un limite superiore pari a `.greatestFiniteMagnitude`, producendo
        // un seek non valido/indefinito verso un tempo che lo stream non ha
        // mai avuto. Senza una durata nota, lo skip è semplicemente un
        // no-op: la UI (PlayerView) non mostra nemmeno i pulsanti di skip
        // in questo caso, ma la protezione resta anche qui a livello di
        // controller per qualunque altro chiamante futuro.
        guard duration > 0 else { return }

        let target = max(0, min(layer.player.currentPlaybackTime + interval, duration))
        seek(to: target)
    }

    func setPlaybackRate(_ rate: Float) {
        layer.player.playbackRate = rate
    }

    func resetAttempts() {
        lastError = nil
        hasEverStartedPlaying = false
        layer.play()
        startWatchdog()
    }

    var audioTracks: [MediaPlayerTrack] { layer.player.tracks(mediaType: .audio) }
    var subtitleTracks: [MediaPlayerTrack] { layer.player.tracks(mediaType: .subtitle) }
    var videoTracks: [MediaPlayerTrack] { layer.player.tracks(mediaType: .video) }

    func select(track: MediaPlayerTrack) {
        layer.player.select(track: track)
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard !self.hasEverStartedPlaying, self.lastError == nil else { return }
            DebugLogger.logAsync(.warning, "KSPlaybackController: nessuna riproduzione avviata dopo 12s (stato=\(self.state)), forzo ciclo pausa->play")
            self.layer.pause()
            self.layer.play()
        }
    }

    deinit {
        watchdogTask?.cancel()
    }
}

extension KSPlaybackController: KSPlayerLayerDelegate {
    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        self.state = state
        switch state {
        case .bufferFinished, .buffering:
            hasEverStartedPlaying = true
            watchdogTask?.cancel()
        case .readyToPlay:
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] = title.isEmpty ? "GassPlayer" : title
        case .error:
            lastError = "Impossibile riprodurre il flusso. Il server potrebbe non essere raggiungibile o il formato non e' supportato."
            watchdogTask?.cancel()
        default:
            break
        }
    }

    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        let durationChanged = totalTime != duration
        guard durationChanged || abs(currentTime - lastPublishedTime) >= 0.2 else { return }

        lastPublishedTime = currentTime
        self.currentTime = currentTime
        self.duration = totalTime
    }

    func player(layer: KSPlayerLayer, finish error: Error?) {
        if let error {
            DebugLogger.logAsync(.error, "KSPlaybackController: riproduzione terminata con errore: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {
        DebugLogger.logAsync(.info, "KSPlaybackController: buffer #\(bufferedCount) pronto in \(consumeTime)s")
    }
}
