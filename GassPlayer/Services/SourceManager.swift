import Foundation
import Combine

@MainActor
final class SourceManager: ObservableObject {
    @Published var sources: [MediaSourceConfig] = []
    private let storageKey = "gassplayer.sources"

    init() { load() }
    func add(_ source: MediaSourceConfig) {
        var s = source
        s.sortOrder = sources.count
        sources.append(s); persist()
    }
    func remove(_ source: MediaSourceConfig) { sources.removeAll { $0.id == source.id }; persist() }
    func update(_ source: MediaSourceConfig) {
        guard let idx = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[idx] = source; persist()
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
    private func persist() {
        if let data = try? JSONEncoder().encode(sources) { UserDefaults.standard.set(data, forKey: storageKey) }
    }
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([MediaSourceConfig].self, from: data) else { return }
        sources = decoded.sorted { $0.sortOrder < $1.sortOrder }
    }
}
