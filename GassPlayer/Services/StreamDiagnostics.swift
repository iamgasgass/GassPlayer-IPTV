import Foundation

// MARK: - User-Agent

/// User-Agent usati per parlare con i provider IPTV.
///
/// Molti pannelli Xtream/Nginx filtrano gli user-agent sconosciuti (403,
/// 406, o addirittura una pagina HTML/JSON di errore con HTTP 200) mentre
/// accettano quelli dei player "classici". Il default storico dell'app
/// (`GassPlayer/1.0`) era proprio uno di quelli che alcuni backend
/// respingono: il primo tentativo ora usa un UA VLC, il piu' tollerato.
enum StreamUserAgents {
    /// Chiave di `UserDefaults` del campo "User Agent" (Impostazioni →
    /// Generale).
    static let customDefaultsKey = "gassplayer.network.userAgent"

    static let defaultVLC = "VLC/3.0.20 LibVLC/3.0.20"

    /// User Agent scelto dall'utente, `nil` se il campo e' vuoto. Letto UNA
    /// sola volta per avvio (`static let` e' valutata alla prima lettura):
    /// e' esattamente il "dovrai riavviare l'app per rendere effettive le
    /// modifiche" mostrato sotto il campo, e garantisce che tutte le
    /// richieste di una sessione usino lo stesso valore.
    static let custom: String? = {
        let raw = UserDefaults.standard.string(forKey: customDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }()

    /// Primo user-agent tentato per riprodurre: quello dell'utente, se
    /// impostato, altrimenti VLC.
    static let vlc: String = custom ?? defaultVLC

    /// Applica l'UA personalizzato (solo se impostato) a una richiesta
    /// verso il provider: chiamate API Xtream, playlist M3U, XMLTV. Senza
    /// impostazione non cambia nulla rispetto a prima.
    static func applyCustom(to request: inout URLRequest) {
        if let custom {
            request.setValue(custom, forHTTPHeaderField: "User-Agent")
        }
    }

    /// Ordine di tentativo quando il provider rifiuta l'accesso.
    static let ladder: [String] = [
        vlc,
        "Lavf/60.16.100",
        "IPTVSmartersPro",
        "okhttp/4.12.0",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    ]
}

/// Ricorda, per host, l'UA e l'estensione che hanno funzionato, cosi' i
/// tentativi successivi partono subito dalla combinazione giusta.
enum PlaybackProfileStore {
    private static let uaKey = "gassplayer.playback.userAgentByHost"
    private static let extKey = "gassplayer.playback.extensionByHostKind"

    static func userAgent(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let map = UserDefaults.standard.dictionary(forKey: uaKey) as? [String: String]
        return map?[host]
    }

    static func remember(userAgent: String, for url: URL) {
        guard let host = url.host?.lowercased() else { return }
        var map = (UserDefaults.standard.dictionary(forKey: uaKey) as? [String: String]) ?? [:]
        if userAgent == StreamUserAgents.vlc {
            map.removeValue(forKey: host)   // e' gia' il default
        } else {
            map[host] = userAgent
        }
        UserDefaults.standard.set(map, forKey: uaKey)
    }

    // MARK: Estensione appresa (per host + tipo movie/series/live)

    private static func extensionKey(for url: URL) -> String? {
        guard let host = url.host?.lowercased(), let kind = StreamURLCandidates.kind(of: url) else { return nil }
        return "\(host)|\(kind)"
    }

    /// Estensione che il provider ha effettivamente servito quando quella
    /// del catalogo falliva. Viene provata per prima la volta dopo.
    static func learnedExtension(for url: URL) -> String? {
        guard let key = extensionKey(for: url) else { return nil }
        let map = UserDefaults.standard.dictionary(forKey: extKey) as? [String: String]
        return map?[key]
    }

