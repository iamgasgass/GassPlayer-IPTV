import Foundation
import Combine

@MainActor
final class SearchHistoryStore: ObservableObject {
    @Published private(set) var items: [String] = []

    private let defaults: UserDefaults
    private let storageKey = "gassplayer.search.history"
    private let limit = 10

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = defaults.stringArray(forKey: storageKey) ?? []
    }

    func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }

        items.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        items.insert(trimmed, at: 0)

        if items.count > limit {
            items = Array(items.prefix(limit))
        }
        persist()
    }

    func remove(_ query: String) {
        items.removeAll { $0 == query }
        persist()
    }

    func clear() {
        items = []
        persist()
    }

    private func persist() {
        defaults.set(items, forKey: storageKey)
    }
}
