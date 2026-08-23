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
                anthropicKeyStore: appDelegate.coordinator.anthropicKeyStore,
                githubRepositoryStore: appDelegate.coordinator.githubRepositoryStore,
                githubRefreshSettings: appDelegate.coordinator.githubRefreshSettings,
                safariService: appDelegate.coordinator.safari,
                shortcutChanged: appDelegate.coordinator.registerHotKey,
                appearanceChanged: appDelegate.coordinator.refreshBrowserAppearance,
                idleGroupingChanged: appDelegate.coordinator.updateIdleGroupingMonitoring,
                githubRefreshIntervalChanged: appDelegate.coordinator.updateGitHubRefreshMonitoring,
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
                Button("Show Full Browser") {
                    appDelegate.coordinator.showFullBrowser()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(appDelegate.coordinator.browserPresentationState.isFullBrowserVisible)
                Button("Show Mini Browser") {
                    appDelegate.coordinator.showMiniBrowser()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(appDelegate.coordinator.browserPresentationState.isMiniBrowserVisible)
                Divider()
                Button("Group by task") {
                    appDelegate.coordinator.setBrowserViewMode(.grouped)
                }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(!appDelegate.coordinator.canGroupByTask)
                Button("Sort all by recent") {
                    appDelegate.coordinator.setBrowserViewMode(.recent)
                }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(!appDelegate.coordinator.canSortAllByRecent)
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
                Button("Refresh Windows") {
                    appDelegate.coordinator.refreshWindows()
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("Regenerate Groups") {
                    appDelegate.coordinator.regenerateGroups()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(appDelegate.coordinator.canGroupByTask)
                Button("Search") {
                    appDelegate.coordinator.focusBrowserSearch()
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}
