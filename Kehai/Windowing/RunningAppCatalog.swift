import AppKit

/// What the app strip needs to know about a running app, captured off the main actor.
struct RunningAppInfo: Sendable {
    let processID: pid_t
    let bundleIdentifier: String?
    let localizedName: String?
    let launchDate: Date?
    nonisolated(unsafe) let icon: NSImage?

    var appKey: String { bundleIdentifier ?? "pid:\(processID)" }
}

/// Keeps the list of user-switchable running apps current in the background.
///
/// NSRunningApplication URLs, icons and bundle Info.plist reads go through
/// LaunchServices and the disk. Under load (e.g. a big build) that can stall for
/// seconds, so presenting the mini UI must only read this cached list.
@MainActor
@Observable
final class RunningAppCatalog {
    private(set) var apps: [RunningAppInfo] = []
    /// Called after `apps` changes so switcher snapshots can merge new apps in.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    func start() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        // Activation catches apps that switch to a regular activation policy after launch.
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification
        ] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let processID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                let terminated = notification.name == NSWorkspace.didTerminateApplicationNotification
                Task { @MainActor [weak self] in
                    self?.handleWorkspaceChange(processID: processID, terminated: terminated)
                }
            })
        }
        refresh()
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Rebuilds the list off the main actor. Callers never wait on it; `onChange`
    /// fires when the new list lands.
    func refresh() {
        generation += 1
        let expectedGeneration = generation
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let started = Date()
            let infos = await Task.detached(priority: .userInitiated) {
                Self.switchableApps(excluding: ownProcessID)
            }.value
            guard let self, !Task.isCancelled, self.generation == expectedGeneration else { return }
            let elapsed = Date().timeIntervalSince(started)
            if elapsed > 0.5 {
                SafeDiagnosticLog.shared.record("running-apps: refresh slow ms=\(Int(elapsed * 1000)) count=\(infos.count)")
            }
            self.apps = infos
            self.onChange?()
        }
    }

    private func handleWorkspaceChange(processID: pid_t?, terminated: Bool) {
        if terminated, let processID {
            SwitchableApplicationCache.shared.forget(processID: processID)
            if apps.contains(where: { $0.processID == processID }) {
                apps.removeAll { $0.processID == processID }
                onChange?()
            }
        }
        refresh()
    }

    private nonisolated static func switchableApps(excluding ownProcessID: pid_t) -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard application.activationPolicy == .regular,
                  !application.isTerminated,
                  application.processIdentifier != ownProcessID,
                  SwitchableApplicationCache.shared.isUserSwitchable(application)
            else { return nil }
            return RunningAppInfo(
                processID: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                localizedName: application.localizedName,
                launchDate: application.launchDate,
                icon: application.icon
            )
        }
    }
}

/// Per-process memo of whether an app is a normal, switchable app. A running
/// process's bundle Info.plist does not change, so each app pays the disk read once.
final class SwitchableApplicationCache: @unchecked Sendable {
    static let shared = SwitchableApplicationCache()

    private let lock = NSLock()
    private var resultsByProcessID: [pid_t: Bool] = [:]

    func isUserSwitchable(_ application: NSRunningApplication) -> Bool {
        let processID = application.processIdentifier
        lock.lock()
        let cached = resultsByProcessID[processID]
        lock.unlock()
        if let cached { return cached }

        let result = Self.computeIsUserSwitchable(application)
        lock.lock()
        resultsByProcessID[processID] = result
        lock.unlock()
        return result
    }

    func forget(processID: pid_t) {
        lock.lock()
        resultsByProcessID.removeValue(forKey: processID)
        lock.unlock()
    }

    private static func computeIsUserSwitchable(_ application: NSRunningApplication) -> Bool {
        guard let executableURL = application.executableURL else { return false }
        guard !executableURL.pathComponents.contains(where: { $0.hasSuffix(".appex") }) else { return false }

        guard let bundleURL = application.bundleURL,
              let bundle = Bundle(url: bundleURL) else { return true }
        return (bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool) != true
            && (bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool) != true
            && bundle.object(forInfoDictionaryKey: "NSExtension") == nil
    }
}
