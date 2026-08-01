import AppKit
import SwiftUI

@MainActor
final class OverviewPanelController: NSObject, NSWindowDelegate {
    private static let frameAutosaveName = "KehaiBrowserWindow"
    private static let compactContentWidthKey = "overview.compactContentWidth"
    private var window: NSWindow?
    private var compactWindow: NSWindow?
    private var compactWindowFrameHeight: CGFloat?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var globalDragMonitor: Any?
    private var accessibilityDisplayOptionsObserver: NSObjectProtocol?
    private let model: OverviewViewModel
    private let appearance: AppearanceSettings
    private let isShortcutSessionActive: () -> Bool

    init(
        model: OverviewViewModel,
        appearance: AppearanceSettings,
        isShortcutSessionActive: @escaping () -> Bool
    ) {
        self.model = model
        self.appearance = appearance
        self.isShortcutSessionActive = isShortcutSessionActive
        super.init()
        accessibilityDisplayOptionsObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateAppearance() }
        }
        model.onDragRedirectActivated = { [weak self] in
            // After dwell-activate, hide Kehai so the raised window can receive the drop.
            self?.close()
        }
    }

    var isVisible: Bool { window?.isVisible == true || compactWindow?.isVisible == true }

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
        show()
        DispatchQueue.main.async { [weak self] in
            self?.model.searchFocusRequest += 1
        }
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
        let minimumWidth: CGFloat = 576
        let savedWidth = UserDefaults.standard.double(forKey: Self.compactContentWidthKey)
        let defaultWidth = min(640, max(minimumWidth, CGFloat(model.recentAppWindows.count + 1) * 50 + 20))
        let preferredWidth = savedWidth > 0 ? CGFloat(savedWidth) : defaultWidth
        let width = min(max(preferredWidth, minimumWidth), visibleFrame.width)
        let allWindowsIconHorizontalInset: CGFloat = 37
        let opensRight = pointer.x + width - allWindowsIconHorizontalInset <= visibleFrame.maxX
        let estimatedHeight: CGFloat = 260
        let height = min(estimatedHeight, visibleFrame.height)
        let topStripIconInset: CGFloat = 32
        let bottomStripIconInset: CGFloat = 50
        let opensUp = pointer.y - (height - topStripIconInset) < visibleFrame.minY
        let iconCenterX = opensRight ? allWindowsIconHorizontalInset : width - allWindowsIconHorizontalInset
        let iconCenterY = opensUp ? bottomStripIconInset : height - topStripIconInset
        let proposedOriginX = pointer.x - iconCenterX
        let proposedOriginY = pointer.y - iconCenterY
        let originX = min(max(proposedOriginX, visibleFrame.minX), visibleFrame.maxX - width)
        let originY = min(max(proposedOriginY, visibleFrame.minY), visibleFrame.maxY - height)

        let panel = NSWindow(
            contentRect: NSRect(x: originX, y: originY, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Kehai Switcher"
        panel.titleVisibility = .visible
        panel.tabbingMode = .disallowed
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.managed, .participatesInCycle]
        let fixedFrameHeight = panel.frame.height
        let minimumFrameWidth = panel.frameRect(
            forContentRect: NSRect(origin: .zero, size: NSSize(width: minimumWidth, height: height))
        ).width
        panel.minSize = NSSize(width: minimumFrameWidth, height: fixedFrameHeight)
        panel.maxSize = NSSize(width: .greatestFiniteMagnitude, height: fixedFrameHeight)
        panel.contentMinSize = NSSize(width: minimumWidth, height: height)
        panel.contentMaxSize = NSSize(width: .greatestFiniteMagnitude, height: height)
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
        updateAppearance()
        panel.standardWindowButton(.zoomButton)?.target = self
        panel.standardWindowButton(.zoomButton)?.action = #selector(openFullBrowserFromCompactZoom(_:))
        panel.standardWindowButton(.zoomButton)?.toolTip = "Open Full Browser"
        installKeyMonitor()
        installMouseMonitor()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        Task { await model.performInitialRefreshIfNeeded() }
    }

    @objc private func openFullBrowserFromCompactZoom(_ sender: Any?) {
        showFullBrowserFromCompactSwitcher()
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
    }

    func show(selectedGroupID: String? = nil) {
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
        updateAppearance()
        installKeyMonitor()
        installMouseMonitor()

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
        Task { await model.performInitialRefreshIfNeeded() }
    }

    func close() {
        model.prepareForBrowserPresentation(selectedGroupID: nil)
        closeCompactSwitcher()
        window?.close()
    }

    func updateAppearance() {
        let usesTransparentBacking = appearance.usesGlassyWindow
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

    func windowDidEndLiveResize(_ notification: Notification) {
        guard notification.object as? NSWindow === compactWindow,
              let width = compactWindow?.contentView?.bounds.width else { return }
        UserDefaults.standard.set(width, forKey: Self.compactContentWidthKey)
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
            if modifiers == .command,
               event.charactersIgnoringModifiers?.lowercased() == "f" {
                self.model.searchFocusRequest += 1
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
                Task { await self.model.refreshWindows() }
                return nil
            }
            if modifiers == .command,
               event.charactersIgnoringModifiers?.lowercased() == "r" {
                Task { await self.model.refreshAndRegenerateGroups() }
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

            let editingText = self.window?.firstResponder is NSTextView
            if event.keyCode == 53 {
                if editingText {
                    self.window?.makeFirstResponder(self.window?.contentView)
                    return nil
                }
                if self.model.focusedAppKey != nil {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        self.model.clearAppFocus()
                    }
                    return nil
                }
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                guard !editingText else { return event }
                if self.model.activateCurrentSelection() { self.close() }
                return nil
            }
            guard !editingText else { return event }

            if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift {
                self.model.cycleSelectionByApp(modifiers == .shift ? -1 : 1)
                return nil
            }

            if modifiers.isEmpty, event.keyCode == 51 {
                self.model.showActionChooserForSelectedWindow()
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

            switch event.keyCode {
            case 123:
                self.model.moveSelection(horizontal: -1, columnCount: self.model.keyboardColumnCount)
            case 124:
                self.model.moveSelection(horizontal: 1, columnCount: self.model.keyboardColumnCount)
            case 125:
                self.model.moveSelection(vertical: 1, columnCount: self.model.keyboardColumnCount)
            case 126:
                self.model.moveSelection(vertical: -1, columnCount: self.model.keyboardColumnCount)
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
