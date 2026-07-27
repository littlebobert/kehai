import AppKit
import CoreGraphics

struct WindowItem: Identifiable, Hashable, Sendable {
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

    var isDusty: Bool {
        guard let lastSeen else { return false }
        return Date().timeIntervalSince(lastSeen) > 3 * 24 * 60 * 60
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
