import Foundation
import Combine

@MainActor
final class M3UPlaylistStore: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var channelsByKind: [XtreamStreamKind: [M3UChannel]] = [:]
    @Published private(set) var sourceCount: Int = 0

    private var loadedURL: URL?

    func loadIfNeeded(url: URL) async {
        guard loadedURL != url else { return }
        isLoading = true
        errorMessage = nil
        let service = M3UPlaylistService()
        do {
            let loaded = try await service.load(from: url)
            guard !loaded.isEmpty else {
                errorMessage = "La playlist è stata scaricata ma non contiene canali validi."
                isLoading = false
                return
            }
            let deduplicate = UserDefaults.standard.object(forKey: "settings.deduplicateM3U") as? Bool ?? true
            let normalized = deduplicate ? Self.normalized(loaded) : loaded
            sourceCount = normalized.count
            channelsByKind = Dictionary(grouping: normalized, by: { $0.kind })
            loadedURL = url
        } catch {
            errorMessage = "Errore nel caricamento della playlist: \(error.localizedDescription)"
        }
        isLoading = false
    }

    func reload(url: URL) async {
        loadedURL = nil
        await loadIfNeeded(url: url)
    }

    func groups(for kind: XtreamStreamKind) -> [String] {
        let channels = channelsByKind[kind] ?? []
        let named = Set(channels.compactMap { group in
            let value = group.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        })
        var result = named.sorted()
        let unnamedCount = channels.filter { ($0.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }.count
        let showUncategorized = UserDefaults.standard.object(forKey: "settings.showUncategorized") as? Bool ?? true
        if unnamedCount > 0 && showUncategorized { result.append("Senza categoria (\(unnamedCount))") }
        if result.isEmpty && !channels.isEmpty { result = ["Tutti i contenuti"] }
        return result
    }

    func channels(for kind: XtreamStreamKind, group: String) -> [M3UChannel] {
        let channels = channelsByKind[kind] ?? []
        if group == "Tutti i contenuti" { return channels }
        if group.hasPrefix("Senza categoria") {
            return channels.filter { $0.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true }
        }
        return channels.filter { $0.groupTitle == group }
    }

    private static func normalized(_ channels: [M3UChannel]) -> [M3UChannel] {
        // Preserve every distinct title/URL pair; repeated EPG/logo metadata is harmless.
        var seen = Set<String>()
        return channels.filter {
            let key = "\($0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))|\($0.streamURL.absoluteString)"
            return seen.insert(key).inserted
        }
    }

    func channels(for kind: XtreamStreamKind, group: String) -> [M3UChannel] {
        let channels = channelsByKind[kind] ?? []
        if group == "Tutti i canali" { return channels }
        return channels.filter { $0.groupTitle == group }
    }

    func totalCount(for kind: XtreamStreamKind) -> Int {
        channelsByKind[kind]?.count ?? 0
    }

    func groupIcon(for kind: XtreamStreamKind, group: String) -> String? {
        channels(for: kind, group: group).first(where: { $0.logoURL?.isEmpty == false })?.logoURL
    }
}
