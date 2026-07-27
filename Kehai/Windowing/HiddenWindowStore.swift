import CoreGraphics
import Foundation

@MainActor
final class HiddenWindowStore {
    private struct Fingerprint: Codable, Hashable {
        let bundleIdentifier: String
        let appName: String
        let normalizedTitle: String
        let safariURLs: Set<String>
        let frame: CGRect

        init(window: WindowItem) {
            bundleIdentifier = window.bundleIdentifier ?? ""
            appName = window.appName.lowercased()
            normalizedTitle = Self.normalize(window.title)
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
                score += 140
            } else if !normalizedTitle.isEmpty, !candidateTitle.isEmpty,
                      normalizedTitle.contains(candidateTitle) || candidateTitle.contains(normalizedTitle) {
                score += 70
            }
            let candidateURLs = Set(window.safariTabs.map { $0.url.lowercased() })
            if !safariURLs.isDisjoint(with: candidateURLs) { score += 180 }

            let frameDistance = abs(frame.origin.x - window.frame.origin.x)
                + abs(frame.origin.y - window.frame.origin.y)
                + abs(frame.width - window.frame.width)
                + abs(frame.height - window.frame.height)
            score += max(0, 45 - Double(frameDistance) / 20)
            return score >= 70 ? score : nil
        }

        private static func normalize(_ value: String) -> String {
            value.lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }

    private static let defaultsKey = "hiddenWindows.fingerprints.v1"
    private var fingerprints: Set<Fingerprint>
    private var liveWindowIDs = Set<CGWindowID>()

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(Set<Fingerprint>.self, from: data) {
            fingerprints = decoded
        } else {
            fingerprints = []
        }
    }

    func reconcile(with windows: [WindowItem]) {
        liveWindowIDs = Set(windows.filter(isHidden).map(\.id))
    }

    func isHidden(_ window: WindowItem) -> Bool {
        liveWindowIDs.contains(window.id) || fingerprints.contains { $0.score(for: window) != nil }
    }

    func hide(_ window: WindowItem) {
        fingerprints.insert(Fingerprint(window: window))
        liveWindowIDs.insert(window.id)
        save()
    }

    func unhide(_ window: WindowItem) {
        fingerprints = fingerprints.filter { $0.score(for: window) == nil }
        liveWindowIDs.remove(window.id)
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(fingerprints) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
