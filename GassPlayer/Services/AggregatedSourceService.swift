import Foundation

struct AggregatedChannelGroup: Identifiable {
    let id: UUID
    let sourceName: String
    let streams: [XtreamStream]
    let credentials: XtreamCredentials
}

actor AggregatedSourceService {
    func fetchLiveChannels(from sources: [MediaSourceConfig], kind: XtreamStreamKind) async -> [AggregatedChannelGroup] {
        let xtreamSources = sources.filter { $0.type == .xtream && $0.isEnabled }

        var results: [AggregatedChannelGroup] = []
        await withTaskGroup(of: AggregatedChannelGroup?.self) { group in
            for source in xtreamSources {
                group.addTask {
                    guard let username = source.username, let password = source.password else { return nil }
                    let credentials = XtreamCredentials(host: source.host, username: username, password: password)
                    let api = XtreamAPIService(credentials: credentials)
                    guard let categories = try? await api.fetchCategories(kind: kind) else { return nil }
                    var allStreams: [XtreamStream] = []
                    for category in categories {
                        if let streams = try? await api.fetchStreams(kind: kind, categoryId: category.categoryId) {
                            allStreams += streams
                        }
                    }
                    return AggregatedChannelGroup(id: source.id, sourceName: source.name, streams: allStreams, credentials: credentials)
                }
            }
            for await result in group {
                if let result { results.append(result) }
            }
        }
        return results.sorted { $0.sourceName < $1.sourceName }
    }
}
