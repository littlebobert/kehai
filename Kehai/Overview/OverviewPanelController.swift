import AppKit
import SwiftUI

@MainActor
final class OverviewPanelController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private var window: NSWindow?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var toolbarControllers: [NSToolbarItem.Identifier: NSViewController] = [:]
    private let model: OverviewViewModel

    private static let groupingItem = NSToolbarItem.Identifier("com.justin.Kehai.toolbar.grouping")
    private static let hiddenWindowsItem = NSToolbarItem.Identifier("com.justin.Kehai.toolbar.hiddenWindows")
    private static let searchItem = NSToolbarItem.Identifier("com.justin.Kehai.toolbar.search")

    init(model: OverviewViewModel) {
        self.model = model
    }

    var isVisible: Bool { window?.isVisible == true }

    func toggle() { window?.isVisible == true ? close() : show() }

    func show(selectedGroupID: String? = nil) {
        if let window {
            if let selectedGroupID {
                model.selectTaskGroup(model.taskGroups.first { $0.id == selectedGroupID })
            }
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
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        configureToolbar(for: window)

        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 520)
        window.collectionBehavior = [.managed, .participatesInCycle]
        window.setFrame(screen.visibleFrame, display: false)
        window.contentView = NSHostingView(
            rootView: OverviewView(model: model) { [weak self] in self?.close() }
        )
        window.delegate = self
        self.window = window
        installKeyMonitor()
        installMouseMonitor()

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
    }

    func close() {
        window?.close()
    }

    private func configureToolbar(for window: NSWindow) {
        let toolbar = NSToolbar(identifier: "KehaiBrowserToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = true
        window.toolbarStyle = .unified
        window.toolbar = toolbar
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.groupingItem, .flexibleSpace, Self.hiddenWindowsItem, Self.searchItem, .space]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.groupingItem, .flexibleSpace, Self.hiddenWindowsItem, Self.searchItem]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let controller: NSViewController
        let label: String
        switch itemIdentifier {
        case Self.groupingItem:
            controller = NSHostingController(rootView: GroupingToolbarView(model: model))
            label = "Task Groups"
        case Self.hiddenWindowsItem:
            controller = NSHostingController(rootView: HiddenWindowsToolbarView(model: model))
            label = "Hidden Windows"
        case Self.searchItem:
            controller = NSHostingController(rootView: SearchToolbarView(model: model) { [weak self] in
                guard let self, self.model.activateSelectedWindow() else { return }
                self.close()
            })
            label = "Search"
        default:
            return nil
        }
        toolbarControllers[itemIdentifier] = controller
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = label
        item.paletteLabel = label
        item.view = controller.view
        return item
    }

    func windowWillClose(_ notification: Notification) {
        model.stopLiveThumbnail()
        removeKeyMonitor()
        removeMouseMonitor()
        window = nil
    }

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self,
                  event.window === self.window,
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

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers == .command,
               event.charactersIgnoringModifiers?.lowercased() == "f" {
                self.model.searchFocusRequest += 1
                return nil
            }
            if modifiers.contains(.command),
               let character = event.charactersIgnoringModifiers,
               character == "+" || character == "=" {
                withAnimation(.easeInOut(duration: 0.16)) {
                    self.model.resizeThumbnails(by: 1)
                }
                return nil
            }
            if modifiers.contains(.command), event.charactersIgnoringModifiers == "-" {
                withAnimation(.easeInOut(duration: 0.16)) {
                    self.model.resizeThumbnails(by: -1)
                }
                return nil
            }

            let editingText = self.window?.firstResponder is NSTextView
            if event.keyCode == 53, editingText {
                self.window?.makeFirstResponder(self.window?.contentView)
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                guard !editingText else { return event }
                if self.model.activateSelectedWindow() { self.close() }
                return nil
            }
            guard !editingText else { return event }

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
