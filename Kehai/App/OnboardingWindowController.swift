import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private static let contentSize = NSSize(width: 660, height: 680)

    init(
        permissionManager: PermissionManager,
        safariService: SafariTabService,
        openAIKeyStore: APIKeyStore,
        anthropicKeyStore: APIKeyStore,
        githubRepositoryStore: GitHubRepositoryStore,
        proceed: @escaping () -> Void
    ) {
        let size = Self.contentSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.string("Kehai Setup")
        window.isReleasedWhenClosed = false
        window.contentMinSize = size
        window.contentMaxSize = size
        window.setContentSize(size)
        window.contentView = NSHostingView(
            rootView: PermissionView(
                permissionManager: permissionManager,
                safariService: safariService,
                openAIKeyStore: openAIKeyStore,
                anthropicKeyStore: anthropicKeyStore,
                githubRepositoryStore: githubRepositoryStore,
                close: { [weak window] in
                    window?.close()
                    proceed()
                }
            )
            .frame(width: size.width, height: size.height)
        )
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
