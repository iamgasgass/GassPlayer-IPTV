import Foundation
import Combine

/// PRIMA: ogni volta che `M3UChannelsView` appariva (ogni cambio tab),
/// ripartiva da zero il download + parsing dell'intera playlist —
/// per una playlist come Free-TV/IPTV (multi-MB, migliaia di righe)
/// questo significava richiamare la rete e riparsare tutto ad ogni
/// swipe tra Live/Film/Serie. Ora il parsing avviene UNA sola volta,
/// condiviso tramite @EnvironmentObject, e i risultati sono già
/// pre-raggruppati per kind (Live/VOD/Serie) e per group-title.
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
}
