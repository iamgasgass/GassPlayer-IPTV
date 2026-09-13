import SwiftUI
import AVKit
import AVFoundation
import UIKit
import MediaPlayer
import Combine

struct PlayerView: View {
    let url: URL
    let title: String
    var onExhaustedNativeOptions: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var vpnManager: PersonalVPNManager
    @StateObject private var reconnectPlayer: SmartReconnectPlayer
    @StateObject private var progress = PlaybackProgress()
    @State private var showTrackPicker = false
    @State private var showBufferSettings = false
    @State private var showQualityPicker = false
    @State private var showExternalPlayerMenu = false
    @State private var audioOptions: [AVMediaSelectionOption] = []
    @State private var subtitleOptions: [AVMediaSelectionOption] = []
    @State private var brightnessOverlay: Double = 0
    @State private var volumeOverlay: Double = 0
    @State private var showBrightnessHUD = false
    @State private var showVolumeHUD = false
    @State private var showControls = true
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var isWaitingForVPN = false

    init(url: URL, title: String, onExhaustedNativeOptions: @escaping () -> Void = {}) {
        self.url = url; self.title = title
        self.onExhaustedNativeOptions = onExhaustedNativeOptions
        _reconnectPlayer = StateObject(wrappedValue: SmartReconnectPlayer(url: url, title: title))
    }

    var body: some View {
        ZStack {
            RealPiPPlayerView(player: reconnectPlayer.player)
                .ignoresSafeArea()
                .task {
                    await connectVPNIfNeededBeforePlayback()
                    await loadMediaSelection()
                }
                .onAppear {
                    progress.attach(to: reconnectPlayer.player)
                    scheduleAutoHide()
                }
                .onDisappear {
                    reconnectPlayer.player.pause()
                    progress.detach()
                    hideControlsTask?.cancel()
                }
                .simultaneousGesture(dragGesture)
                .onTapGesture { toggleControls() }

            if isWaitingForVPN {
                vpnWaitingOverlay
            }

            if showBrightnessHUD { hudOverlay(icon: "sun.max.fill", value: brightnessOverlay) }
            if showVolumeHUD { hudOverlay(icon: "speaker.wave.2.fill", value: volumeOverlay) }

            if let errorMessage = reconnectPlayer.lastError {
                playbackErrorBanner(errorMessage)
            } else if showControls {
                unifiedControlSurface
            }
        }
        .statusBarHidden(true)
        .sheet(isPresented: $showTrackPicker) {
            TrackPickerView(player: reconnectPlayer.player, audioOptions: audioOptions, subtitleOptions: subtitleOptions)
        }
        .sheet(isPresented: $showBufferSettings) {
            BufferSettingsView(reconnectPlayer: reconnectPlayer)
        }
        .sheet(isPresented: $showQualityPicker) {
            QualityPickerView(player: reconnectPlayer.player)
        }
        .confirmationDialog("Apri con un altro player", isPresented: $showExternalPlayerMenu, titleVisibility: .visible) {
            ForEach(ExternalPlayer.available(for: url)) { player in
                Button(player.displayName) {
                    reconnectPlayer.player.pause()
                    UIApplication.shared.open(player.url)
                }
            }
            Button("Annulla", role: .cancel) {}
        }
        .onChange(of: reconnectPlayer.exhaustedAllNativeOptions) { _, exhausted in
            if exhausted {
                onExhaustedNativeOptions()
            }
        }
    }

    private func connectVPNIfNeededBeforePlayback() async {
        guard vpnManager.hasSavedProfile,
              vpnManager.autoConnectOnLaunch,
              vpnManager.activeProtocolIsEncrypted,
              vpnManager.status != .connected,
              vpnManager.status != .connecting else { return }

        isWaitingForVPN = true
        defer { isWaitingForVPN = false }

        try? vpnManager.connect()

        let deadline = Date().addingTimeInterval(4)
        while vpnManager.status != .connected && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if vpnManager.status != .connected {
            DebugLogger.logAsync(.warning, "VPN non connessa entro il timeout di avvio player: si procede comunque con la riproduzione diretta")
        }
    }

