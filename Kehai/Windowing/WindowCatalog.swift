import AppKit
import ApplicationServices
import OSLog
import ScreenCaptureKit

@MainActor
final class WindowCatalog {
    private let logger = Logger(subsystem: "com.justin.Kehai", category: "WindowCatalog")
    private let excludedApps: ExcludedAppStore

    init(excludedApps: ExcludedAppStore) {
        self.excludedApps = excludedApps
    }

    func windows(lastSeen: [CGWindowID: Date]) async throws -> [(WindowItem, SCWindow)] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let candidates = content.windows.filter { window in
            guard let app = window.owningApplication else { return false }
            return app.processID != ownPID
                && !excludedApps.contains(bundleIdentifier: app.bundleIdentifier)
                && window.windowLayer == 0
                && window.frame.width >= 160
                && window.frame.height >= 100
        }
        let candidatesByProcess = Dictionary(grouping: candidates, by: { $0.owningApplication!.processID })
        var accessibilityWindows: [pid_t: [AccessibilityWindowSignature]] = [:]
        for (processID, _) in candidatesByProcess {
            if let signatures = accessibilityWindowSignatures(for: processID) {
                accessibilityWindows[processID] = signatures
            }
        }

        return candidates.compactMap { window in
            guard let app = window.owningApplication else { return nil }
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty || app.applicationName == "Terminal" else { return nil }

            if let signatures = accessibilityWindows[app.processID],
               !signatures.contains(where: { $0.matches(title: title, frame: window.frame) }) {
                logger.notice("Excluded non-AX window id=\(window.windowID) app=\(app.applicationName, privacy: .public) title=\(title, privacy: .public) onScreen=\(window.isOnScreen)")
                return nil
            }

            let item = WindowItem(
                id: window.windowID,
                processID: app.processID,
                appName: app.applicationName,
                bundleIdentifier: app.bundleIdentifier,
                title: title.isEmpty ? app.applicationName : title,
                frame: window.frame,
                isOnScreen: window.isOnScreen,
                lastSeen: lastSeen[window.windowID] ?? Date(),
                appIcon: NSRunningApplication(processIdentifier: app.processID)?.icon
            )
            return (item, window)
        }
    }

    private func accessibilityWindowSignatures(for processID: pid_t) -> [AccessibilityWindowSignature]? {
        let application = AXUIElementCreateApplication(processID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }

        return windows.compactMap { window in
            var subroleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleValue) == .success,
               let subrole = subroleValue as? String,
               subrole != kAXStandardWindowSubrole as String,
               subrole != kAXDialogSubrole as String {
                return nil
            }

            var titleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
            let title = (titleValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            var positionValue: CFTypeRef?
            var sizeValue: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue)
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)
            var origin = CGPoint.zero
            var size = CGSize.zero
            if let positionValue, CFGetTypeID(positionValue) == AXValueGetTypeID() {
                AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
            }
            if let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID() {
                AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
            }
            return AccessibilityWindowSignature(title: title, frame: CGRect(origin: origin, size: size))
        }
    }
}

private struct AccessibilityWindowSignature {
    let title: String
    let frame: CGRect

    func matches(title candidateTitle: String, frame candidateFrame: CGRect) -> Bool {
        let titleMatches = title == candidateTitle
            || (!title.isEmpty && !candidateTitle.isEmpty
                && (title.localizedCaseInsensitiveContains(candidateTitle)
                    || candidateTitle.localizedCaseInsensitiveContains(title)))
        let frameDistance = abs(frame.origin.x - candidateFrame.origin.x)
            + abs(frame.origin.y - candidateFrame.origin.y)
            + abs(frame.width - candidateFrame.width)
            + abs(frame.height - candidateFrame.height)
        return titleMatches && frameDistance <= 24
    }
}
