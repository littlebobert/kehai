import AppKit
import Carbon

@MainActor
final class AppCoordinator: NSObject, NSMenuItemValidation {
    let permissionManager = PermissionManager()
    let safari = SafariTabService()
    private let history = ActivityStore()
    let openAIKeyStore = OpenAIKeyStore()
    let excludedAppStore = ExcludedAppStore()
    let autoUpdates = AutoUpdateService()
    let appearanceSettings = AppearanceSettings()
    let idleGroupingSettings = IdleGroupingSettings()
    private lazy var activityMonitor = ActivityMonitor(store: history)
    private lazy var viewModel = OverviewViewModel(catalog: WindowCatalog(excludedApps: excludedAppStore), thumbnails: ThumbnailService(), safari: safari, history: history, grouping: TaskGroupingService(), openAIKeyStore: openAIKeyStore, excludedAppStore: excludedAppStore, activator: WindowActivator(), activityMonitor: activityMonitor)
    private lazy var panelController = OverviewPanelController(model: viewModel, appearance: appearanceSettings)
    let shortcutSettings = ShortcutSettings()
    private lazy var onboardingController = OnboardingWindowController(
        permissionManager: permissionManager,
        safariService: safari,
        openAIKeyStore: openAIKeyStore,
        proceed: { [weak self] in self?.panelController.show() }
    )
    private lazy var hotKey = GlobalHotKey { [weak self] in self?.show() }
    private let diagnosticReports = DiagnosticReportService()
    private lazy var aboutController = AboutWindowController(
        reportBug: { [weak self] in self?.reportBug() }
    )
    private lazy var settingsController = SettingsWindowController(
        shortcut: shortcutSettings,
        appearance: appearanceSettings,
        idleGrouping: idleGroupingSettings,
        excludedApps: excludedAppStore,
        shortcutChanged: { [weak self] in self?.registerHotKey() },
        appearanceChanged: { [weak self] in self?.refreshBrowserAppearance() },
        idleGroupingChanged: { [weak self] in self?.updateIdleGroupingMonitoring() },
        exclusionsChanged: { [weak self] in
            Task { await self?.viewModel.refresh() }
        }
    )
    private var activationObserver: NSObjectProtocol?
    private var idleTimer: Timer?
    private var handledCurrentIdlePeriod = false
    private var suppressNextActivationPresentation = false

    func start() {
        permissionManager.refresh()
        activityMonitor.start()
        registerHotKey()
        updateIdleGroupingMonitoring()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applicationDidBecomeActive() }
        }
        if !permissionManager.hasCorePermissions {
            DispatchQueue.main.async { [weak self] in self?.showSettings() }
        }
    }

    func stop() {
        hotKey.unregister()
        idleTimer?.invalidate()
        idleTimer = nil
        activityMonitor.stop()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    @objc private func show() {
        permissionManager.refresh()
        guard permissionManager.hasCorePermissions else {
            showSettings()
            return
        }
        if !NSApp.isActive, !panelController.isVisible {
            suppressNextActivationPresentation = true
        }
        panelController.toggle()
    }

    func dockMenu() -> NSMenu? {
        guard permissionManager.hasCorePermissions, !viewModel.taskGroups.isEmpty else { return nil }
        let menu = NSMenu(title: "Task Groups")
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
            alert.messageText = "Could Not Draft Bug Report"
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
            shortcutSettings.registrationError = "This shortcut is unavailable. It may already be used by macOS or another app."
            SafeDiagnosticLog.shared.record("global-hotkey: registration failed status=\(status)")
        }
    }

    func refreshBrowser() {
        Task { await viewModel.refresh() }
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
              openAIKeyStore.hasKey,
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
