import AppKit
import Foundation

struct DiagnosticSnapshot {
    let windowCount: Int
    let usableThumbnailCount: Int
    let groupCount: Int
    let excludedAppCount: Int
    let screenCaptureGranted: Bool
    let accessibilityGranted: Bool
    let safariAutomationStatus: String
    let isLoading: Bool
    let isGrouping: Bool
}

@MainActor
final class DiagnosticReportService {
    private let recipient = "justin.garcia@gmail.com"

    func draftBugReport(snapshot: DiagnosticSnapshot) throws {
        guard let service = NSSharingService(named: .composeEmail) else {
            throw DiagnosticReportError.emailUnavailable
        }
        service.recipients = [recipient]
        service.subject = "Kehai Bug Report"
        service.perform(withItems: [
            "Please describe what happened and what you expected.\n\n\(reportText(snapshot: snapshot))"
        ])
    }

    private func reportText(snapshot: DiagnosticSnapshot) -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let report = """
        Kehai Privacy-Safe Diagnostics
        Generated: \(ISO8601DateFormatter().string(from: Date()))

        App
        Version: \(version)
        Build: \(build)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Architecture: \(architecture)

        Permissions
        Screen Recording: \(snapshot.screenCaptureGranted ? "granted" : "not granted")
        Accessibility: \(snapshot.accessibilityGranted ? "granted" : "not granted")
        Safari Automation: \(safeSafariStatus(snapshot.safariAutomationStatus))

        Aggregate State
        Windows: \(snapshot.windowCount)
        Usable thumbnails: \(snapshot.usableThumbnailCount)
        Task groups: \(snapshot.groupCount)
        Excluded apps: \(snapshot.excludedAppCount)
        Loading windows: \(snapshot.isLoading)
        Generating groups: \(snapshot.isGrouping)

        Recent Sanitized Events
        \(SafeDiagnosticLog.shared.recentText().isEmpty ? "No events recorded." : SafeDiagnosticLog.shared.recentText())

        Privacy
        This report intentionally excludes names, email addresses, app names, bundle identifiers,
        window titles, URLs, repository IDs, file paths, screenshots, API keys, window IDs,
        task-group names, search queries, identifiable activity history, and unified system log messages.
        GitHub organization and repository names may appear only in repository-ranking diagnostics.
        """
        return report
    }

    private var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private func safeSafariStatus(_ status: String) -> String {
        switch status {
        case "Granted", "Needs permission", "Optional", "Requesting": status.lowercased()
        default: "unknown"
        }
    }
}

enum DiagnosticReportError: LocalizedError {
    case emailUnavailable

    var errorDescription: String? {
        L10n.string("No email compose service is available.")
    }
}
