import AppKit
import CoreGraphics

struct WindowItem: Identifiable, Hashable, Sendable {
    /// Synthetic IDs for browser tabs and running apps without enumerable windows.
    /// Real CGWindowIDs stay well below these reserved high ranges.
    static let safariTabIDBase: CGWindowID = 0xE000_0000
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
    var safariTab: SafariTab?
    var sourceWindowID: CGWindowID?

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

    var isSafariTabEntry: Bool { safariTab != nil }
    var physicalWindowID: CGWindowID { sourceWindowID ?? id }

    var isDusty: Bool {
        guard let lastSeen else { return false }
        return Date().timeIntervalSince(lastSeen) > 3 * 24 * 60 * 60
    }

    static func safariTabID(windowID: CGWindowID, tab: SafariTab) -> CGWindowID {
        var hash: UInt32 = 2_166_136_261
        for byte in "\(windowID)|\(tab.url)|\(tab.title)".utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return safariTabIDBase | (hash & 0x0FFF_FFFF)
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

    func searchRank(for query: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        if appName.range(of: query, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil { return 0 }
        if appName.localizedCaseInsensitiveContains(query) { return 1 }
        if title.range(of: query, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil { return 2 }
        if title.localizedCaseInsensitiveContains(query) { return 3 }
        if safariTab?.url.localizedCaseInsensitiveContains(query) == true { return 4 }

        let nestedRanks = safariTabs.compactMap { tab -> Int? in
            if tab.title.range(of: query, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil { return 2 }
            if tab.title.localizedCaseInsensitiveContains(query) { return 3 }
            if tab.url.localizedCaseInsensitiveContains(query) { return 4 }
            return nil
        }
        return nestedRanks.min()
    }

    static func orderedBySearchRelevance(_ windows: [WindowItem], query: String) -> [WindowItem] {
        windows.enumerated().sorted { lhs, rhs in
            let leftRank = lhs.element.searchRank(for: query) ?? .max
            let rightRank = rhs.element.searchRank(for: query) ?? .max
            if leftRank != rightRank { return leftRank < rightRank }
            return isMoreRecent(lhs, than: rhs)
        }.map(\.element)
    }

    static func orderedByRecency(_ windows: [WindowItem]) -> [WindowItem] {
        windows.enumerated().sorted(by: isMoreRecent).map(\.element)
    }

    private static func isMoreRecent(
        _ lhs: (offset: Int, element: WindowItem),
        than rhs: (offset: Int, element: WindowItem)
    ) -> Bool {
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

extension WindowItem {
    static func expandedSafariTabEntries(from windows: [WindowItem]) -> [WindowItem] {
        windows.flatMap { window -> [WindowItem] in
            guard window.bundleIdentifier == "com.apple.Safari",
                  !window.safariTabs.isEmpty else { return [window] }

            return window.safariTabs.map { tab in
                var entry = window
                entry.safariTab = tab
                entry.sourceWindowID = window.id
                entry.safariTabs = []
                entry = WindowItem(
                    id: tab.isCurrent ? window.id : safariTabID(windowID: window.id, tab: tab),
                    processID: entry.processID,
                    appName: entry.appName,
                    bundleIdentifier: entry.bundleIdentifier,
                    title: tab.title.isEmpty ? window.title : tab.title,
                    frame: entry.frame,
                    isOnScreen: tab.isCurrent && entry.isOnScreen,
                    lastSeen: entry.lastSeen,
                    thumbnail: tab.isCurrent ? entry.thumbnail : nil,
                    thumbnailIsUsable: tab.isCurrent && entry.thumbnailIsUsable,
                    thumbnailRevision: entry.thumbnailRevision,
                    appIcon: entry.appIcon,
                    safariTabs: [],
                    safariTab: tab,
                    sourceWindowID: window.id
                )
                return entry
            }
        }
    }
}
