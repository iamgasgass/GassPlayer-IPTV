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
    static let vlc = "VLC/3.0.20 LibVLC/3.0.20"

    /// Ordine di tentativo quando il provider rifiuta l'accesso.
    static let ladder: [String] = [
        vlc,
        "Lavf/60.16.100",
        "IPTVSmartersPro",
        "okhttp/4.12.0",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    ]
}

/// Ricorda, per host, l'UA che ha funzionato l'ultima volta, cosi' i
/// tentativi successivi partono subito da quello giusto.
enum PlaybackProfileStore {
    private static let key = "gassplayer.playback.userAgentByHost"

    static func userAgent(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let map = UserDefaults.standard.dictionary(forKey: key) as? [String: String]
        return map?[host]
    }

    static func remember(userAgent: String, for url: URL) {
        guard let host = url.host?.lowercased() else { return }
        var map = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        if userAgent == StreamUserAgents.vlc {
            map.removeValue(forKey: host)   // e' gia' il default
        } else {
            map[host] = userAgent
        }
        UserDefaults.standard.set(map, forKey: key)
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
    case unplayable(message: String)
}

// MARK: - Diagnostica

enum StreamDiagnostics {

    /// Codici con cui i pannelli IPTV segnalano il limite di connessioni
    /// simultanee (429 standard, 458/509/884 non standard ma diffusi).
    static let connectionLimitCodes: Set<Int> = [429, 458, 509, 884]

    /// Verifica davvero cosa risponde il provider e, se possibile, trova
    /// una combinazione (URL/UA) che il provider serve correttamente.
    ///
    /// Strategia (ferma al primo esito valido):
    /// 1. URL richiesto, con 2 ripetizioni a distanza crescente per errori
    ///    transitori (5xx, 429, timeout) tipici di backend sotto carico.
    /// 2. Altri user-agent, se l'accesso e' negato o la risposta e' una
    ///    pagina di errore.
    /// 3. Estensioni alternative, se il formato richiesto non esiste o il
    ///    backend fallisce solo su quello.
    static func diagnose(
        url: URL,
        preferredUserAgent: String,
        deadline: TimeInterval = 45
    ) async -> StreamDiagnosis {
        let start = Date()
        func hasTime() -> Bool { Date().timeIntervalSince(start) < deadline && !Task.isCancelled }

        var log: [StreamProbeResult] = []
        var bestUA = preferredUserAgent

        // 1. URL richiesto (+ retry per errori transitori)
        var base = await probe(url, userAgent: bestUA)
        log.append(base)

        var retries = 0
        while !base.isPlayable, isTransient(base), retries < 2, hasTime() {
            retries += 1
            try? await Task.sleep(nanoseconds: UInt64(retries) * 1_200_000_000)
            guard hasTime() else { break }
            base = await probe(url, userAgent: bestUA)
            log.append(base)
        }

        if base.isPlayable {
            return .playable(resolution(for: base, userAgent: bestUA))
        }

        // 2. Ladder di user-agent
        if shouldTryOtherUserAgents(base) {
            for ua in StreamUserAgents.ladder where ua != bestUA {
                guard hasTime() else { break }
                let result = await probe(url, userAgent: ua)
                log.append(result)
                if result.isPlayable {
                    bestUA = ua
                    return .playable(resolution(for: result, userAgent: ua))
                }
            }
        }

        // 3. Estensioni alternative
        if shouldTryAlternateExtensions(base) {
            for alternative in StreamURLCandidates.alternatives(for: url) {
                guard hasTime() else { break }
                let result = await probe(alternative, userAgent: bestUA)
                log.append(result)
                if result.isPlayable {
                    return .playable(resolution(for: result, userAgent: bestUA))
                }
            }
        }

        return .unplayable(message: describe(log))
    }

    // MARK: Probe

    /// Richiesta GET con `Range: bytes=0-1023`: legge al massimo 512 byte,
    /// poi chiude la connessione (non scarica il film). Cosi' si vede lo
    /// stesso status che vedrebbe il player, dopo i redirect.
    static func probe(_ url: URL, userAgent: String) async -> StreamProbeResult {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
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

    private static func resolution(for result: StreamProbeResult, userAgent: String) -> StreamResolution {
        StreamResolution(
            requestedURL: result.requestedURL,
            playURL: result.finalURL ?? result.requestedURL,
            userAgent: userAgent
        )
    }

    /// Errori che spesso passano da soli (backend sotto carico, rete lenta).
    private static func isTransient(_ r: StreamProbeResult) -> Bool {
        if let code = r.statusCode {
            return code == 429 || code == 408 || (500...599).contains(code)
        }
        // NSURLErrorTimedOut (-1001), NetworkConnectionLost (-1005)
        return r.networkErrorCode == -1001 || r.networkErrorCode == -1005
    }

    private static func shouldTryOtherUserAgents(_ r: StreamProbeResult) -> Bool {
        if r.looksLikeErrorPage { return true }
        guard let code = r.statusCode else { return false }
        if connectionLimitCodes.contains(code) { return false }
        return [401, 403, 406, 451].contains(code) || (500...599).contains(code)
    }

    private static func shouldTryAlternateExtensions(_ r: StreamProbeResult) -> Bool {
        if r.looksLikeErrorPage { return true }
        guard let code = r.statusCode else { return false }
        if connectionLimitCodes.contains(code) { return false }
        return !(code == 200 || code == 206)
    }

    // MARK: Messaggi

    private static func describe(_ log: [StreamProbeResult]) -> String {
        guard let base = log.first else { return "Il provider non ha risposto." }

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
