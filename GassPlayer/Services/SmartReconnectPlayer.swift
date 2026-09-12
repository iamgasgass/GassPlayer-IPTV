import Foundation
import AVFoundation
import Combine

/// Riscritto seguendo le linee guida Apple (WWDC "Measuring and Optimizing
/// HLS Performance", forum AVFoundation) e le guide di troubleshooting HLS
/// 2025-2026 raccolte in fase di ricerca:
/// - `automaticallyWaitsToMinimizeStalling` gestito esplicitamente invece di
///   lasciare il default (che su reti IPTV instabili causa partenze lente)
/// - asset pre-caricato in modo asincrono (`loadValuesAsynchronously`) prima
///   di assegnarlo al player, per evitare ritardi bloccanti sul main thread
/// - buffer iniziale basso per uno start rapido, poi alzato automaticamente
///   se si verificano stalli ripetuti (adattivo, non un valore fisso)
/// - discesa automatica di risoluzione dopo troppi stalli consecutivi
/// - nessun retry quando `NetworkMonitor` segnala che il device è offline:
///   evita di consumare tentativi (e batteria) in un "retry storm" inutile
@MainActor
final class SmartReconnectPlayer: NSObject, ObservableObject {
    @Published var isBuffering = false
    @Published var reconnectAttempts = 0
    @Published var currentBufferSeconds: Double = 3.0
    @Published var qualityWasAutoReduced = false

    @Published var preferredBufferSeconds: Double = 3.0 {
        didSet { player.currentItem?.preferredForwardBufferDuration = preferredBufferSeconds }
    }

    let player: AVPlayer
    private var url: URL
    private let maxAttempts = 6
    private var consecutiveStalls = 0
    private var statusObserver: NSKeyValueObservation?
    private var stallObserver: NSObjectProtocol?
    private var bufferEmptyObserver: NSKeyValueObservation?
    private var likelyToKeepUpObserver: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()

    init(url: URL) {
        self.url = url
        self.player = AVPlayer()
        super.init()
        player.automaticallyWaitsToMinimizeStalling = true
        loadAsset(url: url)
        observeNetworkChanges()
    }

    /// Precarica l'asset in modo asincrono prima di assegnarlo al player:
    /// evita che la UI resti bloccata mentre AVFoundation risolve DNS/TLS
    /// e legge il manifest HLS iniziale (fonte: WWDC16 "Advances in
    /// AVFoundation Playback").
    private func loadAsset(url: URL) {
        let asset = AVURLAsset(url: url)
        let keys = ["playable", "duration"]
        asset.loadValuesAsynchronously(forKeys: keys) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let item = AVPlayerItem(asset: asset)
                item.preferredForwardBufferDuration = self.currentBufferSeconds
                self.player.replaceCurrentItem(with: item)
                self.observe(item: item)
            }
        }
    }

    private func observe(item: AVPlayerItem) {
        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: nil
        ) { [weak self] _ in
            DebugLogger.logAsync(.warning, "Playback stalled")
            Task { @MainActor in self?.handleStall() }
        }

        statusObserver = item.observe(\.status, options: [.new]) { [weak self] currentItem, _ in
            if currentItem.status == .failed {
                Task { @MainActor in self?.reconnect() }
            }
        }

        bufferEmptyObserver = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] currentItem, _ in
            if currentItem.isPlaybackBufferEmpty {
                Task { @MainActor in self?.isBuffering = true }
            }
        }

        likelyToKeepUpObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] currentItem, _ in
            if currentItem.isPlaybackLikelyToKeepUp {
                Task { @MainActor in
                    self?.isBuffering = false
                    self?.consecutiveStalls = 0
                }
            }
        }
    }

    /// Se la rete è offline, non tentiamo nemmeno la riconnessione:
    /// aspettiamo che NetworkMonitor segnali il ripristino.
    private func observeNetworkChanges() {
        NetworkMonitor.shared.$isConnected
            .sink { [weak self] connected in
                if connected { self?.reconnectAttempts = 0 }
            }
            .store(in: &cancellables)
    }

    private func handleStall() {
        isBuffering = true
        consecutiveStalls += 1

        // Buffer adattivo: parte basso per uno start veloce, sale se lo
        // stream continua a bloccarsi (fino a un massimo ragionevole).
        if consecutiveStalls >= 2 && currentBufferSeconds < 15 {
            currentBufferSeconds = min(currentBufferSeconds + 4, 15)
            player.currentItem?.preferredForwardBufferDuration = currentBufferSeconds
            DebugLogger.logAsync(.info, "Buffer aumentato automaticamente a \(Int(currentBufferSeconds))s dopo \(consecutiveStalls) stalli")
        }

        // Dopo troppi stalli consecutivi, abbassa automaticamente la
        // risoluzione massima richiesta (se il provider offre varianti
        // multiple nel manifest HLS, altrimenti non ha effetto).
        if consecutiveStalls >= 4 && !qualityWasAutoReduced {
            player.currentItem?.preferredMaximumResolution = CGSize(width: 1280, height: 720)
            qualityWasAutoReduced = true
            DebugLogger.logAsync(.warning, "Qualità abbassata automaticamente a 720p dopo stalli ripetuti")
        }

        reconnect()
    }

    private func reconnect() {
        guard NetworkMonitor.shared.isConnected else {
            DebugLogger.logAsync(.warning, "Device offline: riconnessione posticipata")
            return
        }
        guard reconnectAttempts < maxAttempts else {
            DebugLogger.logAsync(.error, "Riconnessione fallita dopo \(maxAttempts) tentativi")
            return
        }
        reconnectAttempts += 1
        let delay = min(pow(1.6, Double(reconnectAttempts)), 12)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.loadAsset(url: self.url)
            self.player.play()
            self.isBuffering = false
        }
    }

    func resetAttempts() { reconnectAttempts = 0; consecutiveStalls = 0 }

    func restoreAutoQuality() {
        player.currentItem?.preferredMaximumResolution = .zero
        qualityWasAutoReduced = false
    }
}
