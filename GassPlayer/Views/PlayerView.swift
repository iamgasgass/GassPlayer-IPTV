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

    /// Precedente/successivo: `nil` = non disponibile in questo contesto
    /// (bordo della lista, o chiamante che non la implementa).
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: KSPlaybackController

    // Environment objects per cronologia canali e ricerca globale
    @EnvironmentObject private var recentlyWatched: RecentlyWatchedStore
    @EnvironmentObject private var sourceManager: SourceManager

    // Picker e menu modali
    @State private var showTrackPicker = false
    @State private var showAdvancedSettings = false
    @State private var showQualityPicker = false
    @State private var showExternalPlayerMenu = false
    @State private var showSpeedPicker = false
    @State private var showSleepTimerPicker = false
    @State private var showAspectPicker = false
    @State private var showChannelHistory = false
    @State private var showChannelSearch = false

    // Selezioni correnti
    @State private var currentPlaybackRate: Double = 1.0
    @State private var selectedAudioTrackName: String?
    @State private var selectedSubtitleTrackName: String?
    @State private var selectedVideoTrackName: String?

    // Timer di spegnimento automatico
    @State private var sleepTimerMinutes: Int?
    @State private var sleepTimerTask: Task<Void, Never>?

    // Gesti brightness / volume
    @State private var brightnessOverlay: Double = 0
    @State private var volumeOverlay: Double = 0
    @State private var showBrightnessHUD = false
    @State private var showVolumeHUD = false
    @State private var hudHideTask: Task<Void, Never>?

    // Toast generico per feedback visivo
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?

    // Controlli generali di riproduzione
    @State private var showControls = true
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var isScrubbing = false

    @State private var containerWidth: CGFloat = UIScreen.main.bounds.width
    @State private var isLocked = false
    @State private var externalPlayers: [ExternalPlayer] = []
    @State private var airPlayRoutePicker: AVRoutePickerView?

    private var isAnyModalPresented: Bool {
        showTrackPicker || showAdvancedSettings || showQualityPicker
            || showExternalPlayerMenu || showSpeedPicker || showSleepTimerPicker
            || showAspectPicker || showChannelHistory || showChannelSearch
    }

    init(url: URL, title: String, onPrevious: (() -> Void)? = nil, onNext: (() -> Void)? = nil) {
        self.url = url
        self.title = title
        self.onPrevious = onPrevious
        self.onNext = onNext
        _controller = StateObject(wrappedValue: KSPlaybackController(url: url, title: title))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // FIX CRITICO: URL e Titolo passati direttamente a KSPlayerContainerView.
            // Quando SwiftUI aggiorna PlayerView per un nuovo canale/episodio,
            // KSPlayerContainerView.updateUIView esegue IMMEDIATAMENTE e in modo sincrono
            // il caricamento e l'aggancio del nuovo flusso, eliminando qualsiasi ritardo
            // di zapping a 1 passo indietro o trasmissione del canale precedente.
            KSPlayerContainerView(url: url, title: title, controller: controller)
                .ignoresSafeArea()

            // Spinner di buffering centrale pulito durante il caricamento o cambio canale
            if controller.isBuffering {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.4)
                    .transition(.opacity)
            }
        }
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
        .onChange(of: isAnyModalPresented) { presented in
            if presented {
                hideControlsTask?.cancel()
            } else {
                scheduleAutoHide()
            }
        }
        .onDisappear {
            controller.layer.pause()
            hideControlsTask?.cancel()
            hudHideTask?.cancel()
            toastTask?.cancel()
            sleepTimerTask?.cancel()
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
            if let toastMessage {
                toastOverlay(toastMessage)
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
        .sheet(isPresented: $showAdvancedSettings) {
            AdvancedSettingsView(controller: controller)
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
        .confirmationDialog("Timer di spegnimento", isPresented: $showSleepTimerPicker, titleVisibility: .visible) {
            ForEach([15, 30, 45, 60], id: \.self) { minutes in
                Button("\(minutes) minuti") { scheduleSleepTimer(minutes: minutes) }
            }
            if sleepTimerMinutes != nil {
                Button("Disattiva timer", role: .destructive) { cancelSleepTimer() }
            }
            Button("Annulla", role: .cancel) {}
        }
        .confirmationDialog("Rapporto di aspetto", isPresented: $showAspectPicker, titleVisibility: .visible) {
            ForEach(VideoGravityMode.allCases) { mode in
                Button(mode == controller.preferences.videoGravity ? "✓ \(mode.label)" : mode.label) {
                    controller.setVideoGravity(mode)
                }
            }
            Button("Annulla", role: .cancel) {}
        }
        .sheet(isPresented: $showChannelHistory) {
            ChannelHistoryView(
                items: recentlyWatched.items.filter { $0.kind == "live" },
                onSelect: { item in
                    controller.layer.pause()
                    controller.load(url: item.streamURL, title: item.title)
                    showChannelHistory = false
                }
            )
        }
        .sheet(isPresented: $showChannelSearch) {
            GlobalSearchView()
                .environmentObject(sourceManager)
        }
    }

    // MARK: - Gestures

    private func handleSingleTap() {
        guard !isLocked else { return }
        toggleControls()
    }

    private func handleDoubleTap(at location: CGPoint) {
        guard !isLocked, controller.duration > 0 else { return }

        let isForward = location.x > containerWidth / 2
        controller.skip(by: isForward ? 10 : -10)
        showToast("\(isForward ? "+" : "-")10s")
        haptic()
        scheduleAutoHide()
    }

    private func showToast(_ message: String, duration: UInt64 = 900_000_000) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task {
            try? await Task.sleep(nanoseconds: duration)
            guard !Task.isCancelled else { return }
            await MainActor.run { toastMessage = nil }
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

    private func presentAfterMenuDismiss(_ setFlag: @escaping () -> Void) {
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { setFlag() }
        }
    }

    // MARK: - Sleep Timer

    private func scheduleSleepTimer(minutes: Int) {
        sleepTimerTask?.cancel()
        sleepTimerMinutes = minutes
        showToast("Timer impostato: \(minutes) min", duration: 1_400_000_000)
        sleepTimerTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                controller.layer.pause()
                sleepTimerMinutes = nil
                dismiss()
            }
        }
    }

    private func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerMinutes = nil
        showToast("Timer disattivato", duration: 1_200_000_000)
    }

    // MARK: - Layout Principale

    private var unifiedControlSurface: some View {
        VStack {
            PlayerTopBar(
                data: PlayerTopBarData(
                    title: title,
                    isBuffering: controller.isBuffering,
                    supportsPictureInPicture: controller.supportsPictureInPicture,
                    videoGravity: controller.preferences.videoGravity,
                    hardwareDecode: controller.preferences.hardwareDecode,
                    currentPlaybackRate: currentPlaybackRate,
                    selectedVideoTrackName: selectedVideoTrackName,
                    sleepTimerMinutes: sleepTimerMinutes
                ),
                actions: PlayerTopBar.Actions(
                    dismiss: { dismiss() },
                    pipToggle: { controller.isPipActive = true },
                    externalPlayer: { showExternalPlayerMenu = true },
                    aspectPicker: { presentAfterMenuDismiss { showAspectPicker = true } },
                    channelHistory: { presentAfterMenuDismiss { showChannelHistory = true } },
                    channelSearch: { presentAfterMenuDismiss { showChannelSearch = true } },
                    lock: {
                        haptic()
                        isLocked = true
                    },
                    hardwareDecodeToggle: {
                        haptic()
                        let wasEnabled = controller.preferences.hardwareDecode
                        controller.setHardwareDecode(!wasEnabled)
                        showToast(wasEnabled ? "Decodifica software (FFmpeg)" : "Decodifica hardware (Metal)", duration: 1_200_000_000)
                    },
                    speedPicker: { presentAfterMenuDismiss { showSpeedPicker = true } },
                    qualityPicker: { presentAfterMenuDismiss { showQualityPicker = true } },
                    advancedSettings: { presentAfterMenuDismiss { showAdvancedSettings = true } },
                    trackPicker: { presentAfterMenuDismiss { showTrackPicker = true } },
                    sleepTimerPicker: { presentAfterMenuDismiss { showSleepTimerPicker = true } },
                    airPlayCreate: { airPlayRoutePicker = $0 },
                    airPlayTrigger: triggerAirPlayPicker,
                    chromecastTap: { showToast("Chromecast non ancora integrato", duration: 1_400_000_000) }
                )
            )
            .equatable()
            Spacer()
            progressBar
        }
    }

    private func triggerAirPlayPicker() {
        guard let picker = airPlayRoutePicker else { return }
        picker.subviews.compactMap { $0 as? UIButton }.first?.sendActions(for: .touchUpInside)
    }

    private var progressBar: some View {
        VStack(spacing: 8) {
            if controller.duration > 0 {
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

            // CORREZIONE MANIACALE HSTACK TRASPORTO / ZAPPING:
            // Al tap di Precedente/Successivo, arresta istantaneamente il vecchio flusso (`controller.layer.pause()`)
            // e invoca l'azione del genitore (`onPrevious` / `onNext`) per passare al nuovo canale/episodio.
            HStack(spacing: 22) {
                if let onPrevious {
                    GlassIconButton(systemImage: "backward.end.fill", size: 30) {
                        haptic()
                        controller.layer.pause()
                        onPrevious()
                    }
                }
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
                if let onNext {
                    GlassIconButton(systemImage: "forward.end.fill", size: 30) {
                        haptic()
                        controller.layer.pause()
                        onNext()
                    }
                }
            }
            .frame(maxWidth: .infinity)

            Group {
                if controller.duration > 0 {
                    Text("\(formatted(controller.currentTime)) / \(formatted(controller.duration))")
                        .font(.caption.monospacedDigit())
                } else {
                    Text("Live").font(.caption.weight(.semibold))
                }
            }
            .foregroundStyle(.white)
            .lineLimit(1)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .safeAreaPadding()
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
            .safeAreaPadding()
        }
        .transition(.opacity)
    }

    private func toggleControls() {
        showControls.toggle()
        if showControls { scheduleAutoHide() }
    }

    private func scheduleAutoHide() {
        hideControlsTask?.cancel()
        guard !isScrubbing, !isAnyModalPresented else { return }
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
                if onPrevious != nil || onNext != nil {
                    HStack(spacing: 24) {
                        if let onPrevious {
                            Button {
                                haptic()
                                controller.layer.pause()
                                onPrevious()
                            } label: {
                                Label("Precedente", systemImage: "backward.end.fill")
                            }
                        }
                        if let onNext {
                            Button {
                                haptic()
                                controller.layer.pause()
                                onNext()
                            } label: {
                                Label("Successivo", systemImage: "forward.end.fill")
                            }
                        }
                    }
                    .font(.subheadline)
                    .padding(.top, 4)
                }
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
            Spacer()
            HStack { GlassIconButton(systemImage: "xmark") { dismiss() }; Spacer() }
                .padding()
                .safeAreaPadding()
        }
    }

    // MARK: - Gesti Luminosità / Volume

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !isLocked else { return }
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

    private func toastOverlay(_ label: String) -> some View {
        Text(label)
            .font(.title3.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .transition(.opacity)
    }
}

