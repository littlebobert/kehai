import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(
        shortcut: ShortcutSettings,
        appearance: AppearanceSettings,
        idleGrouping: IdleGroupingSettings,
        excludedApps: ExcludedAppStore,
        aiExcludedApps: AIExcludedAppStore,
        permissionManager: PermissionManager,
        openAIKeyStore: APIKeyStore,
        anthropicKeyStore: APIKeyStore,
        safariService: SafariTabService,
        shortcutChanged: @escaping () -> Void,
        appearanceChanged: @escaping () -> Void,
        idleGroupingChanged: @escaping () -> Void,
        exclusionsChanged: @escaping () -> Void
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.string("Kehai Settings")
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(
            shortcut: shortcut,
            appearance: appearance,
            idleGrouping: idleGrouping,
            excludedApps: excludedApps,
            aiExcludedApps: aiExcludedApps,
            permissionManager: permissionManager,
            openAIKeyStore: openAIKeyStore,
            anthropicKeyStore: anthropicKeyStore,
            safariService: safariService,
            shortcutChanged: shortcutChanged,
            appearanceChanged: appearanceChanged,
            idleGroupingChanged: idleGroupingChanged,
            exclusionsChanged: exclusionsChanged
        ))
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
