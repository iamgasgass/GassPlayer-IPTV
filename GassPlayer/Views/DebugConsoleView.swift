import SwiftUI

struct DebugConsoleView: View {
    @ObservedObject var logger = DebugLogger.shared

    var body: some View {
        NavigationStack {
            List {
                Toggle("Debug Mode attivo", isOn: $logger.isEnabled)
                ForEach(logger.entries) { entry in
                    VStack(alignment: .leading) {
                        Text("[\(entry.level.rawValue)] \(entry.message)").font(.caption.monospaced())
                        Text(entry.timestamp, style: .time).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Debug Mode")
            .toolbar { Button("Svuota log") { logger.clear() } }
        }
    }
}
