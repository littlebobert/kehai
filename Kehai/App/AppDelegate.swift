import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()
    private var isTerminationPending = false
    private var hasRepliedToTermination = false

    /// Upper bound on how long `.terminateLater` may hold the quit. Teardown talks
    /// to ScreenCaptureKit, Accessibility and Safari, none of which honor
    /// cancellation, so it needs a ceiling it cannot talk its way past.
    private static let terminationDeadline = Duration.milliseconds(600)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.setActivationPolicy(.regular)
        let environment = ProcessInfo.processInfo.environment
        let isRunningTests = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        guard !isRunningTests else { return }
        coordinator.start()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        coordinator.dockMenu()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator.handleDockReopen()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminationPending else { return .terminateLater }
        isTerminationPending = true
        coordinator.prepareForTermination()
        // Two independent tasks race, rather than one awaiting the other, so the
        // watchdog stays free to fire while teardown is stuck in a call it cannot
        // abandon. First one to finish releases the quit.
        Task { @MainActor [weak self] in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            await self.coordinator.finishTermination()
            self.replyToTermination(sender)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.terminationDeadline)
            self?.replyToTermination(sender)
        }
        return .terminateLater
    }

    private func replyToTermination(_ sender: NSApplication) {
        guard !hasRepliedToTermination else { return }
        hasRepliedToTermination = true
        sender.reply(toApplicationShouldTerminate: true)
    }
}
