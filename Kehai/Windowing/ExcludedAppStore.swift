import AppKit
import Foundation
import Observation

struct ExcludedApp: Codable, Hashable, Identifiable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    let name: String

    var icon: NSImage? {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return running.icon
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

@MainActor
@Observable
final class ExcludedAppStore {
    private(set) var apps: [ExcludedApp] = []
    private static let defaultsKey = "privacy.excludedApps.v1"

    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([ExcludedApp].self, from: data) else { return }
        apps = decoded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func contains(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        return apps.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    func contains(appName: String) -> Bool {
        apps.contains { $0.name.localizedCaseInsensitiveCompare(appName) == .orderedSame }
    }

    func exclude(bundleIdentifier: String, name: String) {
        guard !bundleIdentifier.isEmpty, !contains(bundleIdentifier: bundleIdentifier) else { return }
        apps.append(ExcludedApp(bundleIdentifier: bundleIdentifier, name: name))
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
    }

    func allow(_ app: ExcludedApp) {
        apps.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(apps) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
