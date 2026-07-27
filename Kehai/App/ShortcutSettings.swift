import Carbon
import Observation

@MainActor
@Observable
final class ShortcutSettings {
    private enum Keys {
        static let keyCode = "overviewShortcut.keyCode"
        static let modifiers = "overviewShortcut.modifiers"
    }

    var keyCode: UInt32 {
        didSet { UserDefaults.standard.set(Int(keyCode), forKey: Keys.keyCode) }
    }
    var modifiers: UInt32 {
        didSet { UserDefaults.standard.set(Int(modifiers), forKey: Keys.modifiers) }
    }
    var registrationError: String?

    init() {
        let defaults = UserDefaults.standard
        keyCode = defaults.object(forKey: Keys.keyCode) == nil
            ? UInt32(kVK_Space)
            : UInt32(defaults.integer(forKey: Keys.keyCode))
        modifiers = defaults.object(forKey: Keys.modifiers) == nil
            ? UInt32(cmdKey | shiftKey)
            : UInt32(defaults.integer(forKey: Keys.modifiers))
    }

    func update(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    func reset() {
        update(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey))
    }
}
