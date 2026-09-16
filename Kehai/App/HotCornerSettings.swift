import Foundation
import Observation

enum HotCorner: String, CaseIterable, Identifiable {
    case upperLeft
    case upperRight
    case lowerLeft
    case lowerRight

    var id: Self { self }

    var displayName: String {
        switch self {
        case .upperLeft:
            NSLocalizedString("Upper Left", comment: "Hot corner location")
        case .upperRight:
            NSLocalizedString("Upper Right", comment: "Hot corner location")
        case .lowerLeft:
            NSLocalizedString("Lower Left", comment: "Hot corner location")
        case .lowerRight:
            NSLocalizedString("Lower Right", comment: "Hot corner location")
        }
    }

    func contains(pointer: CGPoint, in screenFrame: CGRect, tolerance: CGFloat) -> Bool {
        let horizontalDistance: CGFloat
        let verticalDistance: CGFloat

        switch self {
        case .upperLeft, .lowerLeft:
            horizontalDistance = abs(pointer.x - screenFrame.minX)
        case .upperRight, .lowerRight:
            horizontalDistance = abs(pointer.x - screenFrame.maxX)
        }

        switch self {
        case .upperLeft, .upperRight:
            verticalDistance = abs(pointer.y - screenFrame.maxY)
        case .lowerLeft, .lowerRight:
            verticalDistance = abs(pointer.y - screenFrame.minY)
        }

        return horizontalDistance <= tolerance && verticalDistance <= tolerance
    }
}

@MainActor
@Observable
final class HotCornerSettings {
    private enum Keys {
        static let isEnabled = "hotCorner.isEnabled"
        static let corner = "hotCorner.corner"
    }

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.isEnabled) }
    }

    var corner: HotCorner {
        didSet { defaults.set(corner.rawValue, forKey: Keys.corner) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Keys.isEnabled)
        corner = defaults.string(forKey: Keys.corner)
            .flatMap(HotCorner.init(rawValue:)) ?? .lowerLeft
    }
}
