import SwiftUI
import Combine

enum AppTheme: String, CaseIterable, Identifiable {
    case system = "Automatico"
    case light = "Chiaro"
    case dark = "Scuro"
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
final class ThemeManager: ObservableObject {
    @Published var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "gassplayer.theme") }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "gassplayer.theme")
        theme = AppTheme(rawValue: saved ?? "") ?? .system
    }
}
