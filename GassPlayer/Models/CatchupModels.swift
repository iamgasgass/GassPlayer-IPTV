import Foundation

struct EPGProgram: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let description: String?
    let start: Date
    let end: Date
    let hasArchive: Bool
}

struct CatchupRequest {
    let streamId: Int
    let start: Date
    let durationMinutes: Int
}
