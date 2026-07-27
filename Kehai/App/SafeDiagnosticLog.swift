import Foundation

final class SafeDiagnosticLog: @unchecked Sendable {
    static let shared = SafeDiagnosticLog()

    private let lock = NSLock()
    private var entries: [Entry] = []

    private struct Entry {
        let date: Date
        let event: String
    }

    private init() {}

    func record(_ event: String) {
        lock.lock()
        entries.append(Entry(date: Date(), event: event))
        entries = Array(entries.suffix(200))
        lock.unlock()
    }

    func recentText() -> String {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        let formatter = ISO8601DateFormatter()
        return snapshot.map { "\(formatter.string(from: $0.date)) \($0.event)" }.joined(separator: "\n")
    }
}