    private var vpnWaitingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.white)
            Text("Connessione VPN personale...")
                .font(.caption)
                .foregroundStyle(.white)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .transition(.opacity)
    }

    private var unifiedControlSurface: some View {
        VStack {
            HStack {
                GlassIconButton(systemImage: "xmark") { dismiss() }
                Spacer()
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(radius: 4)
                Spacer()
                if reconnectPlayer.isBuffering { ProgressView().tint(.white).padding(.horizontal, 4) }
                AirPlayButton()
                    .frame(width: 32, height: 32)
                GlassIconButton(systemImage: "arrow.up.forward.app") { showExternalPlayerMenu = true }
                GlassIconButton(systemImage: "4k.tv") { showQualityPicker = true }
                GlassIconButton(systemImage: "dial.low") { showBufferSettings = true }
                GlassIconButton(systemImage: "text.bubble") { showTrackPicker = true }
            }
            .padding()
            .background(LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom))

            Spacer()

            VStack(spacing: 6) {
                if progress.duration > 0 {
                    Slider(value: Binding(
                        get: { progress.currentTime },
                        set: { progress.seek(to: $0) }
                    ), in: 0...max(progress.duration, 1))
                    .tint(.white)
                }
                HStack {
                    GlassIconButton(systemImage: reconnectPlayer.player.timeControlStatus == .playing ? "pause.fill" : "play.fill", size: 40) {
                        togglePlayPause()
                    }
                    if progress.duration > 0 {
                        Text("\(formatted(progress.currentTime)) / \(formatted(progress.duration))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white)
                    } else {
                        Text("Live").font(.caption.weight(.semibold)).foregroundStyle(.white)
                    }
                    Spacer()
                }
            }
            .padding()
            .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
        }
        .transition(.opacity)
    }

    private func togglePlayPause() {
        if reconnectPlayer.player.timeControlStatus == .playing {
            reconnectPlayer.player.pause()
        } else {
            reconnectPlayer.player.play()
        }
        scheduleAutoHide()
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        if showControls { scheduleAutoHide() }
    }

    private func scheduleAutoHide() {
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { withAnimation(.easeInOut(duration: 0.3)) { showControls = false } }
        }
    }

    private func formatted(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private func playbackErrorBanner(_ message: String) -> some View {
        VStack {
            Spacer()
            VStack(spacing: 8) {
                Text("Riproduzione non riuscita")
                    .font(.headline)
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Riprova") {
                    reconnectPlayer.resetAttempts()
                }
                .buttonStyle(.borderedProminent)
                if !ExternalPlayer.available(for: url).isEmpty {
                    Button("Apri con un altro player") { showExternalPlayerMenu = true }
                }
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
            Spacer()
            HStack { GlassIconButton(systemImage: "xmark") { dismiss() }; Spacer() }.padding()
        }
        .transition(.opacity)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                let screenWidth = UIScreen.main.bounds.width
                let delta = -value.translation.height / 200
                if value.startLocation.x < screenWidth / 2 {
                    brightnessOverlay = min(max(UIScreen.main.brightness + delta, 0), 1)
                    UIScreen.main.brightness = brightnessOverlay
                    showBrightnessHUD = true; showVolumeHUD = false
                } else {
                    volumeOverlay = min(max(Double(MPVolumeSlider.currentVolume()) + delta, 0), 1)
                    MPVolumeSlider.setVolume(Float(volumeOverlay))
                    showVolumeHUD = true; showBrightnessHUD = false
                }
            }
            .onEnded { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    showBrightnessHUD = false; showVolumeHUD = false
                }
            }
    }

    private func hudOverlay(icon: String, value: Double) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Image(systemName: icon)
                ProgressView(value: value).frame(width: 120)
            }
            .padding()
            .background(.ultraThinMaterial, in: Capsule())
            Spacer()
        }
        .transition(.opacity)
    }

    private func loadMediaSelection() async {
        guard let asset = reconnectPlayer.player.currentItem?.asset else { return }
        if let audibleGroup = try? await asset.loadMediaSelectionGroup(for: .audible) { audioOptions = audibleGroup.options }
        if let legibleGroup = try? await asset.loadMediaSelectionGroup(for: .legible) { subtitleOptions = legibleGroup.options }
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .systemBlue
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct ExternalPlayer: Identifiable {
    let id = UUID()
    let displayName: String
    let url: URL

    static func available(for streamURL: URL) -> [ExternalPlayer] {
        guard let encoded = streamURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return [] }
        var candidates: [ExternalPlayer] = []

        if let vlcURL = URL(string: "vlc-x-callback://x-callback-url/stream?url=\(encoded)") {
            candidates.append(ExternalPlayer(displayName: "VLC", url: vlcURL))
        }
        if let infuseURL = URL(string: "infuse://x-callback-url/play?url=\(encoded)") {
            candidates.append(ExternalPlayer(displayName: "Infuse", url: infuseURL))
        }
        if let outplayerURL = URL(string: "outplayer://\(encoded)") {
            candidates.append(ExternalPlayer(displayName: "Outplayer", url: outplayerURL))
        }
        return candidates.filter { UIApplication.shared.canOpenURL($0.url) }
    }
}

