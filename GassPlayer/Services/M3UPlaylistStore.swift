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
        guard loadedURL != url else {
            return
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        let service = M3UPlaylistService()

        do {
            let loaded = try await service.load(from: url)

            guard !loaded.isEmpty else {
                errorMessage = "La playlist è stata scaricata ma non contiene canali validi."
                return
            }

            let deduplicate = UserDefaults.standard.object(
                forKey: "settings.deduplicateM3U"
            ) as? Bool ?? true

            let normalized = deduplicate
                ? Self.normalized(loaded)
                : loaded

            sourceCount = normalized.count
            channelsByKind = Dictionary(
                grouping: normalized,
                by: { $0.kind }
            )

            loadedURL = url
        } catch {
            errorMessage = "Errore nel caricamento della playlist: \(error.localizedDescription)"
        }
    }

    func reload(url: URL) async {
        loadedURL = nil
        await loadIfNeeded(url: url)
    }

    func groups(for kind: XtreamStreamKind) -> [String] {
        let channels = channelsByKind[kind] ?? []

        let namedGroups = Set(
            channels.compactMap { channel -> String? in
                let group = channel.groupTitle?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? ""

                return group.isEmpty ? nil : group
            }
        )

        var result = namedGroups.sorted()

        let uncategorizedCount = channels.filter { channel in
            channel.groupTitle?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ?? true
        }
        .count

        let showUncategorized = UserDefaults.standard.object(
            forKey: "settings.showUncategorized"
        ) as? Bool ?? true

        if uncategorizedCount > 0 && showUncategorized {
            result.append("Senza categoria (\(uncategorizedCount))")
        }

        if result.isEmpty && !channels.isEmpty {
            result = ["Tutti i contenuti"]
        }

        return result
    }

    /// Unica implementazione del metodo: la seconda versione era un
    /// copia-incolla residuo e provocava "invalid redeclaration".
    func channels(
        for kind: XtreamStreamKind,
        group: String
    ) -> [M3UChannel] {
        let channels = channelsByKind[kind] ?? []

        if group == "Tutti i contenuti" || group == "Tutti i canali" {
            return channels
        }

        if group.hasPrefix("Senza categoria") {
            return channels.filter { channel in
                channel.groupTitle?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty ?? true
            }
        }

        return channels.filter { channel in
            channel.groupTitle?
                .trimmingCharacters(in: .whitespacesAndNewlines) == group
        }
    }

    /// API esplicita per timeline EPG e altre viste che devono leggere
    /// l'intero catalogo di una tipologia, senza affidarsi al nome fittizio
    /// del gruppo "Tutti i contenuti".
    func allChannels(for kind: XtreamStreamKind) -> [M3UChannel] {
        channelsByKind[kind] ?? []
    }

    func totalCount(for kind: XtreamStreamKind) -> Int {
        channelsByKind[kind]?.count ?? 0
    }

    func groupIcon(
        for kind: XtreamStreamKind,
        group: String
    ) -> String? {
        channels(for: kind, group: group)
            .first(where: { $0.logoURL?.isEmpty == false })?
            .logoURL
    }

    /// Mantiene ogni coppia distinta titolo+URL. I metadati EPG/logo
    /// duplicati non rendono il canale differente; titolo e URL sì.
    private static func normalized(
        _ channels: [M3UChannel]
    ) -> [M3UChannel] {
        var seen = Set<String>()

        return channels.filter { channel in
            let normalizedTitle = channel.title.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )

            let key = "\(normalizedTitle)|\(channel.streamURL.absoluteString)"

            return seen.insert(key).inserted
        }
    }
}
