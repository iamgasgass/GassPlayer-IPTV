import Foundation
import Combine

@MainActor
final class CloudSyncService: ObservableObject {
    @Published var isSyncing = false
    private let store = NSUbiquitousKeyValueStore.default
    private let sourcesKey = "sync.sources"
    private let favoritesKey = "sync.favorites"
    private let watchProgressKey = "sync.watchProgress"

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(externalChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store
        )
        store.synchronize()
    }

    @objc private func externalChange(_ note: Notification) {
        NotificationCenter.default.post(name: .cloudDataDidChange, object: nil)
    }

    func pushSources(_ sources: [MediaSourceConfig]) {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        store.set(data, forKey: sourcesKey); store.synchronize()
    }
    func pullSources() -> [MediaSourceConfig]? {
        guard let data = store.data(forKey: sourcesKey) else { return nil }
        return try? JSONDecoder().decode([MediaSourceConfig].self, from: data)
    }
    func pushWatchProgress(_ progress: [String: Double]) {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        store.set(data, forKey: watchProgressKey); store.synchronize()
    }
    func pullWatchProgress() -> [String: Double] {
        guard let data = store.data(forKey: watchProgressKey),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return decoded
    }
    func pushFavorites(_ ids: Set<String>) { store.set(Array(ids), forKey: favoritesKey); store.synchronize() }
    func pullFavorites() -> Set<String> { Set(store.array(forKey: favoritesKey) as? [String] ?? []) }
}

extension Notification.Name { static let cloudDataDidChange = Notification.Name("cloudDataDidChange") }
