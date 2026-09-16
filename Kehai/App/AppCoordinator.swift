import AppKit
import Carbon
import Observation

@MainActor
@Observable
final class BrowserPresentationState {
    private(set) var isFullBrowserVisible = false
    private(set) var isMiniBrowserVisible = false

    func update(fullBrowserVisible: Bool, miniBrowserVisible: Bool) {
        isFullBrowserVisible = fullBrowserVisible
        isMiniBrowserVisible = miniBrowserVisible
    }
}

@MainActor
final class AppCoordinator: NSObject, NSMenuItemValidation {
    let permissionManager = PermissionManager()
    let safari = SafariTabService()
    private let history = ActivityStore(loadsStoredEvents: false)
    let openAIKeyStore = APIKeyStore.openAI(loadsStoredKey: false)
    let anthropicKeyStore = APIKeyStore.anthropic(loadsStoredKey: false)
    let githubRepositoryStore = GitHubRepositoryStore(
        keyStore: .github(loadsStoredKey: false),
        loadsStoredState: false
    )
    let githubRefreshSettings = GitHubRefreshSettings()
    let excludedAppStore = ExcludedAppStore()
    let aiExcludedAppStore = AIExcludedAppStore()
    let autoUpdates = AutoUpdateService()
    let appearanceSettings = AppearanceSettings()
    let idleGroupingSettings = IdleGroupingSettings()
    let hotCornerSettings = HotCornerSettings()
    let browserPresentationState = BrowserPresentationState()
    private lazy var activityMonitor = ActivityMonitor(store: history)
    private lazy var dockBadgeMonitor: DockBadgeMonitor = {
        let monitor = DockBadgeMonitor()
        monitor.changed = { [weak self] snapshot in
            self?.viewModel.updateAppBadges(snapshot)
        }
        return monitor
    }()
    private lazy var viewModel = OverviewViewModel(
        catalog: WindowCatalog(excludedApps: excludedAppStore),
        thumbnails: ThumbnailService(),
        safari: safari,
        history: history,
        grouping: TaskGroupingService(),
        openAIKeyStore: openAIKeyStore,
        anthropicKeyStore: anthropicKeyStore,
        excludedAppStore: excludedAppStore,
        aiExcludedAppStore: aiExcludedAppStore,
        githubRepositoryStore: githubRepositoryStore,
        activator: WindowActivator(),
        activityMonitor: activityMonitor
    )
    private lazy var windowInventoryMonitor = WindowInventoryMonitor(
        changed: { [weak self] in
            self?.viewModel.scheduleBackgroundInventoryReconciliation()
        },
        focusedWindowChanged: { [weak self] processID in
            Task { await self?.activityMonitor.recordFocusedWindow(processID: processID) }
        }
    )
    private lazy var panelController = OverviewPanelController(
        model: viewModel,
        appearance: appearanceSettings,
        isShortcutSessionActive: { [weak self] in self?.isShortcutSessionActive == true },
        shortcutKeyCode: { [weak self] in UInt16(self?.shortcutSettings.keyCode ?? 0) },
        shortcutModifierFlags: { [weak self] in self?.shortcutModifierFlags ?? [] },
        presentationChanged: { [weak self] fullBrowserVisible, miniBrowserVisible in
            guard let self else { return }
            self.browserPresentationState.update(
                fullBrowserVisible: fullBrowserVisible,
                miniBrowserVisible: miniBrowserVisible
            )
            self.dockBadgeMonitor.setActive(fullBrowserVisible || miniBrowserVisible)
        }
    )
    let shortcutSettings = ShortcutSettings()
    private lazy var onboardingController = OnboardingWindowController(
        permissionManager: permissionManager,
        safariService: safari,
        openAIKeyStore: openAIKeyStore,
        anthropicKeyStore: anthropicKeyStore,
        githubRepositoryStore: githubRepositoryStore,
        proceed: { [weak self] in self?.panelController.show() }
    )
    private lazy var hotKey = GlobalHotKey(
        pressed: { [weak self] in
            SafeDiagnosticLog.shared.record("shortcut: hotkey pressed")
            self?.beginSwitcherMode()
        },
        released: { [weak self] in
            SafeDiagnosticLog.shared.record("shortcut: hotkey released")
            self?.shortcutKeyReleased()
        }
    )
    private let diagnosticReports = DiagnosticReportService()
    private lazy var aboutController = AboutWindowController(
        reportBug: { [weak self] in self?.reportBug() }
    )
    private lazy var settingsController = SettingsWindowController(
        shortcut: shortcutSettings,
        idleGrouping: idleGroupingSettings,
        hotCorner: hotCornerSettings,
        excludedApps: excludedAppStore,
        aiExcludedApps: aiExcludedAppStore,
        permissionManager: permissionManager,
        openAIKeyStore: openAIKeyStore,
        anthropicKeyStore: anthropicKeyStore,
        githubRepositoryStore: githubRepositoryStore,
        githubRefreshSettings: githubRefreshSettings,
        safariService: safari,
        shortcutChanged: { [weak self] in self?.registerHotKey() },
        idleGroupingChanged: { [weak self] in self?.updateIdleGroupingMonitoring() },
        hotCornerChanged: { [weak self] in self?.updateHotCornerMonitoring() },
        githubRefreshIntervalChanged: { [weak self] in self?.updateGitHubRefreshMonitoring() },
        exclusionsChanged: { [weak self] in
            Task { await self?.viewModel.refresh() }
        }
    )
    private static let hotCornerPollingInterval: TimeInterval = 0.1
    private static let hotCornerDwellDuration: TimeInterval = 0.1
    private static let hotCornerTolerance: CGFloat = 5

