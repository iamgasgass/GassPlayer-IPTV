import Foundation
import Combine

@MainActor
final class DebugLogger: ObservableObject {
    static let shared = DebugLogger()
    @Published private(set) var entries: [DebugLogEntry] = []
    @Published var isEnabled = false

    func log(_ level: DebugLogEntry.Level, _ message: String) {
        guard isEnabled else { return }
        entries.append(DebugLogEntry(level: level, message: message))
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
    }
    func clear() { entries.removeAll() }
    func exportText() -> String {
        entries.map { "[\($0.level.rawValue)] \($0.timestamp): \($0.message)" }.joined(separator: "\n")
    }
}
