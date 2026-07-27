import AppKit

@MainActor
final class ActivityMonitor {
    private let store: ActivityStore
    private var observer: NSObjectProtocol?
    private var latestWindows: [WindowItem] = []

    init(store: ActivityStore) { self.store = store }

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let processID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            Task { @MainActor [weak self] in
                guard let self, let item = self.latestWindows.first(where: { $0.processID == processID }) else { return }
                await self.store.record(item)
            }
        }
    }

    func update(windows: [WindowItem]) { latestWindows = windows }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }
}
