import AppKit
import ApplicationServices

@MainActor
final class WindowInventoryMonitor {
    private struct ApplicationObservation {
        let applicationElement: AXUIElement
        let observer: AXObserver
        var windowElements: [AXUIElement]
    }

    private let changed: @MainActor () -> Void
    private let focusedWindowChanged: @MainActor (pid_t) -> Void
    private var workspaceObservers: [NSObjectProtocol] = []
    private var applicationObservations: [pid_t: ApplicationObservation] = [:]
    private var reconciliationTimer: Timer?
    private var changeTask: Task<Void, Never>?
    private var isRunning = false

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

        for application in NSWorkspace.shared.runningApplications {
            observe(application)
        }

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

        for processID in Array(applicationObservations.keys) {
            removeObservation(for: processID)
        }
    }

    private func handleWorkspaceChange(processID: pid_t?, launched: Bool) {
        guard let processID else {
            scheduleChange()
            return
        }
        if launched, let application = NSRunningApplication(processIdentifier: processID) {
            observe(application)
        } else if !launched {
            removeObservation(for: processID)
        }
        scheduleChange()
    }

    private func observe(_ application: NSRunningApplication) {
        let processID = application.processIdentifier
        guard processID != ProcessInfo.processInfo.processIdentifier,
              application.activationPolicy == .regular,
              applicationObservations[processID] == nil else { return }

        var observer: AXObserver?
        guard AXObserverCreate(processID, Self.axCallback, &observer) == .success,
              let observer else { return }

        let applicationElement = AXUIElementCreateApplication(processID)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(observer, applicationElement, notification as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)

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
                AXObserverAddNotification(observation.observer, element, kAXUIElementDestroyedNotification as CFString, refcon)
                AXObserverAddNotification(observation.observer, element, kAXTitleChangedNotification as CFString, refcon)
            }
        } else {
            observation.windowElements = []
        }
        applicationObservations[processID] = observation
    }

    private func removeObservation(for processID: pid_t) {
        guard let observation = applicationObservations.removeValue(forKey: processID) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observation.observer), .commonModes)
    }

    private func handleAXChange(processID: pid_t, focusedWindowDidChange: Bool) {
        if processID != 0 {
            refreshWindowObservations(for: processID)
            if focusedWindowDidChange { focusedWindowChanged(processID) }
        }
        scheduleChange()
    }

    private func scheduleChange(after delay: Duration = .milliseconds(180)) {
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

    private nonisolated static let axCallback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        var processID: pid_t = 0
        AXUIElementGetPid(element, &processID)
        let focusedWindowDidChange = notification as String == kAXFocusedWindowChangedNotification as String
        let monitor = Unmanaged<WindowInventoryMonitor>.fromOpaque(refcon).takeUnretainedValue()
        Task { @MainActor in
            monitor.handleAXChange(processID: processID, focusedWindowDidChange: focusedWindowDidChange)
        }
    }
}
