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
                  !runningApplication.isTerminated,
                  Self.isUserSwitchableApplication(runningApplication) else { return false }
            return app.processID != ownPID
                && !excludedApps.contains(bundleIdentifier: app.bundleIdentifier)
                && window.windowLayer == 0
                && window.frame.width >= 160
                && window.frame.height >= 100
        }
        let candidatesByProcess = Dictionary(grouping: candidates, by: { $0.owningApplication!.processID })
        let liveWindowIDs = await Task.detached(priority: .userInitiated) {
            currentCoreGraphicsWindowIDs()
        }.value

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
        let validatedSafariWindowIDs = validatedSafariWindowIDs(
            candidates: candidates,
            accessibilityWindows: accessibilityWindows,
            liveWindowIDs: liveWindowIDs
        )

        let items: [(WindowItem, SCWindow)] = candidates.compactMap { window -> (WindowItem, SCWindow)? in
            guard let app = window.owningApplication else { return nil }
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty || app.applicationName == "Terminal" else { return nil }

            // For Safari, a successful AX query returning zero windows is authoritative:
            // the process can remain running after its last browser window closes while
            // ScreenCaptureKit continues reporting cached window records.
            if app.bundleIdentifier == "com.apple.Safari",
               accessibilityWindows[app.processID] != nil,
               !validatedSafariWindowIDs.contains(window.windowID) {
                logger.notice("Excluded ScreenCaptureKit Safari window without a unique Accessibility match")
                SafeDiagnosticLog.shared.record("window-catalog: excluded unmatched Safari window")
                return nil
            }

            // A present entry means AX successfully returned an inventory, including
            // an authoritative empty inventory when an app remains running with no windows.
            // A missing entry means AX failed, so retain ScreenCaptureKit's candidate.
            if app.bundleIdentifier != "com.apple.Safari",
               let signatures = accessibilityWindows[app.processID],
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

private func validatedSafariWindowIDs(
    candidates: [SCWindow],
    accessibilityWindows: [pid_t: [AccessibilityWindowSignature]],
    liveWindowIDs: Set<CGWindowID>
) -> Set<CGWindowID> {
    let safariCandidates = candidates.filter { $0.owningApplication?.bundleIdentifier == "com.apple.Safari" }
    var validated: Set<CGWindowID> = []

    for (processID, processCandidates) in Dictionary(grouping: safariCandidates, by: { $0.owningApplication!.processID }) {
        guard let signatures = accessibilityWindows[processID], !signatures.isEmpty else { continue }
        var unmatchedSignatures = signatures

        for candidate in processCandidates where liveWindowIDs.contains(candidate.windowID) {
            guard let matchIndex = unmatchedSignatures.firstIndex(where: { $0.windowID == candidate.windowID }) else { continue }
            validated.insert(candidate.windowID)
            unmatchedSignatures.remove(at: matchIndex)
        }

        unmatchedSignatures.removeAll { $0.windowID != nil }
        let unmatchedCandidates = processCandidates
            .filter { liveWindowIDs.contains($0.windowID) && !validated.contains($0.windowID) }
            .sorted { left, right in
                if left.isOnScreen != right.isOnScreen { return left.isOnScreen }
                return left.windowID > right.windowID
            }

        for candidate in unmatchedCandidates {
            let title = candidate.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let matchIndex = unmatchedSignatures.indices
                .filter({ unmatchedSignatures[$0].matches(title: title, frame: candidate.frame) })
                .min(by: {
                    unmatchedSignatures[$0].matchDistance(title: title, frame: candidate.frame)
                        < unmatchedSignatures[$1].matchDistance(title: title, frame: candidate.frame)
                }) else { continue }
            validated.insert(candidate.windowID)
            unmatchedSignatures.remove(at: matchIndex)
        }
    }

    return validated
}

private func currentCoreGraphicsWindowIDs() -> Set<CGWindowID> {
    guard let windowInfo = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
        as? [[CFString: Any]] else { return [] }
    return Set(windowInfo.compactMap { info in
        (info[kCGWindowNumber] as? NSNumber).map { CGWindowID($0.uint32Value) }
    })
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

        var windowNumberValue: CFTypeRef?
        AXUIElementCopyAttributeValue(window, "AXWindowNumber" as CFString, &windowNumberValue)
        let windowID = (windowNumberValue as? NSNumber).map { CGWindowID($0.uint32Value) }

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
        return AccessibilityWindowSignature(
            windowID: windowID,
            title: title,
            frame: CGRect(origin: origin, size: size)
        )
    }
}

private struct AccessibilityWindowSignature: Sendable {
    let windowID: CGWindowID?
    let title: String
    let frame: CGRect

    func matches(title candidateTitle: String, frame candidateFrame: CGRect) -> Bool {
        let titleMatches = title == candidateTitle
            || (!title.isEmpty && !candidateTitle.isEmpty
                && (title.localizedCaseInsensitiveContains(candidateTitle)
                    || candidateTitle.localizedCaseInsensitiveContains(title)))
        return titleMatches && matchDistance(title: candidateTitle, frame: candidateFrame) <= 24
    }

    func matchDistance(title candidateTitle: String, frame candidateFrame: CGRect) -> CGFloat {
        abs(frame.origin.x - candidateFrame.origin.x)
            + abs(frame.origin.y - candidateFrame.origin.y)
            + abs(frame.width - candidateFrame.width)
            + abs(frame.height - candidateFrame.height)
    }
}
