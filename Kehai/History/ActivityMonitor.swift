import AppKit
import ApplicationServices

@MainActor
final class ActivityMonitor {
    private let store: ActivityStore
    private var windowFocused: (@MainActor (CGWindowID, Date) -> Void)?
    private var observer: NSObjectProtocol?
    private var latestWindows: [WindowItem] = []
    private var activationDatesByProcessID: [pid_t: Date] = [:]
    /// Focus Kehai saw before the focused window reached the inventory, keyed by process.
    private var pendingFocusByProcessID: [pid_t: PendingFocus] = [:]

    /// A newly opened window takes focus before the next inventory reconcile adds it.
    struct PendingFocus {
        let signature: WindowMatchCandidate?
        let date: Date

        /// Long enough to outlast a slow reconcile, short enough not to
        /// credit a much later window with an old focus.
        static let lifetime: TimeInterval = 10 * 60
    }

    init(store: ActivityStore) { self.store = store }

    func setWindowFocusedHandler(_ handler: @escaping @MainActor (CGWindowID, Date) -> Void) {
        windowFocused = handler
    }

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

    func update(windows: [WindowItem]) {
        latestWindows = windows
        resolvePendingFocus()
    }

    func recordFocusedWindow(processID: pid_t) async {
        let focusedAt = Date()
        let candidates = latestWindows.filter { $0.processID == processID }

        let application = AXUIElementCreateApplication(processID)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            if let item = candidates.first {
                await store.record(item)
            } else {
                pendingFocusByProcessID[processID] = PendingFocus(signature: nil, date: focusedAt)
            }
            return
        }

        let focusedWindow = focusedValue as! AXUIElement
        let signature = windowSignature(for: focusedWindow)
        guard let item = Self.focusedWindow(matching: signature, in: candidates) else {
            // The focused window is usually brand new and not inventoried yet.
            // Crediting another window of the app would misorder both of them.
            pendingFocusByProcessID[processID] = PendingFocus(signature: signature, date: focusedAt)
            return
        }
        pendingFocusByProcessID[processID] = nil
        await markFocused(item, at: focusedAt)
    }

    /// The inventory window the focused AX window corresponds to, or nil when no
    /// candidate is a confident match. Without a readable signature, a lone window is.
    static func focusedWindow(matching signature: WindowMatchCandidate?, in candidates: [WindowItem]) -> WindowItem? {
        guard let signature else { return candidates.count == 1 ? candidates.first : nil }
        return candidates
            .map { (window: $0, score: signature.score(for: $0)) }
            .filter { $0.score >= WindowMatchCandidate.minimumConfidentScore }
            .max { $0.score < $1.score }?
            .window
    }

    private func resolvePendingFocus() {
        let now = Date()
        for (processID, pending) in pendingFocusByProcessID {
            guard now.timeIntervalSince(pending.date) <= PendingFocus.lifetime else {
                pendingFocusByProcessID[processID] = nil
                continue
            }
            let candidates = latestWindows.filter { $0.processID == processID }
            guard let item = Self.focusedWindow(matching: pending.signature, in: candidates) else { continue }
            pendingFocusByProcessID[processID] = nil
            // Never let a late-resolving focus override a newer one.
            if let lastSeen = item.lastSeen, lastSeen >= pending.date { continue }
            Task { await self.markFocused(item, at: pending.date) }
        }
    }

    private func markFocused(_ item: WindowItem, at focusedAt: Date) async {
        await store.record(item, at: focusedAt)
        latestWindows = latestWindows.map { window in
            var window = window
            if window.id == item.id { window.lastSeen = max(window.lastSeen ?? focusedAt, focusedAt) }
            return window
        }
        windowFocused?(item.id, focusedAt)
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

    /// Most recent activation for this process, if Kehai observed it this session.
    func activationDate(for processID: pid_t) -> Date? {
        activationDatesByProcessID[processID]
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        activationDatesByProcessID.removeAll()
        pendingFocusByProcessID.removeAll()
    }
}
