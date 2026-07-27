import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private static let contentSize = NSSize(width: 640, height: 610)

    init(permissionManager: PermissionManager, safariService: SafariTabService, openAIKeyStore: OpenAIKeyStore, proceed: @escaping () -> Void) {
        let size = Self.contentSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Kehai Setup"
        window.isReleasedWhenClosed = false
        window.contentMinSize = size
        window.contentMaxSize = size
        window.setContentSize(size)
        window.contentView = NSHostingView(
            rootView: PermissionView(
                permissionManager: permissionManager,
                safariService: safariService,
                openAIKeyStore: openAIKeyStore,
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
        let size = Self.contentSize
        window.contentMinSize = size
        window.contentMaxSize = size
        window.setContentSize(size)

        let targetScreen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        if let visibleFrame = targetScreen?.visibleFrame {
            let frame = window.frame
            window.setFrameOrigin(NSPoint(
                x: visibleFrame.midX - frame.width / 2,
                y: visibleFrame.midY - frame.height / 2
            ))
        } else {
            window.center()
        }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
