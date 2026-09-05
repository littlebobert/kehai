import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(
        shortcut: ShortcutSettings,
        idleGrouping: IdleGroupingSettings,
        excludedApps: ExcludedAppStore,
        aiExcludedApps: AIExcludedAppStore,
        permissionManager: PermissionManager,
        openAIKeyStore: APIKeyStore,
        anthropicKeyStore: APIKeyStore,
        githubRepositoryStore: GitHubRepositoryStore,
        githubRefreshSettings: GitHubRefreshSettings,
        safariService: SafariTabService,
        shortcutChanged: @escaping () -> Void,
        idleGroupingChanged: @escaping () -> Void,
        githubRefreshIntervalChanged: @escaping () -> Void,
        exclusionsChanged: @escaping () -> Void
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.string("Kehai Settings")
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 620, height: 500)
        window.contentView = NSHostingView(rootView: SettingsView(
            shortcut: shortcut,
            idleGrouping: idleGrouping,
            excludedApps: excludedApps,
            aiExcludedApps: aiExcludedApps,
            permissionManager: permissionManager,
            openAIKeyStore: openAIKeyStore,
            anthropicKeyStore: anthropicKeyStore,
            githubRepositoryStore: githubRepositoryStore,
            githubRefreshSettings: githubRefreshSettings,
            safariService: safariService,
            shortcutChanged: shortcutChanged,
            idleGroupingChanged: idleGroupingChanged,
            githubRefreshIntervalChanged: githubRefreshIntervalChanged,
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
