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
    var liveThumbnailWindowID: CGWindowID?
    var liveThumbnail: NSImage?
    var isSwitcherMode = false
    private var hoveredSwitcherWindowID: CGWindowID?
    var searchFocusRequest = 0
    var actionChooserWindow: WindowItem?
    var actionChooserStage: WindowActionChooserStage?
    var actionChooserSelection = 0
    var keyboardColumnCount = 1
    var keyboardAppColumnCount = 1
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
    var openAIErrorMessage: String?

    private var hasPerformedInitialRefresh = false
    private var isPerformingInitialRefresh = false
    private var inventoryReconciliationTask: Task<Void, Never>?
    private var isReconcilingInventory = false
    private let catalog: WindowCatalog
    private let thumbnails: ThumbnailService
    private let safari: SafariTabService
    private let history: ActivityStore
    private let grouping: TaskGroupingService
    private let smartSearch = SmartSearchService()
    private let openAIKeyStore: OpenAIKeyStore
    private let excludedAppStore: ExcludedAppStore
    private let aiExcludedAppStore: AIExcludedAppStore
    private let activator: WindowActivator
    private let activityMonitor: ActivityMonitor
    private let liveThumbnails = LiveThumbnailService()
    private var liveThumbnailTask: Task<Void, Never>?
    private var liveThumbnailEnabled = false
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

    init(catalog: WindowCatalog, thumbnails: ThumbnailService, safari: SafariTabService, history: ActivityStore, grouping: TaskGroupingService, openAIKeyStore: OpenAIKeyStore, excludedAppStore: ExcludedAppStore, aiExcludedAppStore: AIExcludedAppStore, activator: WindowActivator, activityMonitor: ActivityMonitor) {
        let defaults = UserDefaults.standard
        let savedWidth = defaults.double(forKey: Self.thumbnailCardWidthKey)
        thumbnailCardWidth = savedWidth > 0 ? CGFloat(savedWidth) : Self.defaultThumbnailCardWidth
        viewMode = defaults.string(forKey: Self.viewModeKey).flatMap(BrowserViewMode.init(rawValue:)) ?? .grouped
        excludeHiddenWindows = defaults.object(forKey: Self.excludeHiddenWindowsKey) == nil
            ? true
            : defaults.bool(forKey: Self.excludeHiddenWindowsKey)
        self.catalog = catalog; self.thumbnails = thumbnails; self.safari = safari; self.history = history
        self.grouping = grouping; self.openAIKeyStore = openAIKeyStore; self.excludedAppStore = excludedAppStore; self.aiExcludedAppStore = aiExcludedAppStore; self.activator = activator; self.activityMonitor = activityMonitor
        hasGeneratedGroups = taskGroupCache.hasCache
        groupsGeneratedAt = taskGroupCache.generatedAt
    }

    var filteredWindows: [WindowItem] {
        _ = hiddenWindowsRevision
        let selectedWindowIDs = selectedTaskGroupID.flatMap { selectedID in
            taskGroups.first(where: { $0.id == selectedID }).map { Set($0.windowIDs) }
        }
        let eligibleWindows = windows.filter { item in
            let belongsToSelectedGroup = selectedWindowIDs?.contains(item.id) ?? true
            let includedByHiddenFilter = !excludeHiddenWindows || !hiddenWindowStore.isHidden(item)
            return belongsToSelectedGroup && includedByHiddenFilter
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
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else { return }
        var updatedWindows = windows
        updatedWindows[index].lastSeen = date
        windows = WindowItem.orderedByRecency(updatedWindows)
    }

    var recentAppWindows: [WindowItem] {
        _ = hiddenWindowsRevision
        return WindowItem.orderedByRecency(windows.filter { window in
            !excludeHiddenWindows || !hiddenWindowStore.isHidden(window)
        }).reduce(into: [WindowItem]()) { result, window in
            let appKey = window.bundleIdentifier ?? "pid:\(window.processID)"
            guard !result.contains(where: {
                ($0.bundleIdentifier ?? "pid:\($0.processID)") == appKey
            }) else { return }
            result.append(window)
        }
    }

    var windowSections: [BrowserWindowSection] {
        if smartSearchWindowIDs != nil {
            return [BrowserWindowSection(id: "smart-search", title: L10n.string("Smart Results"), windows: filteredWindows)]
        }
        guard viewMode == .grouped, !taskGroups.isEmpty else {
            return [BrowserWindowSection(id: "recent", title: nil, windows: filteredWindows)]
        }

        let visibleByID = Dictionary(uniqueKeysWithValues: filteredWindows.map { ($0.id, $0) })
        let rankedSections = taskGroups.compactMap { group -> BrowserWindowSection? in
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
        viewMode == .grouped && smartSearchWindowIDs == nil && !taskGroups.isEmpty
    }

    var orderedFilteredWindows: [WindowItem] {
        windowSections.flatMap(\.windows)
    }

    func setViewMode(_ mode: BrowserViewMode) {
        viewMode = mode
    }

    func performSmartSearch() async {
        guard !isSmartSearching else { return }
        isSmartSearching = true
        smartSearchStatus = L10n.string("Searching by meaning…")
        errorMessage = nil
        do {
            let resultIDs = try await smartSearch.search(
                query: query,
                windows: windows.filter {
                    (!hiddenWindowStore.isHidden($0) || !excludeHiddenWindows)
                        && !aiExcludedAppStore.contains(bundleIdentifier: $0.bundleIdentifier)
                },
                groups: taskGroups,
                apiKey: openAIKeyStore.apiKey
            )
            smartSearchWindowIDs = resultIDs
            smartSearchStatus = L10n.string(resultIDs.isEmpty ? "No smart results" : "Smart Results")
            selectFirstFilteredWindow()
            SafeDiagnosticLog.shared.record("smart-search: completed results=\(resultIDs.count)")
        } catch {
            smartSearchWindowIDs = nil
            smartSearchStatus = nil
            openAIErrorMessage = error.localizedDescription
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

    func showActionChooserForSelectedWindow() {
        guard let selectedWindow else { return }
        actionChooserWindow = selectedWindow
        actionChooserStage = .removal
        actionChooserSelection = 0
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
        if actionChooserStage == .exclusion {
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
    }

    private func closeWindow(_ window: WindowItem) {
        let started = activator.close(window) { [weak self] didClose in
            guard let self, didClose else { return }
            self.windows.removeAll { $0.id == window.id }
            self.reconcileCachedGroups()
            self.preserveSelectionOrSelectFirst()
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

    private func scheduleSelectedLiveThumbnail() {
        stopLiveThumbnail()
        guard liveThumbnailEnabled,
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

        let currentIndex = selectedAppWindowID.flatMap { id in
            representatives.firstIndex { $0.id == id }
        } ?? (direction > 0 ? -1 : 0)
        let targetIndex = (currentIndex + direction + representatives.count) % representatives.count
        selectedWindowID = nil
        selectedAppWindowID = representatives[targetIndex].id
    }

    func moveSelection(horizontal: Int = 0, vertical: Int = 0, columnCount: Int) {
        if selectedAppWindowID != nil {
            moveAppSelection(horizontal: horizontal, vertical: vertical)
            return
        }

        let visible = orderedFilteredWindows
        guard !visible.isEmpty else {
            selectedWindowID = nil
            return
        }
        if vertical < 0,
           let selectedWindowID,
           let selectedIndex = visible.firstIndex(where: { $0.id == selectedWindowID }),
           selectedIndex < max(columnCount, 1),
           !recentAppWindows.isEmpty {
            let targetIndex = min(selectedIndex, recentAppWindows.count - 1)
            self.selectedWindowID = nil
            selectedAppWindowID = recentAppWindows[targetIndex].id
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

    private func moveAppSelection(horizontal: Int, vertical: Int) {
        let apps = recentAppWindows
        guard !apps.isEmpty else {
            selectedAppWindowID = nil
            return
        }
        let columns = max(keyboardAppColumnCount, 1)
        let currentIndex = selectedAppWindowID.flatMap { id in apps.firstIndex { $0.id == id } } ?? 0
        if vertical > 0 {
            let targetIndex = currentIndex + columns
            if apps.indices.contains(targetIndex) {
                selectedAppWindowID = apps[targetIndex].id
            } else {
                let windows = orderedFilteredWindows
                guard !windows.isEmpty else { return }
                let windowIndex = min(currentIndex % columns, windows.count - 1)
                selectedAppWindowID = nil
                selectedWindowID = windows[windowIndex].id
            }
            return
        }
        if vertical < 0 {
            let targetIndex = currentIndex - columns
            if apps.indices.contains(targetIndex) { selectedAppWindowID = apps[targetIndex].id }
            return
        }
        let targetIndex = min(max(currentIndex + horizontal, 0), apps.count - 1)
        selectedAppWindowID = apps[targetIndex].id
    }

    private func moveSelectionVertically(_ direction: Int, columnCount: Int) -> Bool {
        let sections = windowSections
        guard let selectedWindowID,
              let sectionIndex = sections.firstIndex(where: { section in
                  section.windows.contains { $0.id == selectedWindowID }
              }),
              let itemIndex = sections[sectionIndex].windows.firstIndex(where: { $0.id == selectedWindowID }) else {
            return false
        }

        let columns = max(columnCount, 1)
        let targetInSection = itemIndex + direction * columns
        if sections[sectionIndex].windows.indices.contains(targetInSection) {
            self.selectedWindowID = sections[sectionIndex].windows[targetInSection].id
            return true
        }

        let adjacentSectionIndex = sectionIndex + direction
        guard sections.indices.contains(adjacentSectionIndex) else { return true }
        let column = itemIndex % columns
        let adjacentWindows = sections[adjacentSectionIndex].windows
        let targetIndex: Int
        if direction > 0 {
            targetIndex = min(column, adjacentWindows.count - 1)
        } else {
            let lastRowStart = ((adjacentWindows.count - 1) / columns) * columns
            targetIndex = min(lastRowStart + column, adjacentWindows.count - 1)
        }
        self.selectedWindowID = adjacentWindows[targetIndex].id
        return true
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
        if let selectedAppWindowID,
           let window = recentAppWindows.first(where: { $0.id == selectedAppWindowID }) {
            activate(window)
            return true
        }
        return activateSelectedWindow()
    }

    func beginSwitcherMode() {
        isSwitcherMode = true
        hoveredSwitcherWindowID = nil
    }

    func hoverWindowInSwitcherMode(_ windowID: CGWindowID?) {
        guard isSwitcherMode else { return }
        hoveredSwitcherWindowID = windowID
        if let windowID {
            selectedAppWindowID = nil
            selectedWindowID = windowID
        }
    }

    func hoverAppInSwitcherMode(_ windowID: CGWindowID?) {
        guard isSwitcherMode else { return }
        hoveredSwitcherWindowID = windowID
        if let windowID {
            selectedWindowID = nil
            selectedAppWindowID = windowID
        } else {
            selectedAppWindowID = nil
        }
    }

    @discardableResult
    func finishSwitcherMode() -> Bool {
        defer {
            isSwitcherMode = false
            hoveredSwitcherWindowID = nil
        }
        guard let hoveredSwitcherWindowID,
              let window = orderedFilteredWindows.first(where: { $0.id == hoveredSwitcherWindowID }) else {
            return false
        }
        activate(window)
        return true
    }

    func prepareForPresentation(selectedGroupID: String? = nil) {
        stopLiveThumbnail()
        selectedTaskGroupID = selectedGroupID
        selectedWindowID = nil
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
        guard hasPerformedInitialRefresh else {
            await performInitialRefreshIfNeeded()
            return
        }
        await refresh(generateInitialGroups: false, showsGlobalLoading: false)
    }

    func scheduleBackgroundInventoryReconciliation() {
        inventoryReconciliationTask?.cancel()
        inventoryReconciliationTask = Task { [weak self] in
            guard let self else { return }
            await self.reconcileInventory(includeSafariTabs: false, showsGlobalLoading: self.windows.isEmpty)
        }
    }

    func refresh(generateInitialGroups: Bool = true, showsGlobalLoading: Bool = true) async {
        logger.notice("Thumbnail refresh started")
        SafeDiagnosticLog.shared.record("thumbnail-pipeline: refresh started")
        if showsGlobalLoading { isLoading = true }
        errorMessage = nil
        guard let pairs = await reconcileInventory(includeSafariTabs: true, showsGlobalLoading: showsGlobalLoading) else {
            isLoading = false
            return
        }

        isLoading = false
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
        guard !isReconcilingInventory else { return nil }
        isReconcilingInventory = true
        defer { isReconcilingInventory = false }
        do {
            let seen = await history.lastSeen()
            let pairs = try await catalog.windows(lastSeen: seen)
            logger.notice("Window catalog returned \(pairs.count) capture candidates")
            var items = pairs.map(\.0)

            if includeSafariTabs {
                do {
                    let tabs = try await safari.listTabs()
                    assignSafariTabs(tabs, to: &items)
                } catch {
                    errorMessage = L10n.format("Safari tabs are unavailable: %@", error.localizedDescription)
                    SafeDiagnosticLog.shared.record("safari-tabs: enumeration failed")
                }
            }

            let previousByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
            for index in items.indices {
                if let previous = previousByID[items[index].id] {
                    items[index].lastSeen = [previous.lastSeen, items[index].lastSeen].compactMap { $0 }.max()
                    items[index].thumbnail = previous.thumbnail
                    items[index].thumbnailIsUsable = previous.thumbnailIsUsable
                    items[index].thumbnailRevision = previous.thumbnailRevision
                    if !includeSafariTabs { items[index].safariTabs = previous.safariTabs }
                } else if let activationDate = activityMonitor.recentActivationDate(for: items[index].processID) {
                    items[index].lastSeen = activationDate
                }
            }
            items = WindowItem.orderedByRecency(items)

            let previousIDs = Set(windows.map(\.id))
            let currentIDs = Set(items.map(\.id))
            if previousIDs != currentIDs {
                SafeDiagnosticLog.shared.record("window-inventory: reconciled added=\(currentIDs.subtracting(previousIDs).count) removed=\(previousIDs.subtracting(currentIDs).count)")
            }

            windows = items
            hiddenWindowStore.reconcile(with: items)
            reconcileCachedGroups()
            preserveSelectionOrSelectFirst()
            activityMonitor.update(windows: items)
            if showsGlobalLoading { isLoading = false }
            return pairs
        } catch {
            logger.error("Window inventory reconciliation failed")
            SafeDiagnosticLog.shared.record("window-inventory: reconciliation failed")
            errorMessage = error.localizedDescription
            if showsGlobalLoading { isLoading = false }
            return nil
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
        let prioritizedPairs = pairs.sorted { left, right in
            if left.0.id == selectedWindowID { return true }
            if right.0.id == selectedWindowID { return false }
            return left.0.lastSeen ?? .distantPast > right.0.lastSeen ?? .distantPast
        }
        let ids = Set(prioritizedPairs.map { $0.0.id })
        refreshingThumbnailWindowIDs.formUnion(ids)
        thumbnailStatus = L10n.format("Analyzing %lld of %lld thumbnails…", 0, Int64(prioritizedPairs.count))

        for (offset, pair) in prioritizedPairs.enumerated() {
            guard !Task.isCancelled else { break }
            let (item, window) = pair
            guard windows.contains(where: { $0.id == item.id }) else {
                refreshingThumbnailWindowIDs.remove(item.id)
                continue
            }
            thumbnailStatus = L10n.format("Analyzing %lld of %lld thumbnails…", Int64(offset + 1), Int64(prioritizedPairs.count))
            var capture = await thumbnails.image(for: window)
            if capture == nil {
                try? await Task.sleep(for: .milliseconds(250))
                capture = await thumbnails.image(for: window)
            }
            refreshingThumbnailWindowIDs.remove(item.id)
            if let capture, let index = windows.firstIndex(where: { $0.id == item.id }) {
                logger.notice("Thumbnail result accepted=\(capture.isUsable) variance=\(capture.luminanceVariance, format: .fixed(precision: 1)) edges=\(capture.edgeRatio, format: .fixed(precision: 4)) coverage=\(capture.detailCoverage, format: .fixed(precision: 3))")
                var updatedWindows = windows
                updatedWindows[index].thumbnail = capture.image
                updatedWindows[index].thumbnailIsUsable = capture.isUsable
                updatedWindows[index].thumbnailRevision += 1
                windows = updatedWindows
            } else if capture == nil {
                logger.error("No thumbnail captured")
                SafeDiagnosticLog.shared.record("thumbnail-pipeline: no capture returned")
            }
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
              openAIKeyStore.hasKey,
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
        groupingStatus = L10n.string("Refreshing windows and Safari tabs…")
        await refresh(generateInitialGroups: false)
        await refreshTaskGroups()
    }

    func refreshTaskGroups() async {
        guard !isGrouping else { return }
        isGrouping = true
        groupingStatus = L10n.string("Preparing screenshots…")
        errorMessage = nil
        do {
            let generated = try await grouping.groups(
                for: windows.filter {
                    !hiddenWindowStore.isHidden($0)
                        && !aiExcludedAppStore.contains(bundleIdentifier: $0.bundleIdentifier)
                },
                events: await history.recentEvents().filter {
                    !excludedAppStore.contains(appName: $0.appName)
                        && !aiExcludedAppStore.contains(appName: $0.appName)
                },
                apiKey: openAIKeyStore.apiKey,
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
            openAIErrorMessage = error.localizedDescription
        }
        groupingStatus = nil
        isGrouping = false
    }

    func activate(_ window: WindowItem) { activator.activate(window) }

    func activate(_ tab: SafariTab) async {
        do { try await safari.activate(tab) } catch { errorMessage = error.localizedDescription }
    }
}
