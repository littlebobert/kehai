import AppKit
import ApplicationServices

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
                await self.recordFocusedWindow(processID: processID)
            }
        }
    }

    func update(windows: [WindowItem]) { latestWindows = windows }

    func recordFocusedWindow(processID: pid_t) async {
        let candidates = latestWindows.filter { $0.processID == processID }
        guard !candidates.isEmpty else { return }

        let application = AXUIElementCreateApplication(processID)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            if let item = candidates.first { await store.record(item) }
            return
        }

        let focusedWindow = focusedValue as! AXUIElement
        let signature = windowSignature(for: focusedWindow)
        let item = signature.flatMap { signature in
            candidates.max { signature.score(for: $0) < signature.score(for: $1) }
        } ?? candidates.first
        guard let item else { return }
        await store.record(item)
        latestWindows = latestWindows.map { window in
            var window = window
            if window.id == item.id { window.lastSeen = Date() }
            return window
        }
    }

    private func windowSignature(for element: AXUIElement) -> WindowMatchCandidate? {
        var titleValue: CFTypeRef?
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return WindowMatchCandidate(
            title: (titleValue as? String) ?? "",
            frame: CGRect(origin: position, size: size)
        )
    }

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
