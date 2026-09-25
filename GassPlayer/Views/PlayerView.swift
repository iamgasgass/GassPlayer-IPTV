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

    /// FEATURE MANCANTE aggiunta: pulsanti "precedente"/"successivo" per
    /// scorrere canali Live TV o episodi di una serie senza uscire dal
    /// player. `nil` = funzione non disponibile in questo contesto (es.
    /// primo/ultimo elemento della lista, oppure chiamante che non la
    /// implementa): il pulsante corrispondente si nasconde da solo, non
    /// resta mai visibile ma inattivo.
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: KSPlaybackController

    // Picker/menu
    @State private var showTrackPicker = false
    @State private var showBufferSettings = false
    @State private var showQualityPicker = false
    @State private var showExternalPlayerMenu = false
    @State private var showSpeedPicker = false
    @State private var showSleepTimerPicker = false

    // Selezioni correnti (usate per mostrare un segno di spunta nei picker)
    @State private var currentPlaybackRate: Double = 1.0
    @State private var selectedAudioTrackName: String?
    @State private var selectedSubtitleTrackName: String?
    @State private var selectedVideoTrackName: String?

    // FEATURE MANCANTE aggiunta: timer di spegnimento automatico (comune in
    // tutti i player video/IPTV, utile per addormentarsi guardando un
    // programma senza consumare batteria/dati tutta la notte).
    @State private var sleepTimerMinutes: Int?
    @State private var sleepTimerTask: Task<Void, Never>?

    // Gesti brightness/volume
    @State private var brightnessOverlay: Double = 0
    @State private var volumeOverlay: Double = 0
    @State private var showBrightnessHUD = false
    @State private var showVolumeHUD = false
    @State private var hudHideTask: Task<Void, Never>?

    // Toast generico (feedback doppio-tap, timer, ecc.) — un solo
    // meccanismo riusato ovunque invece di uno stato dedicato per ogni
    // singola notifica temporanea.
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?

    // Controlli generali
    @State private var showControls = true
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var isScrubbing = false

    // BUG FIX: `UIScreen.main.bounds.width` (usato in precedenza nel drag
    // gesture) è deprecato e restituisce dimensioni errate in scenari multi
    // finestra/multi scena (iPad Stage Manager, Slide Over, Split View):
    // la larghezza reale del player viene ora letta dalla gerarchia SwiftUI
    // stessa tramite `GeometryReader` e riusata sia per il gesto
    // luminosità/volume sia per le zone di doppio tap.
    @State private var containerWidth: CGFloat = UIScreen.main.bounds.width

    @State private var isLocked = false

    // Cache dei player esterni disponibili per questo URL.
    @State private var externalPlayers: [ExternalPlayer] = []

    init(url: URL, title: String, onPrevious: (() -> Void)? = nil, onNext: (() -> Void)? = nil) {
        self.url = url
        self.title = title
        self.onPrevious = onPrevious
        self.onNext = onNext
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
            .confirmationDialog("Timer di spegnimento", isPresented: $showSleepTimerPicker, titleVisibility: .visible) {
                ForEach([15, 30, 45, 60], id: \.self) { minutes in
                    Button("\(minutes) minuti") { scheduleSleepTimer(minutes: minutes) }
                }
                if sleepTimerMinutes != nil {
                    Button("Disattiva timer", role: .destructive) { cancelSleepTimer() }
                }
                Button("Annulla", role: .cancel) {}
            }
    }

    // MARK: - Gesture handling

    // BUG DI PROGETTAZIONE EVITATO: uno schermo "bloccato" che si sblocca
    // con un tap qualunque non protegge da nulla (tocchi accidentali in
    // tasca, pulizia dello schermo…). A schermo bloccato un tap generico
    // non fa nulla: l'unico modo per sbloccare è il pulsante dedicato
    // mostrato da `lockedOverlay`.
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

    /// BUG FIX ("preferenze nel menù '…' corrotte/bug al tocco"): un Menu
    /// che chiude se stesso e, nello stesso istante, fa scattare la
    /// presentazione di un'altra sheet/confirmationDialog è un caso noto in
    /// SwiftUI in cui la seconda presentazione può fallire silenziosamente
    /// o richiedere un secondo tocco (i due sistemi di presentazione
    /// competono sulla stessa transazione di animazione). Attendere che la
    /// chiusura del Menu sia completata prima di impostare il flag rende la
    /// voce affidabile al primo tocco, sempre.
    private func presentAfterMenuDismiss(_ setFlag: @escaping () -> Void) {
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { setFlag() }
        }
    }

    // MARK: - Timer di spegnimento

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

    private var sleepTimerMenuLabel: String {
        sleepTimerMinutes.map { "Timer di spegnimento (\($0) min)" } ?? "Timer di spegnimento"
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
            optionsMenu
        }
        .padding(.horizontal)
        .padding(.top, 8)
        // BUG FIX ("player disallineato oltre i bordi"): mancava il
        // rispetto del safe-area verticale (notch/Dynamic Island in alto,
        // home indicator in basso). Combinato con troppe icone ravvicinate
        // nella barra superiore, gli ultimi pulsanti finivano spinti oltre
        // il bordo destro dello schermo su iPhone più stretti. Qui si
        // applica il safe-area a tutti i lati (non solo orizzontale) e si è
        // rimosso un pulsante ridondante (blocco schermo, già presente nel
        // menu "…") che affollava inutilmente la barra.
        .safeAreaPadding()
        .background(LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var optionsMenu: some View {
        Menu {
            Button("Velocità di riproduzione (\(currentPlaybackRate == 1.0 ? "1x" : currentPlaybackRate.formatted() + "x"))", systemImage: "speedometer") {
                presentAfterMenuDismiss { showSpeedPicker = true }
            }
            Button("Qualità video\(selectedVideoTrackName.map { " (\($0))" } ?? "")", systemImage: "4k.tv") {
                presentAfterMenuDismiss { showQualityPicker = true }
            }
            Button("Impostazioni buffer", systemImage: "dial.low") {
                presentAfterMenuDismiss { showBufferSettings = true }
            }
            Button("Audio e sottotitoli", systemImage: "text.bubble") {
                presentAfterMenuDismiss { showTrackPicker = true }
            }
            Divider()
            Button(sleepTimerMenuLabel, systemImage: sleepTimerMinutes != nil ? "moon.zzz.fill" : "moon.zzz") {
                presentAfterMenuDismiss { showSleepTimerPicker = true }
            }
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
            HStack(spacing: 22) {
                // FEATURE MANCANTE aggiunta: precedente/successivo. Non
                // dipendono dalla durata del flusso: servono anche in Live
                // TV per cambiare canale senza uscire dal player.
                if let onPrevious {
                    GlassIconButton(systemImage: "backward.end.fill", size: 30) {
                        haptic()
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
                        onNext()
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
                .safeAreaPadding()
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
                // in corso, perché il primo timer non veniva annullato.
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

    // BUG FIX ("preferenze nel menù '…' corrotte/non funzionanti"): la
    // slider era collegata direttamente a `controller.layer.options`, una
    // proprietà NON osservata da Combine (`KSOptions` non è `@Published`).
    // Il valore veniva sì scritto correttamente, ma l'etichetta con i
    // secondi sotto la slider non si aggiornava a schermo durante il
    // trascinamento, perché nulla notificava alla view di ridisegnarsi:
    // sembrava un'impostazione "rotta" anche se in realtà veniva applicata.
    // Ora la slider guida uno `@State` locale (che SwiftUI osserva
    // nativamente) e lo propaga al controller ad ogni variazione.
    @State private var bufferDuration: Double

    init(controller: KSPlaybackController) {
        self.controller = controller
        _bufferDuration = State(initialValue: controller.layer.options.preferredForwardBufferDuration)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Buffer") {
                    Slider(value: $bufferDuration, in: 1...30, step: 1) { Text("Durata buffer") }
                        .onChange(of: bufferDuration) { newValue in
                            controller.layer.options.preferredForwardBufferDuration = newValue
                        }
                    Text("\(Int(bufferDuration)) secondi").foregroundStyle(.secondary)
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