struct RealPiPPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.showsPlaybackControls = false
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}

@MainActor
final class PlaybackProgress: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    private weak var player: AVPlayer?
    private var timeObserver: Any?

    func attach(to player: AVPlayer) {
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds
            if let itemDuration = player.currentItem?.duration.seconds, itemDuration.isFinite {
                self.duration = itemDuration
            }
        }
    }

    func seek(to time: Double) {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
    }

    func detach() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player = nil
    }
}

enum MPVolumeSlider {
    private static let sharedVolumeView = MPVolumeView(frame: .zero)

    static func currentVolume() -> Float { AVAudioSession.sharedInstance().outputVolume }

    static func setVolume(_ value: Float) {
        if let slider = sharedVolumeView.subviews.compactMap({ $0 as? UISlider }).first {
            slider.value = value
        }
    }
}

struct QualityPickerView: View {
    let player: AVPlayer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button("Automatica (consigliata)") {
                    player.currentItem?.preferredPeakBitRate = 0
                    player.currentItem?.preferredMaximumResolution = .zero
                    dismiss()
                }
                Button("Alta (fino a 1080p)") {
                    player.currentItem?.preferredMaximumResolution = CGSize(width: 1920, height: 1080)
                    dismiss()
                }
                Button("Media (fino a 720p, risparmio dati)") {
                    player.currentItem?.preferredMaximumResolution = CGSize(width: 1280, height: 720)
                    dismiss()
                }
                Button("Bassa (fino a 480p, connessioni lente)") {
                    player.currentItem?.preferredMaximumResolution = CGSize(width: 854, height: 480)
                    dismiss()
                }
            }
            .navigationTitle("Qualità video")
            .toolbar { Button("Chiudi") { dismiss() } }
        }
    }
}

struct BufferSettingsView: View {
    @ObservedObject var reconnectPlayer: SmartReconnectPlayer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Buffer") {
                    Slider(value: $reconnectPlayer.preferredBufferSeconds, in: 1...30, step: 1) { Text("Durata buffer") }
                    Text("\(Int(reconnectPlayer.preferredBufferSeconds)) secondi").foregroundStyle(.secondary)
                }
                Section("Riconnessione") {
                    Text("Tentativi effettuati: \(reconnectPlayer.reconnectAttempts)")
                    Button("Reset contatore") { reconnectPlayer.resetAttempts() }
                }
            }
            .navigationTitle("Impostazioni stream")
            .toolbar { Button("Chiudi") { dismiss() } }
        }
    }
}

struct TrackPickerView: View {
    let player: AVPlayer
    let audioOptions: [AVMediaSelectionOption]
    let subtitleOptions: [AVMediaSelectionOption]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Audio") {
                    ForEach(audioOptions, id: \.self) { option in
                        Button(option.displayName) { select(option, characteristic: .audible) }
                    }
                }
                Section("Sottotitoli") {
                    Button("Disattivati") { selectNone(characteristic: .legible) }
                    ForEach(subtitleOptions, id: \.self) { option in
                        Button(option.displayName) { select(option, characteristic: .legible) }
                    }
                }
            }
            .navigationTitle("Tracce")
            .toolbar { Button("Chiudi") { dismiss() } }
        }
    }

    private func select(_ option: AVMediaSelectionOption, characteristic: AVMediaCharacteristic) {
        guard let asset = player.currentItem?.asset else { return }
        Task { if let group = try? await asset.loadMediaSelectionGroup(for: characteristic) { player.currentItem?.select(option, in: group) } }
    }
    private func selectNone(characteristic: AVMediaCharacteristic) {
        guard let asset = player.currentItem?.asset else { return }
        Task { if let group = try? await asset.loadMediaSelectionGroup(for: characteristic) { player.currentItem?.select(nil, in: group) } }
    }
}
