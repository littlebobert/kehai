import AppKit
import ApplicationServices

struct WindowMatchCandidate: Sendable {
    /// A partial title match, or a frame within ~100pt of total drift.
    static let minimumConfidentScore = 40.0

    let title: String
    let frame: CGRect

    func score(for window: WindowItem) -> Double {
        var score = title == window.title ? 100.0 : (title.localizedCaseInsensitiveContains(window.title) ? 40 : 0)
        let distance = abs(frame.origin.x - window.frame.origin.x) + abs(frame.origin.y - window.frame.origin.y)
            + abs(frame.width - window.frame.width) + abs(frame.height - window.frame.height)
        score += max(0, 50 - Double(distance) / 10)
        return score
    }
}

@MainActor
final class WindowActivator {
    enum QuitOutcome {
        case requested
        case alreadyTerminated
        case failed
    }

    /// Ceiling for each synchronous Accessibility round-trip while raising windows
    /// after app activation, so one unresponsive app can't stall it for seconds.
    private static let accessibilityMessagingTimeout: Float = 0.5

    func activate(_ item: WindowItem) {
        guard let app = NSRunningApplication(processIdentifier: item.processID) else { return }
        // App-only strip entries (no open windows) just need the app frontmost.
        guard !item.isAppPlaceholder else {
            app.activate(options: [.activateAllWindows])
            return
        }
        app.activate(options: [])
        raiseWindow(item)
    }