    static func rememberExtension(_ ext: String, for url: URL) {
        guard let key = extensionKey(for: url), !ext.isEmpty else { return }
        var map = (UserDefaults.standard.dictionary(forKey: extKey) as? [String: String]) ?? [:]
        map[key] = ext.lowercased()
        UserDefaults.standard.set(map, forKey: extKey)
    }

    /// Dimentica l'estensione appresa: serve quando il provider ha ricominciato
    /// a servire il formato del catalogo e quello appreso e' ormai obsoleto
    /// (altrimenti ogni apertura sprecherebbe una sonda sul formato vecchio).
    static func forgetExtension(for url: URL) {
        guard let key = extensionKey(for: url) else { return }
        var map = (UserDefaults.standard.dictionary(forKey: extKey) as? [String: String]) ?? [:]
        guard map.removeValue(forKey: key) != nil else { return }
        UserDefaults.standard.set(map, forKey: extKey)
    }
}

/// Cache in memoria delle risoluzioni riuscite: riaprire lo stesso film
/// (ripresa, cambio app, "Riprova") parte subito, senza nuova verifica.
/// Chiave = URL richiesto completo (quindi legata anche alle credenziali).
enum ResolutionCache {
    private static let lock = NSLock()
    /// Sempre letta/scritta sotto `lock`: `nonisolated(unsafe)` dichiara
    /// al compilatore (anche in modalita' Swift 6) che l'accesso e'
    /// sincronizzato a mano.
    nonisolated(unsafe) private static var entries: [String: (resolution: StreamResolution, date: Date)] = [:]
    private static let ttl: TimeInterval = 600

    static func fresh(for url: URL) -> StreamResolution? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[url.absoluteString] else { return nil }
        if Date().timeIntervalSince(entry.date) > ttl {
            entries.removeValue(forKey: url.absoluteString)
            return nil
        }
        return entry.resolution
    }

    static func store(_ resolution: StreamResolution, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        if entries.count > 200 { entries.removeAll() }
        entries[url.absoluteString] = (resolution, Date())
    }

    static func invalidate(for url: URL) {
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: url.absoluteString)
    }
}

// MARK: - Candidati (estensioni alternative)

/// Genera gli URL alternativi per lo stesso contenuto Xtream cambiando solo
/// l'estensione del contenitore (`/movie/user/pass/123.mkv` ->
/// `/movie/user/pass/123.mp4`, ecc.).
///
/// Perche': `container_extension` nel catalogo e' spesso sbagliato o
/// obsoleto (il file e' stato ricaricato in un altro formato, o il
/// provider lo serve solo transcodificato in mp4/m3u8). Il risultato e' un
/// 404/5xx su quel formato e nessun errore di codec.
enum StreamURLCandidates {
    /// Ordinati per probabilita' di successo su un pannello Xtream.
    static let vodExtensions = ["mp4", "mkv", "avi", "m3u8", "ts", "mov", "m4v", "webm", "flv", "wmv", "mpg"]
    static let liveExtensions = ["m3u8", "ts"]
    static let maxAlternatives = 6

    /// `movie` / `series` / `live` se l'URL ha forma Xtream, altrimenti `nil`.
    static func kind(of url: URL) -> String? {
        let comps = url.pathComponents
        guard comps.count >= 5 else { return nil }
        let kind = comps[comps.count - 4].lowercased()
        return ["movie", "series", "live"].contains(kind) ? kind : nil
    }

    /// URL richiesto + alternative, con in testa l'estensione che questo
    /// provider ha gia' dimostrato di servire (se diversa da quella del
    /// catalogo). Il primo elemento e' quello da provare per primo.
    static func ordered(for url: URL) -> [URL] {
        var list = [url] + alternatives(for: url)
        guard let learned = PlaybackProfileStore.learnedExtension(for: url),
              learned != url.pathExtension.lowercased() else { return list }

        let base = url.deletingPathExtension().lastPathComponent
        let learnedURL = url.deletingLastPathComponent().appendingPathComponent("\(base).\(learned)")
        list.removeAll { $0 == learnedURL }
        list.insert(learnedURL, at: 0)
        return list
    }

