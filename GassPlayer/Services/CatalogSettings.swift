import Foundation
import Combine

@MainActor
final class CatalogSettings: ObservableObject {
    static let shared = CatalogSettings()

    enum RefreshInterval: String, CaseIterable, Identifiable {
        case manual
        case fifteenMinutes
        case thirtyMinutes
        case oneHour
        case threeHours
        case sixHours
        case twelveHours
        case daily

        var id: String { rawValue }

        var title: String {
            switch self {
            case .manual: return "Solo manuale"
            case .fifteenMinutes: return "Ogni 15 minuti"
            case .thirtyMinutes: return "Ogni 30 minuti"
            case .oneHour: return "Ogni ora"
            case .threeHours: return "Ogni 3 ore"
            case .sixHours: return "Ogni 6 ore"
            case .twelveHours: return "Ogni 12 ore"
            case .daily: return "Ogni giorno"
            }
        }

        var timeInterval: TimeInterval? {
            switch self {
            case .manual: return nil
            case .fifteenMinutes: return 15 * 60
            case .thirtyMinutes: return 30 * 60
            case .oneHour: return 60 * 60
            case .threeHours: return 3 * 60 * 60
            case .sixHours: return 6 * 60 * 60
            case .twelveHours: return 12 * 60 * 60
            case .daily: return 24 * 60 * 60
            }
        }
    }

    @Published var refreshInterval: RefreshInterval {
        didSet { defaults.set(refreshInterval.rawValue, forKey: Keys.refreshInterval) }
    }

    @Published var refreshOnLaunch: Bool {
        didSet { defaults.set(refreshOnLaunch, forKey: Keys.refreshOnLaunch) }
    }

    @Published var showEPGInChannelTiles: Bool {
        didSet { defaults.set(showEPGInChannelTiles, forKey: Keys.showEPGInChannelTiles) }
    }

    @Published var preloadSeries: Bool {
        didSet { defaults.set(preloadSeries, forKey: Keys.preloadSeries) }
    }

    @Published private(set) var lastRefreshDate: Date? {
        didSet {
            if let lastRefreshDate {
                defaults.set(lastRefreshDate, forKey: Keys.lastRefreshDate)
            } else {
                defaults.removeObject(forKey: Keys.lastRefreshDate)
            }
        }
    }

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refreshInterval = RefreshInterval(rawValue: defaults.string(forKey: Keys.refreshInterval) ?? "") ?? .manual
        refreshOnLaunch = defaults.object(forKey: Keys.refreshOnLaunch) as? Bool ?? false
        showEPGInChannelTiles = defaults.object(forKey: Keys.showEPGInChannelTiles) as? Bool ?? true
        preloadSeries = defaults.object(forKey: Keys.preloadSeries) as? Bool ?? true
        lastRefreshDate = defaults.object(forKey: Keys.lastRefreshDate) as? Date
    }

    func markRefreshed(at date: Date = Date()) {
        lastRefreshDate = date
    }

    func needsScheduledRefresh(now: Date = Date()) -> Bool {
        guard let interval = refreshInterval.timeInterval else { return false }
        guard let lastRefreshDate else { return true }
        return now.timeIntervalSince(lastRefreshDate) >= interval
    }

    private enum Keys {
        static let refreshInterval = "gassplayer.catalog.refreshInterval"
        static let refreshOnLaunch = "gassplayer.catalog.refreshOnLaunch"
        static let showEPGInChannelTiles = "gassplayer.catalog.showEPGInChannelTiles"
        static let preloadSeries = "gassplayer.catalog.preloadSeries"
        static let lastRefreshDate = "gassplayer.catalog.lastRefreshDate"
    }
}
