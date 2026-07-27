import XCTest
@testable import Kehai

final class KehaiTests: XCTestCase {
    func testDustyAfterThreeDays() {
        let item = WindowItem(id: 1, processID: 1, appName: "Terminal", bundleIdentifier: "com.apple.Terminal", title: "Shell", frame: .zero, isOnScreen: true, lastSeen: Date().addingTimeInterval(-4 * 86_400))
        XCTAssertTrue(item.isDusty)
    }

    func testFreshWindowIsNotDusty() {
        let item = WindowItem(id: 1, processID: 1, appName: "Terminal", bundleIdentifier: nil, title: "Shell", frame: .zero, isOnScreen: true, lastSeen: Date())
        XCTAssertFalse(item.isDusty)
    }

    func testUnknownWindowIsNotDusty() {
        let item = WindowItem(id: 1, processID: 1, appName: "Terminal", bundleIdentifier: nil, title: "Shell", frame: .zero, isOnScreen: true, lastSeen: nil)
        XCTAssertFalse(item.isDusty)
    }

    func testWindowOrderingUsesRecencyThenStableUnknownOrder() {
        let older = WindowItem(id: 1, processID: 1, appName: "Terminal", bundleIdentifier: nil, title: "Older", frame: .zero, isOnScreen: true, lastSeen: Date(timeIntervalSince1970: 100))
        let unknownFirst = WindowItem(id: 2, processID: 1, appName: "Finder", bundleIdentifier: nil, title: "Unknown first", frame: .zero, isOnScreen: true, lastSeen: nil)
        let newer = WindowItem(id: 3, processID: 1, appName: "Safari", bundleIdentifier: nil, title: "Newer", frame: .zero, isOnScreen: true, lastSeen: Date(timeIntervalSince1970: 200))
        let unknownSecond = WindowItem(id: 4, processID: 1, appName: "Messages", bundleIdentifier: nil, title: "Unknown second", frame: .zero, isOnScreen: true, lastSeen: nil)

        XCTAssertEqual(WindowItem.orderedByRecency([older, unknownFirst, newer, unknownSecond]).map(\.id), [3, 1, 2, 4])
    }

    func testSafariResolutionSurvivesReindexing() {
        let target = SafariTab(windowIndex: 1, tabIndex: 5, title: "Kehai", url: "https://example.com/kehai", isCurrent: false)
        let moved = SafariTab(windowIndex: 2, tabIndex: 1, title: "Kehai", url: target.url, isCurrent: false)
        XCTAssertEqual(SafariTabService.resolve(target, in: [moved]), moved)
    }

    func testWindowMatchPrefersExactTitle() {
        let item = WindowItem(id: 1, processID: 1, appName: "Terminal", bundleIdentifier: nil, title: "Build", frame: CGRect(x: 10, y: 10, width: 500, height: 300), isOnScreen: true, lastSeen: Date())
        let exact = WindowMatchCandidate(title: "Build", frame: .zero).score(for: item)
        let geometry = WindowMatchCandidate(title: "Other", frame: item.frame).score(for: item)
        XCTAssertGreaterThan(exact, geometry)
    }

    func testModelGroupsDiscardUnknownWindowIDs() {
        let groups = TaskGroupingService.sanitize([(" Research ", [2, 999]), ("", [2])], validWindowIDs: [1, 2])
        XCTAssertEqual(groups, [TaskGroup(name: "Research", windowIDs: [2])])
    }

    func testActivityPersistence() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = ActivityStore(fileURL: url)
        let item = WindowItem(id: 42, processID: 1, appName: "Safari", bundleIdentifier: nil, title: "Page", frame: .zero, isOnScreen: true, lastSeen: Date())
        await store.record(item)
        let restored = ActivityStore(fileURL: url)
        let lastSeen = await restored.lastSeen()
        XCTAssertNotNil(lastSeen[42])
        try? FileManager.default.removeItem(at: url)
    }
}