    private var activationObserver: NSObjectProtocol?
    private var idleTimer: Timer?
    private var hotCornerTimer: Timer?
    private var githubRefreshTimer: Timer?
    private var hotCornerEntryDate: Date?
    private var hotCornerIsArmed = true
    private var handledCurrentIdlePeriod = false
    private var suppressNextActivationPresentation = false
    private var modifierMonitors: [Any] = []
    private var shortcutNavigationMonitors: [Any] = []
    private var shortcutPointerMonitors: [Any] = []
    private var isShortcutSessionActive = false
    private var shortcutPresentationTask: Task<Void, Never>?
    private var hasStartedServices = false
    private var deferredStartupTask: Task<Void, Never>?
    private lazy var installationLocationController = InstallationLocationWindowController { [weak self] in
        self?.startServices()
    }

    func start() {
        if InstallationLocationWindowController.shouldOfferMove {
            installationLocationController.present()
        } else {
            startServices()
        }
    }

    private func startServices() {
        guard !hasStartedServices else { return }
        hasStartedServices = true
        permissionManager.refresh()
        registerHotKey()
        activityMonitor.setWindowFocusedHandler { [weak self] windowID, date in
            self?.viewModel.recordWindowFocus(windowID: windowID, at: date)
        }
        activityMonitor.start()
        windowInventoryMonitor.start()
        updateIdleGroupingMonitoring()
        updateHotCornerMonitoring()
        updateGitHubRefreshMonitoring()
        startDeferredServices()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applicationDidBecomeActive() }
        }
        if !permissionManager.hasCorePermissions {
            DispatchQueue.main.async { [weak self] in self?.showSettings() }
        }
    }

    func prepareForTermination() {
        guard hasStartedServices else { return }
        hasStartedServices = false
        deferredStartupTask?.cancel()
        deferredStartupTask = nil
        hotKey.unregister()
        shortcutPresentationTask?.cancel()
        shortcutPresentationTask = nil
        isShortcutSessionActive = false
        removeModifierMonitor()
        removeShortcutNavigationMonitor()
        removeShortcutPointerMonitor()
        idleTimer?.invalidate()
        idleTimer = nil
        hotCornerTimer?.invalidate()
        hotCornerTimer = nil
        hotCornerEntryDate = nil
        hotCornerIsArmed = true
        githubRefreshTimer?.invalidate()
        githubRefreshTimer = nil
        activityMonitor.stop()
        windowInventoryMonitor.stop()
        dockBadgeMonitor.setActive(false)
        viewModel.prepareForTermination()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    private func startDeferredServices() {
        deferredStartupTask?.cancel()
        deferredStartupTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }

            async let hydrateOpenAI: Void = self.openAIKeyStore.hydrate()
            async let hydrateAnthropic: Void = self.anthropicKeyStore.hydrate()
            async let hydrateGitHub: Void = self.githubRepositoryStore.hydrate()
            async let hydrateHistory: Void = self.history.hydrate()
            _ = await (hydrateOpenAI, hydrateAnthropic, hydrateGitHub, hydrateHistory)
            guard !Task.isCancelled else { return }

            self.autoUpdates.start()
            if self.githubRepositoryStore.hasSavedTokens {
                await self.githubRepositoryStore.refreshAll()
            }
        }
    }

    func finishTermination() async {
        await viewModel.finishTermination()
    }

    private func beginSwitcherMode() {
        if isShortcutSessionActive {
            let direction = NSEvent.modifierFlags.contains(.shift) ? -1 : 1
            SafeDiagnosticLog.shared.record("shortcut: repeated press cycling direction=\(direction)")
            viewModel.cycleSelectionByApp(direction)
            presentShortcutSwitcherIfNeeded()
            return
        }

        permissionManager.refresh()
        guard permissionManager.hasCorePermissions else {
            showSettings()
            return
        }
        let previousApplicationProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        SafeDiagnosticLog.shared.record(
            "shortcut: session begin frontmost-known=\(previousApplicationProcessID != nil)"
        )
        isShortcutSessionActive = true
        installModifierMonitor()
        installShortcutNavigationMonitor()
        installShortcutPointerMonitor()
        panelController.prepareSwitcherMode(previousApplicationProcessID: previousApplicationProcessID)
        scheduleShortcutSwitcherPresentation()
    }

    private func scheduleShortcutSwitcherPresentation() {
        shortcutPresentationTask?.cancel()
        shortcutPresentationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            guard let self, self.isShortcutSessionActive else { return }
            self.shortcutPresentationTask = nil
            SafeDiagnosticLog.shared.record("shortcut: hold threshold reached")
            self.presentShortcutSwitcherIfNeeded()
        }
    }

    private func presentShortcutSwitcherIfNeeded() {
        shortcutPresentationTask?.cancel()
        shortcutPresentationTask = nil
        removeShortcutNavigationMonitor()
        removeShortcutPointerMonitor()
        guard isShortcutSessionActive, !panelController.isMiniBrowserVisible else { return }
        SafeDiagnosticLog.shared.record("shortcut: presenting mini UI")
        if !NSApp.isActive, !panelController.isVisible {
            suppressNextActivationPresentation = true
        }
        panelController.showPreparedSwitcher()
    }

    private func shortcutKeyReleased() {
        guard isShortcutSessionActive else {
            SafeDiagnosticLog.shared.record("shortcut: release ignored no session")
            return
        }
        let usesCommandAnchor = shortcutModifierFlags.contains(.command)
        let commandIsHeld = NSEvent.modifierFlags.contains(.command)
        let shouldFinish = usesCommandAnchor
            ? !commandIsHeld
            : (!panelController.isMiniBrowserVisible || shortcutModifierFlags.isEmpty)
        SafeDiagnosticLog.shared.record(
            "shortcut: release mini-visible=\(panelController.isMiniBrowserVisible) "
                + "command-held=\(commandIsHeld) finish=\(shouldFinish)"
        )
        if shouldFinish {
            finishSwitcherMode()
        }
    }

    private func finishSwitcherMode() {
        guard isShortcutSessionActive else { return }
        shortcutPresentationTask?.cancel()
        shortcutPresentationTask = nil
        isShortcutSessionActive = false
        removeModifierMonitor()
        removeShortcutNavigationMonitor()
        removeShortcutPointerMonitor()
        let activated = panelController.finishSwitcherMode()
        SafeDiagnosticLog.shared.record("shortcut: session finish activated=\(activated)")
    }

    private var shortcutModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        let modifiers = shortcutSettings.modifiers
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }

    private func installModifierMonitor() {
        removeModifierMonitor()
        let requiredFlags = shortcutModifierFlags
        guard !requiredFlags.isEmpty else { return }
        let sessionAnchorFlags: NSEvent.ModifierFlags = requiredFlags.contains(.command)
            ? .command
            : requiredFlags
        // Command anchors the session like macOS Command-Tab. The user may release
        // the shortcut letter and every other modifier while continuing to browse.
        let handleFlags: (NSEvent) -> Void = { [weak self] event in
            let heldFlags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if heldFlags.intersection(sessionAnchorFlags).isEmpty {
                Task { @MainActor [weak self] in self?.finishSwitcherMode() }
            }
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handleFlags) {
            modifierMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            handleFlags(event)
            return event
        }) {
            modifierMonitors.append(monitor)
        }
    }

    private func removeModifierMonitor() {
        for monitor in modifierMonitors {
            NSEvent.removeMonitor(monitor)
        }
        modifierMonitors.removeAll()
    }

    private func installShortcutNavigationMonitor() {
        removeShortcutNavigationMonitor()
        let navigate: (NSEvent) -> Void = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self,
                      self.isShortcutSessionActive,
                      !self.panelController.isMiniBrowserVisible,
                      event.keyCode == UInt16(self.shortcutSettings.keyCode) else { return }
                let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                guard modifiers.contains(.command),
                      !modifiers.contains(.option),
                      !modifiers.contains(.control),
                      modifiers != self.shortcutModifierFlags else { return }
                let direction = modifiers.contains(.shift) ? -1 : 1
                self.viewModel.cycleSelectionByApp(direction)
                SafeDiagnosticLog.shared.record("shortcut: pre-presentation cycle direction=\(direction)")
                self.presentShortcutSwitcherIfNeeded()
            }
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: navigate) {
            shortcutNavigationMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            navigate(event)
            return event
        }) {
            shortcutNavigationMonitors.append(monitor)
        }
    }

    private func removeShortcutNavigationMonitor() {
        for monitor in shortcutNavigationMonitors {
            NSEvent.removeMonitor(monitor)
        }
        shortcutNavigationMonitors.removeAll()
    }

    private func installShortcutPointerMonitor() {
        removeShortcutPointerMonitor()
        let reveal: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.isShortcutSessionActive,
                      !self.panelController.isMiniBrowserVisible else { return }
                SafeDiagnosticLog.shared.record("shortcut: pointer movement revealed mini UI")
                self.presentShortcutSwitcherIfNeeded()
            }
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: reveal) {
            shortcutPointerMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in
            reveal(event)
            return event
        }) {
            shortcutPointerMonitors.append(monitor)
        }
    }

    private func removeShortcutPointerMonitor() {
        for monitor in shortcutPointerMonitors {
            NSEvent.removeMonitor(monitor)
        }
        shortcutPointerMonitors.removeAll()
    }

    func dockMenu() -> NSMenu? {
        guard permissionManager.hasCorePermissions, !viewModel.taskGroups.isEmpty else { return nil }
        let menu = NSMenu(title: L10n.string("Task Groups"))
        for group in viewModel.taskGroups {
            let item = NSMenuItem(title: group.name, action: #selector(showDockGroup(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = group.id
            menu.addItem(item)
        }
        return menu
    }

    @objc private func showDockGroup(_ sender: NSMenuItem) {
        guard let groupID = sender.representedObject as? String else { return }
        NSApp.activate(ignoringOtherApps: true)
        panelController.show(selectedGroupID: groupID)
    }

    func handleDockReopen() {
        permissionManager.refresh()
        if permissionManager.hasCorePermissions {
            panelController.show()
        } else {
            onboardingController.present()
        }
    }

    private func applicationDidBecomeActive() {
        if suppressNextActivationPresentation {
            suppressNextActivationPresentation = false
            return
        }
        permissionManager.refresh()
        if !permissionManager.hasCorePermissions {
            if onboardingController.window?.isVisible != true {
                onboardingController.present()
            }
        } else if onboardingController.window?.isVisible != true,
                  settingsController.window?.isVisible != true,
                  !panelController.isVisible {
            panelController.show()
        }
    }

    @objc func showAbout() {
        aboutController.present()
    }

    @objc func checkForUpdates() {
        autoUpdates.checkForUpdates()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates) {
            return autoUpdates.canCheckForUpdates
        }
        return true
    }

    var canGroupByTask: Bool { viewModel.viewMode != .grouped }
    var canSortAllByRecent: Bool { viewModel.viewMode != .recent }

    private func reportBug() {
        permissionManager.refresh()
        let snapshot = DiagnosticSnapshot(
            windowCount: viewModel.windows.count,
            usableThumbnailCount: viewModel.windows.filter(\.thumbnailIsUsable).count,
            groupCount: viewModel.taskGroups.count,
            excludedAppCount: excludedAppStore.apps.count,
            screenCaptureGranted: permissionManager.screenCaptureGranted,
            accessibilityGranted: permissionManager.accessibilityGranted,
            safariAutomationStatus: permissionManager.safariAutomationStatus,
            isLoading: viewModel.isLoading,
            isGrouping: viewModel.isGrouping
        )
        do {
            try diagnosticReports.draftBugReport(snapshot: snapshot)
            SafeDiagnosticLog.shared.record("bug-report: email draft requested")
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.string("Could Not Draft Bug Report")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func showPreferences() {
        settingsController.present()
    }

    @objc private func showSettings() {
        permissionManager.refresh()
        onboardingController.present()
    }

    func registerHotKey() {
        let status = hotKey.register(keyCode: shortcutSettings.keyCode, modifiers: shortcutSettings.modifiers)
        if status == noErr {
            shortcutSettings.registrationError = nil
            SafeDiagnosticLog.shared.record("global-hotkey: registered")
        } else {
            shortcutSettings.registrationError = L10n.string("This shortcut is unavailable. It may already be used by macOS or another app.")
            SafeDiagnosticLog.shared.record("global-hotkey: registration failed status=\(status)")
        }
    }

    func refreshBrowser() {
        Task { await viewModel.refresh() }
    }

    private var hasConfiguredAIKey: Bool {
        switch AIProvider.current {
        case .openAI: openAIKeyStore.hasKey
        case .anthropic: anthropicKeyStore.hasKey
        }
    }

    func updateIdleGroupingMonitoring() {
        idleTimer?.invalidate()
        idleTimer = nil
        handledCurrentIdlePeriod = false
        guard idleGroupingSettings.isEnabled else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkIdleGrouping() }
        }
        checkIdleGrouping()
    }

    func updateHotCornerMonitoring() {
        hotCornerTimer?.invalidate()
        hotCornerTimer = nil
        hotCornerEntryDate = nil
        hotCornerIsArmed = true

        guard hotCornerSettings.isEnabled else { return }

        let timer = Timer(timeInterval: Self.hotCornerPollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkHotCorner() }
        }
        hotCornerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        checkHotCorner()
    }

    private func checkHotCorner() {
        let pointer = NSEvent.mouseLocation
        let pointerScreen = NSScreen.screens.first { screen in
            NSMouseInRect(pointer, screen.frame, false)
        }
        let isInConfiguredCorner = pointerScreen.map { screen in
            hotCornerSettings.corner.contains(
                pointer: pointer,
                in: screen.frame,
                tolerance: Self.hotCornerTolerance
            )
        } ?? false

        guard isInConfiguredCorner else {
            hotCornerEntryDate = nil
            hotCornerIsArmed = true
            return
        }
        guard hotCornerIsArmed else { return }

        guard let hotCornerEntryDate else {
            self.hotCornerEntryDate = Date()
            return
        }
        guard Date().timeIntervalSince(hotCornerEntryDate) >= Self.hotCornerDwellDuration else { return }

        self.hotCornerEntryDate = nil
        hotCornerIsArmed = false
        guard permissionManager.hasCorePermissions, !panelController.isVisible else { return }

        SafeDiagnosticLog.shared.record("hot-corner: presenting mini UI corner=\(hotCornerSettings.corner.rawValue)")
        panelController.showMiniBrowser()
    }

    func updateGitHubRefreshMonitoring() {
        githubRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: githubRefreshSettings.timeInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.githubRepositoryStore.hasSavedTokens,
                      !self.githubRepositoryStore.isLoading else { return }
                await self.githubRepositoryStore.refreshAll()
            }
        }
        githubRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func checkIdleGrouping() {
        let idleSeconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: UInt32.max)!
        )
        let threshold = TimeInterval(idleGroupingSettings.delayMinutes * 60)
        if idleSeconds < threshold {
            handledCurrentIdlePeriod = false
            return
        }
        guard !handledCurrentIdlePeriod,
              permissionManager.hasCorePermissions,
              hasConfiguredAIKey,
              !viewModel.isLoading,
              !viewModel.isGrouping else { return }
        handledCurrentIdlePeriod = true
        SafeDiagnosticLog.shared.record("grouping: idle threshold reached")
        Task { await viewModel.refreshAndRegenerateGroupsIfNeeded() }
    }

    func refreshBrowserAppearance() {
        panelController.updateAppearance()
    }

    func setBrowserViewMode(_ mode: BrowserViewMode) {
        viewModel.setViewMode(mode)
    }

    func cycleBrowserSelectionByApp(_ direction: Int) {
        permissionManager.refresh()
        guard permissionManager.hasCorePermissions else {
            showSettings()
            return
        }
        if !panelController.isVisible {
            panelController.show()
            viewModel.selectAllWindowsApp()
        }
        viewModel.cycleSelectionByApp(direction)
    }

    func refreshBrowserContent() {
        permissionManager.refresh()
        guard permissionManager.hasCorePermissions else {
            showSettings()
            return
        }
        panelController.show()
        Task { await viewModel.refreshBrowser() }
    }

    func regenerateGroups() {
        permissionManager.refresh()
        guard permissionManager.hasCorePermissions else {
            showSettings()
            return
        }
        panelController.show()
        Task { await viewModel.refreshAndRegenerateGroups() }
    }

    func focusBrowserSearch() {
        permissionManager.refresh()
        guard permissionManager.hasCorePermissions else {
            showSettings()
            return
        }
        panelController.showAndFocusSearch()
    }

    func showFullBrowser() {
        permissionManager.refresh()
        guard permissionManager.hasCorePermissions else {
            showSettings()
            return
        }
        panelController.showFullBrowser()
    }

    func showMiniBrowser() {
        permissionManager.refresh()
        guard permissionManager.hasCorePermissions else {
            showSettings()
            return
        }
        panelController.showMiniBrowser()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
