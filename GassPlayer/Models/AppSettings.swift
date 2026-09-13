import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var epgURL: String { didSet { save() } }
    @Published var epgEnabled: Bool { didSet { save() } }
    @Published var epgRefreshMinutes: Int { didSet { save() } }
    @Published var showEPGOnLiveCards: Bool { didSet { save() } }
    @Published var preferredContentLayout: ContentLayout { didSet { save() } }
    @Published var showUncategorizedGroup: Bool { didSet { save() } }
    @Published var deduplicateM3U: Bool { didSet { save() } }

    enum ContentLayout: String, CaseIterable, Identifiable {
        case grid = "Griglia", list = "Lista"
        var id: String { rawValue }
    }

    private enum Keys {
        static let epgURL = "settings.epgURL"
        static let epgEnabled = "settings.epgEnabled"
        static let epgRefresh = "settings.epgRefreshMinutes"
        static let showEPG = "settings.showEPGOnLiveCards"
        static let layout = "settings.contentLayout"
        static let uncategorized = "settings.showUncategorized"
        static let deduplicate = "settings.deduplicateM3U"
    }

    private init() {
        let d = UserDefaults.standard
        epgURL = d.string(forKey: Keys.epgURL) ?? ""
        epgEnabled = d.object(forKey: Keys.epgEnabled) as? Bool ?? true
        epgRefreshMinutes = d.object(forKey: Keys.epgRefresh) as? Int ?? 30
        showEPGOnLiveCards = d.object(forKey: Keys.showEPG) as? Bool ?? true
        preferredContentLayout = ContentLayout(rawValue: d.string(forKey: Keys.layout) ?? "") ?? .grid
        showUncategorizedGroup = d.object(forKey: Keys.uncategorized) as? Bool ?? true
        deduplicateM3U = d.object(forKey: Keys.deduplicate) as? Bool ?? true
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(epgURL, forKey: Keys.epgURL)
        d.set(epgEnabled, forKey: Keys.epgEnabled)
        d.set(epgRefreshMinutes, forKey: Keys.epgRefresh)
        d.set(showEPGOnLiveCards, forKey: Keys.showEPG)
        d.set(preferredContentLayout.rawValue, forKey: Keys.layout)
        d.set(showUncategorizedGroup, forKey: Keys.uncategorized)
        d.set(deduplicateM3U, forKey: Keys.deduplicate)
    }
}
