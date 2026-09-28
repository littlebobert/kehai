import AppKit
import SwiftUI

/// The right-click menu for an app icon. Built in AppKit because SwiftUI context
/// menus can't declare alternate items, and "Force Quit App" should replace
/// "Quit App" only while Option is held — live, like the Dock.
struct AppContextMenuActions {
    var quit: () -> Void
    var forceQuit: () -> Void
    var canExcludeFromAI: Bool
    var canExcludeEntirely: Bool
    var excludeFromAI: () -> Void
    var excludeEntirely: () -> Void

    @MainActor
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let quitItem = ClosureMenuItem(title: L10n.string("Quit App"), handler: quit)
        quitItem.keyEquivalentModifierMask = []
        menu.addItem(quitItem)

        // Alternates must share the key equivalent and differ only by modifiers.
        let forceQuitItem = ClosureMenuItem(title: L10n.string("Force Quit App"), handler: forceQuit)
        forceQuitItem.keyEquivalentModifierMask = [.option]
        forceQuitItem.isAlternate = true
        menu.addItem(forceQuitItem)

        let excludeMenu = NSMenu()
        excludeMenu.autoenablesItems = false
        let fromAI = ClosureMenuItem(title: L10n.string("From AI Queries"), handler: excludeFromAI)
        fromAI.isEnabled = canExcludeFromAI
        excludeMenu.addItem(fromAI)
        let entirely = ClosureMenuItem(title: L10n.string("From Kehai Entirely"), handler: excludeEntirely)
        entirely.isEnabled = canExcludeEntirely
        excludeMenu.addItem(entirely)

        let excludeItem = NSMenuItem(title: L10n.string("Exclude App…"), action: nil, keyEquivalent: "")
        excludeItem.submenu = excludeMenu
        excludeItem.isEnabled = canExcludeFromAI || canExcludeEntirely
        menu.addItem(excludeItem)
        return menu
    }
}

extension View {
    func appContextMenu(_ actions: AppContextMenuActions) -> some View {
        overlay(AppContextMenuCatcher(actions: actions))
    }
}

private struct AppContextMenuCatcher: NSViewRepresentable {
    let actions: AppContextMenuActions

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.actions = actions
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.actions = actions
    }

    final class CatcherView: NSView {
        var actions: AppContextMenuActions?

        /// Only claim right-clicks (and Control-clicks); everything else — hover,
        /// clicks, drags, drops — falls through to the SwiftUI content underneath.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let isMenuClick = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return isMenuClick ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) {
            showMenu(for: event)
        }

        override func mouseDown(with event: NSEvent) {
            guard event.modifierFlags.contains(.control) else { return super.mouseDown(with: event) }
            showMenu(for: event)
        }

        private func showMenu(for event: NSEvent) {
            guard let menu = actions?.makeMenu() else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() {
        handler()
    }
}
