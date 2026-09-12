import SwiftUI
import AVKit
import AVFoundation
import UIKit
import MediaPlayer

struct PlayerView: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var reconnectPlayer: SmartReconnectPlayer
    @State private var showTrackPicker = false
    @State private var showBufferSettings = false
    @State private var showQualityPicker = false
    @State private var audioOptions: [AVMediaSelectionOption] = []
    @State private var subtitleOptions: [AVMediaSelectionOption] = []
    @State private var brightnessOverlay: Double = 0
    @State private var volumeOverlay: Double = 0
    @State private var showBrightnessHUD = false
    @State private var showVolumeHUD = false

    init(url: URL, title: String) {
        self.url = url; self.title = title
        _reconnectPlayer = StateObject(wrappedValue: SmartReconnectPlayer(url: url))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RealPiPPlayerView(
                player: reconnectPlayer.player,
                onOpenSubtitles: { showTrackPicker = true },
                onOpenQuality: { showQualityPicker = true },
                onOpenBuffer: { showBufferSettings = true }
            )
            .ignoresSafeArea()
            .onAppear { reconnectPlayer.player.play(); Task { await loadMediaSelection() } }
            .onDisappear { reconnectPlayer.player.pause() }
            .simultaneousGesture(dragGesture)

            if showBrightnessHUD { hudOverlay(icon: "sun.max.fill", value: brightnessOverlay) }
            if showVolumeHUD { hudOverlay(icon: "speaker.wave.2.fill", value: volumeOverlay) }

            GlassIconButton(systemImage: "xmark") { dismiss() }
                .padding()
        }
        .sheet(isPresented: $showTrackPicker) {
            TrackPickerView(player: reconnectPlayer.player, audioOptions: audioOptions, subtitleOptions: subtitleOptions)
        }
        .sheet(isPresented: $showBufferSettings) {
            BufferSettingsView(reconnectPlayer: reconnectPlayer)
        }
        .sheet(isPresented: $showQualityPicker) {
            QualityPickerView(player: reconnectPlayer.player)
        }
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

struct RealPiPPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    let onOpenSubtitles: () -> Void
    let onOpenQuality: () -> Void
    let onOpenBuffer: () -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.showsPlaybackControls = true

        if #available(iOS 16.0, *) {
            controller.transportBarCustomMenuItems = [
                UIAction(title: "Sottotitoli e audio", image: UIImage(systemName: "text.bubble")) { _ in
                    onOpenSubtitles()
                },
                UIAction(title: "Qualità video", image: UIImage(systemName: "4k.tv")) { _ in
                    onOpenQuality()
                },
                UIAction(title: "Buffer e riconnessione", image: UIImage(systemName: "dial.low")) { _ in
                    onOpenBuffer()
                }
            ]
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
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
