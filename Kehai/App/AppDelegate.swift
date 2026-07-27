import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
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

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }
}
