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

    // Picker/menu
    @State private var showTrackPicker = false
    @State private var showBufferSettings = false
    @State private var showQualityPicker = false
    @State private var showExternalPlayerMenu = false
    @State private var showSpeedPicker = false

    // Selezioni correnti (usate per mostrare un segno di spunta nei picker,
    // FEATURE MANCANTE aggiunta: prima non c'era alcun modo di sapere quale
    // velocità/traccia/qualità fosse effettivamente attiva).
    @State private var currentPlaybackRate: Double = 1.0
    @State private var selectedAudioTrackName: String?
    @State private var selectedSubtitleTrackName: String?
    @State private var selectedVideoTrackName: String?

    // Gesti brightness/volume
    @State private var brightnessOverlay: Double = 0
    @State private var volumeOverlay: Double = 0
    @State private var showBrightnessHUD = false
    @State private var showVolumeHUD = false
    @State private var hudHideTask: Task<Void, Never>?

    // Feedback avanzamento/riavvolgimento (doppio tap)
    @State private var skipFeedback: String?
    @State private var skipFeedbackTask: Task<Void, Never>?

    // Controlli generali
    @State private var showControls = true
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var isScrubbing = false

    // BUG FIX: `UIScreen.main.bounds.width` (usato in precedenza nel drag
    // gesture) è deprecato e restituisce dimensioni errate in scenari multi
    // finestra/multi scena (iPad Stage Manager, Slide Over, Split View):
    // la larghezza reale del player viene ora letta dalla gerarchia SwiftUI
    // stessa tramite `GeometryReader` e riusata sia per il gesto
    // luminosità/volume sia per le nuove zone di doppio tap.
    @State private var containerWidth: CGFloat = UIScreen.main.bounds.width

    // FEATURE MANCANTE aggiunta: blocco schermo per evitare tocchi
    // accidentali durante la visione (comune in tutti i player IPTV/VOD).
    @State private var isLocked = false

    // Cache dei player esterni disponibili per questo URL: `available(for:)`
    // esegue `UIApplication.shared.canOpenURL` per ogni candidato, una
    // chiamata non gratuita se ripetuta ad ogni valutazione di `body`
    // (accadeva due volte: nel banner d'errore e nel confirmationDialog).
    // Calcolata una sola volta per URL e riusata ovunque.
    @State private var externalPlayers: [ExternalPlayer] = []

    init(url: URL, title: String) {
        self.url = url; self.title = title
        _controller = StateObject(wrappedValue: KSPlaybackController(url: url, title: title))
    }

    var body: some View {
        KSPlayerContainerView(controller: controller)
            .ignoresSafeArea()
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { containerWidth = geo.size.width }
                        .onChange(of: geo.size) { newValue in containerWidth = newValue.width }
                }
            )
            .onAppear {
                scheduleAutoHide()
            }
            .task(id: url) {
                externalPlayers = ExternalPlayer.available(for: url)
            }
            .onDisappear {
                controller.layer.pause()
                hideControlsTask?.cancel()
                hudHideTask?.cancel()
                skipFeedbackTask?.cancel()
            }
            .simultaneousGesture(dragGesture)
            .onTapGesture(count: 2, coordinateSpace: .local) { location in
                handleDoubleTap(at: location)
            }
            .onTapGesture {
                handleSingleTap()
            }
            .overlay {
                if showBrightnessHUD { hudOverlay(icon: "sun.max.fill", value: brightnessOverlay) }
            }
            .overlay {
                if showVolumeHUD { hudOverlay(icon: "speaker.wave.2.fill", value: volumeOverlay) }
            }
            .overlay {
                if let skipFeedback {
                    skipFeedbackOverlay(skipFeedback)
                }
            }
            .overlay {
                if isLocked {
                    lockedOverlay
                } else if let errorMessage = controller.lastError {
                    playbackErrorBanner(errorMessage)
                } else {
                    unifiedControlSurface
                        .opacity(showControls ? 1 : 0)
                        .allowsHitTesting(showControls)
                        .animation(.easeInOut(duration: 0.2), value: showControls)
                }
            }
            .statusBarHidden(true)
            .sheet(isPresented: $showTrackPicker) {
                TrackPickerView(
                    controller: controller,
                    selectedAudioTrackName: $selectedAudioTrackName,
                    selectedSubtitleTrackName: $selectedSubtitleTrackName
                )
            }
            .sheet(isPresented: $showBufferSettings) {
                BufferSettingsView(controller: controller)
            }
            .sheet(isPresented: $showQualityPicker) {
                QualityPickerView(controller: controller, selectedTrackName: $selectedVideoTrackName)
            }
            .confirmationDialog("Apri con un altro player", isPresented: $showExternalPlayerMenu, titleVisibility: .visible) {
                ForEach(externalPlayers) { player in
                    Button(player.displayName) {
                        controller.layer.pause()
                        UIApplication.shared.open(player.url)
                    }
                }
                Button("Annulla", role: .cancel) {}
            }
            .confirmationDialog("Velocità di riproduzione", isPresented: $showSpeedPicker, titleVisibility: .visible) {
                ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { rate in
                    Button(speedLabel(for: rate)) {
                        controller.setPlaybackRate(Float(rate))
                        currentPlaybackRate = rate
                    }
                }
                Button("Annulla", role: .cancel) {}
            }
    }

    // MARK: - Gesture handling

    // BUG DI PROGETTAZIONE EVITATO: uno schermo "bloccato" che si sblocca
    // con un tap qualunque non protegge da nulla (tocchi accidentali in
    // tasca, pulizia dello schermo…). Con lo schermo bloccato un tap
    // generico non fa nulla: l'unico modo per sbloccare è il pulsante
    // dedicato mostrato da `lockedOverlay`.
    private func handleSingleTap() {
        guard !isLocked else { return }
        toggleControls()
    }

    // FEATURE MANCANTE aggiunta: doppio tap sulla metà sinistra/destra dello
    // schermo per riavvolgere/avanzare di 10s, gesto ormai standard in ogni
    // player video (YouTube, Netflix, VLC…). Disabilitato sui flussi live
    // (duration <= 0), coerentemente con i pulsanti di skip nella barra.
    private func handleDoubleTap(at location: CGPoint) {
        guard !isLocked, controller.duration > 0 else { return }

        let isForward = location.x > containerWidth / 2
        controller.skip(by: isForward ? 10 : -10)
        showSkipFeedback(isForward: isForward)
        haptic()
        scheduleAutoHide()
    }

    private func showSkipFeedback(isForward: Bool, seconds: Int = 10) {
        skipFeedbackTask?.cancel()
        skipFeedback = "\(isForward ? "+" : "-")\(seconds)s"
        skipFeedbackTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { skipFeedback = nil }
        }
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    private func speedLabel(for rate: Double) -> String {
        let base = rate == 1.0 ? "Normale (1x)" : "\(rate.formatted())x"
        return rate == currentPlaybackRate ? "✓ \(base)" : base
    }

    private func unlock() {
        withAnimation { isLocked = false }
        scheduleAutoHide()
    }

    // MARK: - Layout principale

    private var unifiedControlSurface: some View {
        VStack {
            topBar
            Spacer()
            progressBar
        }
    }

    private var topBar: some View {
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
            Button {
                haptic()
                isLocked = true
            } label: {
                GlassIconGlyph(systemImage: "lock")
            }
            .modifier(NativeOrLegacyGlassCircle(tint: nil, isInSystemToolbar: false))
            .accessibilityLabel("Blocca schermo")
            optionsMenu
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .safeAreaPadding(.horizontal)
        .background(LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var optionsMenu: some View {
        Menu {
            Button("Velocità di riproduzione (\(currentPlaybackRate == 1.0 ? "1x" : currentPlaybackRate.formatted() + "x"))", systemImage: "speedometer") {
                showSpeedPicker = true
            }
            Button("Qualità video\(selectedVideoTrackName.map { " (\($0))" } ?? "")", systemImage: "4k.tv") {
                showQualityPicker = true
            }
            Button("Impostazioni buffer", systemImage: "dial.low") { showBufferSettings = true }
            Button("Audio e sottotitoli", systemImage: "text.bubble") { showTrackPicker = true }
            Divider()
            Button("Blocca schermo", systemImage: "lock") {
                haptic()
                isLocked = true
            }
        } label: {
            GlassIconGlyph(systemImage: "ellipsis")
        }
        .menuStyle(.button)
        .modifier(NativeOrLegacyGlassCircle(tint: nil, isInSystemToolbar: false))
        .accessibilityLabel("Altre opzioni")
    }

    private var progressBar: some View {
        VStack(spacing: 6) {
            if controller.duration > 0 {
                // BUG FIX: la barra di avanzamento, se trascinata per più di
                // 4 secondi, spariva sotto al dito perché il timer di
                // auto-hide dei controlli non teneva conto dello scrubbing
                // in corso. Ora il timer viene sospeso durante il
                // trascinamento e riprogrammato solo al rilascio.
                Slider(
                    value: Binding(
                        get: { controller.currentTime },
                        set: { controller.seek(to: $0) }
                    ),
                    in: 0...max(controller.duration, 1),
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        if editing {
                            hideControlsTask?.cancel()
                        } else {
                            scheduleAutoHide()
                        }
                    }
                )
                .tint(.white)
            }
            HStack(spacing: 28) {
                // BUG FIX: i pulsanti di skip ±15s restavano sempre attivi
                // anche sui flussi live (duration == 0), dove `skip(by:)`
                // calcolava un target di seek pari a `.greatestFiniteMagnitude`
                // — un seek non valido per uno stream senza durata nota.
                // Ora sono mostrati (e quindi utilizzabili) solo quando
                // esiste una durata reale da percorrere.
                if controller.duration > 0 {
                    GlassIconButton(systemImage: "gobackward.15", size: 34) {
                        haptic()
                        controller.skip(by: -15)
                        scheduleAutoHide()
                    }
                }
                GlassIconButton(systemImage: controller.isPlaying ? "pause.fill" : "play.fill", size: 44) {
                    haptic()
                    controller.togglePlayPause()
                    scheduleAutoHide()
                }
                if controller.duration > 0 {
                    GlassIconButton(systemImage: "goforward.15", size: 34) {
                        haptic()
                        controller.skip(by: 15)
                        scheduleAutoHide()
                    }
                }
                if controller.duration > 0 {
                    Text("\(formatted(controller.currentTime)) / \(formatted(controller.duration))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .layoutPriority(1)
                } else {
                    Text("Live").font(.caption.weight(.semibold)).foregroundStyle(.white)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .safeAreaPadding(.horizontal)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
    }

    private var lockedOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Button {
                    haptic()
                    unlock()
                } label: {
                    GlassIconGlyph(systemImage: "lock.fill", size: 44)
                }
                .modifier(NativeOrLegacyGlassCircle(tint: nil, isInSystemToolbar: false))
                .accessibilityLabel("Sblocca schermo")
                .padding(.leading, 20)
                .padding(.bottom, 30)
                Spacer()
            }
        }
        .transition(.opacity)
    }

    private func toggleControls() {
        showControls.toggle()
        if showControls { scheduleAutoHide() }
    }

    private func scheduleAutoHide() {
        hideControlsTask?.cancel()
        guard !isScrubbing else { return }
        hideControlsTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { showControls = false }
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
                if !externalPlayers.isEmpty {
                    Button("Apri con un altro player") { showExternalPlayerMenu = true }
                }
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
            Spacer()
            HStack { GlassIconButton(systemImage: "xmark") { dismiss() }; Spacer() }
                .padding()
                .safeAreaPadding(.horizontal)
        }
    }

    // MARK: - Gesti luminosità/volume

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !isLocked else { return }
                // BUG FIX: cancella qualunque nascondimento HUD già
                // programmato appena arriva un nuovo evento di trascinamento,
                // invece di lasciarlo scattare in background: prima, due
                // trascinamenti ravvicinati (es. luminosità poi volume entro
                // 0.8s) potevano far sparire l'HUD del secondo gesto ancora
                // in corso, perché il primo `asyncAfter` non veniva annullato.
                hudHideTask?.cancel()

                let delta = -value.translation.height / 200
                if value.startLocation.x < containerWidth / 2 {
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
                hudHideTask?.cancel()
                hudHideTask = Task {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run { showBrightnessHUD = false; showVolumeHUD = false }
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

    private func skipFeedbackOverlay(_ label: String) -> some View {
        Text(label)
            .font(.title2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
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
    @Binding var selectedTrackName: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                let tracks = controller.videoTracks
                if tracks.count > 1 {
                    List {
                        ForEach(tracks, id: \.trackID) { track in
                            Button {
                                controller.select(track: track)
                                selectedTrackName = track.name
                                dismiss()
                            } label: {
                                HStack {
                                    Text(track.name)
                                    Spacer()
                                    if track.name == selectedTrackName {
                                        Image(systemName: "checkmark")
                                    }
                                }
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
    @Binding var selectedAudioTrackName: String?
    @Binding var selectedSubtitleTrackName: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Audio") {
                    ForEach(controller.audioTracks, id: \.trackID) { track in
                        Button {
                            controller.select(track: track)
                            selectedAudioTrackName = track.name
                            dismiss()
                        } label: {
                            HStack {
                                Text(track.name)
                                Spacer()
                                if track.name == selectedAudioTrackName {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                Section("Sottotitoli") {
                    ForEach(controller.subtitleTracks, id: \.trackID) { track in
                        Button {
                            controller.select(track: track)
                            selectedSubtitleTrackName = track.name
                            dismiss()
                        } label: {
                            HStack {
                                Text(track.name)
                                Spacer()
                                if track.name == selectedSubtitleTrackName {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
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
