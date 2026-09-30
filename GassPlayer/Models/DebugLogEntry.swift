import Foundation

struct DebugLogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp = Date()
    let level: Level
    let message: String
    enum Level: String { case info = "INFO", warning = "WARN", error = "ERROR" }
}
