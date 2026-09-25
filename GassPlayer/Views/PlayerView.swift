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

    // FEATURE aggiunta (menu "…" — sezioni "Cronologia dei canali" /
    // "Cerca canale"): entrambe leggono dati già gestiti altrove
    // nell'app (`RecentlyWatchedStore`, già @Published e persistito;
    // `GlobalSearchView`, già funzionante altrove) invece di duplicarne
    // la logica qui. Sono environment object già iniettati sulla radice
    // della gerarchia (`ContentView`) e propagati automaticamente
    // attraverso la `fullScreenCover` che presenta questo player.
    @EnvironmentObject private var recentlyWatched: RecentlyWatchedStore
    @EnvironmentObject private var sourceManager: SourceManager

    // Picker/menu
    @State private var showTrackPicker = false
    @State private var showAdvancedSettings = false
    @State private var showQualityPicker = false
    @State private var showExternalPlayerMenu = false
    @State private var showSpeedPicker = false
    @State private var showSleepTimerPicker = false
    @State private var showAspectPicker = false
    @State private var showChannelHistory = false
    @State private var showChannelSearch = false

    // Selezioni correnti (usate per mostrare un segno di spunta nei picker)
    @State private var currentPlaybackRate: Double = 1.0
    @State private var selectedAudioTrackName: String?
    @State private var selectedSubtitleTrackName: String?
    @State private var selectedVideoTrackName: String?

    // Timer di spegnimento automatico
    @State private var sleepTimerMinutes: Int?
    @State private var sleepTimerTask: Task<Void, Never>?

    // Gesti brightness/volume
    @State private var brightnessOverlay: Double = 0
    @State private var volumeOverlay: Double = 0
    @State private var showBrightnessHUD = false
    @State private var showVolumeHUD = false
    @State private var hudHideTask: Task<Void, Never>?

    // Toast generico (feedback doppio-tap, timer, ecc.)
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?

    // Controlli generali
    @State private var showControls = true
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var isScrubbing = false

    @State private var containerWidth: CGFloat = UIScreen.main.bounds.width
    @State private var isLocked = false
    @State private var externalPlayers: [ExternalPlayer] = []
    @State private var airPlayRoutePicker: AVRoutePickerView?

    /// BUG FIX ("preferenze nel menù '…' corrotte al tocco"): mentre un
    /// picker/dialog è aperto il timer di auto-hide dei controlli
    /// continuava comunque a scorrere; se l'utente impiegava più di 4
    /// secondi a decidere, `unifiedControlSurface` — che contiene il
    /// pulsante "…" stesso — passava a `opacity(0)` /
    /// `allowsHitTesting(false)`, rendendo il resto dei controlli
    /// irraggiungibili finché non si ritoccava lo schermo. Questo
    /// computed riunisce tutti i flag di presentazione in un unico punto
    /// osservabile da `.onChange`.
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
            // FEATURE MANCANTE aggiunta (precedente/successivo "in-place"):
            // quando il chiamante (ChannelGridView/SeriesEpisodesView)
            // aggiorna l'elemento selezionato tramite `onPrevious`/`onNext`,
            // SwiftUI ricostruisce questa `PlayerView` con un nuovo `url`
            // MANTENENDO la stessa identità di vista (nessun `.id()`, niente
            // dismiss/ri-presentazione della fullScreenCover): qui basta
            // dire al controller — che resta vivo per tutta la sessione —
            // di caricare il nuovo URL. `KSPlayerContainerView` sotto
            // reagisce da sola al cambio di `controller.layer`.
            .onChange(of: url) { newValue in
                controller.load(url: newValue, title: title)
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

    // MARK: - Gesture handling

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

    /// FEATURE aggiunta: adattamento video (Adatta/Riempi/Stira), un tasto
    /// dedicato nella `topBar` invece che sepolto nel menu "…" — è
    /// un'azione che si usa spesso al volo (specie su contenuti con bordi
    /// neri o proporzioni sbagliate nelle playlist IPTV) e merita un solo
    /// tocco, non due.
    private func cycleVideoGravity() {
        let next = controller.preferences.videoGravity.next
        controller.setVideoGravity(next)
        showToast(next.label, duration: 900_000_000)
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

    /// BUG FIX ("player disallineato oltre i bordi" / "troppi tasti che
    /// fuoriescono dallo schermo"): il cluster di icone secondarie
    /// (AirPlay, PiP, apri con altro player, "…") non si riduce mai sotto
    /// la sua larghezza intrinseca in un `HStack` — su schermi stretti
    /// (iPhone piccoli, Slide Over/Stage Manager su iPad, rotazione con
    /// notch che riduce la safe area disponibile) il numero di icone
    /// oggi presenti può superare la larghezza disponibile e finire
    /// tagliato oltre il bordo destro. Racchiuderlo in uno
    /// `ScrollView(.horizontal)` non cambia nulla quando tutto entra
    /// (nessuna indicazione di scroll visibile, nessun tasto "in più" da
    /// notare) ma garantisce che, quando NON entra, resti comunque
    /// raggiungibile scorrendo invece di sparire oltre lo schermo.
    private var topBar: some View {
        HStack {
            GlassIconButton(systemImage: "xmark") { dismiss() }

            Spacer(minLength: 8)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .shadow(radius: 4)
                .layoutPriority(1)

            Spacer(minLength: 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if controller.isBuffering {
                        ProgressView().tint(.white).padding(.horizontal, 4)
                    }
                    AirPlayButton(onCreate: { airPlayRoutePicker = $0 })
                        .frame(width: 30, height: 30)
                    if controller.supportsPictureInPicture {
                        GlassIconButton(systemImage: "pip.enter", size: 34) { controller.isPipActive = true }
                    }
                    GlassIconButton(systemImage: "arrow.up.forward.app", size: 34) { showExternalPlayerMenu = true }
                    GlassIconButton(systemImage: controller.preferences.videoGravity.systemImage, size: 34) {
                        cycleVideoGravity()
                    }
                    optionsMenu
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        // BUG FIX ("player disallineato oltre i bordi"): mancava il
        // rispetto del safe-area verticale (notch/Dynamic Island in alto,
        // home indicator in basso), applicato ora su tutti i lati.
        .safeAreaPadding()
        .background(LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom))
    }

    /// Ricostruito per rispecchiare esattamente la struttura mostrata
    /// dall'utente (3 gruppi con intestazione grigia, stesso ordine/testo/
    /// icona per ogni voce): `Section` dentro un `Menu` nativo SwiftUI
    /// produce di per sé quel pannello arrotondato con divisori e titoli
    /// di gruppo — nessuna vista custom necessaria, stesso comportamento
    /// affidabile di `presentAfterMenuDismiss` già in uso per le voci
    /// esistenti.
    private var optionsMenu: some View {
        Menu {
            Section("Impostazioni e controlli video") {
                Button("Rapporto di aspetto", systemImage: "aspectratio") {
                    presentAfterMenuDismiss { showAspectPicker = true }
                }
                Button("Cronologia dei canali", systemImage: "clock") {
                    presentAfterMenuDismiss { showChannelHistory = true }
                }
                Button("Cerca canale", systemImage: "magnifyingglass") {
                    presentAfterMenuDismiss { showChannelSearch = true }
                }
                Button("Blocca schermo", systemImage: "lock") {
                    haptic()
                    isLocked = true
                }
            }

            Section("Impostazioni lettore") {
                // Motore di decodifica: questo player usa un solo engine
                // (KSPlayer, AVPlayer nativo + fallback FFmpeg incorporato
                // automaticamente da KSPlayer stesso), non una scelta tra
                // più player come in altre app — quindi questa voce
                // corrisponde alla leva reale più vicina: `hardwareDecode`
                // (VideoToolbox/Metal) vs decodifica software FFmpeg pura.
                Button(
                    controller.preferences.hardwareDecode ? "✓ Usa KSPlayer (Metal)" : "Usa KSPlayer (Metal)",
                    systemImage: "cpu"
                ) {
                    haptic()
                    controller.setHardwareDecode(!controller.preferences.hardwareDecode)
                    showToast(controller.preferences.hardwareDecode ? "Decodifica hardware (Metal)" : "Decodifica software (FFmpeg)", duration: 1_200_000_000)
                }
                Button("Velocità di riproduzione (\(currentPlaybackRate == 1.0 ? "1x" : currentPlaybackRate.formatted() + "x"))", systemImage: "speedometer") {
                    presentAfterMenuDismiss { showSpeedPicker = true }
                }
                Button("Qualità video\(selectedVideoTrackName.map { " (\($0))" } ?? "")", systemImage: "4k.tv") {
                    presentAfterMenuDismiss { showQualityPicker = true }
                }
                Button("Impostazioni avanzate", systemImage: "slider.horizontal.3") {
                    presentAfterMenuDismiss { showAdvancedSettings = true }
                }
                Button("Audio e sottotitoli", systemImage: "text.bubble") {
                    presentAfterMenuDismiss { showTrackPicker = true }
                }
                Button(sleepTimerMenuLabel, systemImage: sleepTimerMinutes != nil ? "moon.zzz.fill" : "moon.zzz") {
                    presentAfterMenuDismiss { showSleepTimerPicker = true }
                }
            }

            Section("Trasmissione video e audio") {
                Button("AirPlay audio", systemImage: "airplayaudio") {
                    triggerAirPlayPicker()
                }
                Button("AirPlay video", systemImage: "airplayvideo") {
                    triggerAirPlayPicker()
                }
                // Chromecast richiede il Google Cast SDK come nuova
                // dipendenza SPM/CocoaPods: non presente in questo
                // progetto e non aggiungibile alla cieca senza poter
                // compilare/verificare qui. Voce mostrata per coerenza
                // visiva con lo screenshot ma onestamente non funzionante
                // finché quella dipendenza non viene aggiunta a parte.
                Button("Chromecast (richiede Google Cast SDK)", systemImage: "tv.badge.wifi") {
                    showToast("Chromecast non ancora integrato", duration: 1_400_000_000)
                }
            }
        } label: {
            GlassIconGlyph(systemImage: "ellipsis", size: 34)
        }
        .menuStyle(.button)
        .modifier(NativeOrLegacyGlassCircle(tint: nil, isInSystemToolbar: false))
        .accessibilityLabel("Altre opzioni")
    }

    /// Innesca il picker di sistema AirPlay senza dover mostrare un'altra
    /// `AVRoutePickerView` visibile a schermo: `AVRoutePickerView` non è
    /// programmabile via API pubblica dedicata, ma incapsula internamente
    /// un `UIButton` che risponde a `sendActions(for: .touchUpInside)` —
    /// tecnica ampiamente usata proprio per innescarla da un tasto
    /// personalizzato. Se Apple cambiasse quella gerarchia interna in una
    /// futura versione di iOS, questa chiamata diventerebbe semplicemente
    /// un no-op silenzioso (nessun crash, nessun errore di compilazione):
    /// per questo qui c'è un solo punto di innesco condiviso da entrambe
    /// le voci "AirPlay audio/video", riutilizzando la STESSA istanza già
    /// visibile nella `topBar` invece di crearne una seconda nascosta.
    private func triggerAirPlayPicker() {
        guard let picker = airPlayRoutePicker else { return }
        picker.subviews.compactMap { $0 as? UIButton }.first?.sendActions(for: .touchUpInside)
    }


    private var progressBar: some View {
        VStack(spacing: 8) {
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

            // BUG FIX ("troppi tasti che fuoriescono dallo schermo"): i
            // pulsanti di trasporto (precedente/-15/play-pausa/+15/
            // successivo) sono ora su una riga TUTTA loro, senza dover
            // condividere lo spazio orizzontale con l'etichetta del tempo:
            // prima, su schermi stretti con precedente+successivo
            // visibili, l'intera fila (5 icone + testo "mm:ss / mm:ss")
            // poteva superare la larghezza disponibile e finire tagliata
            // oltre il bordo. Al centro dello schermo, dimensione fissa e
            // sempre ampiamente entro la larghezza minima di un iPhone.
            HStack(spacing: 22) {
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

/// FIX ("cambiare canale senza uscire e riaprire il player"): riflette
/// nella UIKit view il `KSPlayerLayer` corrente del controller. Quando
/// `controller.load(url:title:)` sostituisce `layer` con uno nuovo (stesso
/// controller, stessa `PlayerView`, nessuna nuova presentazione),
/// `updateUIView` se ne accorge e scollega la vecchia `player.view`
/// agganciando quella nuova nello STESSO container già a schermo — non
/// viene mai ricreato l'intero `UIView` del player, quindi nessun nero,
/// nessuna nuova transizione di presentazione, nessun reset dei controlli.
struct KSPlayerContainerView: UIViewRepresentable {
    let controller: KSPlaybackController

    final class Coordinator {
        weak var attachedPlayerView: UIView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        attach(controller.layer.player.view, to: container, coordinator: context.coordinator)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard controller.layer.player.view !== context.coordinator.attachedPlayerView else { return }
        attach(controller.layer.player.view, to: uiView, coordinator: context.coordinator)
    }

    private func attach(_ playerView: UIView?, to container: UIView, coordinator: Coordinator) {
        coordinator.attachedPlayerView?.removeFromSuperview()
        coordinator.attachedPlayerView = playerView

        guard let playerView else { return }

        playerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: container.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            playerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }
}

struct AirPlayButton: UIViewRepresentable {
    /// Espone al chiamante la `AVRoutePickerView` appena creata, così il
    /// menu "…" può innescarla a distanza (vedi `triggerAirPlayPicker`)
    /// riusando questa STESSA istanza invece di crearne una seconda
    /// invisibile — un'unica `AVRoutePickerView` per sessione di
    /// riproduzione, come previsto dalla view stessa.
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

/// Impostazioni avanzate del motore KSPlayer+FFmpeg, tutte su proprietà
/// REALI di `KSOptions` (verificate sul sorgente ufficiale
/// github.com/kingslay/KSPlayer): buffer, decodifica hardware/software,
/// de-interlacciamento automatico, sincronizzazione audio/video, ricerca
/// accurata, sottotitoli. Le modifiche che richiedono il riavvio della
/// pipeline di decodifica (decodifica, de-interlacciamento, sottotitoli)
/// lo fanno in modo esplicito e visibile tramite `controller.reload()`,
/// invece di illudere l'utente con un cambiamento che non si applica
/// davvero finché il flusso non viene ricaricato.
struct AdvancedSettingsView: View {
    @ObservedObject var controller: KSPlaybackController
    @Environment(\.dismiss) private var dismiss

    // BUG FIX ("preferenze nel menù '…' corrotte/non funzionanti"): come
    // per il buffer, ogni slider/toggle qui guida uno `@State` locale
    // (osservato nativamente da SwiftUI) sincronizzato con
    // `controller.preferences`/`layer.options` ad ogni variazione, invece
    // di leggere/scrivere `layer.options` direttamente nel `body` — che
    // non essendo `@Published`-osservato lascia l'interfaccia "congelata"
    // sul valore iniziale anche quando il valore reale è cambiato.
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

/// Sheet "Cronologia dei canali", raggiungibile dal menu "…": elenca i
/// canali live aperti di recente (`RecentlyWatchedStore`, già alimentato
/// altrove nell'app ad ogni riproduzione) e permette di riaprirli
/// nello STESSO player, in-place, con `controller.load(url:title:)` —
/// stesso meccanismo già usato per precedente/successivo, nessuna nuova
/// presentazione del player.
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

/// `ContentUnavailableView` esiste solo da iOS 17: questo fallback usa
/// lo stesso identico markup su iOS 16, evitando di alzare a forza la
/// deployment target del progetto solo per questa sheet.
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
