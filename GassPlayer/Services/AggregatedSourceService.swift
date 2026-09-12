import Foundation

struct AggregatedChannelGroup: Identifiable {
    let id: UUID
    let sourceName: String
    let streams: [XtreamStream]
    let credentials: XtreamCredentials
    /// Non nil se il recupero e' fallito parzialmente o del tutto per questa sorgente
    /// (credenziali errate, rete irraggiungibile, ecc). Prima veniva ingoiato
    /// silenziosamente e la sorgente scompariva senza spiegazione dai risultati.
    let error: String?
}

actor AggregatedSourceService {
    /// Nota: pensato per kind == .live / .movie. Le serie hanno un modello di dati
    /// diverso (XtreamSeriesItem, non XtreamStream) e vanno aggregate separatamente
    /// se in futuro serve "tutte le serie insieme".
    func fetchLiveChannels(from sources: [MediaSourceConfig], kind: XtreamStreamKind) async -> [AggregatedChannelGroup] {
        let xtreamSources = sources.filter { $0.type == .xtream && $0.isEnabled }

        var results: [AggregatedChannelGroup] = []
        await withTaskGroup(of: AggregatedChannelGroup?.self) { group in
            for source in xtreamSources {
                group.addTask {
                    guard let username = source.username, let password = source.password else {
                        return AggregatedChannelGroup(
                            id: source.id, sourceName: source.name, streams: [],
                            credentials: XtreamCredentials(host: source.host, username: "", password: ""),
                            error: "Username o password mancanti per questa sorgente."
                        )
                    }
                    let credentials = XtreamCredentials(host: source.host, username: username, password: password)
                    let api = XtreamAPIService(credentials: credentials)

                    let categories: [XtreamCategory]
                    do {
                        categories = try await api.fetchCategories(kind: kind)
                    } catch let error as XtreamError {
                        return AggregatedChannelGroup(id: source.id, sourceName: source.name, streams: [], credentials: credentials, error: error.errorDescription)
                    } catch {
                        return AggregatedChannelGroup(id: source.id, sourceName: source.name, streams: [], credentials: credentials, error: "Errore imprevisto: \(error.localizedDescription)")
                    }

                    var allStreams: [XtreamStream] = []
                    var partialErrors: [String] = []
                    for category in categories {
                        do {
                            allStreams += try await api.fetchStreams(kind: kind, categoryId: category.categoryId)
                        } catch let error as XtreamError {
                            partialErrors.append(error.errorDescription ?? "errore sconosciuto")
                        } catch {
                            partialErrors.append(error.localizedDescription)
                        }
                    }
                    let combinedError = partialErrors.isEmpty ? nil : "Alcune categorie non sono state caricate: \(Set(partialErrors).joined(separator: "; "))"
                    return AggregatedChannelGroup(id: source.id, sourceName: source.name, streams: allStreams, credentials: credentials, error: combinedError)
                }
            }
            for await result in group {
                if let result { results.append(result) }
            }
        }
        return results.sorted { $0.sourceName < $1.sourceName }
    }
}
