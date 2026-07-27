import Foundation
import Observation

@MainActor
@Observable
final class AppearanceSettings {
    private static let glassyWindowKey = "appearance.glassyWindow"

    var usesGlassyWindow: Bool {
        didSet {
            UserDefaults.standard.set(usesGlassyWindow, forKey: Self.glassyWindowKey)
        }
    }

    init() {
        usesGlassyWindow = UserDefaults.standard.bool(forKey: Self.glassyWindowKey)
    }
}