    /// Restituisce gli URL alternativi (mai quello originale). Vuoto se
    /// l'URL non ha la forma Xtream `/{movie|series|live}/user/pass/{id}.{ext}`.
    static func alternatives(for url: URL) -> [URL] {
        let comps = url.pathComponents
        guard comps.count >= 5 else { return [] }

        let kind = comps[comps.count - 4].lowercased()
        guard ["movie", "series", "live"].contains(kind) else { return [] }

        let last = comps[comps.count - 1]
        let ext = (last as NSString).pathExtension.lowercased()
        let base = (last as NSString).deletingPathExtension
        guard !base.isEmpty, Int(base) != nil else { return [] }

        let order = kind == "live" ? liveExtensions : vodExtensions
        let folder = url.deletingLastPathComponent()

        return order
            .filter { $0 != ext }
            .prefix(maxAlternatives)
            .map { folder.appendingPathComponent("\(base).\($0)") }
    }
}

// MARK: - Risultati

struct StreamProbeResult: Equatable {
    let requestedURL: URL
    let finalURL: URL?
    let userAgent: String
    /// `nil` = errore di rete prima di ricevere una risposta HTTP.
    let statusCode: Int?
    let contentType: String?
    let networkErrorCode: Int?
    /// HTTP 200 ma il corpo e' una pagina HTML/JSON di errore, non video.
    let looksLikeErrorPage: Bool

    var isPlayable: Bool {
        guard let statusCode else { return false }
        return (statusCode == 200 || statusCode == 206) && !looksLikeErrorPage
    }

    var extensionLabel: String {
        let ext = requestedURL.pathExtension.uppercased()
        return ext.isEmpty ? "?" : ext
    }
}

struct StreamResolution: Equatable {
    let requestedURL: URL
    /// URL da dare al motore di riproduzione (dopo eventuali redirect).
    let playURL: URL
    let userAgent: String
}

enum StreamDiagnosis {
    case playable(StreamResolution)
    /// Il provider ha rifiutato/fallito in modo verificato su ogni tentativo.
    case unplayable(message: String)
    /// La sonda non ha potuto stabilire nulla (TLS, metodo non supportato,
    /// ...): il motore video puo' comunque riuscire, quindi si prova lo
    /// stesso l'URL originale prima di dare errore.
    case inconclusive(message: String)
}

// MARK: - Diagnostica

enum StreamDiagnostics {

    /// Codici con cui i pannelli IPTV segnalano il limite di connessioni
    /// simultanee (429 standard, 458/509/884 non standard ma diffusi).
    static let connectionLimitCodes: Set<Int> = [429, 458, 509, 884]

    private enum RaceEvent {
        case probe(StreamProbeResult)
        case tick
    }

