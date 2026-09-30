import Foundation

struct FavoriteItem: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var kind: String
    var addedAt: Date = Date()
}

struct MergedPlaylist: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var memberSourceIds: [UUID]
    var sortOrder: Int = 0
}
