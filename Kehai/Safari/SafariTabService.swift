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
            set fieldSeparator to ASCII character 31
            set recordSeparator to ASCII character 30
            set rows to {}
            repeat with wi from 1 to count of windows
                try
                    set currentIndex to index of current tab of window wi
                on error
                    set currentIndex to 0
                end try
                repeat with ti from 1 to count of tabs of window wi
                    set t to tab ti of window wi
                    try
                        set tabTitle to name of t as text
                    on error
                        set tabTitle to ""
                    end try
                    try
                        set tabURL to URL of t as text
                    on error
                        set tabURL to ""
                    end try
                    set end of rows to (wi as text) & fieldSeparator & (ti as text) & fieldSeparator & tabTitle & fieldSeparator & tabURL & fieldSeparator & ((ti = currentIndex) as text)
                end repeat
            end repeat
            if (count of rows) is 0 then return ""
            set AppleScript's text item delimiters to recordSeparator
            return rows as text
        end tell
        """
        return Self.parseTabs(try execute(source))
    }

    func activate(_ target: SafariTab) throws {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first != nil else {
            throw SafariError.notRunning
        }
        if try activateAtRecordedPosition(target) { return }

        let tabs = try listTabs()
        guard let match = Self.resolve(target, in: tabs) else { throw SafariError.invalidReply }
        try activateWithoutValidation(match)
    }

    private func activateAtRecordedPosition(_ target: SafariTab) throws -> Bool {
        guard target.windowIndex > 0, target.tabIndex > 0, !target.url.isEmpty else { return false }
        let expectedURL = Self.appleScriptStringLiteral(target.url)
        let source = """
        tell application "Safari"
            try
                set targetWindow to window \(target.windowIndex)
                set targetTab to tab \(target.tabIndex) of targetWindow
                set actualURL to ""
                try
                    set actualURL to URL of targetTab as text
                end try
                if actualURL is \(expectedURL) then
                    set current tab of targetWindow to targetTab
                    activate
                    return "true"
                end if
            end try
            return "false"
        end tell
        """
        return try execute(source).lowercased() == "true"
    }

    private func activateWithoutValidation(_ tab: SafariTab) throws {
        let source = """
        tell application "Safari"
            set current tab of window \(tab.windowIndex) to tab \(tab.tabIndex) of window \(tab.windowIndex)
            activate
        end tell
        """
        _ = try execute(source)
    }

    static func resolve(_ target: SafariTab, in candidates: [SafariTab]) -> SafariTab? {
        candidates.first { $0.url == target.url && $0.title == target.title }
            ?? candidates.first { $0.url == target.url }
    }

    static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    static func parseTabs(_ output: String) -> [SafariTab] {
        output.split(separator: Character("\u{001E}"), omittingEmptySubsequences: true).compactMap { record in
            let fields = record.split(separator: Character("\u{001F}"), omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5,
                  let window = Int(fields[0]),
                  let tab = Int(fields[1]) else { return nil }
            return SafariTab(
                windowIndex: window,
                tabIndex: tab,
                title: fields[2],
                url: fields[3] == "missing value" ? "" : fields[3],
                isCurrent: fields[4].lowercased() == "true"
            )
        }
    }

    private func execute(_ source: String) throws -> String {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw SafariError.invalidReply }
        let result = script.executeAndReturnError(&error)
        if let errorNumber = error?[NSAppleScript.errorNumber] as? Int {
            if errorNumber == -1743 { throw SafariError.automationDenied(-1743) }
            let message = error?[NSAppleScript.errorMessage] as? String
            throw NSError(
                domain: "SafariTabService.AppleScript",
                code: errorNumber,
                userInfo: [NSLocalizedDescriptionKey: message ?? L10n.string("Safari returned an unexpected response.")]
            )
        }
        if let value = result.stringValue { return value }
        if result.descriptorType == typeNull { return "" }
        throw SafariError.invalidReply
    }
}
