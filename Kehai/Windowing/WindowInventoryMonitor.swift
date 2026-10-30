import AppKit
import ApplicationServices

@MainActor
final class WindowInventoryMonitor {
    private let changed: @MainActor () -> Void
    private let focusedWindowChanged: @MainActor (pid_t) -> Void
    private var workspaceObservers: [NSObjectProtocol] = []
    private var reconciliationTimer: Timer?
    private var changeTask: Task<Void, Never>?
    private var isRunning = false
    private lazy var observations = AccessibilityObservations { [weak self] processID, focusedWindowDidChange in
        Task { @MainActor [weak self] in
            self?.handleAXChange(processID: processID, focusedWindowDidChange: focusedWindowDidChange)
        }
    }

    private static let initialEnumerationDelay: TimeInterval = 0.25

    init(
        changed: @escaping @MainActor () -> Void,
        focusedWindowChanged: @escaping @MainActor (pid_t) -> Void
    ) {
        self.changed = changed
        self.focusedWindowChanged = focusedWindowChanged
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let processID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                let launched = notification.name == NSWorkspace.didLaunchApplicationNotification
                Task { @MainActor [weak self] in
                    self?.handleWorkspaceChange(processID: processID, launched: launched)
                }
            })
        }

        // Leave launch-critical work clear before observing every running app.
        observations.observeAllRunningApplications(after: Self.initialEnumerationDelay)

        reconciliationTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleChange(after: .zero)
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        changeTask?.cancel()
        changeTask = nil
        reconciliationTimer?.invalidate()
        reconciliationTimer = nil

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()

        observations.removeAll()
    }

    private func handleWorkspaceChange(processID: pid_t?, launched: Bool) {
        guard let processID else {
            scheduleChange()
            return
        }
        if launched {
            observations.observe(processID: processID)
        } else {
            observations.remove(processID: processID)
        }
        scheduleChange()
    }

    private func handleAXChange(processID: pid_t, focusedWindowDidChange: Bool) {
        guard isRunning else { return }
        if processID != 0, focusedWindowDidChange { focusedWindowChanged(processID) }
        scheduleChange()
    }

    private func scheduleChange(after delay: Duration = .milliseconds(350)) {
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            changed()
        }
    }
}

/// Every AXObserver and Accessibility round-trip the inventory needs, confined to one
/// background thread with its own run loop.
///
/// Each call is synchronous IPC into the observed app. A busy app (Xcode mid-build)
/// can take the full messaging timeout to answer, and on the main thread that stalled
/// the hot zone poll and every other UI update behind it.
private final class AccessibilityObservations: @unchecked Sendable {
    private struct ApplicationObservation {
        let applicationElement: AXUIElement
        let observer: AXObserver
        var windowElements: [AXUIElement]
    }

    /// Ceiling for each synchronous Accessibility round-trip. Without it, a single
    /// unresponsive app can stall a call for the system default (~6s).
    private static let accessibilityMessagingTimeout: Float = 0.5
    private static let slowAccessibilityRefreshThreshold: TimeInterval = 0.25

    /// Called on the observation thread after an app's window list was re-read.
    private let changed: @Sendable (pid_t, Bool) -> Void
    // Only touched on the observation thread.
    private var applicationObservations: [pid_t: ApplicationObservation] = [:]
    private var isObserving = false
    private let runLoop: CFRunLoop

    init(changed: @escaping @Sendable (pid_t, Bool) -> Void) {
        self.changed = changed
        final class Handoff: @unchecked Sendable { var runLoop: CFRunLoop? }
        let handoff = Handoff()
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            handoff.runLoop = CFRunLoopGetCurrent()
            // A port keeps the run loop alive while no app is observed yet.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            while true { RunLoop.current.run() }
        }
        thread.name = "Kehai Accessibility observations"
        thread.qualityOfService = .userInitiated
        thread.start()
        ready.wait()
        runLoop = handoff.runLoop!
    }

    func observeAllRunningApplications(after delay: TimeInterval) {
        perform { self.isObserving = true }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [self] in
            perform {
                guard self.isObserving else { return }
                for application in NSWorkspace.shared.runningApplications {
                    self.observeOnThread(processID: application.processIdentifier)
                }
            }
        }
    }

    func observe(processID: pid_t) {
        perform { self.observeOnThread(processID: processID) }
    }

    func remove(processID: pid_t) {
        perform { self.removeOnThread(processID: processID) }
    }

    func removeAll() {
        perform {
            self.isObserving = false
            for processID in Array(self.applicationObservations.keys) {
                self.removeOnThread(processID: processID)
            }
        }
    }

    private func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    private func observeOnThread(processID: pid_t) {
        guard isObserving,
              processID != ProcessInfo.processInfo.processIdentifier,
              applicationObservations[processID] == nil,
              let application = NSRunningApplication(processIdentifier: processID),
              application.activationPolicy == .regular else { return }

        var observer: AXObserver?
        guard AXObserverCreate(processID, Self.axCallback, &observer) == .success,
              let observer else { return }

        let applicationElement = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(applicationElement, Self.accessibilityMessagingTimeout)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(observer, applicationElement, notification as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)

        applicationObservations[processID] = ApplicationObservation(
            applicationElement: applicationElement,
            observer: observer,
            windowElements: []
        )
        refreshWindowObservations(for: processID)
    }

    private func refreshWindowObservations(for processID: pid_t) {
        guard var observation = applicationObservations[processID] else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        for element in observation.windowElements {
            AXObserverRemoveNotification(observation.observer, element, kAXUIElementDestroyedNotification as CFString)
            AXObserverRemoveNotification(observation.observer, element, kAXTitleChangedNotification as CFString)
        }

        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(observation.applicationElement, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement] {
            observation.windowElements = windows
            for element in windows {
                // The messaging timeout is per-element, not inherited from the app element.
                AXUIElementSetMessagingTimeout(element, Self.accessibilityMessagingTimeout)
                AXObserverAddNotification(observation.observer, element, kAXUIElementDestroyedNotification as CFString, refcon)
                AXObserverAddNotification(observation.observer, element, kAXTitleChangedNotification as CFString, refcon)
            }
        } else {
            observation.windowElements = []
        }
        applicationObservations[processID] = observation
    }

    private func removeOnThread(processID: pid_t) {
        guard let observation = applicationObservations.removeValue(forKey: processID) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observation.observer), .defaultMode)
    }

    private func handleAXChange(processID: pid_t, focusedWindowDidChange: Bool) {
        if processID != 0 {
            let started = Date()
            refreshWindowObservations(for: processID)
            let elapsed = Date().timeIntervalSince(started)
            if elapsed > Self.slowAccessibilityRefreshThreshold {
                SafeDiagnosticLog.shared.record(
                    "window-inventory: slow AX observation refresh ms=\(Int(elapsed * 1000)) " +
                        "windows=\(applicationObservations[processID]?.windowElements.count ?? 0)"
                )
            }
        }
        changed(processID, focusedWindowDidChange)
    }

    /// Runs on the observation thread, which owns every observer's run-loop source.
    private static let axCallback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        var processID: pid_t = 0
        AXUIElementGetPid(element, &processID)
        let focusedWindowDidChange = notification as String == kAXFocusedWindowChangedNotification as String
        let observations = Unmanaged<AccessibilityObservations>.fromOpaque(refcon).takeUnretainedValue()
        observations.handleAXChange(processID: processID, focusedWindowDidChange: focusedWindowDidChange)
    }
}
