import Foundation
import Combine

@MainActor
final class M3UPlaylistStore: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var channelsByKind: [XtreamStreamKind: [M3UChannel]] = [:]

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
            channelsByKind = Dictionary(grouping: loaded, by: { $0.kind })
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
        let groups = Array(Set(channels.compactMap { $0.groupTitle })).sorted()
        return groups.isEmpty && !channels.isEmpty ? ["Tutti i canali"] : groups
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
