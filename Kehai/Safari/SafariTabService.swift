import AppKit
import ApplicationServices

actor SafariTabService {
    enum SafariError: LocalizedError {
        case notRunning
        case automationDenied(OSStatus)
        case invalidReply

        var errorDescription: String? {
            switch self {
            case .notRunning: L10n.string("Open Safari, then try again.")
            case .automationDenied(let status): L10n.format("Safari Automation was not enabled (error %lld).", Int64(status))
            case .invalidReply: L10n.string("Safari returned an unexpected response.")
            }
        }
    }

    func requestAutomationAccess() throws {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first != nil else {
            throw SafariError.notRunning
        }
        _ = try execute("tell application \"Safari\" to get name")
    }

    func listTabs() throws -> [SafariTab] {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first != nil else { return [] }
        let source = """
        tell application "Safari"
            set rows to {}
            repeat with wi from 1 to count of windows
                set currentIndex to index of current tab of window wi
                repeat with ti from 1 to count of tabs of window wi
                    set t to tab ti of window wi
                    set end of rows to (wi as text) & tab & (ti as text) & tab & (name of t) & tab & (URL of t) & tab & ((ti = currentIndex) as text)
                end repeat
            end repeat
            set AppleScript's text item delimiters to linefeed
            return rows as text
        end tell
        """
        let output = try execute(source)
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5, let window = Int(fields[0]), let tab = Int(fields[1]) else { return nil }
            return SafariTab(windowIndex: window, tabIndex: tab, title: fields[2], url: fields[3], isCurrent: fields[4].lowercased() == "true")
        }
    }

    func activate(_ target: SafariTab) throws {
        let tabs = try listTabs()
        let match = tabs.first { $0.url == target.url && $0.title == target.title } ?? tabs.first { $0.url == target.url }
        guard let match else { throw SafariError.invalidReply }
        let source = """
        tell application "Safari"
            set current tab of window \(match.windowIndex) to tab \(match.tabIndex) of window \(match.windowIndex)
            activate
        end tell
        """
        _ = try execute(source)
    }

    static func resolve(_ target: SafariTab, in candidates: [SafariTab]) -> SafariTab? {
        candidates.first { $0.url == target.url && $0.title == target.title }
            ?? candidates.first { $0.url == target.url }
    }

    private func execute(_ source: String) throws -> String {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source), let result = script.executeAndReturnError(&error).stringValue else {
            if (error?[NSAppleScript.errorNumber] as? Int) == -1743 { throw SafariError.automationDenied(-1743) }
            throw SafariError.invalidReply
        }
        return result
    }
}
