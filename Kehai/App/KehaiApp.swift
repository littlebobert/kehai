import SwiftUI

@main
struct KehaiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                shortcut: appDelegate.coordinator.shortcutSettings,
                appearance: appDelegate.coordinator.appearanceSettings,
                idleGrouping: appDelegate.coordinator.idleGroupingSettings,
                excludedApps: appDelegate.coordinator.excludedAppStore,
                aiExcludedApps: appDelegate.coordinator.aiExcludedAppStore,
                permissionManager: appDelegate.coordinator.permissionManager,
                openAIKeyStore: appDelegate.coordinator.openAIKeyStore,
                safariService: appDelegate.coordinator.safari,
                shortcutChanged: appDelegate.coordinator.registerHotKey,
                appearanceChanged: appDelegate.coordinator.refreshBrowserAppearance,
                idleGroupingChanged: appDelegate.coordinator.updateIdleGroupingMonitoring,
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
            CommandGroup(after: .toolbar) {
                Divider()
                Button("Group by task") {
                    appDelegate.coordinator.setBrowserViewMode(.grouped)
                }
                .keyboardShortcut("1", modifiers: .command)
                Button("Sort all by recent") {
                    appDelegate.coordinator.setBrowserViewMode(.recent)
                }
                .keyboardShortcut("2", modifiers: .command)
                Divider()
                Button("Next App") {
                    appDelegate.coordinator.cycleBrowserSelectionByApp(1)
                }
                .keyboardShortcut(.tab, modifiers: [])
                Button("Previous App") {
                    appDelegate.coordinator.cycleBrowserSelectionByApp(-1)
                }
                .keyboardShortcut(.tab, modifiers: .shift)
                Divider()
                Button("Regenerate Groups") {
                    appDelegate.coordinator.regenerateGroups()
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("Search") {
                    appDelegate.coordinator.focusBrowserSearch()
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}
