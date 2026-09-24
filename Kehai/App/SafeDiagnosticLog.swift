import Foundation

final class SafeDiagnosticLog: @unchecked Sendable {
    static let shared = SafeDiagnosticLog()

    private let lock = NSLock()
    private var entries: [Entry] = []

    private struct Entry {
        let date: Date
        let event: String
        var repetitionCount: Int
    }

    private init() {}

    func record(_ event: String) {
        lock.lock()
        if entries.last?.event == event {
            entries[entries.count - 1].repetitionCount += 1
        } else {
            entries.append(Entry(date: Date(), event: event, repetitionCount: 1))
            entries = Array(entries.suffix(1000))
        }
        lock.unlock()
    }

    func recentText() -> String {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return snapshot.map { entry in
            let repetition = entry.repetitionCount > 1 ? " repeated=\(entry.repetitionCount)" : ""
            return "\(formatter.string(from: entry.date)) \(entry.event)\(repetition)"
        }.joined(separator: "\n")
    }
}
