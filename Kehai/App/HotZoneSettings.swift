import Foundation
import Observation

enum HotZone: String, CaseIterable, Identifiable {
    case upperLeft
    case upperRight
    case lowerLeft
    case lowerRight
    case bottom
    case left
    case right

    var id: Self { self }

    var displayName: String {
        switch self {
        case .upperLeft:
            NSLocalizedString("Upper Left", comment: "Hot zone location")
        case .upperRight:
            NSLocalizedString("Upper Right", comment: "Hot zone location")
        case .lowerLeft:
            NSLocalizedString("Lower Left", comment: "Hot zone location")
        case .lowerRight:
            NSLocalizedString("Lower Right", comment: "Hot zone location")
        case .bottom:
            NSLocalizedString("Bottom", comment: "Hot zone location")
        case .left:
            NSLocalizedString("Left", comment: "Hot zone location")
        case .right:
            NSLocalizedString("Right", comment: "Hot zone location")
        }
    }

    func contains(pointer: CGPoint, in screenFrame: CGRect, tolerance: CGFloat) -> Bool {
        let isWithinHorizontalBounds = pointer.x >= screenFrame.minX - tolerance
            && pointer.x <= screenFrame.maxX + tolerance
        let isWithinVerticalBounds = pointer.y >= screenFrame.minY - tolerance
            && pointer.y <= screenFrame.maxY + tolerance

        switch self {
        case .upperLeft:
            return abs(pointer.x - screenFrame.minX) <= tolerance
                && abs(pointer.y - screenFrame.maxY) <= tolerance
        case .upperRight:
            return abs(pointer.x - screenFrame.maxX) <= tolerance
                && abs(pointer.y - screenFrame.maxY) <= tolerance
        case .lowerLeft:
            return abs(pointer.x - screenFrame.minX) <= tolerance
                && abs(pointer.y - screenFrame.minY) <= tolerance
        case .lowerRight:
            return abs(pointer.x - screenFrame.maxX) <= tolerance
                && abs(pointer.y - screenFrame.minY) <= tolerance
        case .bottom:
            return isWithinHorizontalBounds
                && abs(pointer.y - screenFrame.minY) <= tolerance
        case .left:
            return isWithinVerticalBounds
                && abs(pointer.x - screenFrame.minX) <= tolerance
        case .right:
            return isWithinVerticalBounds
                && abs(pointer.x - screenFrame.maxX) <= tolerance
        }
    }
}

@MainActor
@Observable
final class HotZoneSettings {
    private enum Keys {
        // Keep the original keys so existing Hot Corner preferences migrate automatically.
        static let isEnabled = "hotCorner.isEnabled"
        static let zone = "hotCorner.corner"
    }

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.isEnabled) }
    }

    var zone: HotZone {
        didSet { defaults.set(zone.rawValue, forKey: Keys.zone) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Keys.isEnabled)
        zone = defaults.string(forKey: Keys.zone)
            .flatMap(HotZone.init(rawValue:)) ?? .lowerLeft
    }
}
