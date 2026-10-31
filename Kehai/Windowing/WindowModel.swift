import AppKit
import CoreGraphics

struct WindowItem: Identifiable, Hashable, Sendable {
    /// Synthetic IDs for launchable (not running) apps, browser tabs, and running apps
    /// without enumerable windows. Real CGWindowIDs stay well below these reserved high ranges.
    static let launchableAppIDBase: CGWindowID = 0xD000_0000
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
    /// Bundle location for a launchable app; nil for anything that is already running.
    var applicationURL: URL?
    /// Other names the app is known by (`CFBundleAlternateNames`), matched like the app name.
    var alternateAppNames: [String] = []

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

    /// True when this item represents an installed app with no process to activate or
    /// window to raise. Opening it goes through the app's bundle.
    var isLaunchableApp: Bool {
        id >= Self.launchableAppIDBase && id < Self.safariTabIDBase
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

    static func launchableAppID(bundleIdentifier: String) -> CGWindowID {
        var hash: UInt32 = 2_166_136_261
        for byte in bundleIdentifier.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return launchableAppIDBase | (hash & 0x0FFF_FFFF)
    }

    /// A strip entry for an installed app that is not running. `processID` is -1 because
    /// there is no process yet; callers must check `isLaunchableApp` before using it.
    static func launchableApp(for application: InstalledAppInfo, lastSeen: Date?) -> WindowItem {
        WindowItem(
            id: launchableAppID(bundleIdentifier: application.bundleIdentifier),
            processID: -1,
            appName: application.localizedName,
            bundleIdentifier: application.bundleIdentifier,
            title: application.localizedName,
            frame: .zero,
            isOnScreen: false,
            lastSeen: lastSeen,
            appIcon: application.icon,
            applicationURL: application.url,
            alternateAppNames: application.alternateNames
        )
    }

    static func appPlaceholder(
        for application: RunningAppInfo,
        lastSeen: Date?
    ) -> WindowItem {
        let name = application.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let appName = (name?.isEmpty == false) ? name! : "App"
        return WindowItem(
            id: appPlaceholderID(processID: application.processID),
            processID: application.processID,
            appName: appName,
            bundleIdentifier: application.bundleIdentifier,
            title: appName,
            frame: .zero,
            isOnScreen: false,
            lastSeen: lastSeen ?? application.launchDate,
            appIcon: application.icon
        )
    }

    /// The strip entry for a running app with no window in the inventory. A record with
    /// no live process can't be activated by PID, so it opens through its bundle like a
    /// launchable app. Nil when it has no bundle to open either.
    static func windowlessApp(for application: RunningAppInfo, lastSeen: Date?) -> WindowItem? {
        if application.hasProcess {
            return appPlaceholder(for: application, lastSeen: lastSeen)
        }
        guard let bundleIdentifier = application.bundleIdentifier,
              let bundleURL = application.bundleURL else { return nil }
        let name = application.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let installed = InstalledAppInfo(
            bundleIdentifier: bundleIdentifier,
            localizedName: (name?.isEmpty == false) ? name! : "App",
            url: bundleURL,
            icon: application.icon
        )
        return launchableApp(for: installed, lastSeen: lastSeen ?? application.launchDate)
    }

    /// Launchable apps rank after running apps whose name matches, but before apps that
    /// only match through a window title: typing "slack" should offer Slack ahead of a
    /// ChatGPT window that mentions a Slack thread.
    static let launchableAppRankOffset = 2

    func searchRank(for query: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        guard !isLaunchableApp else {
            if appName.range(of: query, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil {
                return Self.launchableAppRankOffset
            }
            if appName.localizedCaseInsensitiveContains(query) || matchesAlternateAppName(query) {
                return Self.launchableAppRankOffset + 1
            }
            return nil
        }
        if appName.range(of: query, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil { return 0 }
        if appName.localizedCaseInsensitiveContains(query) || matchesAlternateAppName(query) { return 1 }
        if title.range(of: query, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil { return 4 }
        if title.localizedCaseInsensitiveContains(query) { return 5 }
        if safariTab?.url.localizedCaseInsensitiveContains(query) == true { return 6 }

        let nestedRanks = safariTabs.compactMap { tab -> Int? in
            if tab.title.range(of: query, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil { return 4 }
            if tab.title.localizedCaseInsensitiveContains(query) { return 5 }
            if tab.url.localizedCaseInsensitiveContains(query) { return 6 }
            return nil
        }
        return nestedRanks.min()
    }

    /// An alternate name is still the app's name, so it outranks title matches, but it
    /// ranks below the shown name so "Codex" lists the real Codex app before ChatGPT.
    func matchesAlternateAppName(_ query: String) -> Bool {
        alternateAppNames.contains { $0.localizedCaseInsensitiveContains(query) }
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
    /// The switcher's app list after a change: keeps the order the user is looking at,
    /// drops apps that are gone, and appends new ones. An entry standing in for an app
    /// with no window gives way to what the app is now, so "Open Safari" can't outlive
    /// the moment Safari's window or process shows up.
    static func mergedSwitcherApps(snapshot: [WindowItem], live: [WindowItem]) -> [WindowItem] {
        func key(_ item: WindowItem) -> String { item.bundleIdentifier ?? "pid:\(item.processID)" }
        let liveByKey = Dictionary(live.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        var knownKeys = Set<String>()
        var merged = snapshot.compactMap { item -> WindowItem? in
            guard let liveItem = liveByKey[key(item)] else { return nil }
            knownKeys.insert(key(item))
            return item.isAppPlaceholder || item.isLaunchableApp ? liveItem : item
        }
        merged.append(contentsOf: live.filter { knownKeys.insert(key($0)).inserted })
        return merged
    }

    /// One window per app, preserving input order. Safari expands into every tab,
    /// so prefer the visible tab as the app-strip representative instead of tab 1.
    static func uniquedAppRepresentatives(from windows: [WindowItem]) -> [WindowItem] {
        windows.reduce(into: [WindowItem]()) { result, window in
            let appKey = window.bundleIdentifier ?? "pid:\(window.processID)"
            if let index = result.firstIndex(where: {
                ($0.bundleIdentifier ?? "pid:\($0.processID)") == appKey
            }) {
                if window.safariTab?.isCurrent == true, result[index].safariTab?.isCurrent != true {
                    result[index] = window
                }
                return
            }
            result.append(window)
        }
    }

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
