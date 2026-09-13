import SwiftUI
import AVKit
import AVFoundation
import UIKit
import MediaPlayer
import Combine
import KSPlayer

struct PlayerView: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: KSPlaybackController
    @State private var showTrackPicker = false
    @State private var showBufferSettings = false
    @State private var showQualityPicker = false
    @State private var showExternalPlayerMenu = false
    @State private var showSpeedPicker = false
    @State private var brightnessOverlay: Double = 0
    @State private var volumeOverlay: Double = 0
    @State private var showBrightnessHUD = false
    @State private var showVolumeHUD = false
    @State private var showControls = true
    @State private var hideControlsTask: Task<Void, Never>?

    init(url: URL, title: String) {
        self.url = url; self.title = title
        _controller = StateObject(wrappedValue: KSPlaybackController(url: url, title: title))
    }

    var body: some View {
        KSPlayerContainerView(controller: controller)
            .ignoresSafeArea()
            .onAppear { scheduleAutoHide() }
            .onDisappear {
                controller.layer.pause()
                hideControlsTask?.cancel()
            }
            .simultaneousGesture(dragGesture)
            .onTapGesture { toggleControls() }
            .overlay {
                if showBrightnessHUD { hudOverlay(icon: "sun.max.fill", value: brightnessOverlay) }
            }
            .overlay {
                if showVolumeHUD { hudOverlay(icon: "speaker.wave.2.fill", value: volumeOverlay) }
            }
            .overlay {
                if let errorMessage = controller.lastError {
                    playbackErrorBanner(errorMessage)
                } else if showControls {
                    unifiedControlSurface
                }
            }
            .statusBarHidden(true)
            .sheet(isPresented: $showTrackPicker) {
                TrackPickerView(controller: controller)
            }
            .sheet(isPresented: $showBufferSettings) {
                BufferSettingsView(controller: controller)
            }
            .sheet(isPresented: $showQualityPicker) {
                QualityPickerView(controller: controller)
            }
            .confirmationDialog("Apri con un altro player", isPresented: $showExternalPlayerMenu, titleVisibility: .visible) {
                ForEach(ExternalPlayer.available(for: url)) { player in
                    Button(player.displayName) {
                        controller.layer.pause()
                        UIApplication.shared.open(player.url)
                    }
                }
                Button("Annulla", role: .cancel) {}
            }
            .confirmationDialog("Velocità di riproduzione", isPresented: $showSpeedPicker, titleVisibility: .visible) {
                ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { rate in
                    Button(rate == 1.0 ? "Normale (1x)" : "\(rate.formatted())x") {
                        controller.setPlaybackRate(Float(rate))
                    }
                }
                Button("Annulla", role: .cancel) {}
            }
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
                if controller.isBuffering { ProgressView().tint(.white).padding(.horizontal, 4) }
                AirPlayButton()
                    .frame(width: 32, height: 32)
                if controller.supportsPictureInPicture {
                    GlassIconButton(systemImage: "pip.enter") { controller.isPipActive = true }
                }
                GlassIconButton(systemImage: "arrow.up.forward.app") { showExternalPlayerMenu = true }
                GlassIconButton(systemImage: "speedometer") { showSpeedPicker = true }
                GlassIconButton(systemImage: "4k.tv") { showQualityPicker = true }
                GlassIconButton(systemImage: "dial.low") { showBufferSettings = true }
                GlassIconButton(systemImage: "text.bubble") { showTrackPicker = true }
            }
            .padding()
            .background(LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom))

            Spacer()

            VStack(spacing: 6) {
                if controller.duration > 0 {
                    Slider(value: Binding(
                        get: { controller.currentTime },
                        set: { controller.seek(to: $0) }
                    ), in: 0...max(controller.duration, 1))
                    .tint(.white)
                }
                HStack(spacing: 28) {
                    GlassIconButton(systemImage: "gobackward.15", size: 34) {
                        controller.skip(by: -15)
                        scheduleAutoHide()
                    }
                    GlassIconButton(systemImage: controller.isPlaying ? "pause.fill" : "play.fill", size: 44) {
                        controller.togglePlayPause()
                        scheduleAutoHide()
                    }
                    GlassIconButton(systemImage: "goforward.15", size: 34) {
                        controller.skip(by: 15)
                        scheduleAutoHide()
                    }
                    if controller.duration > 0 {
                        Text("\(formatted(controller.currentTime)) / \(formatted(controller.duration))")
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
                    controller.resetAttempts()
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
}

struct KSPlayerContainerView: UIViewRepresentable {
    let controller: KSPlaybackController

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        if let playerView = controller.layer.player.view {
            playerView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(playerView)
            NSLayoutConstraint.activate([
                playerView.topAnchor.constraint(equalTo: container.topAnchor),
                playerView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                playerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                playerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
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
    @ObservedObject var controller: KSPlaybackController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                let tracks = controller.videoTracks
                if tracks.count > 1 {
                    List {
                        ForEach(tracks, id: \.trackID) { track in
                            Button(track.name) {
                                controller.select(track: track)
                                dismiss()
                            }
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "4k.tv").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Questo flusso offre una sola qualità disponibile.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                }
            }
            .navigationTitle("Qualità video")
            .toolbar { Button("Chiudi") { dismiss() } }
        }
    }
}

struct BufferSettingsView: View {
    @ObservedObject var controller: KSPlaybackController
    @Environment(\.dismiss) private var dismiss

    private var bufferDurationBinding: Binding<Double> {
        Binding(
            get: { controller.layer.options.preferredForwardBufferDuration },
            set: { controller.layer.options.preferredForwardBufferDuration = $0 }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Buffer") {
                    Slider(value: bufferDurationBinding, in: 1...30, step: 1) { Text("Durata buffer") }
                    Text("\(Int(controller.layer.options.preferredForwardBufferDuration)) secondi").foregroundStyle(.secondary)
                }
                Section("Riproduzione") {
                    Text("Stato: \(controller.state.description)")
                    Button("Riprova") { controller.resetAttempts() }
                }
            }
            .navigationTitle("Impostazioni stream")
            .toolbar { Button("Chiudi") { dismiss() } }
        }
    }
}

struct TrackPickerView: View {
    @ObservedObject var controller: KSPlaybackController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Audio") {
                    ForEach(controller.audioTracks, id: \.trackID) { track in
                        Button(track.name) { controller.select(track: track); dismiss() }
                    }
                }
                Section("Sottotitoli") {
                    ForEach(controller.subtitleTracks, id: \.trackID) { track in
                        Button(track.name) { controller.select(track: track); dismiss() }
                    }
                    if controller.subtitleTracks.isEmpty {
                        Text("Nessun sottotitolo disponibile per questo flusso.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Tracce")
            .toolbar { Button("Chiudi") { dismiss() } }
        }
    }
}
