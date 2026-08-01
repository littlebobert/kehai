import AppKit
import ApplicationServices

@MainActor
final class DockBadgeMonitor {
    struct Snapshot: Equatable {
        var byBundleIdentifier: [String: String] = [:]
        var byAppName: [String: String] = [:]
    }

    var changed: ((Snapshot) -> Void)?

    private var task: Task<Void, Never>?
    private var lastSnapshot = Snapshot()

    func setActive(_ active: Bool) {
        if active {
            guard task == nil else { return }
            refresh()
            task = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        return
                    }
                    guard let self else { return }
                    self.refresh()
                }
            }
        } else {
            task?.cancel()
            task = nil
        }
    }

    private func refresh() {
        let snapshot = Self.readSnapshot()
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        changed?(snapshot)
    }

    private static func readSnapshot() -> Snapshot {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.dock"
              ).first else { return Snapshot() }

        let root = AXUIElementCreateApplication(dock.processIdentifier)
        var snapshot = Snapshot()
        collectBadges(from: root, depth: 0, snapshot: &snapshot)
        return snapshot
    }

    private static func collectBadges(
        from element: AXUIElement,
        depth: Int,
        snapshot: inout Snapshot
    ) {
        guard depth <= 4 else { return }

        if let badge = stringAttribute("AXStatusLabel", from: element),
           !badge.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let title = stringAttribute(kAXTitleAttribute, from: element), !title.isEmpty {
                snapshot.byAppName[title] = badge
            }
            if let url = urlAttribute(from: element),
               let bundleIdentifier = Bundle(url: url)?.bundleIdentifier {
                snapshot.byBundleIdentifier[bundleIdentifier] = badge
            }
        }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success,
        let children = value as? [AXUIElement] else { return }

        for child in children {
            collectBadges(from: child, depth: depth + 1, snapshot: &snapshot)
        }
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func urlAttribute(from element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXURLAttribute as CFString,
            &value
        ) == .success else { return nil }
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }
}
