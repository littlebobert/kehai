import Foundation
import Observation

enum BrowserTheme: String, CaseIterable, Identifiable {
    case system
    case classicMac

    var id: Self { self }

    var displayName: String {
        switch self {
        case .system:
            NSLocalizedString("System", comment: "Browser appearance theme")
        case .classicMac:
            NSLocalizedString("Retrofit", comment: "Browser appearance theme")
        }
    }
}

@MainActor
@Observable
final class AppearanceSettings {
    private static let browserThemeKey = "appearance.browserTheme"
    private static let glassyWindowKey = "appearance.glassyWindow"

    var browserTheme: BrowserTheme {
        didSet {
            UserDefaults.standard.set(browserTheme.rawValue, forKey: Self.browserThemeKey)
        }
    }

    var usesGlassyWindow: Bool {
        didSet {
            UserDefaults.standard.set(usesGlassyWindow, forKey: Self.glassyWindowKey)
        }
    }

    init() {
        let storedTheme = UserDefaults.standard.string(forKey: Self.browserThemeKey)
        browserTheme = storedTheme.flatMap(BrowserTheme.init(rawValue:)) ?? .system
        usesGlassyWindow = UserDefaults.standard.bool(forKey: Self.glassyWindowKey)
    }
}
