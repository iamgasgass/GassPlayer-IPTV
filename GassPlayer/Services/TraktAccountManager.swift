import Foundation
import Combine

/// Stato di connessione a Trakt.tv, realmente funzionante: usa il flusso
/// "device code" già implementato in `TraktService` (fin qui mai collegato
/// a una UI) per autenticare l'utente e persiste il token ottenuto.
///
/// Trakt richiede che ogni app registri un proprio Client ID/Secret
/// (https://trakt.tv/oauth/applications): non essendoci credenziali di
/// GassPlayer incluse nel repository, l'utente inserisce le proprie nella
/// schermata "Trakt.tv" prima di avviare la connessione, esattamente come
/// avviene già per le sorgenti Xtream/Plex/Jellyfin/Emby (credenziali
/// dell'utente, non dell'app).
@MainActor
final class TraktAccountManager: ObservableObject {
    static let shared = TraktAccountManager()

    @Published var clientId: String {
        didSet { defaults.set(clientId, forKey: Keys.clientId) }
    }

    @Published var clientSecret: String {
        didSet { defaults.set(clientSecret, forKey: Keys.clientSecret) }
    }

    @Published private(set) var accessToken: String? {
        didSet {
            if let accessToken {
                defaults.set(accessToken, forKey: Keys.accessToken)
            } else {
                defaults.removeObject(forKey: Keys.accessToken)
            }
        }
    }

    @Published private(set) var connectedAt: Date? {
        didSet {
            if let connectedAt {
                defaults.set(connectedAt, forKey: Keys.connectedAt)
            } else {
                defaults.removeObject(forKey: Keys.connectedAt)
            }
        }
    }

    @Published private(set) var isConnecting = false
    @Published private(set) var deviceCode: TraktDeviceCode?
    @Published var connectionError: String?

    private var refreshToken: String? {
        didSet {
            if let refreshToken {
                defaults.set(refreshToken, forKey: Keys.refreshToken)
            } else {
                defaults.removeObject(forKey: Keys.refreshToken)
            }
        }
    }

    private var pollTask: Task<Void, Never>?
    private let defaults: UserDefaults

    var isConnected: Bool { accessToken != nil }

    var hasCredentials: Bool {
        !clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        clientId = defaults.string(forKey: Keys.clientId) ?? ""
        clientSecret = defaults.string(forKey: Keys.clientSecret) ?? ""
        accessToken = defaults.string(forKey: Keys.accessToken)
        refreshToken = defaults.string(forKey: Keys.refreshToken)
        connectedAt = defaults.object(forKey: Keys.connectedAt) as? Date
    }

    /// Avvia il flusso "device code": richiede un codice a Trakt, lo espone
    /// in `deviceCode` (perché la vista mostri l'URL e il codice all'utente)
    /// e avvia in background il polling che completerà la connessione non
    /// appena l'utente avrà autorizzato l'app sul sito.
    func startDeviceFlow() {
        guard hasCredentials else {
            connectionError = "Inserisci Client ID e Client Secret di Trakt.tv per continuare."
            return
        }
        guard !isConnecting else { return }

        connectionError = nil
        isConnecting = true

        let service = TraktService(clientId: clientId, clientSecret: clientSecret)

        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.runDeviceFlow(using: service)
        }
    }

    private func runDeviceFlow(using service: TraktService) async {
        do {
            let code = try await service.requestDeviceCode()
            deviceCode = code
            await poll(service: service, code: code)
        } catch {
            connectionError = "Impossibile avviare la connessione: \(error.localizedDescription)"
            isConnecting = false
        }
    }

    private func poll(service: TraktService, code: TraktDeviceCode) async {
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        let interval = max(code.interval, 1)

        while Date() < deadline, !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }

            do {
                let token = try await service.pollForToken(deviceCode: code.deviceCode)
                accessToken = token.accessToken
                refreshToken = token.refreshToken
                connectedAt = Date()
                deviceCode = nil
                isConnecting = false
                return
            } catch {
                // "authorization_pending" e simili: il device-code flow di
                // Trakt torna un 400 finché l'utente non ha ancora
                // autorizzato l'app sul sito, quindi si continua a fare
                // polling fino alla scadenza del codice.
                continue
            }
        }

        guard !Task.isCancelled else { return }

        connectionError = "Codice scaduto prima dell'autorizzazione. Riprova la connessione."
        isConnecting = false
        deviceCode = nil
    }

    /// Interrompe un flusso di connessione in corso senza disconnettere un
    /// account già collegato in precedenza.
    func cancelConnecting() {
        pollTask?.cancel()
        pollTask = nil
        isConnecting = false
        deviceCode = nil
    }

    func disconnect() {
        cancelConnecting()
        accessToken = nil
        refreshToken = nil
        connectedAt = nil
    }

    private enum Keys {
        static let clientId = "gassplayer.trakt.clientId"
        static let clientSecret = "gassplayer.trakt.clientSecret"
        static let accessToken = "gassplayer.trakt.accessToken"
        static let refreshToken = "gassplayer.trakt.refreshToken"
        static let connectedAt = "gassplayer.trakt.connectedAt"
    }
}
