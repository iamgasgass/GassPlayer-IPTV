import SwiftUI
import AVKit
import UIKit
import MediaPlayer

/// Player con Picture-in-Picture nativo reale (tramite AVPlayerViewController,
/// non più un semplice coordinatore-placeholder), gesture per
/// volume/luminosità stile app video professionali, e selezione qualità.
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
        ZStack(alignment: .top) {
            RealPiPPlayerView(player: reconnectPlayer.player)
                .ignoresSafeArea()
                .onAppear { reconnectPlayer.player.play(); Task { await loadMediaSelection() } }
                .onDisappear { reconnectPlayer.player.pause() }
                .gesture(dragGesture)

            if showBrightnessHUD { hudOverlay(icon: "sun.max.fill", value: brightnessOverlay) }
            if showVolumeHUD { hudOverlay(icon: "speaker.wave.2.fill", value: volumeOverlay) }

            HStack {
                GlassIconButton(systemImage: "xmark") { dismiss() }
                Spacer()
                if reconnectPlayer.isBuffering { ProgressView().padding(.horizontal, 8) }
                GlassIconButton(systemImage: "4k.tv") { showQualityPicker = true }
                GlassIconButton(systemImage: "dial.low") { showBufferSettings = true }
                GlassIconButton(systemImage: "text.bubble") { showTrackPicker = true }
            }
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

    /// Swipe verticale: metà sinistra dello schermo = luminosità, metà destra = volume.
    /// Pattern gesture standard nei player video (YouTube, VLC, Infuse).
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

/// Wrapper UIKit per abilitare il vero PiP di sistema (non un placeholder):
/// AVPlayerViewController gestisce nativamente start/stop PiP quando l'utente
/// esce dall'app o preme il pulsante, senza codice aggiuntivo.
struct RealPiPPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        uiViewController.player = player
    }
}

/// Il volume di sistema su iOS non è leggibile/scrivibile direttamente:
/// si usa lo slider nativo di MPVolumeView come trucco standard.
enum MPVolumeSlider {
    static func currentVolume() -> Float {
        AVAudioSession.sharedInstance().outputVolume
    }
    static func setVolume(_ value: Float) {
        let volumeView = MPVolumeView(frame: .zero)
        if let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first {
            slider.value = value
        }
    }
}

struct QualityPickerView: View {
    let player: AVPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var variants: [String] = []

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
