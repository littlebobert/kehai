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

    func testSearchRankingPrefersAppNameOverMoreRecentTitleMatch() {
        let terminal = WindowItem(id: 1, processID: 1, appName: "Terminal", bundleIdentifier: nil, title: "kotoba-realtime-subtitles", frame: .zero, isOnScreen: true, lastSeen: Date(timeIntervalSince1970: 200))
        let messages = WindowItem(id: 2, processID: 2, appName: "Messages", bundleIdentifier: nil, title: "Conversation", frame: .zero, isOnScreen: true, lastSeen: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(
            WindowItem.orderedBySearchRelevance([terminal, messages], query: "me").map(\.id),
            [messages.id, terminal.id]
        )
    }

    func testSearchRankingUsesRecencyWithinSameTier() {
        let older = WindowItem(id: 1, processID: 1, appName: "Messages", bundleIdentifier: nil, title: "Older", frame: .zero, isOnScreen: true, lastSeen: Date(timeIntervalSince1970: 100))
        let newer = WindowItem(id: 2, processID: 2, appName: "Memory", bundleIdentifier: nil, title: "Newer", frame: .zero, isOnScreen: true, lastSeen: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(
            WindowItem.orderedBySearchRelevance([older, newer], query: "me").map(\.id),
            [newer.id, older.id]
        )
    }

    func testSafariResolutionSurvivesReindexing() {
        let target = SafariTab(windowIndex: 1, tabIndex: 5, title: "Kehai", url: "https://example.com/kehai", isCurrent: false)
        let moved = SafariTab(windowIndex: 2, tabIndex: 1, title: "Kehai", url: target.url, isCurrent: false)
        XCTAssertEqual(SafariTabService.resolve(target, in: [moved]), moved)
    }

    func testSafariAppleScriptLiteralEscapesDynamicValues() {
        XCTAssertEqual(
            SafariTabService.appleScriptStringLiteral("a\\b\"c\nd"),
            "\"a\\\\b\\\"c\\nd\""
        )
    }

    func testSafariTabReplyParsingPreservesWhitespaceInTitles() {
        let field = "\u{001F}"
        let record = "\u{001E}"
        let reply = "1\(field)1\(field)First\tline\nSecond line\(field)https://example.com/one\(field)true"
            + record
            + "1\(field)2\(field)Untitled\(field)missing value\(field)false"

        let tabs = SafariTabService.parseTabs(reply)

        XCTAssertEqual(tabs.count, 2)
        XCTAssertEqual(tabs[0].title, "First\tline\nSecond line")
        XCTAssertEqual(tabs[0].url, "https://example.com/one")
        XCTAssertTrue(tabs[0].isCurrent)
        XCTAssertEqual(tabs[1].url, "")
        XCTAssertFalse(tabs[1].isCurrent)
    }

    func testSafariTabsExpandIntoSeparateEntries() {
        let current = SafariTab(windowIndex: 1, tabIndex: 1, title: "Current", url: "https://example.com/current", isCurrent: true)
        let background = SafariTab(windowIndex: 1, tabIndex: 2, title: "Background", url: "https://example.com/background", isCurrent: false)
        let window = WindowItem(
            id: 42,
            processID: 1,
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            title: "Current",
            frame: .zero,
            isOnScreen: true,
            thumbnail: NSImage(size: NSSize(width: 20, height: 20)),
            thumbnailIsUsable: true,
            appIcon: NSImage(size: NSSize(width: 10, height: 10)),
            safariTabs: [current, background]
        )

        let entries = WindowItem.expandedSafariTabEntries(from: [window])

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].id, window.id)
        XCTAssertTrue(entries[0].thumbnailIsUsable)
        XCTAssertEqual(entries[0].safariTab, current)
        XCTAssertNotEqual(entries[1].id, window.id)
        XCTAssertEqual(entries[1].physicalWindowID, window.id)
        XCTAssertNil(entries[1].thumbnail)
        XCTAssertFalse(entries[1].thumbnailIsUsable)
        XCTAssertEqual(entries[1].safariTab, background)
    }

    func testAppRepresentativePrefersCurrentSafariTab() {
        let first = SafariTab(windowIndex: 1, tabIndex: 1, title: "First", url: "https://example.com/first", isCurrent: false)
        let current = SafariTab(windowIndex: 1, tabIndex: 3, title: "Current", url: "https://example.com/current", isCurrent: true)
        let window = WindowItem(
            id: 42,
            processID: 1,
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            title: "Current",
            frame: .zero,
            isOnScreen: true,
            safariTabs: [first, current]
        )

        let representatives = WindowItem.uniquedAppRepresentatives(
            from: WindowItem.expandedSafariTabEntries(from: [window])
        )

        XCTAssertEqual(representatives.count, 1)
        XCTAssertEqual(representatives[0].safariTab, current)
        XCTAssertEqual(representatives[0].id, window.id)
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
