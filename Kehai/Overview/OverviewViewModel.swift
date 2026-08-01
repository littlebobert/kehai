import AppKit
import OSLog
import ScreenCaptureKit

enum WindowActionChooserStage {
    case removal
    case exclusion
}

enum BrowserViewMode: String, CaseIterable, Identifiable {
    case grouped
    case recent

    var id: Self { self }
    var title: String { L10n.string(self == .grouped ? "Grouped" : "Recent") }
}

struct BrowserWindowSection: Identifiable {
    let id: String
    let title: String?
    let windows: [WindowItem]
}

@MainActor
@Observable
final class OverviewViewModel {
    private let logger = Logger(subsystem: "com.justin.Kehai", category: "ThumbnailPipeline")

    var windows: [WindowItem] = []
    var taskGroups: [TaskGroup] = []
    var selectedTaskGroupID: String?
    var viewMode: BrowserViewMode {
        didSet {
            UserDefaults.standard.set(viewMode.rawValue, forKey: Self.viewModeKey)
            selectedTaskGroupID = nil
            preserveSelectionOrSelectFirst()
        }
    }
    var selectedWindowID: CGWindowID? {
        didSet {
            if selectedWindowID != nil, selectedAppWindowID != nil {
                selectedAppWindowID = nil
            }
            guard selectedWindowID != oldValue, liveThumbnailEnabled else { return }
            scheduleSelectedLiveThumbnail()
        }
    }
    var selectedAppWindowID: CGWindowID? {
        didSet {
            if selectedAppWindowID != nil, selectedWindowID != nil {
                selectedWindowID = nil
            }
        }
    }
    private(set) var focusedAppKey: String?
    private(set) var isAllWindowsAppSelected = false
    private var appWindowIDBeforeEnteringWindows: CGWindowID?

    private struct WindowSelectionSnapshot {
        let id: CGWindowID
        let processID: pid_t
        let bundleIdentifier: String?
        let title: String
    }
    var liveThumbnailWindowID: CGWindowID?
    var liveThumbnail: NSImage?
    var appBadgeRevision = 0
    private var appBadges = DockBadgeMonitor.Snapshot()
    var isSwitcherMode = false
    private var switcherAppWindows: [WindowItem]?
    private var hoveredSwitcherWindowID: CGWindowID?
    /// True while a system drag is interacting with Kehai (Command-Tab-style redirect).
    private(set) var isExternalDragActive = false
    /// Temporarily hides the selection halo during the pre-activate blink.
    private(set) var suppressSelectionHalo = false
    private var dragHoverWindowID: CGWindowID?
    private var dragDwellTask: Task<Void, Never>?
    private var dragSessionGeneration = 0
    private var dragEndMonitors: [Any] = []
    private var dragPasteboardPollTask: Task<Void, Never>?
    /// Bumped when a drag freezes inventory so in-flight SCK/AX work is discarded on resume.
    private var inventoryEpoch = 0
    /// Frozen UI lists while dragging — inventory must not visually shrink mid-drag.
    private var dragDisplayWindows: [WindowItem]?
    private var dragDisplayTaskGroups: [TaskGroup]?
    /// Invoked when dwell-activate should hide the browser so the target can receive the drop.
    var onDragRedirectActivated: (() -> Void)?
    private static let dragDwellMilliseconds: UInt64 = 900
    private static let dragBlinkOffMilliseconds: UInt64 = 45
    private static let dragBlinkOnMilliseconds: UInt64 = 55

    /// Mid-drag SCK/AX snapshots are incomplete and look like errant filtering.
    private var shouldFreezeInventory: Bool {
        isExternalDragActive
    }

    /// Windows shown in the browser grid/app strip. Uses a drag-time snapshot so
    /// in-flight inventory mutations cannot empty the UI under the cursor.
    private var displayWindows: [WindowItem] {
        dragDisplayWindows ?? windows
    }

    private var displayTaskGroups: [TaskGroup] {
        dragDisplayTaskGroups ?? taskGroups
    }

