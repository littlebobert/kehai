import AppKit
import OSLog
import ScreenCaptureKit

@MainActor
@Observable
final class OverviewViewModel {
    private let logger = Logger(subsystem: "com.justin.Kehai", category: "ThumbnailPipeline")

    var windows: [WindowItem] = []
    var taskGroups: [TaskGroup] = []
    var selectedTaskGroupID: String?
    var selectedWindowID: CGWindowID? {
        didSet {
            guard selectedWindowID != oldValue else { return }
            scheduleLiveThumbnail()
        }
    }
    var liveThumbnailWindowID: CGWindowID?
    var liveThumbnail: NSImage?
    var searchFocusRequest = 0
    var keyboardColumnCount = 1
    var hiddenWindowsRevision = 0
    var thumbnailCardWidth: CGFloat {
        didSet { UserDefaults.standard.set(Double(thumbnailCardWidth), forKey: Self.thumbnailCardWidthKey) }
    }
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            preserveSelectionOrSelectFirst()
        }
    }
    var isLoading = true
    var isGrouping = false
    var groupingStatus: String?
    var hasGeneratedGroups = false
    var groupsAreStale = false
    var excludeHiddenWindows: Bool {
        didSet {
            UserDefaults.standard.set(excludeHiddenWindows, forKey: Self.excludeHiddenWindowsKey)
            preserveSelectionOrSelectFirst()
        }
    }
    var thumbnailStatus: String?
    var errorMessage: String?

    private let catalog: WindowCatalog
    private let thumbnails: ThumbnailService
    private let safari: SafariTabService
    private let history: ActivityStore
    private let grouping: TaskGroupingService
    private let openAIKeyStore: OpenAIKeyStore
    private let excludedAppStore: ExcludedAppStore
    private let activator: WindowActivator
    private let activityMonitor: ActivityMonitor
    private let liveThumbnails = LiveThumbnailService()
    private var liveThumbnailTask: Task<Void, Never>?
    private let taskGroupCache = TaskGroupCache()
    private let hiddenWindowStore = HiddenWindowStore()
    private static let excludeHiddenWindowsKey = "overview.excludeHiddenWindows"
    private static let thumbnailCardWidthKey = "overview.thumbnailCardWidth"
    private static let defaultThumbnailCardWidth: CGFloat = 280
    private static let minimumThumbnailCardWidth: CGFloat = 200
    private static let maximumThumbnailCardWidth: CGFloat = 440

    init(catalog: WindowCatalog, thumbnails: ThumbnailService, safari: SafariTabService, history: ActivityStore, grouping: TaskGroupingService, openAIKeyStore: OpenAIKeyStore, excludedAppStore: ExcludedAppStore, activator: WindowActivator, activityMonitor: ActivityMonitor) {
        let defaults = UserDefaults.standard
        let savedWidth = defaults.double(forKey: Self.thumbnailCardWidthKey)
        thumbnailCardWidth = savedWidth > 0 ? CGFloat(savedWidth) : Self.defaultThumbnailCardWidth
        excludeHiddenWindows = defaults.object(forKey: Self.excludeHiddenWindowsKey) == nil
            ? true
            : defaults.bool(forKey: Self.excludeHiddenWindowsKey)
        self.catalog = catalog; self.thumbnails = thumbnails; self.safari = safari; self.history = history
        self.grouping = grouping; self.openAIKeyStore = openAIKeyStore; self.excludedAppStore = excludedAppStore; self.activator = activator; self.activityMonitor = activityMonitor
        hasGeneratedGroups = taskGroupCache.hasCache
    }

    var filteredWindows: [WindowItem] {
        _ = hiddenWindowsRevision
        let selectedWindowIDs = selectedTaskGroupID.flatMap { selectedID in
            taskGroups.first(where: { $0.id == selectedID }).map { Set($0.windowIDs) }
        }
        let matchingWindows = windows.filter { item in
            let belongsToSelectedGroup = selectedWindowIDs?.contains(item.id) ?? true
            let includedByHiddenFilter = !excludeHiddenWindows || !hiddenWindowStore.isHidden(item)
            let matchesQuery = query.isEmpty
                || item.title.localizedCaseInsensitiveContains(query)
                || item.appName.localizedCaseInsensitiveContains(query)
                || item.safariTabs.contains { $0.title.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query) }
            return belongsToSelectedGroup && includedByHiddenFilter && matchesQuery
        }
        return WindowItem.orderedByRecency(matchingWindows)
    }

    var orderedFilteredWindows: [WindowItem] {
        filteredWindows.filter { !$0.isDusty } + filteredWindows.filter(\.isDusty)
    }

    func selectTaskGroup(_ group: TaskGroup?) {
        selectedTaskGroupID = group?.id
        selectFirstFilteredWindow()
    }

    func selectFirstFilteredWindow() {
        selectedWindowID = orderedFilteredWindows.first?.id
    }

    private func preserveSelectionOrSelectFirst() {
        if let selectedWindowID,
           orderedFilteredWindows.contains(where: { $0.id == selectedWindowID }) {
            return
        }
        selectFirstFilteredWindow()
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

    func isWindowHidden(_ window: WindowItem) -> Bool {
        hiddenWindowStore.isHidden(window)
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

    func stopLiveThumbnail() {
        liveThumbnailTask?.cancel()
        liveThumbnailTask = nil
        liveThumbnailWindowID = nil
        liveThumbnail = nil
        Task { await liveThumbnails.stop() }
    }

    private func scheduleLiveThumbnail() {
        liveThumbnailTask?.cancel()
        liveThumbnailTask = nil
        liveThumbnailWindowID = nil
        liveThumbnail = nil
        Task { await liveThumbnails.stop() }

        guard let selectedWindowID,
              let window = windows.first(where: { $0.id == selectedWindowID }),
              window.thumbnailIsUsable else { return }

        liveThumbnailTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(220))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.selectedWindowID == selectedWindowID else { return }
            await self.liveThumbnails.start(
                windowID: selectedWindowID,
                maximumSize: CGSize(width: 880, height: 550)
            ) { [weak self] image in
                guard let self, self.selectedWindowID == selectedWindowID else { return }
                self.liveThumbnailWindowID = selectedWindowID
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

    func moveSelection(horizontal: Int = 0, vertical: Int = 0, columnCount: Int) {
        let visible = orderedFilteredWindows
        guard !visible.isEmpty else {
            selectedWindowID = nil
            return
        }
        let currentIndex = selectedWindowID.flatMap { id in visible.firstIndex(where: { $0.id == id }) } ?? 0
        let stride = max(columnCount, 1)
        let targetIndex: Int
        if horizontal != 0 {
            targetIndex = min(max(currentIndex + horizontal, 0), visible.count - 1)
        } else {
            targetIndex = min(max(currentIndex + vertical * stride, 0), visible.count - 1)
        }
        selectedWindowID = visible[targetIndex].id
    }

    @discardableResult
    func activateSelectedWindow() -> Bool {
        guard let selectedWindowID,
              let window = orderedFilteredWindows.first(where: { $0.id == selectedWindowID }) else { return false }
        activate(window)
        return true
    }

    func prepareForPresentation(selectedGroupID: String? = nil) {
        stopLiveThumbnail()
        selectedTaskGroupID = selectedGroupID
        selectedWindowID = nil
        isGrouping = false
        isLoading = true
        errorMessage = nil
    }

    func refresh() async {
        logger.notice("Thumbnail refresh started")
        SafeDiagnosticLog.shared.record("thumbnail-pipeline: refresh started")
        isLoading = true; errorMessage = nil
        do {
            let seen = await history.lastSeen()
            let pairs = try await catalog.windows(lastSeen: seen)
            logger.notice("Window catalog returned \(pairs.count) capture candidates")
            let tabs = (try? await safari.listTabs()) ?? []
            var items = pairs.map { $0.0 }
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
            windows = items
            hiddenWindowStore.reconcile(with: items)
            reconcileCachedGroups()
            selectFirstFilteredWindow()
            isLoading = false
            thumbnailStatus = "Analyzing 0 of \(pairs.count) thumbnails…"
            activityMonitor.update(windows: items)
            for (offset, pair) in pairs.enumerated() {
                let (item, window) = pair
                thumbnailStatus = "Analyzing \(offset + 1) of \(pairs.count) thumbnails…"
                var capture = await thumbnails.image(for: window)
                if capture == nil {
                    try? await Task.sleep(for: .milliseconds(250))
                    capture = await thumbnails.image(for: window)
                }
                if let capture, let index = windows.firstIndex(where: { $0.id == item.id }) {
                    logger.notice("Thumbnail result accepted=\(capture.isUsable) variance=\(capture.luminanceVariance, format: .fixed(precision: 1)) edges=\(capture.edgeRatio, format: .fixed(precision: 4)) coverage=\(capture.detailCoverage, format: .fixed(precision: 3))")
                    var updatedWindows = windows
                    updatedWindows[index].thumbnail = capture.image
                    updatedWindows[index].thumbnailIsUsable = capture.isUsable
                    updatedWindows[index].thumbnailRevision += 1
                    windows = updatedWindows
                    if selectedWindowID == item.id { scheduleLiveThumbnail() }
                } else if capture == nil {
                    logger.error("No thumbnail captured")
                    SafeDiagnosticLog.shared.record("thumbnail-pipeline: no capture returned")
                } else {
                    logger.error("Captured thumbnail no longer has a matching window")
                }
            }
            let acceptedCount = windows.filter(\.thumbnailIsUsable).count
            logger.notice("Thumbnail refresh finished accepted=\(acceptedCount) total=\(pairs.count)")
            SafeDiagnosticLog.shared.record("thumbnail-pipeline: refresh finished accepted=\(acceptedCount) total=\(pairs.count)")
            thumbnailStatus = nil
            isLoading = false
        } catch {
            logger.error("Thumbnail refresh failed")
            SafeDiagnosticLog.shared.record("thumbnail-pipeline: refresh failed")
            thumbnailStatus = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func refreshTaskGroups() async {
        guard !isGrouping else { return }
        isGrouping = true
        groupingStatus = "Preparing screenshots…"
        errorMessage = nil
        do {
            let generated = try await grouping.groups(
                for: windows.filter { !hiddenWindowStore.isHidden($0) },
                events: await history.recentEvents().filter { !excludedAppStore.contains(appName: $0.appName) },
                apiKey: openAIKeyStore.apiKey,
                progress: { [weak self] status in self?.groupingStatus = status }
            )
            taskGroups = generated
            taskGroupCache.save(groups: generated, windows: windows)
            groupsAreStale = false
            if let selectedTaskGroupID,
               !generated.contains(where: { $0.id == selectedTaskGroupID }) {
                self.selectedTaskGroupID = nil
            }
            hasGeneratedGroups = true
        } catch {
            errorMessage = error.localizedDescription
        }
        groupingStatus = nil
        isGrouping = false
    }

    func activate(_ window: WindowItem) { activator.activate(window) }

    func activate(_ tab: SafariTab) async {
        do { try await safari.activate(tab) } catch { errorMessage = error.localizedDescription }
    }
}
