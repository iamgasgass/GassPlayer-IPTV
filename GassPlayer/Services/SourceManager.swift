import Foundation
import Combine

@MainActor
final class SourceManager: ObservableObject {
    @Published var sources: [MediaSourceConfig] = []
    @Published var activeSourceId: UUID?

    private let storageKey = "gassplayer.sources"
    private let activeKey = "gassplayer.activeSourceId"

    init() { load() }

    func add(_ source: MediaSourceConfig) {
        var s = source
        s.sortOrder = sources.count
        sources.append(s)
        activeSourceId = s.id
        persist()
    }
    func remove(_ source: MediaSourceConfig) {
        sources.removeAll { $0.id == source.id }
        if activeSourceId == source.id { activeSourceId = sources.first?.id }
        persist()
    }
    func rename(_ source: MediaSourceConfig, to newName: String) {
        guard let idx = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[idx].name = newName; persist()
    }
    func move(fromOffsets: IndexSet, toOffset: Int) {
        sources.move(fromOffsets: fromOffsets, toOffset: toOffset)
        for (i, _) in sources.enumerated() { sources[i].sortOrder = i }
        persist()
    }

    func setActive(_ source: MediaSourceConfig) {
        activeSourceId = source.id
        persist()
    }

    var activeSource: MediaSourceConfig? {
        sources.first { $0.id == activeSourceId } ?? sources.last
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(sources) { UserDefaults.standard.set(data, forKey: storageKey) }
        if let activeSourceId { UserDefaults.standard.set(activeSourceId.uuidString, forKey: activeKey) }
    }
    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([MediaSourceConfig].self, from: data) {
            sources = decoded.sorted { $0.sortOrder < $1.sortOrder }
        }
        if let idString = UserDefaults.standard.string(forKey: activeKey), let id = UUID(uuidString: idString) {
            activeSourceId = id
        } else {
            activeSourceId = sources.last?.id
        }
    }
}