    /// Trova un URL/UA che il provider serve davvero, il piu' in fretta
    /// possibile.
    ///
    /// - Prova gli URL in *parallelo scaglionato* (max 2 connessioni, la
    ///   seconda parte dopo 0,7 s o subito se la prima fallisce): vince il
    ///   primo che risponde con un flusso valido. Un formato sbagliato
    ///   costa ~1 round-trip invece di una lunga catena di tentativi.
    /// - Se il provider rifiuta lo user-agent prova la ladder di UA.
    /// - Errori transitori / limite connessioni: al massimo 2 ripetizioni
    ///   (dopo 1,5 s e 3 s), poi diagnosi.
    /// - `useCache`: riusa una risoluzione recente dello stesso URL.
    static func diagnose(
        url: URL,
        preferredUserAgent: String,
        useCache: Bool = false,
        deadline overall: TimeInterval = 40
    ) async -> StreamDiagnosis {
        if useCache, let cached = ResolutionCache.fresh(for: url) {
            return .playable(cached)
        }

        let deadline = Date().addingTimeInterval(overall)
        var userAgent = preferredUserAgent
        var log: [StreamProbeResult] = []
        var primary: StreamProbeResult?

        func note(_ results: [StreamProbeResult]) {
            log += results
            if primary == nil { primary = results.first { $0.requestedURL == url } }
        }
        func canContinue() -> Bool { !Task.isCancelled && Date() < deadline }

        let candidates = StreamURLCandidates.ordered(for: url)

        // A. URL richiesto + formati alternativi in parallelo scaglionato.
        let firstPairs: [(url: URL, ua: String)] = candidates.map { (url: $0, ua: userAgent) }
        var outcome = await race(firstPairs, deadline: deadline)
        note(outcome.results)
        if let winner = outcome.winner {
            return .playable(finish(winner, userAgent: userAgent, requested: url))
        }

        // B. Accesso negato / pagina di errore: altri user-agent sull'URL richiesto.
        if canContinue(), shouldTryOtherUserAgents(primary) {
            let others: [(url: URL, ua: String)] = StreamUserAgents.ladder
                .filter { $0 != userAgent }
                .map { (url: url, ua: $0) }
            outcome = await race(others, stagger: 0.5, deadline: deadline)
            note(outcome.results)
            if let winner = outcome.winner {
                userAgent = winner.userAgent
                return .playable(finish(winner, userAgent: userAgent, requested: url))
            }
        }

        // C. Errore transitorio o slot connessione ancora occupato: attendi e riprova.
        if isTransient(primary) || isConnectionLimit(primary) {
            for attempt in 1...2 where canContinue() {
                try? await Task.sleep(nanoseconds: UInt64(Double(attempt) * 1_500_000_000))
                guard canContinue() else { break }
                let retryPairs: [(url: URL, ua: String)] = candidates.map { (url: $0, ua: userAgent) }
                outcome = await race(retryPairs, deadline: deadline)
                note(outcome.results)
                if let winner = outcome.winner {
                    return .playable(finish(winner, userAgent: userAgent, requested: url))
                }
            }
        }

        let message = describe(base: primary, log: log)
        return isInconclusive(primary) ? .inconclusive(message: message) : .unplayable(message: message)
    }

    /// Sonda le coppie (URL, UA) con concorrenza limitata e ritorna alla prima valida.
    private static func race(
        _ pairs: [(url: URL, ua: String)],
        stagger: TimeInterval = 0.7,
        maxConcurrent: Int = 2,
        probeTimeout: TimeInterval = 8,
        deadline: Date
    ) async -> (winner: StreamProbeResult?, results: [StreamProbeResult]) {
        guard !pairs.isEmpty else { return (nil, []) }

        var results: [StreamProbeResult] = []
        var winner: StreamProbeResult?

        await withTaskGroup(of: RaceEvent.self) { group in
            var next = 0
            var inFlight = 0

            func launch() {
                let pair = pairs[next]
                next += 1
                inFlight += 1
                // Mai oltre la scadenza globale: prima una sonda appesa
                // poteva sforarla fino a `probeTimeout` secondi.
                let timeout = max(1, min(probeTimeout, deadline.timeIntervalSinceNow))
                group.addTask {
                    .probe(await StreamDiagnostics.probe(pair.url, userAgent: pair.ua, timeout: timeout))
                }
            }
            func scheduleTick() {
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(stagger * 1_000_000_000))
                    return .tick
                }
            }

            launch()
            if pairs.count > 1 { scheduleTick() }

