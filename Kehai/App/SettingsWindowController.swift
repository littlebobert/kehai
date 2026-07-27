import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(shortcut: ShortcutSettings, appearance: AppearanceSettings, idleGrouping: IdleGroupingSettings, excludedApps: ExcludedAppStore, shortcutChanged: @escaping () -> Void, appearanceChanged: @escaping () -> Void, idleGroupingChanged: @escaping () -> Void, exclusionsChanged: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Kehai Settings"
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(shortcut: shortcut, appearance: appearance, idleGrouping: idleGrouping, excludedApps: excludedApps, shortcutChanged: shortcutChanged, appearanceChanged: appearanceChanged, idleGroupingChanged: idleGroupingChanged, exclusionsChanged: exclusionsChanged))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        guard let window else { return }
        window.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
