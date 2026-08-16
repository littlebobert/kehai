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
    static func isSparseSnapshot(
        previous: [WindowItem],
        current: [WindowItem],
        isProcessRunning: (pid_t) -> Bool = isProcessRunning
    ) -> Bool {
        let currentIDs = Set(current.map(\.id))
        let protectedPreviousIDs = Set(previous.lazy
            .filter { $0.bundleIdentifier != "com.apple.Safari" && isProcessRunning($0.processID) }
            .map(\.id))
        let protectedCurrentCount = current.lazy
            .filter { $0.bundleIdentifier != "com.apple.Safari" }
            .count
        let removedCount = protectedPreviousIDs.subtracting(currentIDs).count
        return !protectedPreviousIDs.isEmpty
            && removedCount > 0
            && protectedCurrentCount < protectedPreviousIDs.count
            && Double(protectedCurrentCount) < Double(protectedPreviousIDs.count) * 0.6
    }
}
