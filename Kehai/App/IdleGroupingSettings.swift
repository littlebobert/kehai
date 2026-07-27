import Foundation
import Observation

@MainActor
@Observable
final class IdleGroupingSettings {
    private enum Keys {
        static let isEnabled = "idleGrouping.isEnabled"
        static let delayMinutes = "idleGrouping.delayMinutes"
    }

    static let availableDelays = [5, 10, 15, 30]

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.isEnabled) }
    }
    var delayMinutes: Int {
        didSet { UserDefaults.standard.set(delayMinutes, forKey: Keys.delayMinutes) }
    }

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Keys.isEnabled)
        let savedDelay = defaults.integer(forKey: Keys.delayMinutes)
        delayMinutes = Self.availableDelays.contains(savedDelay) ? savedDelay : 5
    }
}
