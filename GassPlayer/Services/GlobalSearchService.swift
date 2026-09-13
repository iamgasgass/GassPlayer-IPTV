import Foundation

struct SearchResult: Identifiable, Hashable {
    let id: String, title: String, sourceName: String
    let kind: XtreamStreamKind, streamId: Int
    let credentials: XtreamCredentials
    static func == (l: SearchResult, r: SearchResult) -> Bool { l.id == r.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

actor GlobalSearchService {
    private let sources: [(MediaSourceConfig, XtreamCredentials, CachedXtreamRepository)]

    init(configs: [MediaSourceConfig]) {
        self.sources = configs.filter { $0.type == .xtream && $0.isEnabled }.compactMap { config in
            guard let user = config.username, let pass = config.password else { return nil }
            let creds = XtreamCredentials(host: config.host, username: user, password: pass)
            return (config, creds, CachedXtreamRepository(credentials: creds))
        }
    }

    func search(_ query: String) async -> [SearchResult] {
        guard !query.isEmpty else { return [] }
        var results: [SearchResult] = []
        await withTaskGroup(of: [SearchResult].self) { group in
            for (config, creds, repository) in sources {
                group.addTask {
                    var partial: [SearchResult] = []

                    for kind in [XtreamStreamKind.live, .movie] {
                        if let streams = try? await repository.streams(kind: kind, categoryId: nil) {
                            partial += streams
                                .filter { $0.name.localizedCaseInsensitiveContains(query) }
                                .map {
                                    SearchResult(
                                        id: "\(config.id)-\(kind.rawValue)-\($0.streamId)",
                                        title: $0.name,
                                        sourceName: config.name,
                                        kind: kind,
                                        streamId: $0.streamId,
                                        credentials: creds
                                    )
                                }
                        }
                    }

                    let seriesAPI = XtreamAPIService(credentials: creds)
                    if let seriesItems = try? await seriesAPI.fetchSeriesList(categoryId: nil) {
                        partial += seriesItems
                            .filter { $0.name.localizedCaseInsensitiveContains(query) }
                            .map {
                                SearchResult(
                                    id: "\(config.id)-series-\($0.seriesId)",
                                    title: $0.name,
                                    sourceName: config.name,
                                    kind: .series,
                                    streamId: $0.seriesId,
                                    credentials: creds
                                )
                            }
                    }

                    return partial
                }
            }
            for await partial in group { results += partial }
        }
        return results
    }
}
