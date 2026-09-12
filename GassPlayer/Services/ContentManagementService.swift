import Foundation
import Combine

@MainActor
final class ContentManagementService: ObservableObject {
    @Published var favorites: [FavoriteItem] = []
    @Published var mergedPlaylists: [MergedPlaylist] = []

    private let favoritesKey = "gassplayer.favorites"
    private let mergedKey = "gassplayer.mergedPlaylists"

    init() { load() }

    func toggleFavorite(id: String, title: String, kind: String) {
        if let idx = favorites.firstIndex(where: { $0.id == id }) {
            favorites.remove(at: idx)
        } else {
            favorites.append(FavoriteItem(id: id, title: title, kind: kind))
        }
        persist()
    }
    func isFavorite(id: String) -> Bool { favorites.contains { $0.id == id } }

    func createMergedPlaylist(name: String, sourceIds: [UUID]) {
        mergedPlaylists.append(MergedPlaylist(name: name, memberSourceIds: sourceIds, sortOrder: mergedPlaylists.count))
        persist()
    }
    func renameMergedPlaylist(_ playlist: MergedPlaylist, to newName: String) {
        guard let idx = mergedPlaylists.firstIndex(where: { $0.id == playlist.id }) else { return }
        mergedPlaylists[idx].name = newName
        persist()
    }
    func removeMergedPlaylist(_ playlist: MergedPlaylist) {
        mergedPlaylists.removeAll { $0.id == playlist.id }
        persist()
    }
    func reorderMergedPlaylists(fromOffsets: IndexSet, toOffset: Int) {
        mergedPlaylists.move(fromOffsets: fromOffsets, toOffset: toOffset)
        for (i, _) in mergedPlaylists.enumerated() { mergedPlaylists[i].sortOrder = i }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(favorites) { UserDefaults.standard.set(data, forKey: favoritesKey) }
        if let data = try? JSONEncoder().encode(mergedPlaylists) { UserDefaults.standard.set(data, forKey: mergedKey) }
    }
    private func load() {
        if let data = UserDefaults.standard.data(forKey: favoritesKey),
           let decoded = try? JSONDecoder().decode([FavoriteItem].self, from: data) { favorites = decoded }
        if let data = UserDefaults.standard.data(forKey: mergedKey),
           let decoded = try? JSONDecoder().decode([MergedPlaylist].self, from: data) { mergedPlaylists = decoded.sorted { $0.sortOrder < $1.sortOrder } }
    }
}
