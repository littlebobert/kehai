import AppKit
import Carbon

@MainActor
final class AppCoordinator: NSObject {
    let permissionManager = PermissionManager()
    let safari = SafariTabService()
    private let history = ActivityStore()
    let openAIKeyStore = OpenAIKeyStore()
    let excludedAppStore = ExcludedAppStore()
    private lazy var activityMonitor = ActivityMonitor(store: history)
    private lazy var viewModel = OverviewViewModel(catalog: WindowCatalog(excludedApps: excludedAppStore), thumbnails: ThumbnailService(), safari: safari, history: history, grouping: TaskGroupingService(), openAIKeyStore: openAIKeyStore, excludedAppStore: excludedAppStore, activator: WindowActivator(), activityMonitor: activityMonitor)
    private lazy var panelController = OverviewPanelController(model: viewModel)
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
        excludedApps: excludedAppStore,
        shortcutChanged: { [weak self] in self?.registerHotKey() },
        exclusionsChanged: { [weak self] in
            Task { await self?.viewModel.refresh() }
        }
    )
    private var statusItem: NSStatusItem?
    private var showBrowserMenuItem: NSMenuItem?
    private var activationObserver: NSObjectProtocol?

    func start() {
        permissionManager.refresh()
        activityMonitor.start()
        registerHotKey()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Kehai")
        let menu = NSMenu()
        menu.addItem(withTitle: "About Kehai", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(.separator())
        let showBrowserItem = NSMenuItem(title: "Show Browser", action: #selector(show), keyEquivalent: "")
        showBrowserItem.target = self
        menu.addItem(showBrowserItem)
        showBrowserMenuItem = showBrowserItem
        updateShowBrowserMenuShortcut()
        menu.addItem(withTitle: "Settings…", action: #selector(showPreferences), keyEquivalent: ",")
        menu.addItem(withTitle: "Setup & Permissions…", action: #selector(showSettings), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Kehai", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
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
        activityMonitor.stop()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    @objc private func show() {
        permissionManager.refresh()
        guard permissionManager.hasCorePermissions else {
            showSettings()
            return
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
        hotKey.register(keyCode: shortcutSettings.keyCode, modifiers: shortcutSettings.modifiers)
        updateShowBrowserMenuShortcut()
    }

    func refreshBrowser() {
        Task { await viewModel.refresh() }
    }

    private func updateShowBrowserMenuShortcut() {
        guard let item = showBrowserMenuItem else { return }
        item.keyEquivalent = keyEquivalent(for: shortcutSettings.keyCode)
        var mask: NSEvent.ModifierFlags = []
        if shortcutSettings.modifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
        if shortcutSettings.modifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if shortcutSettings.modifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        if shortcutSettings.modifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        item.keyEquivalentModifierMask = mask
    }

    private func keyEquivalent(for keyCode: UInt32) -> String {
        let specialKeys: [UInt32: String] = [
            UInt32(kVK_Space): " ", UInt32(kVK_Return): "\r",
            UInt32(kVK_Tab): "\t", UInt32(kVK_Delete): "\u{8}",
            UInt32(kVK_UpArrow): String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)),
            UInt32(kVK_DownArrow): String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)),
            UInt32(kVK_LeftArrow): String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)),
            UInt32(kVK_RightArrow): String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        ]
        if let specialKey = specialKeys[keyCode] { return specialKey }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "" }
        let layoutData = unsafeBitCast(data, to: CFData.self) as Data
        return layoutData.withUnsafeBytes { bytes in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return "" }
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, characters.count, &length, &characters
            )
            guard status == noErr, length > 0 else { return "" }
            return String(utf16CodeUnits: characters, count: length).lowercased()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
