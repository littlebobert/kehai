import AppKit
import SwiftUI

@MainActor
final class OverviewPanelController: NSObject, NSWindowDelegate {
    private static let frameAutosaveName = "KehaiBrowserWindow"
    private var window: NSWindow?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private let model: OverviewViewModel
    private let appearance: AppearanceSettings

    init(model: OverviewViewModel, appearance: AppearanceSettings) {
        self.model = model
        self.appearance = appearance
    }

    var isVisible: Bool { window?.isVisible == true }

    private var minimumContentSize: NSSize {
        NSSize(width: model.thumbnailCardWidth + 88, height: 490)
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
        show()
    }

    func finishSwitcherMode() {
        guard model.isSwitcherMode else { return }
        if model.finishSwitcherMode() {
            close()
        }
    }

    func show(selectedGroupID: String? = nil) {
        if let window {
            if let selectedGroupID {
                model.selectTaskGroup(model.taskGroups.first { $0.id == selectedGroupID })
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
        window?.close()
    }

    func updateAppearance() {
        guard let window else { return }
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .automatic
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(
            width: max(frameSize.width, sender.minSize.width),
            height: max(frameSize.height, sender.minSize.height)
        )
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
        removeKeyMonitor()
        removeMouseMonitor()
    }

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .scrollWheel]) { [weak self] event in
            guard let self, event.window === self.window else { return event }

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
                    let maximumY = max(0, documentView.bounds.height - clipView.bounds.height)
                    let wheelDelta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
                        ? event.scrollingDeltaY
                        : event.scrollingDeltaX
                    let distance = wheelDelta * 18
                    let targetY = min(max(clipView.bounds.origin.y - distance, 0), maximumY)
                    clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: targetY))
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
    }

    private func removeMouseMonitor() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }

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
            if event.keyCode == 53, editingText {
                self.window?.makeFirstResponder(self.window?.contentView)
                return nil
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
