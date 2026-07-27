import SwiftUI

@main
struct KehaiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                shortcut: appDelegate.coordinator.shortcutSettings,
                excludedApps: appDelegate.coordinator.excludedAppStore,
                shortcutChanged: appDelegate.coordinator.registerHotKey,
                exclusionsChanged: appDelegate.coordinator.refreshBrowser
            )
        }
    }
}
