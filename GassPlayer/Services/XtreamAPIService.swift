import Foundation

/// Client diretto per l'API Xtream (`player_api.php`), senza cache.
/// La cache e le politiche di retry sono responsabilita' di
/// `CachedXtreamRepository`, che avvolge questo servizio.
///
/// OTTIMIZZAZIONE 2026-09-20 (velocità massima di caricamento/ricaricamento
/// playlist, import invariato — vedi `fetchAllStreams` per il dettaglio):
/// il vero collo di bottiglia della lentezza percepita nel caricamento del
/// catalogo era qui, non nei livelli di UI/cache superiori già ottimizzati
/// in precedenza.
actor XtreamAPIService {
    let credentials: XtreamCredentials

    private let session: URLSession
    private let requestTimeout: TimeInterval
    private static let categoryBatchSize = 6

    /// Sessione dedicata alle chiamate `player_api.php` (cataloghi anche da
    /// diversi MB): senza `URLCache` (la cache applicativa è già gestita da
    /// `CachedXtreamRepository` + snapshot su disco, quindi `URLSession.shared`
    /// copiava inutilmente ogni risposta enorme anche in `URLCache`), con
    /// timeout di risorsa adeguato ai cataloghi grandi su rete lenta e max
    /// 6 connessioni per host, il numero che i pannelli Xtream tollerano
    /// senza rifiutare richieste parallele (live + VOD + serie + categorie).
    static let catalogSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    init(
        credentials: XtreamCredentials,
        session: URLSession = XtreamAPIService.catalogSession,
        requestTimeout: TimeInterval = 30
    ) {
        self.credentials = credentials
        self.session = session
        self.requestTimeout = requestTimeout
    }

    // MARK: - Endpoint construction

    private func endpoint(
        action: String? = nil,
        extra: [String: String] = [:],
        path: String = "/player_api.php"
    ) throws -> URL {
        guard let host = normalizedHostURL() else {
            throw XtreamError.malformedHost(credentials.host)
        }

        guard var components = URLComponents(
            url: host.appendingPathComponent(
                String(path.dropFirst(path.hasPrefix("/") ? 1 : 0))
            ),
            resolvingAgainstBaseURL: false
        ) else {
            throw XtreamError.malformedHost(credentials.host)
        }

        var items = [
            URLQueryItem(name: "username", value: credentials.username),
            URLQueryItem(name: "password", value: credentials.password)
        ]

        if let action {
            items.append(URLQueryItem(name: "action", value: action))
        }

        for (key, value) in extra.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: key, value: value))
        }

        components.queryItems = items

        guard let url = components.url else {
            throw XtreamError.invalidURL
        }

        return url
    }

    private func normalizedHostURL() -> URL? {
        let raw = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines)

        guard var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            return nil
        }

        components.query = nil
        components.fragment = nil

        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }

        return components.url
    }

    private func request(
        action: String? = nil,
        extra: [String: String] = [:],
        path: String = "/player_api.php"
    ) throws -> URLRequest {
        let url = try endpoint(action: action, extra: extra, path: path)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "application/json, text/plain, */*",
            forHTTPHeaderField: "Accept"
        )

        return request
    }

    private func data(
        action: String? = nil,
        extra: [String: String] = [:],
        path: String = "/player_api.php"
    ) async throws -> Data {
        let urlRequest = try request(action: action, extra: extra, path: path)

        do {
            let (data, response) = try await session.data(for: urlRequest)
            try validate(response)
            return data
        } catch let error as XtreamError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw XtreamError.timeout
        } catch let error as URLError {
            throw XtreamError.unreachable(underlying: error)
        } catch {
            throw XtreamError.unreachable(underlying: error)
        }
    }

    /// Decodifica fuori dall'actor: i cataloghi (decine di migliaia di voci)
    /// richiedono centinaia di ms di CPU; eseguita sull'actor bloccava
    /// l'avvio/ripresa delle altre richieste Xtream concorrenti (live, VOD e
    /// serie condividono la stessa istanza) e serializzava le tre decodifiche.
    /// Su un task separato le decodifiche procedono in parallelo sui core.
    private func decodeOffActor<T: Decodable & Sendable>(_ type: [T].Type, from data: Data) async -> [T] {
        await Task.detached(priority: .userInitiated) {
            FlexibleArrayDecoder.decode(type, from: data)
        }.value
    }

    // MARK: - Authentication

    func authenticate() async throws -> XtreamAuthResponse {
        let payload = try await data()

        do {
            let decoded = try JSONDecoder().decode(XtreamAuthResponse.self, from: payload)

            guard decoded.userInfo.status.lowercased() == "active" else {
                throw XtreamError.wrongCredentials
            }

            return decoded
        } catch let error as XtreamError {
            throw error
        } catch {
            throw XtreamError.decoding(error)
        }
    }

    /// Recupera le informazioni account senza imporre che lo stato sia
    /// "active": usata dalla schermata "Gestisci sorgente" per mostrare lo
    /// stato reale, le connessioni e la scadenza anche quando l'account non
    /// è attivo — caso in cui `authenticate()` lancia `.wrongCredentials`
    /// perché pensato per i soli flussi di riproduzione, che devono
    /// bloccarsi subito su un account non valido.
    func fetchAccountInfo() async throws -> XtreamAuthResponse {
        let payload = try await data()

        do {
            return try JSONDecoder().decode(XtreamAuthResponse.self, from: payload)
        } catch {
            throw XtreamError.decoding(error)
        }
    }

    // MARK: - Categories

    func fetchCategories(kind: XtreamStreamKind) async throws -> [XtreamCategory] {
        let action: String

        switch kind {
        case .live:
            action = "get_live_categories"
        case .movie:
            action = "get_vod_categories"
        case .series:
            action = "get_series_categories"
        }

        return await decodeOffActor(
            [XtreamCategory].self,
            from: try await data(action: action)
        )
    }

    // MARK: - Streams (Live / VOD)

    func fetchStreams(
        kind: XtreamStreamKind,
        categoryId: String? = nil
    ) async throws -> [XtreamStream] {
        guard kind != .series else {
            throw XtreamError.invalidURL
        }

        let action = kind == .live ? "get_live_streams" : "get_vod_streams"
        let normalizedCategoryId = categoryId?.trimmingCharacters(in: .whitespacesAndNewlines)

        let extra = (normalizedCategoryId?.isEmpty == false)
            ? ["category_id": normalizedCategoryId!]
            : [:]

        return await decodeOffActor(
            [XtreamStream].self,
            from: try await data(action: action, extra: extra)
        )
    }

    /// Recupera l'intero catalogo evitando che categorie vuote, mancanti o
    /// anomale facciano sparire i VOD/canali. La risposta globale del
    /// provider e' la base autorevole; le risposte per categoria vengono
    /// interrogate SOLO per le categorie che risultano completamente
    /// assenti dalla risposta globale, come recupero mirato — non come
    /// ripetizione sistematica dell'intero catalogo categoria per
    /// categoria.
    ///
    /// OTTIMIZZAZIONE 2026-09-20: in precedenza questa funzione rifaceva
    /// SEMPRE una richiesta `get_*_streams` per OGNI categoria del
    /// provider, anche quando la risposta globale (senza `category_id`)
    /// conteneva già tutti i canali — che e' il caso comune per la
    /// stragrande maggioranza dei pannelli Xtream, dove l'endpoint globale
    /// e' già completo. Con playlist di decine/centinaia di categorie
    /// questo significava altrettante richieste HTTP aggiuntive ad ogni
    /// caricamento/ricaricamento: il principale responsabile della
    /// lentezza percepita, ben più di qualunque ottimizzazione di
    /// rendering lato UI. Ora il recupero per categoria scatta solo per le
    /// categorie realmente assenti dal risultato globale
    /// (`missingCategoryIDs`), tipicamente zero: il caso comune torna a
    /// costare 1-2 richieste totali invece di decine o centinaia, mentre
    /// la protezione contro i provider con l'endpoint globale incompleto
    /// resta intatta.
    ///
    /// Il parametro `categories`, se fornito, evita di richiedere di nuovo
    /// `get_*_categories`: `CachedXtreamRepository.allStreams` lo passa già
    /// valorizzato con il risultato (cacheato, TTL 600s) della propria
    /// chiamata `categories(kind:)`, eliminando così anche la richiesta di
    /// categorie duplicata che avveniva in precedenza (una volta dal
    /// repository per popolare i chip della UI, una seconda volta — MAI
    /// cacheata — dentro questa funzione).
    func fetchAllStreams(
        kind: XtreamStreamKind,
        categories providedCategories: [XtreamCategory]? = nil
    ) async throws -> [XtreamStream] {
        try await fetchAllStreamsReportingEmpty(
            kind: kind,
            categories: providedCategories,
            skippingCategoryIDs: []
        ).streams
    }

    /// Esito di `fetchAllStreamsReportingEmpty`: il catalogo e le categorie
    /// che il provider ha confermato VUOTE (assenti dalla risposta globale
    /// e senza contenuti anche interrogandole direttamente).
    struct CatalogFetchResult {
        let streams: [XtreamStream]
        let emptyCategoryIDs: Set<String>
    }

    /// Come `fetchAllStreams`, ma:
    /// - non rifà la richiesta per le categorie in `skippingCategoryIDs`
    ///   (già note come vuote da un recupero precedente): quasi tutti i
    ///   pannelli hanno decine di categorie vuote, che costavano altrettante
    ///   richieste inutili ad OGNI caricamento;
    /// - restituisce le categorie risultate vuote, così il chiamante può
    ///   ricordarle. Il salto è applicato solo se la risposta globale NON è
    ///   vuota (altrimenti il provider potrebbe aver avuto un problema
    ///   temporaneo e il recupero per categoria resta necessario).
    func fetchAllStreamsReportingEmpty(
        kind: XtreamStreamKind,
        categories providedCategories: [XtreamCategory]? = nil,
        skippingCategoryIDs: Set<String>
    ) async throws -> CatalogFetchResult {
        guard kind != .series else {
            throw XtreamError.invalidURL
        }

        let globalStreams: [XtreamStream]
        let categories: [XtreamCategory]

        if let providedCategories {
            globalStreams = try await fetchStreams(kind: kind)
            categories = providedCategories
        } else {
            // Nessuna lista categorie fornita dal chiamante: richiediamo
            // stream globali e categorie IN PARALLELO invece che in
            // sequenza, dimezzando la latenza di questa fase.
            async let globalTask = fetchStreams(kind: kind)
            async let categoriesTask: [XtreamCategory]? = try? await fetchCategories(kind: kind)

            globalStreams = try await globalTask

            guard let fetchedCategories = await categoriesTask else {
                return CatalogFetchResult(streams: stableDeduplicated(globalStreams), emptyCategoryIDs: [])
            }
            categories = fetchedCategories
        }

        let globalCategoryIDs = Set(
            globalStreams
                .compactMap { $0.categoryId?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )

        let allCategoryIDs = Set(
            categories
                .map(\.categoryId)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )

        let absentCategoryIDs = allCategoryIDs.subtracting(globalCategoryIDs)

        // Salta le categorie già note come vuote solo se la risposta
        // globale contiene davvero dei contenuti.
        let skipped = globalStreams.isEmpty
            ? Set<String>()
            : absentCategoryIDs.intersection(skippingCategoryIDs)

        let missingCategoryIDs = Array(absentCategoryIDs.subtracting(skipped))

        guard !missingCategoryIDs.isEmpty else {
            return CatalogFetchResult(streams: stableDeduplicated(globalStreams), emptyCategoryIDs: skipped)
        }

        DebugLogger.logAsync(
            .info,
            "Xtream: recupero mirato di \(missingCategoryIDs.count) categorie assenti dalla risposta globale (\(kind.rawValue)), \(skipped.count) note vuote saltate"
        )

        var collected: [XtreamStream] = []
        var confirmedEmpty = skipped

        for batchStart in stride(
            from: 0,
            to: missingCategoryIDs.count,
            by: Self.categoryBatchSize
        ) {
            let batchEnd = min(
                batchStart + Self.categoryBatchSize,
                missingCategoryIDs.count
            )
            let batch = Array(missingCategoryIDs[batchStart..<batchEnd])

            let batchResults: [(String, [XtreamStream]?)] = await withTaskGroup(
                of: (String, [XtreamStream]?).self,
                returning: [(String, [XtreamStream]?)].self
            ) { group in
                for categoryID in batch {
                    group.addTask {
                        (categoryID, try? await self.fetchStreams(
                            kind: kind,
                            categoryId: categoryID
                        ))
                    }
                }

                var results: [(String, [XtreamStream]?)] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }

            for (categoryID, streams) in batchResults {
                // `nil` = richiesta fallita: NON si considera vuota.
                guard let streams else { continue }

                if streams.isEmpty {
                    confirmedEmpty.insert(categoryID)
                } else {
                    collected.append(contentsOf: streams)
                }
            }
        }

        return CatalogFetchResult(
            streams: stableDeduplicated(globalStreams + collected),
            emptyCategoryIDs: confirmedEmpty
        )
    }

    // MARK: - VOD detail

    /// Dettaglio di un film VOD (`get_vod_info`): trama, cast, genere,
    /// backdrop e rating forniti dal provider, base immediata per la
    /// scheda dettaglio mostrata al tap sulla locandina, prima/in assenza
    /// dell'arricchimento TMDB.
    func fetchVODInfo(vodId: Int) async throws -> XtreamVODInfo {
        do {
            return try JSONDecoder().decode(
                XtreamVODInfo.self,
                from: try await data(
                    action: "get_vod_info",
                    extra: ["vod_id": String(vodId)]
                )
            )
        } catch let error as XtreamError {
            throw error
        } catch {
            throw XtreamError.decoding(error)
        }
    }

    // MARK: - Series

    func fetchSeriesList(categoryId: String? = nil) async throws -> [XtreamSeriesItem] {
        let normalizedCategoryId = categoryId?.trimmingCharacters(in: .whitespacesAndNewlines)

        let extra = (normalizedCategoryId?.isEmpty == false)
            ? ["category_id": normalizedCategoryId!]
            : [:]

        return await decodeOffActor(
            [XtreamSeriesItem].self,
            from: try await data(action: "get_series", extra: extra)
        )
    }

    func fetchSeriesInfo(seriesId: Int) async throws -> XtreamSeriesInfo {
        do {
            return try JSONDecoder().decode(
                XtreamSeriesInfo.self,
                from: try await data(
                    action: "get_series_info",
                    extra: ["series_id": String(seriesId)]
                )
            )
        } catch let error as XtreamError {
            throw error
        } catch {
            throw XtreamError.decoding(error)
        }
    }

    // MARK: - Streaming URL construction

    nonisolated private func buildStreamingURL(
        pathComponent: String,
        idAndExtension: String
    ) -> URL? {
        let host = credentials.host.trimmingCharacters(in: .whitespacesAndNewlines)

        guard var components = URLComponents(string: host),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            return nil
        }

        components.query = nil
        components.fragment = nil

        guard let baseURL = components.url else {
            return nil
        }

        return baseURL
            .appendingPathComponent(pathComponent)
            .appendingPathComponent(credentials.username)
            .appendingPathComponent(credentials.password)
            .appendingPathComponent(idAndExtension)
    }

    nonisolated func streamURL(
        for stream: XtreamStream,
        kind: XtreamStreamKind
    ) -> URL? {
        let ext = stream.containerExtension?.isEmpty == false
            ? stream.containerExtension!
            : kind.defaultExtension

        return buildStreamingURL(
            pathComponent: kind.pathComponent,
            idAndExtension: "\(stream.streamId).\(ext)"
        )
    }

    nonisolated func streamURL(
        for streamId: Int,
        kind: XtreamStreamKind,
        ext: String? = nil
    ) -> URL? {
        buildStreamingURL(
            pathComponent: kind.pathComponent,
            idAndExtension: "\(streamId).\(ext ?? kind.defaultExtension)"
        )
    }

    nonisolated func episodeStreamURL(
        episodeId: Int,
        ext: String
    ) -> URL? {
        buildStreamingURL(
            pathComponent: "series",
            idAndExtension: "\(episodeId).\(ext)"
        )
    }

    // MARK: - Helpers

    private func stableDeduplicated(_ streams: [XtreamStream]) -> [XtreamStream] {
        var seen = Set<Int>()
        return streams.filter { seen.insert($0.streamId).inserted }
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            return
        }

        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw XtreamError.wrongCredentials
        default:
            throw XtreamError.httpStatus(http.statusCode)
        }
    }
}