    private static var isSystemDragPasteboardActive: Bool {
        !(NSPasteboard(name: .drag).pasteboardItems ?? []).isEmpty
    }
    var searchFocusRequest = 0
    var actionChooserWindow: WindowItem?
    var actionChooserStage: WindowActionChooserStage?
    var actionChooserSelection = 0
    private var actionChooserReturnsToRemoval = false
    var keyboardColumnCount = 1
    var hiddenWindowsRevision = 0
    var thumbnailCardWidth: CGFloat {
        didSet { UserDefaults.standard.set(Double(thumbnailCardWidth), forKey: Self.thumbnailCardWidthKey) }
    }
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            smartSearchWindowIDs = nil
            smartSearchStatus = nil
            preserveSelectionOrSelectFirst()
        }
    }
    var isSmartSearching = false
    var smartSearchStatus: String?
    var isLoading = true
    var isGrouping = false
    var groupingStatus: String?
    var hasGeneratedGroups = false
    var groupsGeneratedAt: Date?
    var groupsAreStale = false
    var excludeHiddenWindows: Bool {
        didSet {
            UserDefaults.standard.set(excludeHiddenWindows, forKey: Self.excludeHiddenWindowsKey)
            preserveSelectionOrSelectFirst()
        }
    }
    var thumbnailStatus: String?
    var refreshingThumbnailWindowIDs: Set<CGWindowID> = []
    var errorMessage: String?
    var aiErrorMessage: String?

    private var hasPerformedInitialRefresh = false
    private var isPerformingInitialRefresh = false
    private var inventoryReconciliationTask: Task<Void, Never>?
    private var isReconcilingInventory = false
    private var activeRefreshCount = 0
    private var isTerminating = false
    private var thumbnailCapturedAt: [CGWindowID: Date] = [:]
    private static let thumbnailStaleInterval: TimeInterval = 5 * 60
    private let catalog: WindowCatalog
    private let thumbnails: ThumbnailService
    private let safari: SafariTabService
    private let history: ActivityStore
    private let grouping: TaskGroupingService
    private let smartSearch = SmartSearchService()
    private let openAIKeyStore: APIKeyStore
    private let anthropicKeyStore: APIKeyStore
    private let excludedAppStore: ExcludedAppStore
    private let aiExcludedAppStore: AIExcludedAppStore
    private let activator: WindowActivator
    private let activityMonitor: ActivityMonitor
    private let liveThumbnails = LiveThumbnailService()
    private var liveThumbnailTask: Task<Void, Never>?
    private var liveThumbnailEnabled = false
    private var liveThumbnailPausedForMenu = false
    private var smartSearchWindowIDs: [CGWindowID]?
    private let taskGroupCache = TaskGroupCache()
    private let hiddenWindowStore = HiddenWindowStore()
    private static let excludeHiddenWindowsKey = "overview.excludeHiddenWindows"
    private static let thumbnailCardWidthKey = "overview.thumbnailCardWidth"
    private static let viewModeKey = "overview.viewMode"
    private static let automaticGroupingAttemptedKey = "grouping.automaticFirstRunAttempted"
    private static let defaultThumbnailCardWidth: CGFloat = 280
    private static let minimumThumbnailCardWidth: CGFloat = 200
    private static let maximumThumbnailCardWidth: CGFloat = 440

    init(catalog: WindowCatalog, thumbnails: ThumbnailService, safari: SafariTabService, history: ActivityStore, grouping: TaskGroupingService, openAIKeyStore: APIKeyStore, anthropicKeyStore: APIKeyStore, excludedAppStore: ExcludedAppStore, aiExcludedAppStore: AIExcludedAppStore, activator: WindowActivator, activityMonitor: ActivityMonitor) {
        let defaults = UserDefaults.standard
        let savedWidth = defaults.double(forKey: Self.thumbnailCardWidthKey)
        thumbnailCardWidth = savedWidth > 0 ? CGFloat(savedWidth) : Self.defaultThumbnailCardWidth
        viewMode = defaults.string(forKey: Self.viewModeKey).flatMap(BrowserViewMode.init(rawValue:)) ?? .grouped
        excludeHiddenWindows = defaults.object(forKey: Self.excludeHiddenWindowsKey) == nil
            ? true
            : defaults.bool(forKey: Self.excludeHiddenWindowsKey)
        self.catalog = catalog; self.thumbnails = thumbnails; self.safari = safari; self.history = history
        self.grouping = grouping
        self.openAIKeyStore = openAIKeyStore
        self.anthropicKeyStore = anthropicKeyStore
        self.excludedAppStore = excludedAppStore
        self.aiExcludedAppStore = aiExcludedAppStore
        self.activator = activator
        self.activityMonitor = activityMonitor
        hasGeneratedGroups = taskGroupCache.hasCache
        groupsGeneratedAt = taskGroupCache.generatedAt
    }

    private func appKey(for window: WindowItem) -> String {
        window.bundleIdentifier ?? "pid:\(window.processID)"
    }

    var focusedAppName: String? {
        guard let focusedAppKey else { return nil }
        return recentAppWindows.first(where: { appKey(for: $0) == focusedAppKey })?.appName
    }

    func isAppFocused(_ windowID: CGWindowID) -> Bool {
        guard selectedAppWindowID != nil,
              let focusedAppKey,
              let representative = recentAppWindows.first(where: { $0.id == windowID }) else { return false }
        return appKey(for: representative) == focusedAppKey
    }

    func updateAppBadges(_ snapshot: DockBadgeMonitor.Snapshot) {
        guard appBadges != snapshot else { return }
        appBadges = snapshot
        appBadgeRevision += 1
    }

    func badgeLabel(for window: WindowItem) -> String? {
        _ = appBadgeRevision
        if let bundleIdentifier = window.bundleIdentifier,
           let badge = appBadges.byBundleIdentifier[bundleIdentifier] {
            return badge
        }
        return appBadges.byAppName[window.appName]
    }

    func taskContext(for windowID: CGWindowID) -> String? {
        guard focusedAppKey != nil else { return nil }
        let names = displayTaskGroups
            .filter { $0.windowIDs.contains(windowID) }
            .map(\.name)
        guard !names.isEmpty else { return nil }
        return names.prefix(2).joined(separator: " · ")
    }

    var filteredWindows: [WindowItem] {
        _ = hiddenWindowsRevision
        let sourceWindows = displayWindows
        let selectedWindowIDs = selectedTaskGroupID.flatMap { selectedID in
            displayTaskGroups.first(where: { $0.id == selectedID }).map { Set($0.windowIDs) }
        }
        let eligibleWindows = sourceWindows.filter { item in
            let belongsToSelectedGroup = selectedWindowIDs?.contains(item.id) ?? true
            let includedByHiddenFilter = !excludeHiddenWindows || !hiddenWindowStore.isHidden(item)
            let belongsToFocusedApp = focusedAppKey.map { appKey(for: item) == $0 } ?? true
            return belongsToSelectedGroup && includedByHiddenFilter && belongsToFocusedApp
        }
        if let smartSearchWindowIDs {
            let windowsByID = Dictionary(uniqueKeysWithValues: eligibleWindows.map { ($0.id, $0) })
            return smartSearchWindowIDs.compactMap { windowsByID[$0] }
        }
        let matchingWindows = eligibleWindows.filter { item in
            query.isEmpty
                || item.title.localizedCaseInsensitiveContains(query)
                || item.appName.localizedCaseInsensitiveContains(query)
                || item.safariTabs.contains { $0.title.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query) }
        }
        return WindowItem.orderedByRecency(matchingWindows)
    }

    func recordWindowFocus(windowID: CGWindowID, at date: Date) {
        // Don't reshuffle MRU order under the cursor during a system drag.
        guard !shouldFreezeInventory else { return }
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else { return }
        var updatedWindows = windows
        updatedWindows[index].lastSeen = date
        windows = WindowItem.orderedByRecency(updatedWindows)
    }

    var recentAppWindows: [WindowItem] {
        if let switcherAppWindows { return switcherAppWindows }
        return currentRecentAppWindows
    }

    private func appendNewAppsToSwitcherSnapshot() {
        guard var switcherAppWindows else { return }
        var knownKeys = Set(switcherAppWindows.map(appKey(for:)))
        let newApps = currentRecentAppWindows.filter { knownKeys.insert(appKey(for: $0)).inserted }
        guard !newApps.isEmpty else { return }
        switcherAppWindows.append(contentsOf: newApps)
        self.switcherAppWindows = switcherAppWindows
    }

    private var currentRecentAppWindows: [WindowItem] {
        _ = hiddenWindowsRevision
        let eligibleWindows = displayWindows.filter { window in
            !excludeHiddenWindows || !hiddenWindowStore.isHidden(window)
        }
        let contextualWindows: [WindowItem]
        if let smartSearchWindowIDs {
            let windowsByID = Dictionary(uniqueKeysWithValues: eligibleWindows.map { ($0.id, $0) })
            contextualWindows = smartSearchWindowIDs.compactMap { windowsByID[$0] }
        } else if !query.isEmpty {
            contextualWindows = WindowItem.orderedByRecency(eligibleWindows.filter { window in
                window.title.localizedCaseInsensitiveContains(query)
                    || window.appName.localizedCaseInsensitiveContains(query)
                    || window.safariTabs.contains {
                        $0.title.localizedCaseInsensitiveContains(query)
                            || $0.url.localizedCaseInsensitiveContains(query)
                    }
            })
        } else {
            contextualWindows = WindowItem.orderedByRecency(eligibleWindows)
        }

        // One representative per app that currently has an open window.
        var apps = contextualWindows.reduce(into: [WindowItem]()) { result, window in
            let appKey = window.bundleIdentifier ?? "pid:\(window.processID)"
            guard !result.contains(where: {
                ($0.bundleIdentifier ?? "pid:\($0.processID)") == appKey
            }) else { return }
            result.append(window)
        }

        // Command-Tab also shows running apps with no open windows (e.g. menu-bar-only
        // or everything closed). Smart Search is window-scoped, so skip there.
        if smartSearchWindowIDs == nil {
            apps.append(contentsOf: windowlessRunningApps(excluding: apps))
            apps = WindowItem.orderedByRecency(apps)
        }
        return apps
    }

    /// Regular, user-switchable apps that aren't already represented by an open window in the strip.
    private func windowlessRunningApps(excluding represented: [WindowItem]) -> [WindowItem] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let presentKeys = Set(represented.map { $0.bundleIdentifier ?? "pid:\($0.processID)" })
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        return NSWorkspace.shared.runningApplications.compactMap { application in
            guard application.activationPolicy == .regular,
                  !application.isTerminated,
                  application.processIdentifier != ownPID,
                  isUserSwitchableApplication(application),
                  !excludedAppStore.contains(bundleIdentifier: application.bundleIdentifier)
            else { return nil }

            let appKey = application.bundleIdentifier ?? "pid:\(application.processIdentifier)"
            guard !presentKeys.contains(appKey) else { return nil }

            let name = application.localizedName ?? ""
            if !trimmedQuery.isEmpty,
               !name.localizedCaseInsensitiveContains(trimmedQuery),
               !(application.bundleIdentifier?.localizedCaseInsensitiveContains(trimmedQuery) ?? false) {
                return nil
            }

            return WindowItem.appPlaceholder(
                for: application,
                lastSeen: activityMonitor.activationDate(for: application.processIdentifier)
                    ?? application.launchDate
            )
        }
    }

    private func isUserSwitchableApplication(_ application: NSRunningApplication) -> Bool {
        guard let executableURL = application.executableURL else { return false }
        let pathComponents = executableURL.pathComponents
        guard !pathComponents.contains(where: { $0.hasSuffix(".appex") }) else { return false }

        guard let bundleURL = application.bundleURL,
              let bundle = Bundle(url: bundleURL) else { return true }
        return (bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool) != true
            && (bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool) != true
            && bundle.object(forInfoDictionaryKey: "NSExtension") == nil
    }

    var windowSections: [BrowserWindowSection] {
        if let focusedAppKey {
            return [BrowserWindowSection(
                id: "app-focus-\(focusedAppKey)",
                title: nil,
                windows: filteredWindows
            )]
        }
        if smartSearchWindowIDs != nil {
            return [BrowserWindowSection(id: "smart-search", title: L10n.string("Smart Results"), windows: filteredWindows)]
        }
        guard viewMode == .grouped, !displayTaskGroups.isEmpty else {
            return [BrowserWindowSection(id: "recent", title: nil, windows: filteredWindows)]
        }

        let visibleByID = Dictionary(uniqueKeysWithValues: filteredWindows.map { ($0.id, $0) })
        let rankedSections = displayTaskGroups.compactMap { group -> BrowserWindowSection? in
            let groupWindows = WindowItem.orderedByRecency(group.windowIDs.compactMap { visibleByID[$0] })
            guard !groupWindows.isEmpty else { return nil }
            return BrowserWindowSection(id: group.id, title: group.name, windows: groupWindows)
        }.sorted { sectionRecency($0) > sectionRecency($1) }

        var assignedIDs = Set<CGWindowID>()
        var sections = rankedSections.compactMap { section -> BrowserWindowSection? in
            let uniqueWindows = section.windows.filter { assignedIDs.insert($0.id).inserted }
            guard !uniqueWindows.isEmpty else { return nil }
            return BrowserWindowSection(id: section.id, title: section.title, windows: uniqueWindows)
        }

        let otherWindows = filteredWindows.filter { !assignedIDs.contains($0.id) }
        if !otherWindows.isEmpty {
            sections.append(BrowserWindowSection(id: "other", title: L10n.string("Other Windows"), windows: otherWindows))
        }
        return sections
    }

    var usesTaskSectionLayout: Bool {
        focusedAppKey == nil && viewMode == .grouped && smartSearchWindowIDs == nil && !displayTaskGroups.isEmpty
    }

    var orderedFilteredWindows: [WindowItem] {
        windowSections.flatMap(\.windows)
    }

    func setViewMode(_ mode: BrowserViewMode) {
        viewMode = mode
    }

    func performSmartSearch() async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSmartSearching, !trimmedQuery.isEmpty else { return }
        isSmartSearching = true
        smartSearchStatus = L10n.string("Searching by meaning…")
        errorMessage = nil
        do {
            let credentials = try currentAICredentials()
            let resultIDs = try await smartSearch.search(
                query: trimmedQuery,
                windows: windows.filter {
                    (!hiddenWindowStore.isHidden($0) || !excludeHiddenWindows)
                        && !aiExcludedAppStore.contains(bundleIdentifier: $0.bundleIdentifier)
                },
                groups: taskGroups,
                provider: credentials.provider,
                apiKey: credentials.apiKey
            )
            smartSearchWindowIDs = resultIDs
            smartSearchStatus = L10n.string(resultIDs.isEmpty ? "No smart results" : "Smart Results")
            selectFirstFilteredWindow()
            SafeDiagnosticLog.shared.record("smart-search: completed results=\(resultIDs.count)")
        } catch {
            smartSearchWindowIDs = nil
            smartSearchStatus = nil
            aiErrorMessage = error.localizedDescription
            SafeDiagnosticLog.shared.record("smart-search: failed")
        }
        isSmartSearching = false
    }

    private func sectionRecency(_ section: BrowserWindowSection) -> Date {
        section.windows.compactMap(\.lastSeen).max() ?? .distantPast
    }

    func selectTaskGroup(_ group: TaskGroup?) {
        selectedTaskGroupID = group?.id
        selectFirstFilteredWindow()
    }

    func selectFirstFilteredWindow() {
        selectedWindowID = orderedFilteredWindows.first?.id
    }

    private func preserveSelectionOrSelectFirst() {
        if let focusedAppKey,
           !recentAppWindows.contains(where: { appKey(for: $0) == focusedAppKey }) {
            self.focusedAppKey = nil
        }
        if let selectedAppWindowID {
            if recentAppWindows.contains(where: { $0.id == selectedAppWindowID }) {
                return
            }
            self.selectedAppWindowID = nil
        }
        if let selectedWindowID,
           orderedFilteredWindows.contains(where: { $0.id == selectedWindowID }) {
            return
        }
        selectFirstFilteredWindow()
    }

    private func selectionSnapshot() -> WindowSelectionSnapshot? {
        guard let selectedWindowID,
              let window = windows.first(where: { $0.id == selectedWindowID })
                ?? orderedFilteredWindows.first(where: { $0.id == selectedWindowID }) else { return nil }
        return WindowSelectionSnapshot(
            id: window.id,
            processID: window.processID,
            bundleIdentifier: window.bundleIdentifier,
            title: window.title
        )
    }

    private func restoreSelection(from snapshot: WindowSelectionSnapshot?) {
        guard let snapshot else {
            preserveSelectionOrSelectFirst()
            return
        }
        let visible = orderedFilteredWindows
        let restored = visible.first(where: { $0.id == snapshot.id })
            ?? visible.first(where: {
                $0.processID == snapshot.processID
                    && $0.bundleIdentifier == snapshot.bundleIdentifier
                    && $0.title == snapshot.title
            })
        selectedWindowID = restored?.id ?? visible.first?.id
    }

    func showActionChooserForSelectedWindow() {
        guard let selectedWindow else { return }
        showActionChooser(for: selectedWindow, stage: .removal)
    }

    func showExclusionChooserForFocusedApp() -> Bool {
        guard selectedAppWindowID != nil,
              let focusedAppKey,
              let window = recentAppWindows.first(where: { appKey(for: $0) == focusedAppKey }),
              canExcludeApp(window) else { return false }
        showActionChooser(for: window, stage: .exclusion)
        return true
    }

    func showActionChooser(for window: WindowItem, stage: WindowActionChooserStage) {
        actionChooserWindow = window
        actionChooserStage = stage
        actionChooserSelection = 0
        actionChooserReturnsToRemoval = stage == .removal
    }

    func moveActionChooserSelection(_ direction: Int) {
        guard direction != 0 else { return }
        let count = actionChooserOptionCount
        guard count > 0 else { return }
        actionChooserSelection = (actionChooserSelection + direction + count) % count
    }

    func confirmActionChooserSelection() {
        guard let window = actionChooserWindow, let actionChooserStage else { return }
        switch actionChooserStage {
        case .removal:
            if actionChooserSelection == 0 {
                closeWindow(window)
                dismissActionChooser()
            } else if actionChooserSelection == 1 {
                if !isWindowHidden(window) { toggleHidden(window) }
                dismissActionChooser()
            } else {
                self.actionChooserStage = .exclusion
                actionChooserSelection = 0
            }
        case .exclusion:
            if canExcludeAppFromAI(window), actionChooserSelection == 0 {
                excludeAppFromAI(window)
            } else {
                excludeApp(for: window)
            }
            dismissActionChooser()
        }
    }

    func cancelActionChooser() {
        if actionChooserStage == .exclusion, actionChooserReturnsToRemoval {
            actionChooserStage = .removal
            actionChooserSelection = 2
        } else {
            dismissActionChooser()
        }
    }

    private var actionChooserOptionCount: Int {
        guard let window = actionChooserWindow, let actionChooserStage else { return 0 }
        switch actionChooserStage {
        case .removal: return canExcludeApp(window) ? 3 : 2
        case .exclusion: return canExcludeAppFromAI(window) ? 2 : 1
        }
    }

    private func dismissActionChooser() {
        actionChooserWindow = nil
        actionChooserStage = nil
        actionChooserSelection = 0
        actionChooserReturnsToRemoval = false
    }

    func closeWindowFromMenu(_ window: WindowItem) {
        closeWindow(window)
    }

    func quitApp(_ window: WindowItem) {
        guard window.bundleIdentifier?.caseInsensitiveCompare("com.apple.finder") != .orderedSame,
              window.appName.caseInsensitiveCompare("Finder") != .orderedSame else {
            SafeDiagnosticLog.shared.record("menu: ignored quit for Finder")
            return
        }
        guard activator.quit(window) else {
            errorMessage = L10n.string("Kehai could not quit this app.")
            return
        }
        windows.removeAll {
            $0.processID == window.processID
                || (window.bundleIdentifier != nil && $0.bundleIdentifier == window.bundleIdentifier)
        }
        reconcileCachedGroups()
        preserveSelectionOrSelectFirst()
    }

    private func closeWindow(_ window: WindowItem, keepKehaiActive: Bool = true) {
        let started = activator.close(window, keepKehaiActive: keepKehaiActive) { [weak self] didClose in
            guard let self else { return }
            if didClose {
                self.windows.removeAll { $0.id == window.id }
                self.reconcileCachedGroups()
                self.preserveSelectionOrSelectFirst()
            } else if keepKehaiActive {
                // Unsaved-changes sheet likely appeared; stay in Kehai.
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        if !started {
            errorMessage = L10n.string("Kehai could not close this window.")
        }
    }

    func canExcludeApp(_ window: WindowItem) -> Bool {
        guard let bundleIdentifier = window.bundleIdentifier else { return false }
        return !bundleIdentifier.isEmpty && !excludedAppStore.contains(bundleIdentifier: bundleIdentifier)
    }

    func excludeApp(for window: WindowItem) {
        guard let bundleIdentifier = window.bundleIdentifier, !bundleIdentifier.isEmpty else { return }
        excludedAppStore.exclude(bundleIdentifier: bundleIdentifier, name: window.appName)
        windows.removeAll { $0.bundleIdentifier == bundleIdentifier }
        reconcileCachedGroups()
        preserveSelectionOrSelectFirst()
    }

    func canExcludeAppFromAI(_ window: WindowItem) -> Bool {
        guard let bundleIdentifier = window.bundleIdentifier else { return false }
        return !bundleIdentifier.isEmpty && !aiExcludedAppStore.contains(bundleIdentifier: bundleIdentifier)
    }

    func excludeAppFromAI(_ window: WindowItem) {
        guard let bundleIdentifier = window.bundleIdentifier, !bundleIdentifier.isEmpty else { return }
        aiExcludedAppStore.exclude(bundleIdentifier: bundleIdentifier, name: window.appName)
    }

    func isWindowHidden(_ window: WindowItem) -> Bool {
        _ = hiddenWindowsRevision
        return hiddenWindowStore.isHidden(window)
    }

    func toggleHidden(_ window: WindowItem) {
        if hiddenWindowStore.isHidden(window) {
            hiddenWindowStore.unhide(window)
        } else {
            hiddenWindowStore.hide(window)
        }
        hiddenWindowsRevision += 1
        preserveSelectionOrSelectFirst()
    }

    func resizeThumbnails(by steps: Int) {
        let proposedWidth = thumbnailCardWidth + CGFloat(steps) * 40
        thumbnailCardWidth = min(max(proposedWidth, Self.minimumThumbnailCardWidth), Self.maximumThumbnailCardWidth)
    }

    func setLiveThumbnailEnabled(_ enabled: Bool) {
        guard liveThumbnailEnabled != enabled else { return }
        liveThumbnailEnabled = enabled
        if enabled {
            scheduleSelectedLiveThumbnail()
        } else {
            stopLiveThumbnail()
        }
    }

    func stopLiveThumbnail() {
        liveThumbnailTask?.cancel()
        liveThumbnailTask = nil
        liveThumbnailWindowID = nil
        liveThumbnail = nil
        Task { await liveThumbnails.stop() }
    }

    func setMenuTrackingActive(_ active: Bool) {
        guard liveThumbnailPausedForMenu != active else { return }
        liveThumbnailPausedForMenu = active
        if active {
            stopLiveThumbnail()
        } else if liveThumbnailEnabled {
            scheduleSelectedLiveThumbnail()
        }
    }

    /// Synchronously tears down any active capture so nothing outlives the
    /// process during app termination.
    func prepareForTermination() {
        isTerminating = true
        inventoryReconciliationTask?.cancel()
        inventoryReconciliationTask = nil
        dragDwellTask?.cancel()
        dragDwellTask = nil
        dragPasteboardPollTask?.cancel()
        dragPasteboardPollTask = nil
        liveThumbnailTask?.cancel()
        liveThumbnailWindowID = nil
        liveThumbnail = nil
        liveThumbnailEnabled = false
        thumbnails.prepareForTermination()
        liveThumbnails.prepareForTermination()
    }

    func finishTermination() async {
        if let liveThumbnailTask {
            await liveThumbnailTask.value
            self.liveThumbnailTask = nil
        }
        while activeRefreshCount > 0 {
            try? await Task.sleep(for: .milliseconds(25))
        }
        await liveThumbnails.stop()
    }

    private func scheduleSelectedLiveThumbnail() {
        stopLiveThumbnail()
        guard liveThumbnailEnabled,
              !liveThumbnailPausedForMenu,
              NSApp.isActive,
              let windowID = selectedWindowID,
              windows.contains(where: { $0.id == windowID }) else { return }

        liveThumbnailTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(220))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.liveThumbnailEnabled,
                  NSApp.isActive,
                  self.selectedWindowID == windowID else { return }
            await self.liveThumbnails.start(
                windowID: windowID,
                maximumSize: CGSize(width: 880, height: 550)
            ) { [weak self] image in
                guard let self,
                      self.liveThumbnailEnabled,
                      NSApp.isActive,
                      self.selectedWindowID == windowID else { return }
                self.liveThumbnailWindowID = windowID
                self.liveThumbnail = image
            }
        }
    }

    private func reconcileCachedGroups() {
        let reconciliation = taskGroupCache.reconcile(with: windows)
        taskGroups = reconciliation.groups
        groupsAreStale = reconciliation.isStale
        hasGeneratedGroups = taskGroupCache.hasCache
        if let selectedTaskGroupID,
           !taskGroups.contains(where: { $0.id == selectedTaskGroupID }) {
            self.selectedTaskGroupID = nil
        }
    }

    @discardableResult
    func moveSelectionToAdjacentGroup(_ direction: Int) -> Bool {
        guard selectedAppWindowID == nil,
              viewMode == .grouped,
              windowSections.count > 1,
              direction != 0 else { return false }
        let sections = windowSections
        let currentSectionIndex = selectedWindowID.flatMap { selectedID in
            sections.firstIndex { section in section.windows.contains { $0.id == selectedID } }
        } ?? (direction > 0 ? -1 : sections.count)
        let targetIndex = min(max(currentSectionIndex + direction, 0), sections.count - 1)
        guard targetIndex != currentSectionIndex,
              let targetWindow = sections[targetIndex].windows.first else { return false }
        selectedWindowID = targetWindow.id
        return true
    }

    func cycleSelectionByApp(_ direction: Int) {
        guard direction != 0 else { return }
        let representatives = recentAppWindows
        guard !representatives.isEmpty else { return }

        let itemCount = representatives.count + 1
        let currentIndex: Int
        if isAllWindowsAppSelected {
            currentIndex = 0
        } else if let focusedAppKey,
                  let appIndex = representatives.firstIndex(where: { appKey(for: $0) == focusedAppKey }) {
            currentIndex = appIndex + 1
        } else {
            currentIndex = direction > 0 ? -1 : 0
        }
        let targetIndex = (currentIndex + direction + itemCount) % itemCount
        if targetIndex == 0 {
            selectAllWindowsApp()
        } else {
            focusApp(representatives[targetIndex - 1].id)
        }
    }

    func moveSelection(
        horizontal: Int = 0,
        vertical: Int = 0,
        columnCount: Int,
        windowsAboveAppStrip: Bool = false
    ) {
        if selectedAppWindowID != nil || isAllWindowsAppSelected {
            moveAppSelection(
                horizontal: horizontal,
                vertical: vertical,
                windowsAboveAppStrip: windowsAboveAppStrip
            )
            return
        }

        let visible = orderedFilteredWindows
        guard !visible.isEmpty else {
            selectedWindowID = nil
            return
        }
        if selectedWindowID == nil || !visible.contains(where: { $0.id == selectedWindowID }) {
            selectedWindowID = visible.first?.id
            return
        }
        let visualRows = keyboardWindowRows(columnCount: columnCount)
        let returnsToAppStrip = windowsAboveAppStrip ? vertical > 0 : vertical < 0
        if returnsToAppStrip,
           let selectedWindowID,
           let firstRow = visualRows.first,
           firstRow.contains(where: { $0.id == selectedWindowID }) {
            if let appWindowIDBeforeEnteringWindows,
               recentAppWindows.contains(where: { $0.id == appWindowIDBeforeEnteringWindows }) {
                focusApp(appWindowIDBeforeEnteringWindows)
            } else {
                selectAllWindowsApp()
            }
            appWindowIDBeforeEnteringWindows = nil
            return
        }
        selectedAppWindowID = nil
        if vertical != 0, moveSelectionVertically(vertical, columnCount: columnCount) {
            return
        }
        let currentIndex = selectedWindowID.flatMap { id in visible.firstIndex(where: { $0.id == id }) } ?? 0
        let targetIndex = min(max(currentIndex + horizontal, 0), visible.count - 1)
        selectedWindowID = visible[targetIndex].id
    }

    private func moveAppSelection(horizontal: Int, vertical: Int, windowsAboveAppStrip: Bool) {
        let apps = recentAppWindows
        guard !apps.isEmpty else {
            selectedAppWindowID = nil
            isAllWindowsAppSelected = true
            return
        }
        let currentIndex = isAllWindowsAppSelected
            ? 0
            : (focusedAppKey.flatMap { key in apps.firstIndex { appKey(for: $0) == key } }.map { $0 + 1 } ?? 1)
        let entersWindows = windowsAboveAppStrip ? vertical < 0 : vertical > 0
        if entersWindows {
            guard let mostRecentWindow = orderedFilteredWindows.first else { return }
            appWindowIDBeforeEnteringWindows = selectedAppWindowID
            isAllWindowsAppSelected = false
            selectedAppWindowID = nil
            selectedWindowID = mostRecentWindow.id
            return
        }
        if vertical != 0 { return }
        let targetIndex = min(max(currentIndex + horizontal, 0), apps.count)
        if targetIndex == 0 {
            selectAllWindowsApp()
        } else {
            focusApp(apps[targetIndex - 1].id)
        }
    }

    private func moveSelectionVertically(_ direction: Int, columnCount: Int) -> Bool {
        let rows = keyboardWindowRows(columnCount: columnCount)
        guard let selectedWindowID,
              let rowIndex = rows.firstIndex(where: { row in row.contains { $0.id == selectedWindowID } }),
              let columnIndex = rows[rowIndex].firstIndex(where: { $0.id == selectedWindowID }) else {
            return false
        }
        let targetRowIndex = rowIndex + direction
        guard rows.indices.contains(targetRowIndex) else { return true }
        let targetRow = rows[targetRowIndex]
        self.selectedWindowID = targetRow[min(columnIndex, targetRow.count - 1)].id
        return true
    }

    private func keyboardWindowRows(columnCount: Int) -> [[WindowItem]] {
        let columns = max(columnCount, 1)
        guard usesTaskSectionLayout else {
            return stride(from: 0, to: orderedFilteredWindows.count, by: columns).map { start in
                Array(orderedFilteredWindows[start..<min(start + columns, orderedFilteredWindows.count)])
            }
        }

        var rows: [[WindowItem]] = []
        var currentRow: [WindowItem] = []
        var remainingSlots = columns
        for section in windowSections {
            var remainingWindows = section.windows
            while !remainingWindows.isEmpty {
                if remainingWindows.count <= columns,
                   remainingWindows.count > remainingSlots,
                   remainingSlots < columns {
                    rows.append(currentRow)
                    currentRow = []
                    remainingSlots = columns
                }
                let count = min(remainingWindows.count, remainingSlots)
                currentRow.append(contentsOf: remainingWindows.prefix(count))
                remainingWindows.removeFirst(count)
                remainingSlots -= count
                if remainingSlots == 0 {
                    rows.append(currentRow)
                    currentRow = []
                    remainingSlots = columns
                }
            }
        }
        if !currentRow.isEmpty { rows.append(currentRow) }
        return rows
    }

    var selectedWindow: WindowItem? {
        guard let selectedWindowID else { return nil }
        return orderedFilteredWindows.first { $0.id == selectedWindowID }
    }

    @discardableResult
    func activateSelectedWindow() -> Bool {
        guard let window = selectedWindow else { return false }
        activate(window)
        return true
    }

    @discardableResult
    func activateCurrentSelection() -> Bool {
        if let focusedAppKey,
           let window = recentAppWindows.first(where: { appKey(for: $0) == focusedAppKey }) {
            activate(window)
            return true
        }
        return activateSelectedWindow()
    }

    func beginSwitcherMode() {
        // Hotkey switcher should always show the full inventory, not a leftover
        // search, smart-search result set, or Dock-selected task group.
        clearTransientFilters(selectedGroupID: nil)
        switcherAppWindows = currentRecentAppWindows
        isSwitcherMode = true
        hoveredSwitcherWindowID = nil
        selectAllWindowsApp()
    }

    /// Clears search / smart-search / optional group filter left over from a prior session.
    func clearTransientFilters(selectedGroupID: String? = nil) {
        focusedAppKey = nil
        isAllWindowsAppSelected = false
        smartSearchWindowIDs = nil
        smartSearchStatus = nil
        isSmartSearching = false
        if !query.isEmpty {
            query = ""
        }
        selectedTaskGroupID = selectedGroupID
        suppressSelectionHalo = false
    }

    func prepareForBrowserPresentation(selectedGroupID: String? = nil) {
        isSwitcherMode = false
        switcherAppWindows = nil
        hoveredSwitcherWindowID = nil
        appWindowIDBeforeEnteringWindows = nil
        clearTransientFilters(selectedGroupID: selectedGroupID)
        selectedAppWindowID = nil
        preserveSelectionOrSelectFirst()
    }

    func hoverWindowInSwitcherMode(_ windowID: CGWindowID?) {
        guard isSwitcherMode else { return }
        hoveredSwitcherWindowID = windowID
        if let windowID {
            isAllWindowsAppSelected = false
            selectedAppWindowID = nil
            selectedWindowID = windowID
        }
    }

    func focusApp(_ windowID: CGWindowID) {
        guard let representative = recentAppWindows.first(where: { $0.id == windowID }) else { return }
        appWindowIDBeforeEnteringWindows = nil
        isAllWindowsAppSelected = false
        focusedAppKey = appKey(for: representative)
        selectedWindowID = nil
        selectedAppWindowID = windowID
    }

    func selectAllWindowsApp() {
        focusedAppKey = nil
        selectedWindowID = nil
        selectedAppWindowID = nil
        hoveredSwitcherWindowID = nil
        isAllWindowsAppSelected = true
    }

    func clearAppFocus() {
        focusedAppKey = nil
        selectedAppWindowID = nil
        hoveredSwitcherWindowID = nil
        isAllWindowsAppSelected = false
        preserveSelectionOrSelectFirst()
    }

    func hoverAppInSwitcherMode(_ windowID: CGWindowID?) {
        guard isSwitcherMode, let windowID else { return }
        hoveredSwitcherWindowID = windowID
        focusApp(windowID)
    }

    /// Called while the browser is open whenever a mouse-drag event arrives.
    /// Freezes inventory as soon as a real system drag is in progress, before the
    /// cursor reaches a card (where DropDelegate would finally fire).
    func notePotentialSystemDrag() {
        guard !isExternalDragActive else { return }
        guard NSEvent.pressedMouseButtons != 0, Self.isSystemDragPasteboardActive else { return }
        beginExternalDragSession()
    }

    /// Any system drag interacting with Kehai — freeze inventory so SCK/AX thrash can't shrink the list.
    func beginExternalDragSession() {
        guard !isExternalDragActive else { return }
        isExternalDragActive = true
        // Snapshot what the user currently sees; UI reads these until the drag ends.
        dragDisplayWindows = windows
        dragDisplayTaskGroups = taskGroups
        // Invalidate any in-flight catalog work that may still apply after await.
        inventoryEpoch += 1
        inventoryReconciliationTask?.cancel()
        inventoryReconciliationTask = nil
        installDragEndMonitors()
        SafeDiagnosticLog.shared.record("drag-session: begin freeze inventory count=\(windows.count)")
    }

    /// Drag entered a window card or app icon — select it and start dwell-to-activate.
    func dragHoverEntered(windowID: CGWindowID, isAppStrip: Bool) {
        beginExternalDragSession()
        dragHoverWindowID = windowID
        if isAppStrip {
            focusApp(windowID)
        } else {
            selectedAppWindowID = nil
            selectedWindowID = windowID
        }
        if isSwitcherMode {
            hoveredSwitcherWindowID = windowID
        }
        restartDragDwellTimer()
    }

    func dragHoverExited(windowID: CGWindowID) {
        guard dragHoverWindowID == windowID else { return }
        dragDwellTask?.cancel()
        dragDwellTask = nil
        dragHoverWindowID = nil
        // Still mid-session until mouse-up ends the drag.
    }

    func dragSessionEnded() {
        let wasDragging = isExternalDragActive
        clearDragSessionState()
        if wasDragging {
            SafeDiagnosticLog.shared.record("drag-session: end thaw inventory")
            // Catch up on opens/closes that happened while the list was frozen.
            scheduleBackgroundInventoryReconciliation()
        }
    }

    private func clearDragSessionState() {
        dragDwellTask?.cancel()
        dragDwellTask = nil
        dragHoverWindowID = nil
        isExternalDragActive = false
        suppressSelectionHalo = false
        dragDisplayWindows = nil
        dragDisplayTaskGroups = nil
        dragSessionGeneration += 1
        removeDragEndMonitors()
    }

    private func installDragEndMonitors() {
        removeDragEndMonitors()
        // SwiftUI DropDelegate never gets a cancel callback; mouse-up is the reliable end.
        let mask: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            Task { @MainActor in self?.dragSessionEnded() }
            return event
        }) {
            dragEndMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor in self?.dragSessionEnded() }
        }) {
            dragEndMonitors.append(global)
        }
        // Fallback if mouse-up is missed (e.g. drag ended in another space).
        dragPasteboardPollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    return
                }
                guard let self, self.isExternalDragActive else { return }
                // Only end when the mouse is up. Pasteboard alone is unreliable —
                // macOS often leaves drag items around after the gesture ends.
                if NSEvent.pressedMouseButtons == 0 {
                    self.dragSessionEnded()
                    return
                }
            }
        }
    }

    private func removeDragEndMonitors() {
        for monitor in dragEndMonitors {
            NSEvent.removeMonitor(monitor)
        }
        dragEndMonitors.removeAll()
        dragPasteboardPollTask?.cancel()
        dragPasteboardPollTask = nil
    }

    private func restartDragDwellTimer() {
        dragDwellTask?.cancel()
        suppressSelectionHalo = false
        let windowID = dragHoverWindowID
        let generation = dragSessionGeneration
        dragDwellTask = Task { [weak self] in
            do {
                // Command-Tab-like dwell before raising the target under a live drag.
                try await Task.sleep(for: .milliseconds(Self.dragDwellMilliseconds))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.dragSessionGeneration == generation,
                  self.dragHoverWindowID == windowID,
                  let windowID,
                  let window = self.windowForDragTarget(windowID) else { return }

            // Blink the focus halo twice as a final cue, then open.
            for _ in 0..<2 {
                guard !Task.isCancelled,
                      self.dragSessionGeneration == generation,
                      self.dragHoverWindowID == windowID else {
                    self.suppressSelectionHalo = false
                    return
                }
                self.suppressSelectionHalo = true
                do {
                    try await Task.sleep(for: .milliseconds(Self.dragBlinkOffMilliseconds))
                } catch {
                    self.suppressSelectionHalo = false
                    return
                }
                self.suppressSelectionHalo = false
                do {
                    try await Task.sleep(for: .milliseconds(Self.dragBlinkOnMilliseconds))
                } catch {
                    return
                }
            }

            guard !Task.isCancelled,
                  self.dragSessionGeneration == generation,
                  self.dragHoverWindowID == windowID else { return }

            self.activator.activateForDragRedirect(window)
            // End switcher immediately; modifier-release later only tears down monitors.
            self.isSwitcherMode = false
            self.switcherAppWindows = nil
            self.hoveredSwitcherWindowID = nil
            self.clearDragSessionState()
            SafeDiagnosticLog.shared.record("drag-redirect: dwell activated")
            // Hide Kehai so the raised window can receive the drop at the cursor.
            self.onDragRedirectActivated?()
        }
    }

    private func windowForDragTarget(_ windowID: CGWindowID) -> WindowItem? {
        windows.first(where: { $0.id == windowID })
            ?? orderedFilteredWindows.first(where: { $0.id == windowID })
            ?? recentAppWindows.first(where: { $0.id == windowID })
    }

    @discardableResult
    func finishSwitcherMode() -> Bool {
        let preservesAllWindowsSelection = isAllWindowsAppSelected
            && dragHoverWindowID == nil
            && hoveredSwitcherWindowID == nil
        defer {
            isSwitcherMode = false
            switcherAppWindows = nil
            hoveredSwitcherWindowID = nil
            focusedAppKey = nil
            if !preservesAllWindowsSelection {
                isAllWindowsAppSelected = false
            }
        }
        // Prefer pointer/drag targets, then the app selected by repeated shortcut-key presses.
        let targetID = dragHoverWindowID ?? hoveredSwitcherWindowID ?? selectedAppWindowID
        guard !isAllWindowsAppSelected,
              let targetID,
              let window = windowForDragTarget(targetID) else {
            return false
        }
        if isExternalDragActive {
            activator.activateForDragRedirect(window)
        } else {
            activate(window)
        }
        return true
    }

    /// Command-Tab-style quit: quit the app for the hovered/selected item.
    @discardableResult
    func quitSelectedAppInSwitcherMode() -> Bool {
        guard isSwitcherMode, let window = switcherTargetWindow(preferAppStrip: true) else { return false }
        guard window.bundleIdentifier?.caseInsensitiveCompare("com.apple.finder") != .orderedSame,
              window.appName.caseInsensitiveCompare("Finder") != .orderedSame else {
            SafeDiagnosticLog.shared.record("switcher: ignored quit for Finder")
            return false
        }
        guard activator.quit(window) else {
            errorMessage = L10n.string("Kehai could not quit this app.")
            return false
        }
        let processID = window.processID
        let bundleIdentifier = window.bundleIdentifier
        let quittingAppKey = appKey(for: window)
        let quittingAppIndex = switcherAppWindows?.firstIndex { appKey(for: $0) == quittingAppKey }
        windows.removeAll {
            $0.processID == processID
                || (bundleIdentifier != nil && $0.bundleIdentifier == bundleIdentifier)
        }
        switcherAppWindows?.removeAll { appKey(for: $0) == quittingAppKey }
        reconcileCachedGroups()
        selectedWindowID = nil
        hoveredSwitcherWindowID = nil

        if let switcherAppWindows, !switcherAppWindows.isEmpty {
            let nextIndex = min(quittingAppIndex ?? 0, switcherAppWindows.count - 1)
            focusApp(switcherAppWindows[nextIndex].id)
        } else {
            selectedAppWindowID = nil
            focusedAppKey = nil
            isAllWindowsAppSelected = true
        }
        preserveSelectionOrSelectFirst()
        SafeDiagnosticLog.shared.record("switcher: quit app")
        return true
    }

    /// Close the hovered/selected window card (not an app-strip icon).
    @discardableResult
    func closeSelectedWindowInSwitcherMode() -> Bool {
        guard isSwitcherMode else { return false }
        // Prefer the window under the pointer; ignore app-strip selection for W.
        let window: WindowItem?
        if let hoveredSwitcherWindowID,
           let hovered = windows.first(where: { $0.id == hoveredSwitcherWindowID })
                ?? orderedFilteredWindows.first(where: { $0.id == hoveredSwitcherWindowID }) {
            // If the hover target is only represented as an app icon (same id as strip),
            // still allow closing that representative window.
            window = hovered
        } else if selectedAppWindowID == nil, let selectedWindowID {
            window = windows.first(where: { $0.id == selectedWindowID })
                ?? orderedFilteredWindows.first(where: { $0.id == selectedWindowID })
        } else {
            window = nil
        }
        guard let window else {
            SafeDiagnosticLog.shared.record("switcher: close window missed target")
            return false
        }

        // Optimistically drop the card so W feels immediate, like Command-Tab.
        let closedID = window.id
        windows.removeAll { $0.id == closedID }
        if selectedWindowID == closedID { selectedWindowID = nil }
        if hoveredSwitcherWindowID == closedID { hoveredSwitcherWindowID = nil }
        reconcileCachedGroups()
        preserveSelectionOrSelectFirst()

        let started = activator.close(window, keepKehaiActive: true) { [weak self] didClose in
            guard let self else { return }
            if didClose {
                // Already removed; keep selection coherent if inventory races.
                self.windows.removeAll { $0.id == closedID }
                self.reconcileCachedGroups()
                self.preserveSelectionOrSelectFirst()
                NSApp.activate(ignoringOtherApps: true)
            } else {
                // Close was blocked (e.g. unsaved changes). Restore the card and
                // surface the target app so the user can respond to its prompt.
                if !self.windows.contains(where: { $0.id == closedID }) {
                    self.windows.insert(window, at: 0)
                    self.reconcileCachedGroups()
                }
                self.selectedWindowID = closedID
                self.activator.activate(window)
            }
        }
        if !started {
            if !windows.contains(where: { $0.id == closedID }) {
                windows.insert(window, at: 0)
                reconcileCachedGroups()
            }
            selectedWindowID = closedID
            errorMessage = L10n.string("Kehai could not close this window.")
            SafeDiagnosticLog.shared.record("switcher: close window failed to start")
            return false
        }
        SafeDiagnosticLog.shared.record("switcher: close window")
        return true
    }

    private func switcherTargetWindow(preferAppStrip: Bool) -> WindowItem? {
        if preferAppStrip, let selectedAppWindowID,
           let window = recentAppWindows.first(where: { $0.id == selectedAppWindowID })
                ?? windows.first(where: { $0.id == selectedAppWindowID }) {
            return window
        }
        if let hoveredSwitcherWindowID {
            return windows.first(where: { $0.id == hoveredSwitcherWindowID })
                ?? orderedFilteredWindows.first(where: { $0.id == hoveredSwitcherWindowID })
                ?? recentAppWindows.first(where: { $0.id == hoveredSwitcherWindowID })
        }
        if let selectedWindowID,
           let window = windows.first(where: { $0.id == selectedWindowID })
                ?? orderedFilteredWindows.first(where: { $0.id == selectedWindowID }) {
            return window
        }
        if let selectedAppWindowID {
            return recentAppWindows.first(where: { $0.id == selectedAppWindowID })
                ?? windows.first(where: { $0.id == selectedAppWindowID })
        }
        return nil
    }

    func prepareForPresentation(selectedGroupID: String? = nil) {
        stopLiveThumbnail()
        prepareForBrowserPresentation(selectedGroupID: selectedGroupID)
        isGrouping = false
        isLoading = windows.isEmpty
        errorMessage = nil
    }

    func performInitialRefreshIfNeeded() async {
        guard !hasPerformedInitialRefresh, !isPerformingInitialRefresh else { return }
        isPerformingInitialRefresh = true
        await refresh()
        isPerformingInitialRefresh = false
        hasPerformedInitialRefresh = !windows.isEmpty || errorMessage != nil
    }

    func refreshForForeground() async {
        guard !isTerminating else { return }
        // Don't re-inventory mid-drag — SCK/AX snapshots are incomplete and wipe the grid.
        guard !shouldFreezeInventory else { return }
        guard hasPerformedInitialRefresh else {
            await performInitialRefreshIfNeeded()
            return
        }
        await refresh(generateInitialGroups: false, showsGlobalLoading: false)
    }

    func scheduleBackgroundInventoryReconciliation() {
        // System drags make ScreenCaptureKit / Accessibility snapshots incomplete;
        // reconciling then looks like "errant filtering" of apps and windows.
        guard !isTerminating, !shouldFreezeInventory else { return }
        inventoryReconciliationTask?.cancel()
        inventoryReconciliationTask = Task { [weak self] in
            guard let self, !self.shouldFreezeInventory else { return }
            await self.reconcileInventory(includeSafariTabs: false, showsGlobalLoading: self.windows.isEmpty)
        }
    }

    func refresh(generateInitialGroups: Bool = true, showsGlobalLoading: Bool = true) async {
        guard !isTerminating else { return }
        activeRefreshCount += 1
        defer { activeRefreshCount -= 1 }
        guard !shouldFreezeInventory else {
            // Never leave the first-launch spinner up if a drag blocked refresh.
            if showsGlobalLoading, windows.isEmpty { isLoading = false }
            return
        }
        logger.notice("Thumbnail refresh started")
        SafeDiagnosticLog.shared.record("thumbnail-pipeline: refresh started")
        if showsGlobalLoading { isLoading = true }
        errorMessage = nil

        // A user/foreground refresh must run after any background pass rather than
        // being dropped by reconcileInventory's single-flight guard.
        if let backgroundTask = inventoryReconciliationTask {
            inventoryReconciliationTask = nil
            backgroundTask.cancel()
            await backgroundTask.value
        }

        guard let pairs = await reconcileInventory(includeSafariTabs: true, showsGlobalLoading: showsGlobalLoading) else {
            if showsGlobalLoading { isLoading = false }
            return
        }

        // Inventory is ready; clear the global spinner before thumbnail capture.
        if showsGlobalLoading { isLoading = false }
        await refreshThumbnails(for: pairs)
        if generateInitialGroups {
            await generateInitialGroupsIfNeeded()
        }
    }

    @discardableResult
    private func reconcileInventory(
        includeSafariTabs: Bool,
        showsGlobalLoading: Bool
    ) async -> [(WindowItem, SCWindow)]? {
        guard !shouldFreezeInventory else { return nil }
        guard !isReconcilingInventory else { return nil }
        isReconcilingInventory = true
        let epochAtStart = inventoryEpoch
        defer { isReconcilingInventory = false }
        do {
            let seen = await history.lastSeen()
            // Re-check after every await — a drag may have started mid-catalog.
            guard inventoryEpoch == epochAtStart, !shouldFreezeInventory else {
                SafeDiagnosticLog.shared.record("window-inventory: discarded after freeze mid-catalog")
                return nil
            }
            let pairs = try await catalog.windows(lastSeen: seen)
            guard inventoryEpoch == epochAtStart, !shouldFreezeInventory else {
                SafeDiagnosticLog.shared.record("window-inventory: discarded sparse catalog during drag")
                return nil
            }
            logger.notice("Window catalog returned \(pairs.count) capture candidates")
            var items = pairs.map(\.0)

            if includeSafariTabs {
                do {
                    let tabs = try await safari.listTabs()
                    guard inventoryEpoch == epochAtStart, !shouldFreezeInventory else {
                        SafeDiagnosticLog.shared.record("window-inventory: discarded after freeze mid-safari")
                        return nil
                    }
                    assignSafariTabs(tabs, to: &items)
                } catch {
                    errorMessage = L10n.format("Safari tabs are unavailable: %@", error.localizedDescription)
                    SafeDiagnosticLog.shared.record("safari-tabs: enumeration failed")
                }
            }

            let previousByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
            var thumbnailRefreshIDs = Set<CGWindowID>()
            for index in items.indices {
                if let previous = previousByID[items[index].id] {
                    let metadataChanged = previous.title != items[index].title
                        || previous.frame != items[index].frame
                        || previous.isOnScreen != items[index].isOnScreen
                    items[index].lastSeen = [previous.lastSeen, items[index].lastSeen].compactMap { $0 }.max()
                    items[index].thumbnail = previous.thumbnail
                    items[index].thumbnailIsUsable = previous.thumbnailIsUsable
                    items[index].thumbnailRevision = previous.thumbnailRevision
                    if previous.appIcon != nil { items[index].appIcon = previous.appIcon }
                    if !includeSafariTabs { items[index].safariTabs = previous.safariTabs }
                    let thumbnailIsStale = thumbnailCapturedAt[items[index].id]
                        .map { Date().timeIntervalSince($0) >= Self.thumbnailStaleInterval }
                        ?? false
                    if metadataChanged || previous.thumbnail == nil || !previous.thumbnailIsUsable || thumbnailIsStale {
                        thumbnailRefreshIDs.insert(items[index].id)
                    }
                } else {
                    thumbnailRefreshIDs.insert(items[index].id)
                    if let activationDate = activityMonitor.recentActivationDate(for: items[index].processID) {
                        items[index].lastSeen = activationDate
                    }
                }
            }

            // Background ticks must not drop still-running windows. Sparse SCK/AX
            // mid-drag (or under load) otherwise looks like the UI is "filtering".
            // Safari is the exception: keeping every missing window while Safari is
            // still running leaves genuinely closed browser windows in the inventory.
            if !includeSafariTabs {
                let newIDs = Set(items.map(\.id))
                for previous in windows where !newIDs.contains(previous.id) {
                    let appStillRunning = NSRunningApplication(processIdentifier: previous.processID) != nil
                    if appStillRunning, previous.bundleIdentifier != "com.apple.Safari" {
                        items.append(previous)
                    }
                }
            }

            items = WindowItem.orderedByRecency(items)

            let previousIDs = Set(windows.map(\.id))
            let currentIDs = Set(items.map(\.id))
            // Guard against sparse mid-drag / transient SCK snapshots replacing a healthy list.
            // Missing Safari windows are authoritative, so only protected non-Safari
            // removals participate in this safety check.
            let protectedPreviousIDs = Set(windows.lazy
                .filter { $0.bundleIdentifier != "com.apple.Safari" }
                .map(\.id))
            let protectedCurrentCount = items.lazy
                .filter { $0.bundleIdentifier != "com.apple.Safari" }
                .count
            let removedCount = protectedPreviousIDs.subtracting(currentIDs).count
            if !protectedPreviousIDs.isEmpty,
               removedCount > 0,
               protectedCurrentCount < protectedPreviousIDs.count,
               Double(protectedCurrentCount) < Double(protectedPreviousIDs.count) * 0.6 {
                logger.notice("Rejected sparse inventory snapshot (\(items.count) vs \(self.windows.count))")
                SafeDiagnosticLog.shared.record(
                    "window-inventory: rejected sparse snapshot new=\(items.count) previous=\(windows.count) removed=\(removedCount)"
                )
                if showsGlobalLoading { isLoading = false }
                return nil
            }

            guard inventoryEpoch == epochAtStart, !shouldFreezeInventory else {
                SafeDiagnosticLog.shared.record("window-inventory: discarded before apply during drag")
                return nil
            }

            if previousIDs != currentIDs {
                SafeDiagnosticLog.shared.record("window-inventory: reconciled added=\(currentIDs.subtracting(previousIDs).count) removed=\(previousIDs.subtracting(currentIDs).count)")
            }

            let inventoryChanged = !inventoryIsEquivalent(windows, items)
            if inventoryChanged {
                windows = items
                hiddenWindowStore.reconcile(with: items)
                appendNewAppsToSwitcherSnapshot()
                reconcileCachedGroups()
                preserveSelectionOrSelectFirst()
                activityMonitor.update(windows: items)
            }
            thumbnailCapturedAt = thumbnailCapturedAt.filter { currentIDs.contains($0.key) }
            if showsGlobalLoading { isLoading = false }
            // Map only windows whose thumbnail is new, changed, missing, rejected, or stale.
            let appliedIDs = Set(items.map(\.id))
            return pairs.filter {
                appliedIDs.contains($0.0.id) && thumbnailRefreshIDs.contains($0.0.id)
            }
        } catch {
            logger.error("Window inventory reconciliation failed")
            SafeDiagnosticLog.shared.record("window-inventory: reconciliation failed")
            errorMessage = error.localizedDescription
            if showsGlobalLoading { isLoading = false }
            return nil
        }
    }

    private func inventoryIsEquivalent(_ lhs: [WindowItem], _ rhs: [WindowItem]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.id == right.id
                && left.processID == right.processID
                && left.appName == right.appName
                && left.bundleIdentifier == right.bundleIdentifier
                && left.title == right.title
                && left.frame == right.frame
                && left.isOnScreen == right.isOnScreen
                && left.lastSeen == right.lastSeen
                && left.thumbnailRevision == right.thumbnailRevision
                && left.safariTabs == right.safariTabs
        }
    }

    private func assignSafariTabs(_ tabs: [SafariTab], to items: inout [WindowItem]) {
        let safariWindows = items.indices.filter { items[$0].bundleIdentifier == "com.apple.Safari" }
        var unassignedTabs = tabs
        for index in safariWindows {
            if let current = unassignedTabs.first(where: { $0.isCurrent && $0.title == items[index].title }) {
                let matching = unassignedTabs.filter { $0.windowIndex == current.windowIndex }
                items[index].safariTabs = matching
                let ids = Set(matching.map(\.id))
                unassignedTabs.removeAll { ids.contains($0.id) }
            }
        }
        for index in safariWindows where items[index].safariTabs.isEmpty {
            guard let windowIndex = unassignedTabs.first?.windowIndex else { break }
            let matching = unassignedTabs.filter { $0.windowIndex == windowIndex }
            items[index].safariTabs = matching
            let ids = Set(matching.map(\.id))
            unassignedTabs.removeAll { ids.contains($0.id) }
        }
    }

    private func refreshThumbnails(for pairs: [(WindowItem, SCWindow)]) async {
        guard !isTerminating, !Task.isCancelled, !pairs.isEmpty else { return }
        let prioritizedPairs = pairs.sorted { left, right in
            if left.0.id == selectedWindowID { return true }
            if right.0.id == selectedWindowID { return false }
            return left.0.lastSeen ?? .distantPast > right.0.lastSeen ?? .distantPast
        }
        let ids = Set(prioritizedPairs.map { $0.0.id })
        refreshingThumbnailWindowIDs.formUnion(ids)
        thumbnailStatus = L10n.format("Analyzing %lld of %lld thumbnails…", 0, Int64(prioritizedPairs.count))

        var capturesByID: [CGWindowID: CapturedThumbnail] = [:]
        for (offset, pair) in prioritizedPairs.enumerated() {
            guard !isTerminating, !Task.isCancelled else { break }
            let (item, window) = pair
            guard windows.contains(where: { $0.id == item.id }) else {
                refreshingThumbnailWindowIDs.remove(item.id)
                continue
            }
            thumbnailStatus = L10n.format("Analyzing %lld of %lld thumbnails…", Int64(offset + 1), Int64(prioritizedPairs.count))
            // Yield so key events / scrolling can run between captures.
            await Task.yield()
            guard !isTerminating, !Task.isCancelled else { break }
            var capture = await thumbnails.image(for: window)
            if capture == nil, !isTerminating, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !isTerminating, !Task.isCancelled else { break }
                capture = await thumbnails.image(for: window)
            }
            refreshingThumbnailWindowIDs.remove(item.id)
            if let capture {
                logger.notice("Thumbnail result accepted=\(capture.isUsable) variance=\(capture.luminanceVariance, format: .fixed(precision: 1)) edges=\(capture.edgeRatio, format: .fixed(precision: 4)) coverage=\(capture.detailCoverage, format: .fixed(precision: 3))")
                capturesByID[item.id] = capture
            } else {
                logger.error("No thumbnail captured")
                SafeDiagnosticLog.shared.record("thumbnail-pipeline: no capture returned")
            }
        }

        if !capturesByID.isEmpty {
            var updatedWindows = windows
            for index in updatedWindows.indices {
                guard let capture = capturesByID[updatedWindows[index].id] else { continue }
                updatedWindows[index].thumbnail = capture.image
                updatedWindows[index].thumbnailIsUsable = capture.isUsable
                updatedWindows[index].thumbnailRevision += 1
                thumbnailCapturedAt[updatedWindows[index].id] = Date()
            }
            windows = updatedWindows
        }
        refreshingThumbnailWindowIDs.subtract(ids)
        let acceptedCount = windows.filter(\.thumbnailIsUsable).count
        logger.notice("Thumbnail refresh finished accepted=\(acceptedCount) total=\(pairs.count)")
        SafeDiagnosticLog.shared.record("thumbnail-pipeline: refresh finished accepted=\(acceptedCount) total=\(pairs.count)")
        thumbnailStatus = nil
    }

    func refreshAndRegenerateGroupsIfNeeded() async {
        await refresh(generateInitialGroups: false)
        guard taskGroups.isEmpty || groupsAreStale else {
            SafeDiagnosticLog.shared.record("grouping: idle regeneration skipped workspace unchanged")
            return
        }
        await refreshTaskGroups()
    }

    private func generateInitialGroupsIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !taskGroupCache.hasCache,
              !defaults.bool(forKey: Self.automaticGroupingAttemptedKey),
              hasConfiguredAIKey,
              windows.count >= 2 else { return }
        defaults.set(true, forKey: Self.automaticGroupingAttemptedKey)
        SafeDiagnosticLog.shared.record("grouping: automatic first-run generation started")
        await refreshTaskGroups()
    }

    func refreshWindows() async {
        guard !isGrouping, !isLoading else { return }
        await refresh(generateInitialGroups: false)
    }

    func refreshAndRegenerateGroups() async {
        guard !isGrouping, !isLoading else { return }
        let selection = selectionSnapshot()
        groupingStatus = L10n.string("Refreshing windows and Safari tabs…")
        await refresh(generateInitialGroups: false)
        await refreshTaskGroups()
        restoreSelection(from: selection)
    }

    func refreshTaskGroups() async {
        guard !isGrouping else { return }
        isGrouping = true
        groupingStatus = L10n.string("Preparing screenshots…")
        errorMessage = nil
        do {
            let credentials = try currentAICredentials()
            let generated = try await grouping.groups(
                for: windows.filter {
                    !hiddenWindowStore.isHidden($0)
                        && !aiExcludedAppStore.contains(bundleIdentifier: $0.bundleIdentifier)
                },
                events: await history.recentEvents().filter {
                    !excludedAppStore.contains(appName: $0.appName)
                        && !aiExcludedAppStore.contains(appName: $0.appName)
                },
                provider: credentials.provider,
                apiKey: credentials.apiKey,
                progress: { [weak self] status in self?.groupingStatus = status }
            )
            taskGroups = generated
            taskGroupCache.save(groups: generated, windows: windows)
            groupsGeneratedAt = taskGroupCache.generatedAt
            groupsAreStale = false
            if let selectedTaskGroupID,
               !generated.contains(where: { $0.id == selectedTaskGroupID }) {
                self.selectedTaskGroupID = nil
            }
            hasGeneratedGroups = true
        } catch {
            aiErrorMessage = error.localizedDescription
        }
        groupingStatus = nil
        isGrouping = false
    }

    func activate(_ window: WindowItem) { activator.activate(window) }

    func activate(_ tab: SafariTab) async {
        do { try await safari.activate(tab) } catch { errorMessage = error.localizedDescription }
    }

    private var hasConfiguredAIKey: Bool {
        switch AIProvider.current {
        case .openAI: openAIKeyStore.hasKey
        case .anthropic: anthropicKeyStore.hasKey
        }
    }

    private func currentAICredentials() throws -> (provider: AIProvider, apiKey: String) {
        let provider = AIProvider.current
        let keyStore = switch provider {
        case .openAI: openAIKeyStore
        case .anthropic: anthropicKeyStore
        }
        let apiKey = keyStore.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw TaskGroupingService.GroupingError.missingAPIKey
        }
        return (provider, apiKey)
    }
}
