import Foundation

/// Istantanea di tutte le preferenze dell'app (non le sorgenti, già coperte
/// da `SourceBackupCodec`): riproduzione, griglia, sottotitoli, rete, tema,
/// catalogo e guida TV. Permette di spostare la configurazione dell'app da
/// un dispositivo all'altro senza toccare credenziali o playlist.
struct AppPreferencesBackup: Codable {
    var version: Int = 1
    var exportedAt: Date = Date()

    var autoplayNextEpisode: Bool
    var resumePlayback: Bool
    var preferredPlaybackSpeed: Double

    var channelGridDensity: String
    var showChannelNumbers: Bool
    var subtitleLanguage: String
    var preferredDNS: String
    var downloadWifiOnly: Bool

    var theme: String

    var catalogRefreshInterval: String
    var catalogRefreshOnLaunch: Bool
    var showEPGInChannelTiles: Bool
    var preloadSeries: Bool

    var epgAutoUpdateEnabled: Bool
}

enum AppPreferencesBackupCodec {
    enum CodecError: LocalizedError {
        case invalidText

        var errorDescription: String? {
            switch self {
            case .invalidText:
                return "Il testo del backup non è in un formato UTF-8 valido."
            }
        }
    }

    private enum DefaultsKey {
        static let autoplayNextEpisode = "gassplayer.playback.autoplayNextEpisode"
        static let resumePlayback = "gassplayer.playback.resumePlayback"
        static let preferredPlaybackSpeed = "gassplayer.playback.speed"
        static let channelGridDensity = "gassplayer.grid.density"
        static let showChannelNumbers = "gassplayer.grid.showChannelNumbers"
        static let subtitleLanguage = "gassplayer.subtitles.language"
        static let preferredDNS = "gassplayer.network.preferredDNS"
    }

    /// Costruisce il backup leggendo lo stato corrente da `UserDefaults`
    /// (per i campi `@AppStorage` di `SettingsView`) e dai servizi già
    /// esistenti nell'app, senza introdurre una seconda fonte di verità.
    @MainActor
    static func currentSnapshot(
        themeManager: ThemeManager,
        catalogSettings: CatalogSettings,
        epgManager: EPGManager,
        downloadManager: DownloadManager,
        defaults: UserDefaults = .standard
    ) -> AppPreferencesBackup {
        AppPreferencesBackup(
            autoplayNextEpisode: defaults.object(forKey: DefaultsKey.autoplayNextEpisode) as? Bool ?? true,
            resumePlayback: defaults.object(forKey: DefaultsKey.resumePlayback) as? Bool ?? true,
            preferredPlaybackSpeed: defaults.object(forKey: DefaultsKey.preferredPlaybackSpeed) as? Double ?? 1.0,
            channelGridDensity: defaults.string(forKey: DefaultsKey.channelGridDensity) ?? "comfortable",
            showChannelNumbers: defaults.object(forKey: DefaultsKey.showChannelNumbers) as? Bool ?? false,
            subtitleLanguage: defaults.string(forKey: DefaultsKey.subtitleLanguage) ?? "it",
            preferredDNS: defaults.string(forKey: DefaultsKey.preferredDNS) ?? "1.1.1.1",
            downloadWifiOnly: downloadManager.wifiOnly,
            theme: themeManager.theme.rawValue,
            catalogRefreshInterval: catalogSettings.refreshInterval.rawValue,
            catalogRefreshOnLaunch: catalogSettings.refreshOnLaunch,
            showEPGInChannelTiles: catalogSettings.showEPGInChannelTiles,
            preloadSeries: catalogSettings.preloadSeries,
            epgAutoUpdateEnabled: epgManager.autoUpdateEnabled
        )
    }

    static func encodeAsString(_ backup: AppPreferencesBackup) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(backup)

        guard let string = String(data: data, encoding: .utf8) else {
            throw CodecError.invalidText
        }
        return string
    }

    static func decode(fromString string: String) throws -> AppPreferencesBackup {
        guard let data = string.data(using: .utf8) else {
            throw CodecError.invalidText
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppPreferencesBackup.self, from: data)
    }

    /// Applica un backup importato a tutti i servizi coinvolti. I campi
    /// `@AppStorage` vengono scritti direttamente su `UserDefaults`: la
    /// property wrapper osserva le modifiche esterne e aggiorna la UI da
    /// sola, senza bisogno di un canale di comunicazione dedicato.
    @MainActor
    static func apply(
        _ backup: AppPreferencesBackup,
        themeManager: ThemeManager,
        catalogSettings: CatalogSettings,
        epgManager: EPGManager,
        downloadManager: DownloadManager,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(backup.autoplayNextEpisode, forKey: DefaultsKey.autoplayNextEpisode)
        defaults.set(backup.resumePlayback, forKey: DefaultsKey.resumePlayback)
        defaults.set(backup.preferredPlaybackSpeed, forKey: DefaultsKey.preferredPlaybackSpeed)
        defaults.set(backup.channelGridDensity, forKey: DefaultsKey.channelGridDensity)
        defaults.set(backup.showChannelNumbers, forKey: DefaultsKey.showChannelNumbers)
        defaults.set(backup.subtitleLanguage, forKey: DefaultsKey.subtitleLanguage)
        defaults.set(backup.preferredDNS, forKey: DefaultsKey.preferredDNS)

        downloadManager.wifiOnly = backup.downloadWifiOnly
        themeManager.theme = AppTheme(rawValue: backup.theme) ?? themeManager.theme
        catalogSettings.refreshInterval = CatalogSettings.RefreshInterval(rawValue: backup.catalogRefreshInterval)
            ?? catalogSettings.refreshInterval
        catalogSettings.refreshOnLaunch = backup.catalogRefreshOnLaunch
        catalogSettings.showEPGInChannelTiles = backup.showEPGInChannelTiles
        catalogSettings.preloadSeries = backup.preloadSeries
        epgManager.autoUpdateEnabled = backup.epgAutoUpdateEnabled
    }
}
