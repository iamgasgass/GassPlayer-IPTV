import SwiftUI
import AVKit

struct PlayerView: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var reconnectPlayer: SmartReconnectPlayer
    @State private var showTrackPicker = false
    @State private var showBufferSettings = false
    @State private var audioOptions: [AVMediaSelectionOption] = []
    @State private var subtitleOptions: [AVMediaSelectionOption] = []

    init(url: URL, title: String) {
        self.url = url; self.title = title
        _reconnectPlayer = StateObject(wrappedValue: SmartReconnectPlayer(url: url))
    }

    var body: some View {
        ZStack(alignment: .top) {
            VideoPlayer(player: reconnectPlayer.player)
                .ignoresSafeArea()
                .onAppear { reconnectPlayer.player.play(); Task { await loadMediaSelection() } }
                .onDisappear { reconnectPlayer.player.pause() }

            HStack {
                GlassIconButton(systemImage: "xmark") { dismiss() }
                Spacer()
                if reconnectPlayer.isBuffering { ProgressView().padding(.horizontal, 8) }
                GlassIconButton(systemImage: "dial.low") { showBufferSettings = true }
                GlassIconButton(systemImage: "text.bubble") { showTrackPicker = true }
                GlassIconButton(systemImage: "pip.enter") { PiPCoordinator.shared.spawnMiniPlayer(url: url, title: title) }
            }
            .padding()
        }
        .sheet(isPresented: $showTrackPicker) {
            TrackPickerView(player: reconnectPlayer.player, audioOptions: audioOptions, subtitleOptions: subtitleOptions)
        }
        .sheet(isPresented: $showBufferSettings) {
            BufferSettingsView(reconnectPlayer: reconnectPlayer)
        }
    }

    private func loadMediaSelection() async {
        guard let asset = reconnectPlayer.player.currentItem?.asset else { return }
        if let audibleGroup = try? await asset.loadMediaSelectionGroup(for: .audible) { audioOptions = audibleGroup.options }
        if let legibleGroup = try? await asset.loadMediaSelectionGroup(for: .legible) { subtitleOptions = legibleGroup.options }
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

@MainActor
final class PiPCoordinator {
    static let shared = PiPCoordinator()
    private(set) var miniPlayers: [(id: UUID, url: URL, title: String)] = []
    let maxConcurrent = 4

    func spawnMiniPlayer(url: URL, title: String) {
        guard miniPlayers.count < maxConcurrent else { return }
        miniPlayers.append((UUID(), url, title))
    }
    func closeMiniPlayer(id: UUID) { miniPlayers.removeAll { $0.id == id } }
}