// MARK: - TopBar Data & View

struct PlayerTopBarData: Equatable {
    var title: String
    var isBuffering: Bool
    var supportsPictureInPicture: Bool
    var videoGravity: VideoGravityMode
    var hardwareDecode: Bool
    var currentPlaybackRate: Double
    var selectedVideoTrackName: String?
    var sleepTimerMinutes: Int?
}

struct PlayerTopBar: View, Equatable {
    struct Actions {
        var dismiss: () -> Void
        var pipToggle: () -> Void
        var externalPlayer: () -> Void
        var aspectPicker: () -> Void
        var channelHistory: () -> Void
        var channelSearch: () -> Void
        var lock: () -> Void
        var hardwareDecodeToggle: () -> Void
        var speedPicker: () -> Void
        var qualityPicker: () -> Void
        var advancedSettings: () -> Void
        var trackPicker: () -> Void
        var sleepTimerPicker: () -> Void
        var airPlayCreate: (AVRoutePickerView) -> Void
        var airPlayTrigger: () -> Void
        var chromecastTap: () -> Void
    }

    let data: PlayerTopBarData
    let actions: Actions

    static func == (lhs: PlayerTopBar, rhs: PlayerTopBar) -> Bool {
        lhs.data == rhs.data
    }

    var body: some View {
        HStack {
            GlassIconButton(systemImage: "xmark") { actions.dismiss() }

            Spacer(minLength: 8)

            Text(data.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .shadow(radius: 4)
                .layoutPriority(1)

            Spacer(minLength: 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if data.isBuffering {
                        ProgressView().tint(.white).padding(.horizontal, 4)
                    }
                    AirPlayButton(onCreate: actions.airPlayCreate)
                        .frame(width: 30, height: 30)
                    if data.supportsPictureInPicture {
                        GlassIconButton(systemImage: "pip.enter", size: 34) { actions.pipToggle() }
                    }
                    GlassIconButton(systemImage: "arrow.up.forward.app", size: 34) { actions.externalPlayer() }
                    GlassIconButton(systemImage: "lock", size: 34) { actions.lock() }
                    optionsMenu
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .safeAreaPadding()
        .background(LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var optionsMenu: some View {
        Menu {
            Section("Impostazioni e controlli video") {
                Button("Rapporto di aspetto", systemImage: "aspectratio") {
                    actions.aspectPicker()
                }
                Button("Cronologia dei canali", systemImage: "clock") {
                    actions.channelHistory()
                }
                Button("Cerca canale", systemImage: "magnifyingglass") {
                    actions.channelSearch()
                }
                Button("Blocca schermo", systemImage: "lock") {
                    actions.lock()
                }
            }

            Section("Impostazioni lettore") {
                Button(
                    data.hardwareDecode ? "✓ Usa KSPlayer (Metal)" : "Usa KSPlayer (Metal)",
                    systemImage: "cpu"
                ) {
                    actions.hardwareDecodeToggle()
                }
                Button("Velocità di riproduzione (\(data.currentPlaybackRate == 1.0 ? "1x" : data.currentPlaybackRate.formatted() + "x"))", systemImage: "speedometer") {
                    actions.speedPicker()
                }
                Button("Qualità video\(data.selectedVideoTrackName.map { " (\($0))" } ?? "")", systemImage: "4k.tv") {
                    actions.qualityPicker()
                }
                Button("Impostazioni avanzate", systemImage: "slider.horizontal.3") {
                    actions.advancedSettings()
                }
                Button("Audio e sottotitoli", systemImage: "text.bubble") {
                    actions.trackPicker()
                }
                Button(
                    data.sleepTimerMinutes.map { "Timer di spegnimento (\($0) min)" } ?? "Timer di spegnimento",
                    systemImage: data.sleepTimerMinutes != nil ? "moon.zzz.fill" : "moon.zzz"
                ) {
                    actions.sleepTimerPicker()
                }
            }

            Section("Trasmissione video e audio") {
                Button("AirPlay audio", systemImage: "airplayaudio") {
                    actions.airPlayTrigger()
                }
                Button("AirPlay video", systemImage: "airplayvideo") {
                    actions.airPlayTrigger()
                }
                Button("Chromecast (richiede Google Cast SDK)", systemImage: "tv.badge.wifi") {
                    actions.chromecastTap()
                }
            }
        } label: {
            GlassIconGlyph(systemImage: "ellipsis", size: 34)
        }
        .menuStyle(.button)
        .modifier(NativeOrLegacyGlassCircle(tint: nil, isInSystemToolbar: false))
        .accessibilityLabel("Altre opzioni")
    }
}

// MARK: - KSPlayer Container Representable

/// Render Container per KSPlayer con gestione in-place ultra-ottimizzata.
/// Riceve direttamente URL e Titolo. Quando l'URL cambia (es. zapping in Live TV o Serie TV),
/// `updateUIView` esegue in modo sincrono:
/// 1) Lo spegnimento del vecchio layer per bloccare istantaneamente il flusso e l'audio precedenti.
/// 2) Il caricamento (`controller.load`) e l'aggancio del nuovo layer nel container senza sfarfallio o ritardi.
/// 3) La deallocazione immediata di qualsiasi texture video residua del canale precedente.
struct KSPlayerContainerView: UIViewRepresentable {
    let url: URL
    let title: String
    @ObservedObject var controller: KSPlaybackController

    final class Coordinator {
        var currentURL: URL?
        weak var currentLayer: KSPlayerLayer?
        weak var attachedPlayerView: UIView?
        var pendingPlayRetry: [DispatchWorkItem]?
        var stateCancellable: AnyCancellable?

        func cancelPendingTasks() {
            pendingPlayRetry?.forEach { $0.cancel() }
            pendingPlayRetry = nil
            stateCancellable?.cancel()
            stateCancellable = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        context.coordinator.currentURL = url
        attach(controller.layer, in: container, coordinator: context.coordinator)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let coordinator = context.coordinator

        // Se l'URL è cambiato rispetto a quello correntemente renderizzato
        if coordinator.currentURL != url {
            coordinator.currentURL = url
            // 1. Arresta immediatamente il vecchio flusso
            controller.layer.pause()
            // 2. Carica in tempo reale il nuovo URL e Titolo nel controller
            controller.load(url: url, title: title)
            // 3. Riaggancia il layer del nuovo flusso nel container
            attach(controller.layer, in: uiView, coordinator: coordinator)
            return
        }

        let layer = controller.layer
        let currentView = layer.player.view

        // Se il layer o la playerView interna è stata rigenerata dal controller
        if coordinator.currentLayer !== layer || coordinator.attachedPlayerView !== currentView {
            attach(layer, in: uiView, coordinator: coordinator)
        }
    }

    private func attach(_ layer: KSPlayerLayer, in container: UIView, coordinator: Coordinator) {
        coordinator.cancelPendingTasks()

        // Rimuove e pulisce all'istante la vista precedente per non lasciare nessun fotogramma congelato
        if let oldPlayerView = coordinator.attachedPlayerView {
            oldPlayerView.removeFromSuperview()
            coordinator.attachedPlayerView = nil
        }
        container.subviews.forEach { $0.removeFromSuperview() }

        coordinator.currentLayer = layer

        guard let playerView = layer.player.view else { return }
        coordinator.attachedPlayerView = playerView

        // La vista parte a trasparenza zero (sfondo nero puro) durante la connessione/decodifica del nuovo canale
        playerView.alpha = 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            playerView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(playerView)
            NSLayoutConstraint.activate([
                playerView.topAnchor.constraint(equalTo: container.topAnchor),
                playerView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                playerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                playerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
            container.layoutIfNeeded()
        }
        CATransaction.commit()

        // Rivelazione immediata appena il nuovo canale inizia a trasmettere fotogrammi reali
        coordinator.stateCancellable = controller.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak controller, weak playerView] _ in
                DispatchQueue.main.async {
                    guard let controller, let playerView else { return }
                    if controller.isPlaying && !controller.isBuffering && playerView.alpha < 1 {
                        UIView.animate(withDuration: 0.15) {
                            playerView.alpha = 1.0
                        }
                    }
                }
            }

        // Avvio immediato della riproduzione e retry dedicati
        layer.play()
        let retries = [0.05, 0.2, 0.5, 1.0].map { delay in
            let item = DispatchWorkItem { [weak layer, weak controller, weak playerView] in
                layer?.play()
                if let controller, let playerView, controller.isPlaying, !controller.isBuffering {
                    playerView.alpha = 1.0
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }
        coordinator.pendingPlayRetry = retries
    }
}

// MARK: - AirPlay, External Player, Audio Slider

struct AirPlayButton: UIViewRepresentable {
    var onCreate: ((AVRoutePickerView) -> Void)? = nil

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .systemBlue
        onCreate?(view)
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

// MARK: - Modals & Pickers

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

struct AdvancedSettingsView: View {
    @ObservedObject var controller: KSPlaybackController
    @Environment(\.dismiss) private var dismiss

    @State private var preferredBuffer: Double
    @State private var maxBuffer: Double
    @State private var hardwareDecode: Bool
    @State private var autoDeInterlace: Bool
    @State private var isAccurateSeek: Bool
    @State private var videoDelay: Double

    init(controller: KSPlaybackController) {
        self.controller = controller
        let prefs = controller.preferences
        _preferredBuffer = State(initialValue: prefs.preferredForwardBufferDuration)
        _maxBuffer = State(initialValue: prefs.maxBufferDuration)
        _hardwareDecode = State(initialValue: prefs.hardwareDecode)
        _autoDeInterlace = State(initialValue: prefs.autoDeInterlace)
        _isAccurateSeek = State(initialValue: prefs.isAccurateSeek)
        _videoDelay = State(initialValue: prefs.videoDelay)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Slider(value: $preferredBuffer, in: 1...30, step: 1) { Text("Buffer minimo") }
                        .onChange(of: preferredBuffer) { newValue in
                            controller.setPreferredForwardBufferDuration(newValue)
                        }
                    Text("Minimo: \(Int(preferredBuffer))s").foregroundStyle(.secondary)

                    Slider(value: $maxBuffer, in: Double(max(Int(preferredBuffer), 5))...120, step: 5) { Text("Buffer massimo") }
                        .onChange(of: maxBuffer) { newValue in
                            controller.setMaxBufferDuration(newValue)
                        }
                    Text("Massimo: \(Int(maxBuffer))s").foregroundStyle(.secondary)
                } header: {
                    Text("Buffer")
                } footer: {
                    Text("Un buffer più ampio riduce le interruzioni su reti instabili, a costo di un avvio più lento del flusso.")
                }

                Section {
                    Toggle("Decodifica hardware", isOn: $hardwareDecode)
                        .onChange(of: hardwareDecode) { newValue in
                            controller.setHardwareDecode(newValue)
                        }
                    Toggle("De-interlacciamento automatico", isOn: $autoDeInterlace)
                        .onChange(of: autoDeInterlace) { newValue in
                            controller.setAutoDeInterlace(newValue)
                        }
                } header: {
                    Text("Decodifica")
                } footer: {
                    Text("Disattiva la decodifica hardware se un canale si blocca o mostra artefatti: FFmpeg in software è più lento ma compatibile con flussi malformati. Il de-interlacciamento corregge l'effetto \"pettine\" tipico dei canali SD interlacciati. Entrambe ricaricano il flusso per applicarsi.")
                }

                Section {
                    Slider(value: $videoDelay, in: -2...2, step: 0.05) { Text("Sincronizzazione") }
                        .onChange(of: videoDelay) { newValue in
                            controller.setVideoDelay(newValue)
                        }
                    Text(videoDelaySummary).foregroundStyle(.secondary)
                    Button("Ripristina sincronizzazione") {
                        videoDelay = 0
                        controller.setVideoDelay(0)
                    }
                } header: {
                    Text("Sincronizzazione audio/video")
                } footer: {
                    Text("Se il video anticipa l'audio, sposta verso destra; se lo insegue, sposta verso sinistra.")
                }

                Section("Ricerca") {
                    Toggle("Ricerca accurata", isOn: $isAccurateSeek)
                        .onChange(of: isAccurateSeek) { newValue in
                            controller.setAccurateSeek(newValue)
                        }
                    Text("Posiziona la riproduzione esattamente al fotogramma richiesto invece che al keyframe più vicino: più precisa, leggermente più lenta.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Riproduzione") {
                    Text("Stato: \(controller.state.description)")
                    Button("Riprova") { controller.resetAttempts() }
                }
            }
            .navigationTitle("Impostazioni avanzate")
            .toolbar { Button("Chiudi") { dismiss() } }
        }
    }

    private var videoDelaySummary: String {
        if abs(videoDelay) < 0.01 { return "Sincronizzato" }
        let ms = Int((videoDelay * 1000).rounded())
        return videoDelay > 0 ? "Video ritardato di \(ms)ms" : "Video anticipato di \(-ms)ms"
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

struct ChannelHistoryView: View {
    let items: [RecentlyWatchedItem]
    let onSelect: (RecentlyWatchedItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableViewCompat(
                        title: "Nessun canale recente",
                        message: "I canali live che apri verranno elencati qui."
                    )
                } else {
                    List(items) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            HStack {
                                Image(systemName: "play.tv")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading) {
                                    Text(item.title).lineLimit(1)
                                    Text(item.openedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Cronologia dei canali")
            .toolbar { Button("Chiudi") { dismiss() } }
        }
    }
}

struct ContentUnavailableViewCompat: View {
    let title: String
    let message: String

    var body: some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView(title, systemImage: "clock", description: Text(message))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "clock").font(.largeTitle).foregroundStyle(.secondary)
                Text(title).font(.headline)
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding()
        }
    }
}
