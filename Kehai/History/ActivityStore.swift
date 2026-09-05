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
    private var hasHydratedStoredEvents: Bool
    private var hydrationTask: Task<[ActivityEvent], Never>?

    init(fileURL: URL? = nil, loadsStoredEvents: Bool = true) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.fileURL = fileURL ?? base.appending(path: "Kehai/activity.json")
        hasHydratedStoredEvents = loadsStoredEvents
        if loadsStoredEvents {
            events = Self.loadEvents(from: self.fileURL)
        }
    }

    func hydrate() async {
        guard !hasHydratedStoredEvents else { return }
        let task: Task<[ActivityEvent], Never>
        if let hydrationTask {
            task = hydrationTask
        } else {
            let fileURL = fileURL
            task = Task.detached(priority: .utility) {
                Self.loadEvents(from: fileURL)
            }
            hydrationTask = task
        }
        let storedEvents = await task.value
        guard !hasHydratedStoredEvents else { return }
        events = Array((storedEvents + events).suffix(5_000))
        hasHydratedStoredEvents = true
        hydrationTask = nil
    }

    func record(_ window: WindowItem, at date: Date = Date()) async {
        await hydrate()
        events.append(ActivityEvent(windowID: window.id, appName: window.appName, title: window.title, date: date))
        events = Array(events.suffix(5_000))
        persist()
    }

    func lastSeen() async -> [CGWindowID: Date] {
        await hydrate()
        return Dictionary(events.map { ($0.windowID, $0.date) }, uniquingKeysWith: max)
    }

    func recentEvents(limit: Int = 100) async -> [ActivityEvent] {
        await hydrate()
        return Array(events.suffix(limit))
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(events) { try? data.write(to: fileURL, options: .atomic) }
    }

    nonisolated private static func loadEvents(from fileURL: URL) -> [ActivityEvent] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ActivityEvent].self, from: data) else {
            return []
        }
        return decoded
    }
}
