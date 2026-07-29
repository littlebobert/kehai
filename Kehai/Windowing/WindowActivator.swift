import AppKit
import ApplicationServices

struct WindowMatchCandidate: Sendable {
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
    func activate(_ item: WindowItem) {
        guard let app = NSRunningApplication(processIdentifier: item.processID) else { return }
        app.activate(options: [.activateAllWindows])
        raiseWindow(item)
    }

    /// Raise the target window for a drag-redirect without forcing every app window up first.
    func activateForDragRedirect(_ item: WindowItem) {
        guard let app = NSRunningApplication(processIdentifier: item.processID) else { return }
        app.activate(options: [])
        raiseWindow(item)
    }

    private func raiseWindow(_ item: WindowItem) {
        let application = AXUIElementCreateApplication(item.processID)
        guard let best = matchingWindow(item, in: application) else { return }
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
                   self.windowNumber(of: byID) == item.id {
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

    @discardableResult
    func quit(_ item: WindowItem) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: item.processID),
              !app.isTerminated else { return false }
        return app.terminate()
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
        if let byNumber = windows.first(where: { windowNumber(of: $0) == item.id }) {
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
