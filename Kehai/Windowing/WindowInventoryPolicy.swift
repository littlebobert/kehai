import AppKit

enum WindowInventoryPolicy {
    static func isProcessRunning(_ processID: pid_t) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: processID) else { return false }
        return !application.isTerminated
    }

    /// True when `current` looks like a transient ScreenCaptureKit / Accessibility
    /// snapshot rather than a real close. Windows from apps that have already quit
    /// are not protected — otherwise quitting QuickTime with many movies open would
    /// look like a 60% inventory collapse and freeze the ghost windows in place.
    /// Windows Accessibility positively contradicted are not protected either:
    /// closing several windows of a running app is a real close, not a sparse read.
    static func isSparseSnapshot(
        previous: [WindowItem],
        current: [WindowItem],
        accessibilityContradictedWindowIDs: Set<CGWindowID> = [],
        isProcessRunning: (pid_t) -> Bool = isProcessRunning
    ) -> Bool {
        let currentIDs = Set(current.map(\.id))
        let protectedPreviousIDs = Set(previous
            .filter {
                $0.bundleIdentifier != "com.apple.Safari"
                    && isProcessRunning($0.processID)
                    && !accessibilityContradictedWindowIDs.contains($0.id)
            }
            .map(\.id))
        let protectedCurrentCount = current
            .filter { $0.bundleIdentifier != "com.apple.Safari" }
            .count
        let removedCount = protectedPreviousIDs.subtracting(currentIDs).count
        return !protectedPreviousIDs.isEmpty
            && removedCount > 0
            && protectedCurrentCount < protectedPreviousIDs.count
            && Double(protectedCurrentCount) < Double(protectedPreviousIDs.count) * 0.6
    }
}

/// Escape hatch for `isSparseSnapshot`. A transient ScreenCaptureKit / Accessibility
/// read is sparse once or twice; a snapshot that keeps coming back with the same
/// windows for several reconciles spanning real time is the truth (typically after
/// sleep/wake or a display reconfigure). Without this, a large pre-sleep inventory
/// blocks every later inventory and, with it, every thumbnail refresh until relaunch.
struct SparseSnapshotStreak {
    static let acceptanceCount = 3
    static let acceptanceInterval: TimeInterval = 5

    private(set) var count = 0
    private var firstRejectionDate: Date?
    private var lastIDs: Set<CGWindowID> = []

    /// Records that a sparse snapshot was rejected. Returns true when the streak
    /// is long and stable enough that the snapshot should be accepted instead.
    mutating func recordRejection(currentIDs: Set<CGWindowID>, at date: Date = Date()) -> Bool {
        if count > 0, Self.isSimilar(currentIDs, lastIDs) {
            count += 1
        } else {
            count = 1
            firstRejectionDate = date
        }
        lastIDs = currentIDs
        guard count >= Self.acceptanceCount, let firstRejectionDate else { return false }
        return date.timeIntervalSince(firstRejectionDate) >= Self.acceptanceInterval
    }

    mutating func reset() {
        count = 0
        firstRejectionDate = nil
        lastIDs = []
    }

    /// Windows open and close between ticks; a couple of differences is still "the same" snapshot.
    private static func isSimilar(_ lhs: Set<CGWindowID>, _ rhs: Set<CGWindowID>) -> Bool {
        lhs.symmetricDifference(rhs).count <= 2
    }
}
