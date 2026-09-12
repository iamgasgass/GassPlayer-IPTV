import SwiftUI

/// Estratto in file dedicato e aggiornato per mostrare lo stato del
/// buffer adattivo (non più solo uno slider manuale statico) e permettere
/// di annullare la riduzione automatica di qualità dopo stalli ripetuti.
struct BufferSettingsView: View {
    @ObservedObject var reconnectPlayer: SmartReconnectPlayer
    @ObservedObject var networkMonitor = NetworkMonitor.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Stato rete") {
                    HStack {
                        Text(networkMonitor.isConnected ? "Connesso" : "Offline")
                        Spacer()
                        if networkMonitor.isExpensive { Text("Rete a consumo").font(.caption).foregroundStyle(.orange) }
                    }
                }
                Section("Buffer adattivo") {
                    Text("Attuale: \(Int(reconnectPlayer.currentBufferSeconds)) secondi")
                    Text("Il buffer si alza automaticamente se lo stream va spesso in stallo, per privilegiare la stabilità sulla latenza.")
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: $reconnectPlayer.preferredBufferSeconds, in: 1...30, step: 1) { Text("Buffer manuale") }
                }
                Section("Qualità") {
                    if reconnectPlayer.qualityWasAutoReduced {
                        Label("Qualità abbassata automaticamente per stabilità", systemImage: "arrow.down.circle")
                            .foregroundStyle(.orange)
                        Button("Ripristina qualità automatica") { reconnectPlayer.restoreAutoQuality() }
                    } else {
                        Text("Qualità gestita automaticamente in base alla rete.").font(.caption).foregroundStyle(.secondary)
                    }
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