            for await event in group {
                if Task.isCancelled || Date() >= deadline {
                    group.cancelAll()
                    return
                }
                switch event {
                case .tick:
                    if next < pairs.count {
                        if inFlight < maxConcurrent { launch() }
                        scheduleTick()
                    }
                case .probe(let result):
                    inFlight -= 1
                    results.append(result)
                    if result.isPlayable {
                        winner = result
                        group.cancelAll()
                        return
                    }
                    // Fallimento: rimpiazza subito la sonda persa.
                    while next < pairs.count && inFlight < maxConcurrent { launch() }
                    if inFlight == 0 && next >= pairs.count {
                        group.cancelAll()
                        return
                    }
                }
            }
        }
        return (winner, results)
    }

    /// Registra l'esito: memorizza UA/estensione che funzionano e mette in
    /// cache la risoluzione. Si riproduce l'URL *originale* del candidato,
    /// non quello dopo i redirect: i token CDN dei redirect possono essere
    /// monouso e il player ne ottiene uno nuovo da solo.
    private static func finish(_ winner: StreamProbeResult, userAgent: String, requested: URL) -> StreamResolution {
        let resolution = StreamResolution(
            requestedURL: requested,
            playURL: winner.requestedURL,
            userAgent: userAgent
        )
        ResolutionCache.store(resolution, for: requested)
        let ext = winner.requestedURL.pathExtension.lowercased()
        if ext != requested.pathExtension.lowercased() {
            PlaybackProfileStore.rememberExtension(ext, for: requested)
        } else if let learned = PlaybackProfileStore.learnedExtension(for: requested), learned != ext {
            // Ha vinto il formato del catalogo: quello appreso e' obsoleto.
            PlaybackProfileStore.forgetExtension(for: requested)
        }
        return resolution
    }

    // MARK: Probe

    /// Richiesta GET con `Range: bytes=0-1023`: legge al massimo 512 byte,
    /// poi chiude la connessione (non scarica il film). Cosi' si vede lo
    /// stesso status che vedrebbe il player, dopo i redirect.
    static func probe(_ url: URL, userAgent: String, timeout: TimeInterval = 8) async -> StreamProbeResult {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 6
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        // Chiude comunque la connessione: non deve restare uno slot
        // "connessione attiva" occupato sul provider dopo la prova.
        defer { session.invalidateAndCancel() }

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                return StreamProbeResult(
                    requestedURL: url, finalURL: response.url, userAgent: userAgent,
                    statusCode: nil, contentType: nil, networkErrorCode: nil,
                    looksLikeErrorPage: false
                )
            }

            var head = Data()
            if http.statusCode == 200 || http.statusCode == 206 {
                do {
                    for try await byte in bytes {
                        head.append(byte)
                        if head.count >= 512 { break }
                    }
                } catch {
                    // Lettura interrotta: conta solo cio' che e' arrivato.
                }
            }

            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
            return StreamProbeResult(
                requestedURL: url,
                finalURL: http.url ?? url,
                userAgent: userAgent,
                statusCode: http.statusCode,
                contentType: contentType,
                networkErrorCode: nil,
                looksLikeErrorPage: looksLikeErrorPage(head: head, contentType: contentType)
            )
        } catch {
            return StreamProbeResult(
                requestedURL: url, finalURL: nil, userAgent: userAgent,
                statusCode: nil, contentType: nil,
                networkErrorCode: (error as NSError).code,
                looksLikeErrorPage: false
            )
        }
    }

    /// Riconosce le risposte "200 OK" che in realta' sono pagine di errore
    /// del pannello (HTML o JSON) e non un flusso video/playlist.
    static func looksLikeErrorPage(head: Data, contentType: String?) -> Bool {
        let text = String(decoding: head.prefix(96), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // Una playlist HLS e' valida anche se servita come text/plain.
        if text.hasPrefix("#extm3u") { return false }

        if let contentType {
            if contentType.contains("text/html") || contentType.contains("application/json") {
                return true
            }
        }
        if text.hasPrefix("<!doctype html") || text.hasPrefix("<html") || text.hasPrefix("<head") {
            return true
        }
        if (text.hasPrefix("{") || text.hasPrefix("[")) && text.contains("\"") && head.count < 512 {
            return true
        }
        return false
    }

    // MARK: Classificazione

    /// Errori che spesso passano da soli (backend sotto carico, rete lenta).
    private static func isTransient(_ r: StreamProbeResult?) -> Bool {
        guard let r else { return false }
        if let code = r.statusCode {
            return code == 408 || (500...599).contains(code)
        }
        // NSURLErrorTimedOut (-1001), NetworkConnectionLost (-1005)
        return r.networkErrorCode == -1001 || r.networkErrorCode == -1005
    }

    private static func isConnectionLimit(_ r: StreamProbeResult?) -> Bool {
        guard let code = r?.statusCode else { return false }
        return connectionLimitCodes.contains(code)
    }

    private static func shouldTryOtherUserAgents(_ r: StreamProbeResult?) -> Bool {
        guard let r else { return false }
        if r.looksLikeErrorPage { return true }
        guard let code = r.statusCode else { return false }
        return [401, 403, 406, 451].contains(code)
    }

    /// Casi in cui la sonda non e' affidabile ma FFmpeg potrebbe riuscire:
    /// metodo/Range non gestiti dal server, errori TLS, ATS.
    private static func isInconclusive(_ r: StreamProbeResult?) -> Bool {
        guard let r else { return false }
        if let code = r.statusCode { return [400, 405, 416, 501].contains(code) }
        guard let net = r.networkErrorCode else { return true }
        return net == -1022 || net == -999 || (-1206 ... -1200).contains(net)
    }

    // MARK: Messaggi

    private static func describe(base: StreamProbeResult?, log: [StreamProbeResult]) -> String {
        guard let base = base ?? log.first else { return "Il provider non ha risposto in tempo." }

        // Riepilogo per formato (solo se e' stato provato piu' di un formato).
        var perFormat: [String] = []
        var seen = Set<String>()
        for r in log {
            let label = r.extensionLabel
            guard seen.insert(label).inserted else { continue }
            let outcome: String
            if let code = r.statusCode {
                outcome = "HTTP \(code)"
            } else if r.looksLikeErrorPage {
                outcome = "pagina errore"
            } else {
                outcome = "no risposta"
            }
            perFormat.append("\(label): \(outcome)")
        }
        let formats = perFormat.count > 1 ? "\n\nFormati provati → " + perFormat.joined(separator: ", ") : ""

        if base.looksLikeErrorPage {
            return "Il provider risponde con una pagina di errore invece del video (abbonamento scaduto, credenziali non valide o limite di connessioni)." + formats
        }

        guard let code = base.statusCode else {
            let networkCode = base.networkErrorCode ?? 0
            switch networkCode {
            case -1009:
                return "Nessuna connessione a Internet."
            case -1001:
                return "Il server del provider non risponde (timeout). Potrebbe essere offline o sovraccarico."
            case -1003, -1004:
                return "Server del provider non raggiungibile (host inesistente o spento)."
            case -1200, -1201, -1202, -1203, -1204, -1205, -1206:
                return "Errore di connessione sicura (HTTPS/certificato) verso il provider."
            default:
                return "Impossibile contattare il provider (errore di rete \(networkCode))."
            }
        }

        switch code {
        case 401, 403:
            return "Il provider ha rifiutato l'accesso (HTTP \(code)). Controlla che l'abbonamento non sia scaduto e che le credenziali siano corrette; alcuni provider bloccano anche certi IP/VPN." + formats
        case 404, 410:
            return "Il provider non ha questo contenuto (HTTP \(code)) in nessun formato provato: il file e' stato rimosso o non e' piu' caricato sul server. Prova «Altre fonti»." + formats
        case 429, 458, 509, 884:
            return "Limite di connessioni simultanee raggiunto (HTTP \(code)). Chiudi altri dispositivi/player collegati allo stesso account e riprova tra qualche secondo."
        case 500...599:
            return "Il backend del provider sta fallendo nel servire questo contenuto (HTTP \(code)). Non e' un problema di formato o dell'app: riprova piu' tardi o usa «Altre fonti»." + formats
        default:
            return "Risposta inattesa dal provider (HTTP \(code))." + formats
        }
    }
}
