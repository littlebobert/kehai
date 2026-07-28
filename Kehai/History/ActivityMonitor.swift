import AppKit

@MainActor
final class ActivityMonitor {
    private let store: ActivityStore
    private var observer: NSObjectProtocol?
    private var latestWindows: [WindowItem] = []
    private var activationDatesByProcessID: [pid_t: Date] = [:]

    init(store: ActivityStore) { self.store = store }

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let processID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activationDatesByProcessID[processID] = Date()
                guard let item = self.latestWindows.first(where: { $0.processID == processID }) else { return }
                await self.store.record(item)
            }
        }
    }

    func update(windows: [WindowItem]) { latestWindows = windows }

    func recentActivationDate(for processID: pid_t, within interval: TimeInterval = 30) -> Date? {
        guard let date = activationDatesByProcessID[processID],
              Date().timeIntervalSince(date) <= interval else { return nil }
        return date
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        activationDatesByProcessID.removeAll()
    }
}
