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
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Kehai") {
                    appDelegate.coordinator.showAbout()
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    appDelegate.coordinator.checkForUpdates()
                }
                .disabled(!appDelegate.coordinator.autoUpdates.canCheckForUpdates)
            }
        }
    }
}
