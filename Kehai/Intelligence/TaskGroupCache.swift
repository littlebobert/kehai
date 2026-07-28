import CoreGraphics
import Foundation

struct TaskGroupCacheReconciliation {
    let groups: [TaskGroup]
    let isStale: Bool
}

@MainActor
final class TaskGroupCache {
    private struct Cache: Codable {
        let generatedAt: Date
        let groups: [CachedGroup]
    }

    private struct CachedGroup: Codable {
        let name: String
        let members: [WindowFingerprint]
    }

    private struct WindowFingerprint: Codable, Hashable {
        let bundleIdentifier: String
        let appName: String
        let normalizedTitle: String
        let safariHosts: Set<String>
        let safariURLs: Set<String>
        let frame: CGRect

        init(window: WindowItem) {
            bundleIdentifier = window.bundleIdentifier ?? ""
            appName = window.appName.lowercased()
            normalizedTitle = Self.normalize(window.title)
            safariHosts = Set(window.safariTabs.map { $0.domain.lowercased() }.filter { !$0.isEmpty })
            safariURLs = Set(window.safariTabs.map { $0.url.lowercased() }.filter { !$0.isEmpty })
            frame = window.frame
        }

        func score(for window: WindowItem) -> Double? {
            let candidateBundle = window.bundleIdentifier ?? ""
            guard (!bundleIdentifier.isEmpty && bundleIdentifier == candidateBundle)
                    || (bundleIdentifier.isEmpty && appName == window.appName.lowercased()) else { return nil }

            let candidateTitle = Self.normalize(window.title)
            var score = 0.0
            if normalizedTitle == candidateTitle, !normalizedTitle.isEmpty {
                score += 120
            } else if !normalizedTitle.isEmpty, !candidateTitle.isEmpty,
                      normalizedTitle.contains(candidateTitle) || candidateTitle.contains(normalizedTitle) {
                score += 70
            }

            let candidateURLs = Set(window.safariTabs.map { $0.url.lowercased() })
            let candidateHosts = Set(window.safariTabs.map { $0.domain.lowercased() })
            if !safariURLs.isDisjoint(with: candidateURLs) { score += 160 }
            if !safariHosts.isDisjoint(with: candidateHosts) { score += 60 }

            let frameDistance = abs(frame.origin.x - window.frame.origin.x)
                + abs(frame.origin.y - window.frame.origin.y)
                + abs(frame.width - window.frame.width)
                + abs(frame.height - window.frame.height)
            score += max(0, 35 - Double(frameDistance) / 25)
            return score >= 55 ? score : nil
        }

        private static func normalize(_ value: String) -> String {
            value.lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }

    private static let defaultsKey = "taskGroups.cache.v1"
    private var cache: Cache?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey) {
            cache = try? JSONDecoder().decode(Cache.self, from: data)
        }
    }

    var hasCache: Bool { cache?.groups.isEmpty == false }
    var generatedAt: Date? { cache?.generatedAt }

    func reconcile(with windows: [WindowItem]) -> TaskGroupCacheReconciliation {
        guard let cache, !cache.groups.isEmpty else {
            return TaskGroupCacheReconciliation(groups: [], isStale: false)
        }

        var matchedWindowIDs = Set<CGWindowID>()
        var matchedFingerprints = Set<WindowFingerprint>()
        let groups = cache.groups.compactMap { cachedGroup -> TaskGroup? in
            let ids = cachedGroup.members.compactMap { fingerprint -> CGWindowID? in
                guard let match = windows.compactMap({ window -> (WindowItem, Double)? in
                    fingerprint.score(for: window).map { (window, $0) }
                }).max(by: { $0.1 < $1.1 })?.0 else { return nil }
                matchedWindowIDs.insert(match.id)
                matchedFingerprints.insert(fingerprint)
                return match.id
            }
            let uniqueIDs = Array(Set(ids)).sorted()
            guard !uniqueIDs.isEmpty else { return nil }
            return TaskGroup(name: cachedGroup.name, windowIDs: uniqueIDs)
        }

        let allFingerprints = Set(cache.groups.flatMap(\.members))
        let unmatchedCurrentRatio = windows.isEmpty ? 0 : Double(windows.count - matchedWindowIDs.count) / Double(windows.count)
        let disappearedRatio = allFingerprints.isEmpty ? 0 : Double(allFingerprints.count - matchedFingerprints.count) / Double(allFingerprints.count)
        let emptyGroupRatio = cache.groups.isEmpty ? 0 : Double(cache.groups.count - groups.count) / Double(cache.groups.count)
        let stale = unmatchedCurrentRatio > 0.30 || disappearedRatio > 0.50 || emptyGroupRatio > 0.34
        return TaskGroupCacheReconciliation(groups: groups, isStale: stale)
    }

    func save(groups: [TaskGroup], windows: [WindowItem]) {
        let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let cachedGroups = groups.compactMap { group -> CachedGroup? in
            let members = group.windowIDs.compactMap { windowsByID[$0] }.map(WindowFingerprint.init)
            guard !members.isEmpty else { return nil }
            return CachedGroup(name: group.name, members: members)
        }
        let newCache = Cache(generatedAt: Date(), groups: cachedGroups)
        guard let data = try? JSONEncoder().encode(newCache) else { return }
        cache = newCache
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
