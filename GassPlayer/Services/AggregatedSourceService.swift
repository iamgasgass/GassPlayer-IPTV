import Foundation

struct AggregatedChannelGroup: Identifiable {
    let id: UUID
    let sourceName: String
    let streams: [XtreamStream]
    let credentials: XtreamCredentials
    let error: String?
}

actor AggregatedSourceService {
    /// Carica gruppi di stream da tutte le sorgenti Xtream abilitate.
    /// Per VOD usa il catalogo completo globale e include anche i titoli senza
    /// categoria dichiarata dal provider.
    func fetchStreamGroups(
        from sources: [MediaSourceConfig],
        kind: XtreamStreamKind,
        forceRefresh: Bool = false
    ) async -> [AggregatedChannelGroup] {
        guard kind != .series else { return [] }
        let xtreamSources = sources.filter { $0.type == .xtream && $0.isEnabled }

        let groups = await withTaskGroup(of: AggregatedChannelGroup.self, returning: [AggregatedChannelGroup].self) { group in
            for source in xtreamSources {
                group.addTask {
                    guard let username = source.username?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !username.isEmpty,
                          let password = source.password,
                          !password.isEmpty else {
                        return AggregatedChannelGroup(
                            id: source.id,
                            sourceName: source.name,
                            streams: [],
                            credentials: XtreamCredentials(host: source.host, username: "", password: ""),
                            error: "Username o password mancanti per questa sorgente."
                        )
                    }

                    let credentials = XtreamCredentials(host: source.host, username: username, password: password)
                    let repository = CachedXtreamRepository(credentials: credentials)

                    do {
                        let streams = try await repository.allStreams(kind: kind, forceRefresh: forceRefresh)
                        return AggregatedChannelGroup(
                            id: source.id,
                            sourceName: source.name,
                            streams: streams,
                            credentials: credentials,
                            error: nil
                        )
                    } catch let error as XtreamError {
                        return AggregatedChannelGroup(
                            id: source.id,
                            sourceName: source.name,
                            streams: [],
                            credentials: credentials,
                            error: error.errorDescription
                        )
                    } catch {
                        return AggregatedChannelGroup(
                            id: source.id,
                            sourceName: source.name,
                            streams: [],
                            credentials: credentials,
                            error: "Errore imprevisto: \(error.localizedDescription)"
                        )
                    }
                }
            }

            var results: [AggregatedChannelGroup] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        return groups.sorted {
            if $0.sourceName.localizedCaseInsensitiveCompare($1.sourceName) == .orderedSame {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.sourceName.localizedCaseInsensitiveCompare($1.sourceName) == .orderedAscending
        }
    }

    /// Compatibilità con i call-site esistenti. Il nome storico non cambia il
    /// comportamento: per kind .movie usa comunque il catalogo VOD completo.
    func fetchLiveChannels(
        from sources: [MediaSourceConfig],
        kind: XtreamStreamKind
    ) async -> [AggregatedChannelGroup] {
        await fetchStreamGroups(from: sources, kind: kind)
    }
}
