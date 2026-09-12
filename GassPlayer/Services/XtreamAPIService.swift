import Foundation

/// Aggiornato dopo ricerca su cause comuni di fallimento login/caricamento
/// Xtream Codes (fonte: documentazione player_api.php e guide di
/// troubleshooting 2026): timeout troppo corti, scelta errata tra http/https,
/// "max connections reached" restituito come JSON valido ma con auth=0,
/// risposte vuote o non-JSON dai pannelli sovraccarichi.
actor XtreamAPIService {
    let credentials: XtreamCredentials
    private let session: URLSession

    init(credentials: XtreamCredentials, session: URLSession? = nil) {
        self.credentials = credentials
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            // Molti pannelli IPTV sono lenti sotto carico: 30s è il valore
            // raccomandato dalle guide di troubleshooting (vedi Dispatcharr
            // Xtream Codes API docs) invece del default di sistema (60s per
            // resource, ma la connessione iniziale può restare "pending"
            // troppo a lungo con il default).
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    private func endpoint(action: String? = nil, extra: [String: String] = [:], path: String = "/player_api.php", overrideHost: String? = nil) throws -> URL {
        let host = overrideHost ?? credentials.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = URL(string: host)?.scheme, scheme == "http" || scheme == "https" else {
            throw XtreamError.malformedHost(host)
        }
        guard var components = URLComponents(string: host + path) else {
            throw XtreamError.malformedHost(host)
        }
        var items = [
            URLQueryItem(name: "username", value: credentials.username),
            URLQueryItem(name: "password", value: credentials.password)
        ]
        if let action { items.append(URLQueryItem(name: "action", value: action)) }
        for (k, v) in extra { items.append(URLQueryItem(name: k, value: v)) }
        components.queryItems = items
        guard let url = components.url else { throw XtreamError.invalidURL }
        return url
    }

    /// Prova prima lo schema dichiarato dall'utente; se il server non
    /// risponde per motivi di rete (non per credenziali sbagliate), prova
    /// automaticamente lo schema alternativo (http<->https). Molte guide
    /// utente sui pannelli IPTV segnalano questo come causa frequente di
    /// falso "server non raggiungibile".
    func authenticate() async throws -> XtreamAuthResponse {
        do {
            return try await authenticateOnce(overrideHost: nil)
        } catch XtreamError.unreachable, XtreamError.timeout {
            if let alternativeHost = swappedScheme(of: credentials.host) {
                DebugLogger.logAsync(.info, "Retry con schema alternativo: \(alternativeHost)")
                return try await authenticateOnce(overrideHost: alternativeHost)
            }
            throw XtreamError.unreachable(underlying: XtreamError.timeout)
        }
    }

    private func swappedScheme(of host: String) -> String? {
        if host.hasPrefix("http://") { return "https://" + host.dropFirst("http://".count) }
        if host.hasPrefix("https://") { return "http://" + host.dropFirst("https://".count) }
        return nil
    }

    private func authenticateOnce(overrideHost: String?) async throws -> XtreamAuthResponse {
        let url = try endpoint(overrideHost: overrideHost)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await RetryPolicy.withRetry(maxAttempts: 2, initialDelay: 1.0, shouldRetry: { error in
                if let urlError = error as? URLError { return urlError.code != .cancelled }
                return true
            }) {
                try await self.session.data(from: url)
            }
        } catch let urlError as URLError {
            if urlError.code == .timedOut { throw XtreamError.timeout }
            throw XtreamError.unreachable(underlying: urlError)
        } catch {
            throw XtreamError.unreachable(underlying: error)
        }

        guard !data.isEmpty else {
            throw XtreamError.decoding(NSError(domain: "GassPlayer", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Il server ha risposto senza contenuto: probabilmente sovraccarico o in manutenzione."]))
        }

        try validate(response)

        do {
            let decoded = try JSONDecoder().decode(XtreamAuthResponse.self, from: data)
            let status = decoded.userInfo.status.lowercased()
            if status == "expired" {
                throw XtreamError.wrongCredentials
            }
            if status != "active" {
                // Molti pannelli restituiscono "Disabled"/"Banned" o simili:
                // trattiamo tutto ciò che non è "Active" come credenziali/account
                // non validi, ma logghiamo lo stato esatto per diagnosi.
                DebugLogger.logAsync(.warning, "Stato account non attivo: \(decoded.userInfo.status)")
                throw XtreamError.wrongCredentials
            }
            if overrideHost != nil {
                DebugLogger.logAsync(.info, "Autenticazione riuscita con schema alternativo")
            }
            return decoded
        } catch let xtreamError as XtreamError {
            throw xtreamError
        } catch {
            throw XtreamError.decoding(error)
        }
    }

    func fetchCategories(kind: XtreamStreamKind) async throws -> [XtreamCategory] {
        let action = "get_\(kind == .live ? "live" : kind == .movie ? "vod" : "series")_categories"
        return try await RetryPolicy.withRetry(maxAttempts: 3) {
            let url = try self.endpoint(action: action)
            let (data, response) = try await self.session.data(from: url)
            try self.validate(response)
            guard !data.isEmpty else { return [] }
            return try JSONDecoder().decode([XtreamCategory].self, from: data)
        }
    }

    func fetchStreams(kind: XtreamStreamKind, categoryId: String? = nil) async throws -> [XtreamStream] {
        let action = "get_\(kind == .live ? "live" : kind == .movie ? "vod" : "series")_streams"
        var extra: [String: String] = [:]
        if let categoryId { extra["category_id"] = categoryId }
        return try await RetryPolicy.withRetry(maxAttempts: 3) {
            let url = try self.endpoint(action: action, extra: extra)
            let (data, response) = try await self.session.data(from: url)
            try self.validate(response)
            guard !data.isEmpty else { return [] }
            return try JSONDecoder().decode([XtreamStream].self, from: data)
        }
    }

    nonisolated func streamURL(for streamId: Int, kind: XtreamStreamKind, ext: String = "m3u8") -> URL? {
        URL(string: "\(credentials.host)/\(kind.pathComponent)/\(credentials.username)/\(credentials.password)/\(streamId).\(ext)")
    }

    /// Fallback automatico: se lo stream .m3u8 (HLS) non è raggiungibile,
    /// molti pannelli servono comunque il flusso in .ts diretto — utile per
    /// provider più vecchi che non generano manifest HLS.
    func resolvedStreamURL(for streamId: Int, kind: XtreamStreamKind) async -> URL? {
        guard let hlsURL = streamURL(for: streamId, kind: kind, ext: "m3u8") else { return nil }
        var headRequest = URLRequest(url: hlsURL)
        headRequest.httpMethod = "HEAD"
        headRequest.timeoutInterval = 6
        if let (_, response) = try? await session.data(for: headRequest),
           let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
            return hlsURL
        }
        DebugLogger.logAsync(.warning, "HLS non raggiungibile per stream \(streamId), fallback a .ts")
        return streamURL(for: streamId, kind: kind, ext: "ts")
    }

    func fetchProviderVPNConfig() async throws -> ProviderVPNConfig {
        let candidateActions = ["get_vpn_config", "get_vpn", "vpn_info"]
        for action in candidateActions {
            if let url = try? endpoint(action: action),
               let (data, response) = try? await session.data(from: url),
               let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let config = try? JSONDecoder().decode(ProviderVPNConfig.self, from: data) {
                return config
            }
        }
        let candidatePaths = ["/vpn/config.json", "/panel_api.php"]
        for path in candidatePaths {
            if let url = try? endpoint(action: "get_vpn_config", path: path),
               let (data, response) = try? await session.data(from: url),
               let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let config = try? JSONDecoder().decode(ProviderVPNConfig.self, from: data) {
                return config
            }
        }
        throw XtreamError.noProviderVPN
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 { throw XtreamError.wrongCredentials }
        if http.statusCode == 429 {
            throw XtreamError.httpStatus(429) // spesso "troppe connessioni simultanee"
        }
        guard (200..<300).contains(http.statusCode) else { throw XtreamError.httpStatus(http.statusCode) }
    }
}
