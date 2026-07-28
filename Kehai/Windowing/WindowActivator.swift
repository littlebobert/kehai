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
        let application = AXUIElementCreateApplication(item.processID)
        guard let best = matchingWindow(item, in: application) else { return }
        AXUIElementSetAttributeValue(best, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(best, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, best)
    }

    @discardableResult
    func close(_ item: WindowItem, completion: @escaping (Bool) -> Void) -> Bool {
        let application = AXUIElementCreateApplication(item.processID)
        guard let window = matchingWindow(item, in: application),
              let closeButton: AXUIElement = value(window, attribute: kAXCloseButtonAttribute),
              AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success else { return false }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            let application = AXUIElementCreateApplication(item.processID)
            if let remainingWindow = self.matchingWindow(item, in: application),
               self.score(remainingWindow, item) >= 55,
               let app = NSRunningApplication(processIdentifier: item.processID) {
                completion(false)
                app.activate(options: [.activateAllWindows])
                AXUIElementPerformAction(remainingWindow, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, remainingWindow)
            } else {
                completion(true)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        return true
    }

    private func matchingWindow(_ item: WindowItem, in application: AXUIElement) -> AXUIElement? {
        guard let windows: [AXUIElement] = value(application, attribute: kAXWindowsAttribute) else { return nil }
        return windows.max { score($0, item) < score($1, item) }
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