    /// Open an *app* rather than one of its windows, like clicking its Dock icon:
    /// the app comes forward with `item` on top, and opening an app that was already
    /// frontmost (`raisingAllWindows`) brings every unminimized window with it.
    @discardableResult
    func activateApp(_ item: WindowItem, raisingAllWindows: Bool) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: item.processID), !app.isTerminated else {
            SafeDiagnosticLog.shared.record("app-activation: target process unavailable")
            return false
        }
        guard let applicationURL = app.bundleURL else {
            SafeDiagnosticLog.shared.record("app-activation: target bundle unavailable")
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { [weak self] openedApp, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard error == nil, let openedApp else {
                    SafeDiagnosticLog.shared.record("app-activation: workspace open failed")
                    return
                }
                if openedApp.isHidden { openedApp.unhide() }
                self.raiseWindowsAfterAppActivation(item, all: raisingAllWindows)
                SafeDiagnosticLog.shared.record("app-activation: workspace open completed all=\(raisingAllWindows)")
                self.verifyActivation(processID: item.processID, item: item, raisingAllWindows: raisingAllWindows)
            }
        }
        SafeDiagnosticLog.shared.record("app-activation: workspace open requested")
        return true
    }

    private func verifyActivation(processID: pid_t, item: WindowItem, raisingAllWindows: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self,
                  let app = NSRunningApplication(processIdentifier: processID),
                  !app.isTerminated else {
                SafeDiagnosticLog.shared.record("app-activation: verification target unavailable")
                return
            }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == processID {
                SafeDiagnosticLog.shared.record("app-activation: verified frontmost")
                return
            }
            SafeDiagnosticLog.shared.record("app-activation: not frontmost; retrying workspace open")
            guard let applicationURL = app.bundleURL else {
                SafeDiagnosticLog.shared.record("app-activation: retry bundle unavailable")
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { [weak self] _, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.raiseWindowsAfterAppActivation(item, all: raisingAllWindows)
                    let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == processID
                    SafeDiagnosticLog.shared.record(
                        "app-activation: workspace retry error=\(error != nil) frontmost=\(isFrontmost)"
                    )
                }
            }
        }
    }

    /// Hand dropped files or links to the app that owns `item`, as if they were
    /// dropped on its Dock icon. The app decides which window opens them.
    func open(_ urls: [URL], with item: WindowItem) {
        guard let app = NSRunningApplication(processIdentifier: item.processID),
              !app.isTerminated,
              let applicationURL = app.bundleURL else {
            SafeDiagnosticLog.shared.record("drop-open: target app unavailable")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: applicationURL, configuration: configuration) { _, error in
            SafeDiagnosticLog.shared.record("drop-open: count=\(urls.count) error=\(error != nil)")
        }
    }

    /// Raise the target window for a drag-redirect without forcing every app window up first.
    func activateForDragRedirect(_ item: WindowItem) {
        guard let app = NSRunningApplication(processIdentifier: item.processID) else { return }
        if item.isAppPlaceholder {
            app.activate(options: [.activateAllWindows])
            return
        }
        app.activate(options: [])
        raiseWindow(item)
    }

    /// Raising every window through Accessibility restacks them visibly one by one,
    /// so that is kept for re-opening the app the user was already in. Otherwise only
    /// the strip's representative window needs putting on top.
    private func raiseWindowsAfterAppActivation(_ item: WindowItem, all: Bool) {
        if all {
            raiseAllWindows(for: item, focusing: !item.isAppPlaceholder)
        } else if !item.isAppPlaceholder {
            raiseWindow(item, messagingTimeout: Self.accessibilityMessagingTimeout)
        }
    }

    /// Activation alone leaves an app's other windows behind other apps. Raising each
    /// window through Accessibility forces the whole app's stack forward.
    private func raiseAllWindows(for item: WindowItem, focusing shouldFocusTarget: Bool) {
        let application = AXUIElementCreateApplication(item.processID)
        AXUIElementSetMessagingTimeout(application, Self.accessibilityMessagingTimeout)
        guard let windows: [AXUIElement] = value(application, attribute: kAXWindowsAttribute) else {
            if shouldFocusTarget { raiseWindow(item) }
            return
        }
        let target = shouldFocusTarget ? matchingWindow(item, in: application) : nil
        // AX reports windows front-to-back, so raising in reverse preserves their
        // relative order. Minimized windows stay in the Dock, as they do in Mission Control.
        for window in windows.reversed() {
            if let target, CFEqual(window, target) { continue }
            // The messaging timeout is per-element, not inherited from the app element.
            AXUIElementSetMessagingTimeout(window, Self.accessibilityMessagingTimeout)
            guard !isMinimized(window) else { continue }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        guard let target else { return }
        AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, target)
    }

    private func isMinimized(_ window: AXUIElement) -> Bool {
        value(window, attribute: kAXMinimizedAttribute) as NSNumber? == true
    }

    private func raiseWindow(_ item: WindowItem, messagingTimeout: Float? = nil) {
        let application = AXUIElementCreateApplication(item.processID)
        if let messagingTimeout { AXUIElementSetMessagingTimeout(application, messagingTimeout) }
        guard let best = matchingWindow(item, in: application) else { return }
        // The messaging timeout is per-element, not inherited from the app element.
        if let messagingTimeout { AXUIElementSetMessagingTimeout(best, messagingTimeout) }
        AXUIElementSetAttributeValue(best, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(best, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, best)
    }

    @discardableResult
    func close(
        _ item: WindowItem,
        keepKehaiActive: Bool = true,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        let application = AXUIElementCreateApplication(item.processID)
        guard let window = matchingWindow(item, in: application) else { return false }
        // Raise within the app's AX hierarchy without activating it, so the
        // close button is actionable while Kehai stays frontmost in switcher mode.
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        guard pressClose(on: window) else { return false }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            let application = AXUIElementCreateApplication(item.processID)
            let stillPresent: Bool = {
                if let byID = self.matchingWindow(item, in: application),
                   self.windowNumber(of: byID) == item.physicalWindowID {
                    return true
                }
                if let remainingWindow = self.matchingWindow(item, in: application),
                   self.score(remainingWindow, item) >= 55 {
                    return true
                }
                return false
            }()
            if stillPresent {
                completion(false)
                if keepKehaiActive {
                    NSApp.activate(ignoringOtherApps: true)
                } else if let remainingWindow = self.matchingWindow(item, in: application),
                          let app = NSRunningApplication(processIdentifier: item.processID) {
                    app.activate(options: [.activateAllWindows])
                    AXUIElementPerformAction(remainingWindow, kAXRaiseAction as CFString)
                    AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, remainingWindow)
                }
            } else {
                completion(true)
                if keepKehaiActive {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        return true
    }

    func quit(_ item: WindowItem) -> QuitOutcome {
        guard let app = NSRunningApplication(processIdentifier: item.processID),
              !app.isTerminated else {
            return .alreadyTerminated
        }
        if app.terminate() {
            return .requested
        }
        return app.isTerminated ? .alreadyTerminated : .failed
    }

    /// Like Force Quit in the Dock: kills the app without letting it save or ask.
    func forceQuit(_ item: WindowItem) -> QuitOutcome {
        guard let app = NSRunningApplication(processIdentifier: item.processID),
              !app.isTerminated else {
            return .alreadyTerminated
        }
        if app.forceTerminate() {
            return .requested
        }
        return app.isTerminated ? .alreadyTerminated : .failed
    }

    private func pressClose(on window: AXUIElement) -> Bool {
        if let closeButton: AXUIElement = value(window, attribute: kAXCloseButtonAttribute),
           AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success {
            return true
        }
        // Some apps expose a Cancel action on sheets / utility windows.
        if AXUIElementPerformAction(window, kAXCancelAction as CFString) == .success {
            return true
        }
        return false
    }

    private func matchingWindow(_ item: WindowItem, in application: AXUIElement) -> AXUIElement? {
        guard let windows: [AXUIElement] = value(application, attribute: kAXWindowsAttribute) else { return nil }
        if let byNumber = windows.first(where: { windowNumber(of: $0) == item.physicalWindowID }) {
            return byNumber
        }
        return windows.max { score($0, item) < score($1, item) }
    }

    private func windowNumber(of element: AXUIElement) -> CGWindowID? {
        // Public AX attribute that matches CGWindowID on modern macOS.
        if let number: NSNumber = value(element, attribute: "AXWindowNumber") {
            return CGWindowID(number.uint32Value)
        }
        if let number: Int = value(element, attribute: "AXWindowNumber") {
            return CGWindowID(number)
        }
        return nil
    }

    private func score(_ element: AXUIElement, _ item: WindowItem) -> Double {
        let title: String = value(element, attribute: kAXTitleAttribute) ?? ""
        var position: CFTypeRef?
        var size: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size)
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        if let position { AXValueGetValue(position as! AXValue, .cgPoint, &point) }
        if let size { AXValueGetValue(size as! AXValue, .cgSize, &dimensions) }
        return WindowMatchCandidate(title: title, frame: CGRect(origin: point, size: dimensions)).score(for: item)
    }

    private func value<T>(_ element: AXUIElement, attribute: String) -> T? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result as? T
    }
}
