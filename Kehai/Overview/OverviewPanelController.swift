import AppKit
import SwiftUI

@MainActor
final class OverviewPanelController: NSObject, NSWindowDelegate {
    private static let frameAutosaveName = "KehaiBrowserWindow"
    private var window: NSWindow?
    private var compactWindow: NSWindow?
    private var compactWindowFrameHeight: CGFloat?
    private var compactWindowsAboveAppStrip = false
    private var isConstrainingCompactWindowFrame = false
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var globalDragMonitor: Any?
    private var accessibilityDisplayOptionsObserver: NSObjectProtocol?
    private var menuTrackingObservers: [NSObjectProtocol] = []
    private var menuTrackingDepth = 0
    private let model: OverviewViewModel
    private let appearance: AppearanceSettings
    private let isShortcutSessionActive: () -> Bool
    private let shortcutKeyCode: () -> UInt16
    private let shortcutModifierFlags: () -> NSEvent.ModifierFlags
    private let presentationChanged: (Bool, Bool) -> Void

    init(
        model: OverviewViewModel,
        appearance: AppearanceSettings,
        isShortcutSessionActive: @escaping () -> Bool,
        shortcutKeyCode: @escaping () -> UInt16,
        shortcutModifierFlags: @escaping () -> NSEvent.ModifierFlags,
        presentationChanged: @escaping (Bool, Bool) -> Void
    ) {
        self.model = model
        self.appearance = appearance
        self.isShortcutSessionActive = isShortcutSessionActive
        self.shortcutKeyCode = shortcutKeyCode
        self.shortcutModifierFlags = shortcutModifierFlags
        self.presentationChanged = presentationChanged
        super.init()
        accessibilityDisplayOptionsObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateAppearance() }
        }
        menuTrackingObservers = [
            NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.menuTrackingDidBegin() }
            },
            NotificationCenter.default.addObserver(
                forName: NSMenu.didEndTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.menuTrackingDidEnd() }
            }
        ]
        model.onDragRedirectActivated = { [weak self] in
            // After dwell-activate, hide Kehai so the raised window can receive the drop.
            self?.close()
        }
    }

    var isVisible: Bool { isFullBrowserVisible || isMiniBrowserVisible }
    var isFullBrowserVisible: Bool { window?.isVisible == true }
    var isMiniBrowserVisible: Bool { compactWindow?.isVisible == true }

    private func menuTrackingDidBegin() {
        menuTrackingDepth += 1
        if menuTrackingDepth == 1 {
            model.setMenuTrackingActive(true)
        }
    }

    private func menuTrackingDidEnd() {
        menuTrackingDepth = max(0, menuTrackingDepth - 1)
        if menuTrackingDepth == 0 {
            model.setMenuTrackingActive(false)
        }
    }

    private func notifyPresentationChanged() {
        presentationChanged(isFullBrowserVisible, isMiniBrowserVisible)
    }

    private var minimumContentSize: NSSize {
        // One default-width thumbnail plus the browser's horizontal insets and scrollbar.
        NSSize(width: 356, height: 490)
    }

    private func applyMinimumSize(to window: NSWindow) {
        window.contentMinSize = minimumContentSize
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: minimumContentSize)).size
    }

    func toggle() {
        if NSApp.isActive, window?.isVisible == true {
            close()
        } else {
            show()
        }
    }

    func showAndFocusSearch() {
        closeCompactSwitcher()
        show()
        DispatchQueue.main.async { [weak self] in
            self?.model.searchFocusRequest += 1
        }
    }

    func showFullBrowser() {
        closeCompactSwitcher()
        show()
    }

    func showMiniBrowser() {
        model.beginSwitcherMode()
        showCompactSwitcher()
    }

    func beginSwitcherMode() {
        model.beginSwitcherMode()
        showCompactSwitcher()
    }

    func finishSwitcherMode() {
        guard model.isSwitcherMode else { return }
        let wasDragging = model.isExternalDragActive
        if model.isAllWindowsAppSelected, !wasDragging {
            // Keep switcher interaction active while the compact panel is pinned.
            return
        }
        if model.finishSwitcherMode() {
            // Always close after a successful activate so a live drag can land on the target.
            closeCompactSwitcher()
        } else if wasDragging {
            // Keys released mid-drag with no target — end switcher but keep the compact view open.
            model.dragSessionEnded()
        } else {
            // Releasing on All Windows pins the mini UI; clicking All Windows opens the browser.
        }
    }

    private func showCompactSwitcher() {
        closeCompactSwitcher()
        window?.orderOut(nil)
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let threeThumbnailWidth: CGFloat = 676
        let oneThumbnailMinimumWidth: CGFloat = 244
        let allWindowsIconHorizontalInset: CGFloat = 41.5
        let preferredWidth = threeThumbnailWidth
        let referenceContentRect = NSRect(x: 0, y: 0, width: 1, height: 1)
        let referenceFrameRect = NSWindow.frameRect(forContentRect: referenceContentRect, styleMask: styleMask)
        let leftFrameInset = referenceContentRect.minX - referenceFrameRect.minX
        let rightFrameInset = referenceFrameRect.maxX - referenceContentRect.maxX
        let maximumRightWidth = visibleFrame.maxX
            - (pointer.x - allWindowsIconHorizontalInset)
            - rightFrameInset
        let maximumLeftWidth = pointer.x
            + allWindowsIconHorizontalInset
            - visibleFrame.minX
            - leftFrameInset
        let opensRight: Bool
        if maximumRightWidth >= preferredWidth {
            opensRight = true
        } else if maximumLeftWidth >= preferredWidth {
            opensRight = false
        } else {
            opensRight = maximumRightWidth >= maximumLeftWidth
        }
        let maximumAnchoredWidth = floor(max(1, opensRight ? maximumRightWidth : maximumLeftWidth))
        let minimumWidth = min(oneThumbnailMinimumWidth, maximumAnchoredWidth)
        let width = min(preferredWidth, maximumAnchoredWidth)
        let usesRetrofit = appearance.browserTheme == .classicMac
        let estimatedHeight: CGFloat
        if model.githubRepositoryStore.hasSavedTokens {
            estimatedHeight = usesRetrofit ? 408 : 388
        } else {
            estimatedHeight = usesRetrofit ? 312 : 292
        }
        let height = min(estimatedHeight, visibleFrame.height)
        let topStripIconInset: CGFloat = 65.5
        let bottomStripIconInset: CGFloat = 41
        let opensUp = pointer.y - (height - topStripIconInset) < visibleFrame.minY
        compactWindowsAboveAppStrip = opensUp
        let iconCenterX = opensRight ? allWindowsIconHorizontalInset : width - allWindowsIconHorizontalInset
        let iconCenterY = opensUp ? bottomStripIconInset : height - topStripIconInset
        let proposedOriginX = pointer.x - iconCenterX
        let proposedOriginY = pointer.y - iconCenterY
        let originX = min(max(proposedOriginX, visibleFrame.minX), visibleFrame.maxX - width)
        let originY = min(max(proposedOriginY, visibleFrame.minY), visibleFrame.maxY - height)

        let panel = NSWindow(
            contentRect: NSRect(x: originX, y: originY, width: width, height: height),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        panel.title = "Kehai mini"
        panel.titleVisibility = .visible
        panel.tabbingMode = .disallowed
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.managed, .participatesInCycle]
        let fixedFrameHeight = panel.frame.height
        let minimumFrameWidth = panel.frameRect(
            forContentRect: NSRect(origin: .zero, size: NSSize(width: minimumWidth, height: height))
        ).width
        let maximumFrameWidth = panel.frameRect(
            forContentRect: NSRect(origin: .zero, size: NSSize(width: maximumAnchoredWidth, height: height))
        ).width
        panel.minSize = NSSize(width: minimumFrameWidth, height: fixedFrameHeight)
        panel.maxSize = NSSize(width: maximumFrameWidth, height: fixedFrameHeight)
        panel.contentMinSize = NSSize(width: minimumWidth, height: height)
        panel.contentMaxSize = NSSize(width: maximumAnchoredWidth, height: height)
        let hostingView = NSHostingView(
            rootView: CompactSwitcherView(
                model: model,
                appearance: appearance,
                opensRight: opensRight,
                opensUp: opensUp,
                openBrowser: { [weak self] in self?.showFullBrowserFromCompactSwitcher() },
                close: { [weak self] in self?.dismissCompactSwitcherAfterActivation() }
            )
        )
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.delegate = self
        compactWindow = panel
        compactWindowFrameHeight = fixedFrameHeight
        constrainCompactWindowToVisibleScreen(panel, screen: screen)
        updateAppearance()
        panel.standardWindowButton(.zoomButton)?.target = self
        panel.standardWindowButton(.zoomButton)?.action = #selector(openFullBrowserFromCompactZoom(_:))
        panel.standardWindowButton(.zoomButton)?.toolTip = "Open Full Browser"
        installKeyMonitor()
        installMouseMonitor()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        notifyPresentationChanged()
        Task { await model.performInitialRefreshIfNeeded() }
    }

    @objc private func openFullBrowserFromCompactZoom(_ sender: Any?) {
        showFullBrowserFromCompactSwitcher()
    }

    @objc private func openMiniBrowserFromFullZoom(_ sender: Any?) {
        showMiniBrowser()
    }

    private func showFullBrowserFromCompactSwitcher() {
        closeCompactSwitcher()
        show()
    }

    private func dismissCompactSwitcherAfterActivation() {
        model.prepareForBrowserPresentation(selectedGroupID: nil)
        closeCompactSwitcher()
    }

    private func closeCompactSwitcher() {
        compactWindow?.orderOut(nil)
        compactWindow?.contentView = nil
        compactWindow = nil
        compactWindowFrameHeight = nil
        if window?.isVisible != true {
            removeKeyMonitor()
            removeMouseMonitor()
        }
        notifyPresentationChanged()
    }

    func show(selectedGroupID: String? = nil) {
        closeCompactSwitcher()
        if let window {
            // Drop leftover search / smart-search / group filters unless this open
            // explicitly targets a Dock menu group.
            if let selectedGroupID {
                model.prepareForBrowserPresentation(selectedGroupID: selectedGroupID)
                model.selectTaskGroup(model.taskGroups.first { $0.id == selectedGroupID })
            } else {
                model.prepareForBrowserPresentation(selectedGroupID: nil)
            }
            updateAppearance()
            installKeyMonitor()
            installMouseMonitor()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(window.contentView)
            notifyPresentationChanged()
            return
        }

        guard let screen = NSScreen.main else { return }
        model.prepareForPresentation(selectedGroupID: selectedGroupID)
        let window = NSWindow(
            contentRect: screen.visibleFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Kehai"
        window.titleVisibility = .visible
        window.tabbingMode = .disallowed

        window.isReleasedWhenClosed = false
        applyMinimumSize(to: window)
        window.collectionBehavior = [.managed, .participatesInCycle]
        window.setFrame(screen.visibleFrame, display: false)
        window.setFrameAutosaveName(Self.frameAutosaveName)
        window.setFrameUsingName(Self.frameAutosaveName, force: false)
        window.contentView = NSHostingView(
            rootView: OverviewView(model: model, appearance: appearance) { [weak self] in self?.close() }
        )
        window.delegate = self
        self.window = window
        window.standardWindowButton(.zoomButton)?.target = self
        window.standardWindowButton(.zoomButton)?.action = #selector(openMiniBrowserFromFullZoom(_:))
        window.standardWindowButton(.zoomButton)?.toolTip = "Open Mini Browser"
        updateAppearance()
        installKeyMonitor()
        installMouseMonitor()

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
        notifyPresentationChanged()
        Task { await model.performInitialRefreshIfNeeded() }
    }

    func close() {
        model.prepareForBrowserPresentation(selectedGroupID: nil)
        closeCompactSwitcher()
        window?.close()
    }

    func updateAppearance() {
        let usesTransparentBacking = appearance.browserTheme == .system
            && appearance.usesGlassyWindow
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        for browserWindow in [window, compactWindow].compactMap({ $0 }) {
            browserWindow.titlebarAppearsTransparent = false
            browserWindow.titlebarSeparatorStyle = .automatic
            browserWindow.isOpaque = !usesTransparentBacking
            browserWindow.backgroundColor = usesTransparentBacking
                ? NSColor.windowBackgroundColor.withAlphaComponent(0.28)
                : .windowBackgroundColor
        }
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        if sender === compactWindow {
            return NSSize(
                width: max(frameSize.width, sender.minSize.width),
                height: compactWindowFrameHeight ?? sender.frame.height
            )
        }
        return NSSize(
            width: max(frameSize.width, sender.minSize.width),
            height: max(frameSize.height, sender.minSize.height)
        )
    }

    func windowDidResize(_ notification: Notification) {
        guard let resizedWindow = notification.object as? NSWindow,
              resizedWindow === compactWindow else { return }
        if resizedWindow.inLiveResize {
            constrainCompactWindowToVisibleScreen(resizedWindow)
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard notification.object as? NSWindow === compactWindow,
              let compactWindow else { return }
        constrainCompactWindowToVisibleScreen(compactWindow)
    }

    private func constrainCompactWindowToVisibleScreen(_ window: NSWindow, screen: NSScreen? = nil) {
        guard !isConstrainingCompactWindowFrame,
              let visibleFrame = (screen ?? window.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = window.frame
        frame.size.width = min(frame.width, visibleFrame.width)
        frame.size.height = min(frame.height, visibleFrame.height)
        frame.origin.x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - frame.height)
        guard frame != window.frame else { return }
        isConstrainingCompactWindowFrame = true
        window.setFrame(frame, display: true)
        isConstrainingCompactWindowFrame = false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.setLiveThumbnailEnabled(true)
        Task { await model.refreshForForeground() }
    }

    func windowDidResignKey(_ notification: Notification) {
        model.setLiveThumbnailEnabled(false)
    }

    func windowWillClose(_ notification: Notification) {
        model.setLiveThumbnailEnabled(false)
        model.dragSessionEnded()
        if notification.object as? NSWindow === compactWindow {
            model.prepareForBrowserPresentation(selectedGroupID: nil)
            compactWindow = nil
        }
        notifyPresentationChanged()
        removeKeyMonitor()
        removeMouseMonitor()
    }

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        let dragMask: NSEvent.EventTypeMask = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged]

        // Local: drag events while Kehai is key, plus click/scroll handling.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: dragMask.union([.leftMouseDown, .scrollWheel])) { [weak self] event in
            guard let self else { return event }

            // Freeze inventory as soon as a system drag is underway — before the
            // cursor hits a card DropDelegate (which is too late to stop SCK thrash).
            if event.type == .leftMouseDragged
                || event.type == .rightMouseDragged
                || event.type == .otherMouseDragged {
                self.model.notePotentialSystemDrag()
                return event
            }

            guard event.window === self.window || event.window === self.compactWindow else { return event }

            if event.type == .scrollWheel,
               self.model.isSwitcherMode,
               !event.hasPreciseScrollingDeltas,
               let window = self.window,
               let contentView = window.contentView {
                let location = contentView.convert(event.locationInWindow, from: nil)
                var view = contentView.hitTest(location)
                while let current = view, !(current is NSScrollView) {
                    view = current.superview
                }
                if let scrollView = view as? NSScrollView,
                   let documentView = scrollView.documentView {
                    let clipView = scrollView.contentView
                    let usesHorizontalScrolling = documentView.bounds.width > clipView.bounds.width
                    let dominantDelta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
                        ? event.scrollingDeltaY
                        : event.scrollingDeltaX
                    let distance = dominantDelta * 18
                    if usesHorizontalScrolling {
                        let maximumX = max(0, documentView.bounds.width - clipView.bounds.width)
                        let targetX = min(max(clipView.bounds.origin.x - distance, 0), maximumX)
                        clipView.scroll(to: NSPoint(x: targetX, y: clipView.bounds.origin.y))
                    } else {
                        let maximumY = max(0, documentView.bounds.height - clipView.bounds.height)
                        let targetY = min(max(clipView.bounds.origin.y - distance, 0), maximumY)
                        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: targetY))
                    }
                    scrollView.reflectScrolledClipView(clipView)
                    return nil
                }
            }

            guard event.type == .leftMouseDown,
                  let window = self.window,
                  let editor = window.firstResponder as? NSTextView,
                  editor.isFieldEditor,
                  let textField = editor.delegate as? NSTextField else { return event }

            let location = event.locationInWindow
            if !textField.frame.contains(textField.superview?.convert(location, from: nil) ?? location) {
                window.makeFirstResponder(window.contentView)
            }
            return event
        }

        // Global: drags that start in another app and enter Kehai (local monitors miss these).
        if globalDragMonitor == nil {
            globalDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: dragMask) { [weak self] _ in
                Task { @MainActor in
                    self?.model.notePotentialSystemDrag()
                }
            }
        }
    }

    private func removeMouseMonitor() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        if let globalDragMonitor {
            NSEvent.removeMonitor(globalDragMonitor)
            self.globalDragMonitor = nil
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.window === self.window || event.window === self.compactWindow else { return event }

            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if self.model.actionChooserStage != nil {
                switch event.keyCode {
                case 53:
                    self.model.cancelActionChooser()
                case 36, 76:
                    self.model.confirmActionChooserSelection()
                case 123, 126:
                    self.model.moveActionChooserSelection(-1)
                case 124, 125:
                    self.model.moveActionChooserSelection(1)
                default:
                    return nil
                }
                return nil
            }
            if self.model.isSwitcherMode, self.isShortcutSessionActive() {
                let configuredKeyCode = self.shortcutKeyCode()
                let configuredModifiers = self.shortcutModifierFlags()
                if event.keyCode == configuredKeyCode {
                    let reverseModifiers = configuredModifiers.subtracting(.shift)
                    if configuredModifiers.contains(.shift), modifiers == reverseModifiers {
                        self.model.cycleSelectionByApp(-1)
                        return nil
                    }
                }
            }

            // Switcher Q/W: allow optional Shift (users often still hold ⌘⇧ from the hotkey).
            // Swallow before AppKit menu Close (⌘W) can dismiss Kehai itself.
            if self.model.isSwitcherMode,
               self.isShortcutSessionActive(),
               modifiers.contains(.command),
               !modifiers.contains(.control),
               !modifiers.contains(.option) {
                let character = event.charactersIgnoringModifiers?.lowercased()
                // keyCode fallbacks: 12 = Q, 13 = W (ANSI).
                if character == "q" || event.keyCode == 12 {
                    _ = self.model.quitSelectedAppInSwitcherMode()
                    return nil
                }
                if character == "w" || event.keyCode == 13 {
                    _ = self.model.closeSelectedWindowInSwitcherMode()
                    return nil
                }
            }
            if event.window === self.compactWindow,
               modifiers == .command,
               event.charactersIgnoringModifiers?.lowercased() == "a",
               !self.model.query.isEmpty {
                self.model.compactSearchFocusRequest += 1
                DispatchQueue.main.async { [weak self] in
                    DispatchQueue.main.async { [weak self] in
                        guard let self,
                              let editor = self.compactWindow?.firstResponder as? NSTextView else { return }
                        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
                    }
                }
                return nil
            }
            if modifiers == .command,
               event.charactersIgnoringModifiers?.lowercased() == "f" {
                if event.window === self.compactWindow {
                    self.showAndFocusSearch()
                } else {
                    self.model.searchFocusRequest += 1
                }
                return nil
            }
            if modifiers == .command, (event.keyCode == 36 || event.keyCode == 76) {
                Task { await self.model.performSmartSearch() }
                return nil
            }
            if modifiers == .command, event.charactersIgnoringModifiers == "1" {
                withAnimation(.easeInOut(duration: 0.14)) {
                    self.model.setViewMode(.grouped)
                }
                return nil
            }
            if modifiers == .command, event.charactersIgnoringModifiers == "2" {
                withAnimation(.easeInOut(duration: 0.14)) {
                    self.model.setViewMode(.recent)
                }
                return nil
            }
            if modifiers == [.command, .shift],
               event.charactersIgnoringModifiers?.lowercased() == "r" {
                guard self.model.viewMode == .grouped else { return nil }
                Task { await self.model.refreshAndRegenerateGroups() }
                return nil
            }
            if modifiers == .command,
               event.charactersIgnoringModifiers?.lowercased() == "r" {
                Task { await self.model.refreshWindows() }
                return nil
            }
            if modifiers.contains(.command),
               let character = event.charactersIgnoringModifiers,
               character == "+" || character == "=" {
                withAnimation(.easeInOut(duration: 0.16)) {
                    self.model.resizeThumbnails(by: 1)
                }
                if let window = self.window { self.applyMinimumSize(to: window) }
                return nil
            }
            if modifiers.contains(.command), event.charactersIgnoringModifiers == "-" {
                withAnimation(.easeInOut(duration: 0.16)) {
                    self.model.resizeThumbnails(by: -1)
                }
                if let window = self.window { self.applyMinimumSize(to: window) }
                return nil
            }

            let editingText = event.window?.firstResponder is NSTextView
            let isPinnedMiniBrowser = event.window === self.compactWindow
                && self.model.isSwitcherMode
                && !self.isShortcutSessionActive()
            if event.keyCode == 53 {
                if editingText {
                    if isPinnedMiniBrowser {
                        self.model.compactSearchBlurRequest += 1
                        self.compactWindow?.makeFirstResponder(self.compactWindow?.contentView)
                    } else {
                        self.model.searchBlurRequest += 1
                        self.window?.makeFirstResponder(self.window?.contentView)
                    }
                    return nil
                }
                if isPinnedMiniBrowser, !self.model.query.isEmpty {
                    self.model.clearPinnedSwitcherQuery()
                    return nil
                }
                if self.model.focusedAppKey != nil {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        self.model.clearAppFocus()
                    }
                    return nil
                }
                if isPinnedMiniBrowser {
                    self.closeCompactSwitcher()
                    return nil
                }
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                guard !editingText else { return event }
                if event.window === self.compactWindow, self.model.isAllWindowsAppSelected {
                    self.showFullBrowserFromCompactSwitcher()
                } else if self.model.activateCurrentSelection() {
                    if event.window === self.compactWindow {
                        self.dismissCompactSwitcherAfterActivation()
                    } else {
                        self.close()
                    }
                }
                return nil
            }
            guard !editingText else { return event }

            if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift {
                self.model.cycleSelectionByApp(modifiers == .shift ? -1 : 1)
                return nil
            }

            if isPinnedMiniBrowser,
               modifiers.isEmpty,
               event.keyCode == 51,
               !self.model.query.isEmpty {
                self.model.deleteLastPinnedSwitcherQueryCharacter()
                return nil
            }

            if modifiers.isEmpty, event.keyCode == 51 {
                if !self.model.showExclusionChooserForFocusedApp() {
                    self.model.showActionChooserForSelectedWindow()
                }
                return nil
            }

            if isPinnedMiniBrowser,
               ![123, 124, 125, 126].contains(event.keyCode),
               modifiers.isEmpty || modifiers == .shift,
               let characters = event.characters,
               !characters.isEmpty,
               characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                self.model.queuePinnedSwitcherSearchText(characters)
                return nil
            }

            if event.window === self.window,
               ![123, 124, 125, 126].contains(event.keyCode),
               modifiers.isEmpty || modifiers == .shift,
               let characters = event.characters,
               !characters.isEmpty,
               characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                self.model.queueSearchText(characters)
                return nil
            }

            if modifiers == .option, event.keyCode == 125 {
                if !self.model.moveSelectionToAdjacentGroup(1) {
                    self.model.moveSelection(vertical: 1, columnCount: self.model.keyboardColumnCount)
                }
                return nil
            }
            if modifiers == .option, event.keyCode == 126 {
                if !self.model.moveSelectionToAdjacentGroup(-1) {
                    self.model.moveSelection(vertical: -1, columnCount: self.model.keyboardColumnCount)
                }
                return nil
            }

            let windowsAboveAppStrip = event.window === self.compactWindow
                && self.compactWindowsAboveAppStrip

            switch event.keyCode {
            case 123:
                self.model.moveSelection(horizontal: -1, columnCount: self.model.keyboardColumnCount)
            case 124:
                self.model.moveSelection(horizontal: 1, columnCount: self.model.keyboardColumnCount)
            case 125:
                if event.window === self.compactWindow,
                   self.model.moveCompactWindowSelectionToRepositories() {
                    break
                }
                self.model.moveSelection(
                    vertical: 1,
                    columnCount: self.model.keyboardColumnCount,
                    windowsAboveAppStrip: windowsAboveAppStrip
                )
            case 126:
                self.model.moveSelection(
                    vertical: -1,
                    columnCount: self.model.keyboardColumnCount,
                    windowsAboveAppStrip: windowsAboveAppStrip
                )
            default:
                return event
            }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}
