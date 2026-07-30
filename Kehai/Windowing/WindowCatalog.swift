import AppKit
import ApplicationServices
import OSLog
import ScreenCaptureKit

@MainActor
final class WindowCatalog {
    private let logger = Logger(subsystem: "com.justin.Kehai", category: "WindowCatalog")
    private let excludedApps: ExcludedAppStore
    private var iconCache: [String: NSImage] = [:]

    init(excludedApps: ExcludedAppStore) {
        self.excludedApps = excludedApps
    }

    func windows(lastSeen: [CGWindowID: Date]) async throws -> [(WindowItem, SCWindow)] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let candidates = content.windows.filter { window in
            guard let app = window.owningApplication,
                  let runningApplication = NSRunningApplication(processIdentifier: app.processID),
                  Self.isUserSwitchableApplication(runningApplication) else { return false }
            return app.processID != ownPID
                && !excludedApps.contains(bundleIdentifier: app.bundleIdentifier)
                && window.windowLayer == 0
                && window.frame.width >= 160
                && window.frame.height >= 100
        }
        let candidatesByProcess = Dictionary(grouping: candidates, by: { $0.owningApplication!.processID })

        // AX IPC is synchronous and can stall for hundreds of ms per app.
        // Run it off the main actor so background inventory doesn't beachball the UI.
        let processIDs = Array(candidatesByProcess.keys)
        let accessibilityWindows = await Task.detached(priority: .userInitiated) {
            var result: [pid_t: [AccessibilityWindowSignature]] = [:]
            result.reserveCapacity(processIDs.count)
            for processID in processIDs {
                if Task.isCancelled { break }
                if let signatures = accessibilityWindowSignatures(for: processID) {
                    result[processID] = signatures
                }
            }
            return result
        }.value

        let items: [(WindowItem, SCWindow)] = candidates.compactMap { window -> (WindowItem, SCWindow)? in
            guard let app = window.owningApplication else { return nil }
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty || app.applicationName == "Terminal" else { return nil }

            // Only apply the AX cross-check when Accessibility actually returned
            // windows. An empty list often means AX is temporarily unavailable
            // (common mid-drag / under heavy load) — don't wipe the inventory.
            if let signatures = accessibilityWindows[app.processID], !signatures.isEmpty,
               !signatures.contains(where: { $0.matches(title: title, frame: window.frame) }) {
                logger.notice("Excluded ScreenCaptureKit window without a matching Accessibility window")
                SafeDiagnosticLog.shared.record("window-catalog: excluded unmatched window")
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
                lastSeen: lastSeen[window.windowID],
                appIcon: cachedIcon(for: app)
            )
            return (item, window)
        }
        let orderedItems = WindowItem.orderedByRecency(items.map(\.0))
        let pairsByID: [CGWindowID: (WindowItem, SCWindow)] = Dictionary(
            uniqueKeysWithValues: items.map { ($0.0.id, $0) }
        )
        return orderedItems.compactMap { pairsByID[$0.id] }
    }

    private static func isUserSwitchableApplication(_ application: NSRunningApplication) -> Bool {
        guard application.activationPolicy == .regular,
              let executableURL = application.executableURL else { return false }
        let pathComponents = executableURL.pathComponents
        guard !pathComponents.contains(where: { $0.hasSuffix(".appex") }) else { return false }

        guard let bundleURL = application.bundleURL,
              let bundle = Bundle(url: bundleURL) else { return true }
        return (bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool) != true
            && (bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool) != true
            && bundle.object(forInfoDictionaryKey: "NSExtension") == nil
    }

    private func cachedIcon(for app: SCRunningApplication) -> NSImage? {
        let cacheKey = app.bundleIdentifier.isEmpty ? "pid:\(app.processID)" : app.bundleIdentifier
        if let cached = iconCache[cacheKey] { return cached }
        guard let icon = NSRunningApplication(processIdentifier: app.processID)?.icon else { return nil }
        iconCache[cacheKey] = icon
        return icon
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

private struct AccessibilityWindowSignature: Sendable {
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
