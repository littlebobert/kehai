import AppKit
import CoreGraphics

struct WindowItem: Identifiable, Hashable, Sendable {
    /// Synthetic IDs for running apps that currently have no enumerable windows.
    /// Real CGWindowIDs stay well below this reserved high range.
    static let appPlaceholderIDBase: CGWindowID = 0xF000_0000

    let id: CGWindowID
    let processID: pid_t
    let appName: String
    let bundleIdentifier: String?
    let title: String
    let frame: CGRect
    let isOnScreen: Bool
    var lastSeen: Date?
    var thumbnail: NSImage?
    var thumbnailIsUsable = false
    var thumbnailRevision = 0
    var appIcon: NSImage?
    var safariTabs: [SafariTab] = []

    static func == (lhs: WindowItem, rhs: WindowItem) -> Bool {
        lhs.id == rhs.id && lhs.thumbnailRevision == rhs.thumbnailRevision
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(thumbnailRevision)
    }

    var renderID: String { "\(id)-\(thumbnailRevision)" }

    /// True when this item represents a running app with no open window in Kehai's inventory.
    var isAppPlaceholder: Bool {
        id >= Self.appPlaceholderIDBase
    }

    var isDusty: Bool {
        guard let lastSeen else { return false }
        return Date().timeIntervalSince(lastSeen) > 3 * 24 * 60 * 60
    }

    static func appPlaceholderID(processID: pid_t) -> CGWindowID {
        appPlaceholderIDBase | CGWindowID(UInt32(bitPattern: processID))
    }

    static func appPlaceholder(
        for application: NSRunningApplication,
        lastSeen: Date?
    ) -> WindowItem {
        let name = application.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let appName = (name?.isEmpty == false) ? name! : "App"
        return WindowItem(
            id: appPlaceholderID(processID: application.processIdentifier),
            processID: application.processIdentifier,
            appName: appName,
            bundleIdentifier: application.bundleIdentifier,
            title: appName,
            frame: .zero,
            isOnScreen: false,
            lastSeen: lastSeen ?? application.launchDate,
            appIcon: application.icon
        )
    }

    static func orderedByRecency(_ windows: [WindowItem]) -> [WindowItem] {
        windows.enumerated().sorted { lhs, rhs in
            switch (lhs.element.lastSeen, rhs.element.lastSeen) {
            case let (left?, right?):
                return left == right ? lhs.offset < rhs.offset : left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}

struct SafariTab: Identifiable, Codable, Hashable, Sendable {
    var id: String { "\(windowIndex):\(tabIndex):\(url)" }
    let windowIndex: Int
    let tabIndex: Int
    let title: String
    let url: String
    let isCurrent: Bool

    var domain: String { URL(string: url)?.host() ?? url }
}
