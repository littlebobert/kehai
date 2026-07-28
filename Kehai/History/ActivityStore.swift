import CoreGraphics
import Foundation

struct ActivityEvent: Codable, Sendable {
    let windowID: UInt32
    let appName: String
    let title: String
    let date: Date
}

actor ActivityStore {
    private var events: [ActivityEvent] = []
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.fileURL = fileURL ?? base.appending(path: "Kehai/activity.json")
        if let data = try? Data(contentsOf: self.fileURL), let decoded = try? JSONDecoder().decode([ActivityEvent].self, from: data) {
            events = decoded
        }
    }

    func record(_ window: WindowItem, at date: Date = Date()) {
        events.append(ActivityEvent(windowID: window.id, appName: window.appName, title: window.title, date: date))
        events = Array(events.suffix(5_000))
        persist()
    }

    func lastSeen() -> [CGWindowID: Date] {
        Dictionary(events.map { ($0.windowID, $0.date) }, uniquingKeysWith: max)
    }

    func recentEvents(limit: Int = 100) -> [ActivityEvent] { Array(events.suffix(limit)) }

    private func persist() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(events) { try? data.write(to: fileURL, options: .atomic) }
    }
}
