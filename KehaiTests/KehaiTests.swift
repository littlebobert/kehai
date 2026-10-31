import XCTest
@testable import Kehai

private final class GitHubURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var eventsHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let responseAndData: (HTTPURLResponse, Data)
            if request.url?.path.hasPrefix("/users/") == true,
               request.url?.path.hasSuffix("/events") == true {
                if let eventsHandler = Self.eventsHandler {
                    responseAndData = try eventsHandler(request)
                } else {
                    let response = HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: [:]
                    )!
                    responseAndData = (response, Data("[]".utf8))
                }
            } else {
                guard let handler = Self.handler else {
                    throw URLError(.badServerResponse)
                }
                responseAndData = try handler(request)
            }
            let (response, data) = responseAndData
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

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

    func testLaunchableAppNameMatchRanksBetweenRunningNameAndTitleMatches() {
        let installed = InstalledAppInfo(bundleIdentifier: "com.apple.dt.Xcode", localizedName: "Xcode", url: URL(fileURLWithPath: "/Applications/Xcode.app"), icon: nil)
        let launchable = WindowItem.launchableApp(for: installed, lastSeen: Date())
        let runningTitleMatch = WindowItem(id: 7, processID: 7, appName: "Safari", bundleIdentifier: "com.apple.Safari", title: "Xcode release notes", frame: .zero, isOnScreen: true, lastSeen: Date().addingTimeInterval(-3_600))

        XCTAssertTrue(launchable.isLaunchableApp)
        XCTAssertFalse(launchable.isAppPlaceholder)
        XCTAssertEqual(launchable.searchRank(for: "xc"), WindowItem.launchableAppRankOffset)
        XCTAssertEqual(launchable.searchRank(for: "code"), WindowItem.launchableAppRankOffset + 1)
        XCTAssertNil(launchable.searchRank(for: "safari"))

        let runningNameMatch = WindowItem(id: 8, processID: 8, appName: "Xcode Cloud", bundleIdentifier: "com.example.xcodecloud", title: "Builds", frame: .zero, isOnScreen: true, lastSeen: nil)
        let ordered = WindowItem.orderedBySearchRelevance([runningTitleMatch, launchable, runningNameMatch], query: "xc")
        XCTAssertEqual(ordered.map(\.id), [runningNameMatch.id, launchable.id, runningTitleMatch.id])
    }

    func testWindowlessAppWithProcessIsPlaceholder() {
        let running = RunningAppInfo(processID: 42, bundleIdentifier: "com.apple.Safari", localizedName: "Safari", launchDate: nil, icon: nil, bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"))
        let item = WindowItem.windowlessApp(for: running, lastSeen: nil)

        XCTAssertEqual(item?.processID, 42)
        XCTAssertEqual(item?.isAppPlaceholder, true)
        XCTAssertEqual(item?.isLaunchableApp, false)
    }

    func testWindowlessAppWithoutProcessOpensThroughItsBundle() {
        let bundleURL = URL(fileURLWithPath: "/Applications/Safari.app")
        let phantom = RunningAppInfo(processID: -1, bundleIdentifier: "com.apple.Safari", localizedName: "Safari", launchDate: nil, icon: nil, bundleURL: bundleURL)
        let item = WindowItem.windowlessApp(for: phantom, lastSeen: nil)

        XCTAssertEqual(item?.isLaunchableApp, true)
        XCTAssertEqual(item?.isAppPlaceholder, false)
        XCTAssertEqual(item?.applicationURL, bundleURL)
        XCTAssertEqual(item?.appName, "Safari")
    }

    func testWindowlessAppWithoutProcessOrBundleIsDropped() {
        let noURL = RunningAppInfo(processID: -1, bundleIdentifier: "com.apple.Safari", localizedName: "Safari", launchDate: nil, icon: nil, bundleURL: nil)
        let noBundleIdentifier = RunningAppInfo(processID: -1, bundleIdentifier: nil, localizedName: "Safari", launchDate: nil, icon: nil, bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"))

        XCTAssertNil(WindowItem.windowlessApp(for: noURL, lastSeen: nil))
        XCTAssertNil(WindowItem.windowlessApp(for: noBundleIdentifier, lastSeen: nil))
    }

    func testSwitcherMergeReplacesStandInsAndKeepsOrder() {
        let launchable = WindowItem.launchableApp(for: InstalledAppInfo(bundleIdentifier: "com.apple.Safari", localizedName: "Safari", url: URL(fileURLWithPath: "/Applications/Safari.app"), icon: nil), lastSeen: nil)
        let finderOld = WindowItem(id: 1, processID: 1, appName: "Finder", bundleIdentifier: "com.apple.finder", title: "Old", frame: .zero, isOnScreen: true, lastSeen: nil)
        let finderNew = WindowItem(id: 2, processID: 1, appName: "Finder", bundleIdentifier: "com.apple.finder", title: "New", frame: .zero, isOnScreen: true, lastSeen: nil)
        let gone = WindowItem(id: 3, processID: 3, appName: "Gone", bundleIdentifier: "com.example.gone", title: "Gone", frame: .zero, isOnScreen: true, lastSeen: nil)
        let safariWindow = WindowItem(id: 4, processID: 4, appName: "Safari", bundleIdentifier: "com.apple.Safari", title: "Start Page", frame: .zero, isOnScreen: true, lastSeen: nil)
        let notes = WindowItem(id: 5, processID: 5, appName: "Notes", bundleIdentifier: "com.apple.Notes", title: "Notes", frame: .zero, isOnScreen: true, lastSeen: nil)

        let merged = WindowItem.mergedSwitcherApps(
            snapshot: [launchable, finderOld, gone],
            live: [notes, finderNew, safariWindow]
        )

        // The stand-in becomes the real window; a real window entry stays put.
        XCTAssertEqual(merged.map(\.id), [safariWindow.id, finderOld.id, notes.id])
    }

    func testAlternateAppNamesMatchAsAppNames() {
        let installed = InstalledAppInfo(
            bundleIdentifier: "com.openai.codex",
            localizedName: "ChatGPT",
            url: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            icon: nil,
            alternateNames: ["Codex"]
        )
        let launchable = WindowItem.launchableApp(for: installed, lastSeen: nil)
        XCTAssertEqual(launchable.searchRank(for: "chat"), WindowItem.launchableAppRankOffset)
        XCTAssertEqual(launchable.searchRank(for: "codex"), WindowItem.launchableAppRankOffset + 1)
        XCTAssertNil(launchable.searchRank(for: "claude"))

        var chatGPTWindow = WindowItem(id: 1, processID: 1, appName: "ChatGPT", bundleIdentifier: "com.openai.codex", title: "New chat", frame: .zero, isOnScreen: true, lastSeen: nil)
        let titleMatch = WindowItem(id: 2, processID: 2, appName: "Terminal", bundleIdentifier: nil, title: "codex --resume", frame: .zero, isOnScreen: true, lastSeen: Date())
        XCTAssertNil(chatGPTWindow.searchRank(for: "codex"))
        chatGPTWindow.alternateAppNames = installed.alternateNames
        XCTAssertEqual(chatGPTWindow.searchRank(for: "codex"), 1)
        XCTAssertEqual(
            WindowItem.orderedBySearchRelevance([titleMatch, chatGPTWindow], query: "codex").map(\.id),
            [chatGPTWindow.id, titleMatch.id]
        )
    }

    func testAlternateAppNamesDropBlanksDuplicatesAndTheDisplayName() {
        XCTAssertEqual(
            InstalledAppCatalog.alternateNames(["Codex", " codex ", "", "ChatGPT", 42, "Codex CLI"], excluding: "ChatGPT"),
            ["Codex", "Codex CLI"]
        )
        XCTAssertEqual(InstalledAppCatalog.alternateNames("Codex", excluding: "ChatGPT"), [])
        XCTAssertEqual(InstalledAppCatalog.alternateNames(nil, excluding: "ChatGPT"), [])
    }

    private func fileResult(
        _ path: String,
        lastUsed: Date? = nil,
        modified: Date? = nil,
        contentOnly: Bool = false,
        contentType: String? = "public.plain-text"
    ) -> FileSearchResult {
        FileSearchResult(
            path: path,
            name: (path as NSString).lastPathComponent,
            contentType: contentType,
            lastUsed: lastUsed,
            modified: modified,
            matchedContentOnly: contentOnly,
            icon: nil
        )
    }

    func testFileRankingPrefersOpenedThenNamePrefixThenNameOverText() {
        let now = Date()
        let openedPrefix = fileResult("/Users/me/Documents/Lease 2026.pdf", lastUsed: now.addingTimeInterval(-86_400))
        let openedWord = fileResult("/Users/me/Documents/Apartment lease.pdf", lastUsed: now)
        let unopenedPrefix = fileResult("/Users/me/Downloads/lease-draft.pdf", modified: now)
        let textOnly = fileResult("/Users/me/Documents/Notes.txt", lastUsed: now, contentOnly: true)
        let newerOpenedPrefix = fileResult("/Users/me/Desktop/Lease scan.pdf", lastUsed: now.addingTimeInterval(-60))

        let ranked = FileSearchRanking.rank(
            [textOnly, unopenedPrefix, openedWord, openedPrefix, newerOpenedPrefix],
            query: "lea",
            limit: 10
        )
        XCTAssertEqual(ranked.map(\.name), ["Lease scan.pdf", "Lease 2026.pdf", "Apartment lease.pdf", "lease-draft.pdf", "Notes.txt"])
        XCTAssertEqual(FileSearchRanking.rank(ranked, query: "lea", limit: 2).count, 2)
    }

    func testFileNoiseFilterDropsHiddenBuildAndAppPathsUnlessOpened() {
        let home = "/Users/me"
        XCTAssertTrue(FileSearchRanking.isNoise(fileResult("/Users/me/dev/app/.build/debug/Kehai.o"), homePath: home))
        XCTAssertTrue(FileSearchRanking.isNoise(fileResult("/Users/me/dev/site/node_modules/lib/kehai.js"), homePath: home))
        XCTAssertTrue(FileSearchRanking.isNoise(fileResult("/Users/me/Applications/Tool.app/Contents/Info.plist"), homePath: home))
        XCTAssertTrue(FileSearchRanking.isNoise(fileResult("/Users/me/Applications/Tool.app", contentType: "com.apple.application-bundle"), homePath: home))
        XCTAssertFalse(FileSearchRanking.isNoise(fileResult("/Users/me/dev/site/build/report.pdf", lastUsed: Date()), homePath: home))
        XCTAssertTrue(FileSearchRanking.isNoise(fileResult("/Users/me/dev/site/build/report.pdf"), homePath: home))
        XCTAssertFalse(FileSearchRanking.isNoise(fileResult("/Users/me/Documents/Taxes/2025.pdf"), homePath: home))
    }

    func testFileQueryMatchesEveryWordPrefixAndEscapesSyntax() {
        XCTAssertEqual(
            FileSearchService.matchExpression(attribute: "kMDItemDisplayName", words: ["apt", "lea"]),
            #"((kMDItemDisplayName == "apt*"cdw) && (kMDItemDisplayName == "lea*"cdw))"#
        )
        XCTAssertEqual(FileSearchService.escape(#"a"b*c\d"#), #"a\"b\*c\\d"#)
    }

    func testFileResultShortensHomeInParentPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(fileResult(home + "/Documents/Taxes/2025.pdf").parentDisplayPath, "~/Documents/Taxes")
        XCTAssertEqual(fileResult(home + "/notes.txt").parentDisplayPath, "~")
        XCTAssertEqual(fileResult("/Volumes/Backup/notes.txt").parentDisplayPath, "/Volumes/Backup")
        XCTAssertEqual(
            fileResult(home + "/Library/Mobile Documents/com~apple~CloudDocs/Taxes/2025.pdf").parentDisplayPath,
            "iCloud Drive/Taxes"
        )
    }

    func testLaunchableAppIDIsStableAndStaysInItsReservedRange() {
        let first = WindowItem.launchableAppID(bundleIdentifier: "com.example.one")
        XCTAssertEqual(first, WindowItem.launchableAppID(bundleIdentifier: "com.example.one"))
        XCTAssertNotEqual(first, WindowItem.launchableAppID(bundleIdentifier: "com.example.two"))
        XCTAssertGreaterThanOrEqual(first, WindowItem.launchableAppIDBase)
        XCTAssertLessThan(first, WindowItem.safariTabIDBase)
    }

    func testInstalledAppScanKeepsUserFacingAndMenuBarAppsAndSkipsBackgroundOnesAndDuplicates() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kehai-installed-apps-\(UUID().uuidString)", directoryHint: .isDirectory)
        let primary = root.appending(path: "Applications", directoryHint: .isDirectory)
        let secondary = root.appending(path: "System Applications", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        func makeApp(in directory: URL, name: String, bundleIdentifier: String, extra: [String: Any] = [:]) throws {
            let bundle = directory.appending(path: "\(name).app", directoryHint: .isDirectory)
            let macOS = bundle.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: macOS.appending(path: name).path, contents: Data())
            var plist: [String: Any] = [
                "CFBundleIdentifier": bundleIdentifier,
                "CFBundleExecutable": name,
                "CFBundlePackageType": "APPL"
            ]
            plist.merge(extra) { _, new in new }
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: bundle.appending(path: "Contents/Info.plist"))
        }

        try makeApp(in: primary, name: "Zebra", bundleIdentifier: "com.example.zebra")
        try makeApp(in: primary, name: "Menu Extra", bundleIdentifier: "com.example.menuextra", extra: ["LSUIElement": true])
        try makeApp(in: primary, name: "Daemon", bundleIdentifier: "com.example.daemon", extra: ["LSBackgroundOnly": "1"])
        try makeApp(in: primary, name: "Kehai", bundleIdentifier: "com.justin.Kehai")
        try makeApp(in: primary.appending(path: "Utilities"), name: "Nested", bundleIdentifier: "com.example.nested")
        try makeApp(in: primary.appending(path: "Too/Deep"), name: "Buried", bundleIdentifier: "com.example.buried")
        try makeApp(in: secondary, name: "Zebra Copy", bundleIdentifier: "com.example.zebra")
        try makeApp(in: secondary, name: "Alpha", bundleIdentifier: "com.example.alpha")
        // Like /Applications/Safari.app: a hidden symlink to a bundle that lives somewhere unscanned.
        let cryptex = root.appending(path: "Cryptex", directoryHint: .isDirectory)
        try makeApp(in: cryptex, name: "Linked", bundleIdentifier: "com.example.linked")
        var hiddenValues = URLResourceValues()
        hiddenValues.isHidden = true
        var linkedTarget = cryptex.appending(path: "Linked.app", directoryHint: .isDirectory)
        try linkedTarget.setResourceValues(hiddenValues)
        try FileManager.default.createSymbolicLink(
            at: primary.appending(path: "Linked.app"),
            withDestinationURL: linkedTarget
        )
        try makeApp(in: primary, name: ".Hidden Helper", bundleIdentifier: "com.example.dotprefixed")
        // Like Xcode's Device Hub: an app shipped inside another app's Contents/Applications.
        let host = primary.appending(path: "Zebra.app/Contents/Applications", directoryHint: .isDirectory)
        try makeApp(in: host, name: "Embedded", bundleIdentifier: "com.example.embedded")
        try makeApp(in: primary.appending(path: "Zebra.app/Contents/PrivateApplications"), name: "Private", bundleIdentifier: "com.example.private")

        let apps = InstalledAppCatalog.scan(
            directories: [primary, secondary],
            excludingBundleIdentifier: "com.justin.Kehai",
            includeIcons: false
        )

        XCTAssertEqual(apps.map(\.localizedName), ["Alpha", "Embedded", "Linked", "Menu Extra", "Nested", "Zebra"])
        XCTAssertEqual(apps.first(where: { $0.bundleIdentifier == "com.example.zebra" })?.url.lastPathComponent, "Zebra.app")
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

    func testSparseGuardAllowsQuittingAnAppWithManyWindows() {
        let terminals = (1...3).map { id in
            WindowItem(
                id: CGWindowID(id),
                processID: 10,
                appName: "Terminal",
                bundleIdentifier: "com.apple.Terminal",
                title: "Shell \(id)",
                frame: .zero,
                isOnScreen: true
            )
        }
        let quickTime = (10...29).map { id in
            WindowItem(
                id: CGWindowID(id),
                processID: 99,
                appName: "QuickTime Player",
                bundleIdentifier: "com.apple.QuickTimePlayerX",
                title: "Movie \(id)",
                frame: .zero,
                isOnScreen: true
            )
        }

        XCTAssertFalse(
            WindowInventoryPolicy.isSparseSnapshot(
                previous: terminals + quickTime,
                current: terminals,
                isProcessRunning: { $0 != 99 }
            )
        )
    }

    func testSparseGuardRejectsSuddenLossOfRunningAppWindows() {
        let previous = (1...10).map { id in
            WindowItem(
                id: CGWindowID(id),
                processID: 10,
                appName: "Terminal",
                bundleIdentifier: "com.apple.Terminal",
                title: "Shell \(id)",
                frame: .zero,
                isOnScreen: true
            )
        }

        XCTAssertTrue(
            WindowInventoryPolicy.isSparseSnapshot(
                previous: previous,
                current: Array(previous.prefix(3)),
                isProcessRunning: { _ in true }
            )
        )
    }

    func testSparseGuardAllowsAccessibilityConfirmedCloses() {
        let previous = (1...10).map { id in
            WindowItem(
                id: CGWindowID(id),
                processID: 10,
                appName: "Terminal",
                bundleIdentifier: "com.apple.Terminal",
                title: "Shell \(id)",
                frame: .zero,
                isOnScreen: true
            )
        }
        let survivors = Array(previous.prefix(3))
        let closed = Set(previous.dropFirst(3).map(\.id))

        XCTAssertFalse(
            WindowInventoryPolicy.isSparseSnapshot(
                previous: previous,
                current: survivors,
                accessibilityContradictedWindowIDs: closed,
                isProcessRunning: { _ in true }
            )
        )
    }

    func testSparseGuardStillRejectsUnexplainedLoss() {
        let previous = (1...10).map { id in
            WindowItem(
                id: CGWindowID(id),
                processID: 10,
                appName: "Terminal",
                bundleIdentifier: "com.apple.Terminal",
                title: "Shell \(id)",
                frame: .zero,
                isOnScreen: true
            )
        }

        // Only one window is accounted for, so the rest are still an unexplained collapse.
        XCTAssertTrue(
            WindowInventoryPolicy.isSparseSnapshot(
                previous: previous,
                current: Array(previous.prefix(3)),
                accessibilityContradictedWindowIDs: [previous[9].id],
                isProcessRunning: { _ in true }
            )
        )
    }

    func testSparseStreakAcceptsPersistentStableSnapshot() {
        var streak = SparseSnapshotStreak()
        let start = Date()
        let ids: Set<CGWindowID> = [1, 2, 3, 4]

        XCTAssertFalse(streak.recordRejection(currentIDs: ids, at: start))
        XCTAssertFalse(streak.recordRejection(currentIDs: ids, at: start.addingTimeInterval(2)))
        // Third rejection, but not enough wall-clock time yet.
        XCTAssertFalse(streak.recordRejection(currentIDs: ids, at: start.addingTimeInterval(4)))
        // Same snapshot, stable for longer than any drag: accept.
        XCTAssertTrue(streak.recordRejection(currentIDs: ids, at: start.addingTimeInterval(6)))
    }

    func testSparseStreakToleratesSmallChurn() {
        var streak = SparseSnapshotStreak()
        let start = Date()

        XCTAssertFalse(streak.recordRejection(currentIDs: [1, 2, 3, 4], at: start))
        XCTAssertFalse(streak.recordRejection(currentIDs: [1, 2, 3, 5], at: start.addingTimeInterval(3)))
        XCTAssertTrue(streak.recordRejection(currentIDs: [1, 2, 3, 5], at: start.addingTimeInterval(6)))
    }

    func testSparseStreakRestartsWhenSnapshotChanges() {
        var streak = SparseSnapshotStreak()
        let start = Date()

        XCTAssertFalse(streak.recordRejection(currentIDs: [1, 2, 3, 4], at: start))
        XCTAssertFalse(streak.recordRejection(currentIDs: [1, 2, 3, 4], at: start.addingTimeInterval(3)))
        // A very different sparse read is a different transient, not the same truth.
        XCTAssertFalse(streak.recordRejection(currentIDs: [7, 8, 9, 10], at: start.addingTimeInterval(6)))
        XCTAssertEqual(streak.count, 1)
        XCTAssertFalse(streak.recordRejection(currentIDs: [7, 8, 9, 10], at: start.addingTimeInterval(9)))
        XCTAssertFalse(streak.recordRejection(currentIDs: [7, 8, 9, 10], at: start.addingTimeInterval(10)))
        XCTAssertTrue(streak.recordRejection(currentIDs: [7, 8, 9, 10], at: start.addingTimeInterval(12)))
    }

    func testSparseStreakResetClearsHistory() {
        var streak = SparseSnapshotStreak()
        let start = Date()

        XCTAssertFalse(streak.recordRejection(currentIDs: [1, 2, 3], at: start))
        XCTAssertFalse(streak.recordRejection(currentIDs: [1, 2, 3], at: start.addingTimeInterval(3)))
        streak.reset()
        XCTAssertEqual(streak.count, 0)
        XCTAssertFalse(streak.recordRejection(currentIDs: [1, 2, 3], at: start.addingTimeInterval(6)))
        XCTAssertEqual(streak.count, 1)
    }

    func testWindowMatchPrefersExactTitle() {
        let item = WindowItem(id: 1, processID: 1, appName: "Terminal", bundleIdentifier: nil, title: "Build", frame: CGRect(x: 10, y: 10, width: 500, height: 300), isOnScreen: true, lastSeen: Date())
        let exact = WindowMatchCandidate(title: "Build", frame: .zero).score(for: item)
        let geometry = WindowMatchCandidate(title: "Other", frame: item.frame).score(for: item)
        XCTAssertGreaterThan(exact, geometry)
    }

    @MainActor
    func testFocusOnUninventoriedWindowIsNotCreditedToASibling() {
        let existing = WindowItem(id: 1, processID: 1, appName: "Safari", bundleIdentifier: nil, title: "Home / X", frame: CGRect(x: 0, y: 0, width: 1200, height: 800), isOnScreen: true, lastSeen: nil)
        let newWindow = WindowMatchCandidate(title: "weather tokyo - Google Search", frame: CGRect(x: 600, y: 300, width: 900, height: 600))
        XCTAssertNil(ActivityMonitor.focusedWindow(matching: newWindow, in: [existing]))
        XCTAssertNil(ActivityMonitor.focusedWindow(matching: newWindow, in: []))

        let inventoried = WindowItem(id: 2, processID: 1, appName: "Safari", bundleIdentifier: nil, title: "weather tokyo - Google Search", frame: newWindow.frame, isOnScreen: true, lastSeen: nil)
        XCTAssertEqual(ActivityMonitor.focusedWindow(matching: newWindow, in: [existing, inventoried])?.id, 2)
    }

    @MainActor
    func testFocusMatchToleratesTitleChangeOnSameFrame() {
        let terminal = WindowItem(id: 1, processID: 1, appName: "Terminal", bundleIdentifier: nil, title: "justin — -zsh", frame: CGRect(x: 10, y: 10, width: 800, height: 500), isOnScreen: true, lastSeen: nil)
        let focused = WindowMatchCandidate(title: "justin — sudo ▸ log", frame: terminal.frame)
        XCTAssertEqual(ActivityMonitor.focusedWindow(matching: focused, in: [terminal])?.id, 1)
        XCTAssertEqual(ActivityMonitor.focusedWindow(matching: nil, in: [terminal])?.id, 1)
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

    @MainActor
    func testGitHubRefreshSettingsDefaultToThirtyMinutesAndPersistChanges() {
        let suiteName = "KehaiTests.GitHubRefresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = GitHubRefreshSettings(defaults: defaults)
        XCTAssertEqual(settings.intervalMinutes, 30)
        XCTAssertEqual(settings.timeInterval, 30 * 60)

        settings.intervalMinutes = 60
        XCTAssertEqual(GitHubRefreshSettings(defaults: defaults).intervalMinutes, 60)
    }

    @MainActor
    func testHotZoneSettingsDefaultOffLowerLeftAndPersistChanges() {
        let suiteName = "KehaiTests.HotZone.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = HotZoneSettings(defaults: defaults)
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.zone, .lowerLeft)

        settings.isEnabled = true
        settings.zone = .upperRight

        let restoredSettings = HotZoneSettings(defaults: defaults)
        XCTAssertTrue(restoredSettings.isEnabled)
        XCTAssertEqual(restoredSettings.zone, .upperRight)
    }

    func testHotZoneHitRegionsMatchConfiguredEdgesAndCorners() {
        let screenFrame = CGRect(x: -100, y: 50, width: 1_200, height: 800)
        let miniBrowserSize = CGSize(width: 600, height: 300)
        let tolerance: CGFloat = 5
        let edgePadding: CGFloat = 24

        XCTAssertTrue(HotZone.upperLeft.contains(
            pointer: CGPoint(x: -98, y: 848),
            in: screenFrame,
            tolerance: tolerance
        ))
        XCTAssertTrue(HotZone.lowerRight.contains(
            pointer: CGPoint(x: 1_098, y: 52),
            in: screenFrame,
            tolerance: tolerance
        ))
        XCTAssertTrue(HotZone.bottom.contains(
            pointer: CGPoint(x: 500, y: 52),
            in: screenFrame,
            tolerance: tolerance,
            miniBrowserSize: miniBrowserSize,
            edgePadding: edgePadding
        ))
        XCTAssertTrue(HotZone.bottom.contains(
            pointer: CGPoint(x: 824, y: 52),
            in: screenFrame,
            tolerance: tolerance,
            miniBrowserSize: miniBrowserSize,
            edgePadding: edgePadding
        ))
        XCTAssertFalse(HotZone.bottom.contains(
            pointer: CGPoint(x: 825, y: 52),
            in: screenFrame,
            tolerance: tolerance,
            miniBrowserSize: miniBrowserSize,
            edgePadding: edgePadding
        ))
        XCTAssertTrue(HotZone.left.contains(
            pointer: CGPoint(x: -98, y: 276),
            in: screenFrame,
            tolerance: tolerance,
            miniBrowserSize: miniBrowserSize,
            edgePadding: edgePadding
        ))
        XCTAssertFalse(HotZone.left.contains(
            pointer: CGPoint(x: -98, y: 275),
            in: screenFrame,
            tolerance: tolerance,
            miniBrowserSize: miniBrowserSize,
            edgePadding: edgePadding
        ))
        XCTAssertTrue(HotZone.right.contains(
            pointer: CGPoint(x: 1_098, y: 450),
            in: screenFrame,
            tolerance: tolerance,
            miniBrowserSize: miniBrowserSize,
            edgePadding: edgePadding
        ))
        XCTAssertFalse(HotZone.lowerLeft.contains(
            pointer: CGPoint(x: -90, y: 52),
            in: screenFrame,
            tolerance: tolerance
        ))
    }

    func testHotZoneWindowPlacementPinsAndCentersTheMiniUI() {
        let screenFrame = CGRect(x: -100, y: 50, width: 1_000, height: 700)
        let windowSize = CGSize(width: 600, height: 300)

        XCTAssertEqual(
            HotZone.bottom.windowFrameOrigin(windowSize: windowSize, in: screenFrame),
            CGPoint(x: 100, y: 50)
        )
        XCTAssertEqual(
            HotZone.left.windowFrameOrigin(windowSize: windowSize, in: screenFrame),
            CGPoint(x: -100, y: 250)
        )
        XCTAssertEqual(
            HotZone.lowerLeft.windowFrameOrigin(windowSize: windowSize, in: screenFrame),
            CGPoint(x: -100, y: 50)
        )
    }

    func testGitHubRepositoryDecodingMapsNestedAndSnakeCaseFields() throws {
        let repository = try JSONDecoder().decode(GitHubRepository.self, from: githubRepositoryJSON(
            id: 9,
            name: "Kehai",
            owner: "octocat",
            description: "Window switcher",
            pushedAt: "2026-08-20T12:30:00Z",
            isPrivate: true,
            isFork: true,
            isArchived: true
        ))

        XCTAssertEqual(repository.id, 9)
        XCTAssertEqual(repository.name, "Kehai")
        XCTAssertEqual(repository.fullName, "octocat/Kehai")
        XCTAssertEqual(repository.ownerLogin, "octocat")
        XCTAssertEqual(repository.ownerAvatarURL, URL(string: "https://avatars.example/octocat.png"))
        XCTAssertEqual(repository.description, "Window switcher")
        XCTAssertEqual(repository.htmlURL, URL(string: "https://github.com/octocat/Kehai"))
        XCTAssertTrue(repository.isPrivate)
        XCTAssertTrue(repository.isFork)
        XCTAssertTrue(repository.isArchived)
        XCTAssertNotNil(repository.pushedAt)
    }

    func testGitHubServiceValidatesUserAndFollowsRepositoryPagination() async throws {
        let session = githubStubSession()
        let service = GitHubRepositorySearchService(
            session: session,
            baseURL: URL(string: "https://api.github.test")!
        )
        nonisolated(unsafe) var repositoryPage = 0

        GitHubURLProtocolStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Kehai")

            if request.url?.path == "/graphql" {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
                let body = try XCTUnwrap(self.githubRequestBody(request))
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let query = try XCTUnwrap(object["query"] as? String)
                let responseData = query.contains("KehaiViewerInteractions")
                    ? self.githubInteractionsJSON(nodes: [], hasNextPage: false)
                    : self.githubContributionsJSON()
                return (self.githubResponse(url: request.url!), responseData)
            }

            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
            if request.url?.path == "/user" {
                return (self.githubResponse(url: request.url!), Data(#"{"login":"octocat"}"#.utf8))
            }
            if request.url?.path == "/search/issues" {
                return (self.githubResponse(url: request.url!), self.githubSearchIssuesJSON(
                    totalCount: 1,
                    items: [("https://api.github.test/repos/octocat/repo", "2026-08-26T12:00:00Z")]
                ))
            }

            repositoryPage += 1
            if repositoryPage == 1 {
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "per_page" })?.value, "100")
                let next = "<https://api.github.test/user/repos?page=2>; rel=\"next\", <https://api.github.test/user/repos?page=2>; rel=\"last\""
                return (self.githubResponse(url: request.url!, headers: ["Link": next]), self.githubRepositoryArrayJSON(ids: [1]))
            }
            XCTAssertEqual(request.url?.query, "page=2")
            return (self.githubResponse(url: request.url!), self.githubRepositoryArrayJSON(ids: [2]))
        }
        defer { GitHubURLProtocolStub.handler = nil }

        let account = try await service.loadAuthenticatedRepositories(token: " secret-token ")

        XCTAssertEqual(account.username, "octocat")
        XCTAssertEqual(account.repositories.map(\.id), [1, 2])
        XCTAssertEqual(account.contributionActivity[1]?.totalCount, 10)
        XCTAssertNil(account.contributionWarning)
        XCTAssertEqual(repositoryPage, 2)
    }

    func testGitHubUserEventsRequestUsesAuthenticationURLAndPaginationQuery() async throws {
        let service = GitHubRepositorySearchService(
            session: githubStubSession(),
            baseURL: URL(string: "https://api.github.test")!
        )
        GitHubURLProtocolStub.handler = { request in
            try self.githubAccountResponse(request, repositoryIDs: [11])
        }
        GitHubURLProtocolStub.eventsHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Kehai")
            XCTAssertEqual(request.url?.path, "/users/octocat/events")
            let queryItems = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(queryItems.first(where: { $0.name == "per_page" })?.value, "100")
            XCTAssertEqual(queryItems.first(where: { $0.name == "page" })?.value, "1")
            return (self.githubResponse(url: request.url!), Data("[]".utf8))
        }
        defer {
            GitHubURLProtocolStub.handler = nil
            GitHubURLProtocolStub.eventsHandler = nil
        }

        let account = try await service.loadAuthenticatedRepositories(token: " secret-token ")

        XCTAssertEqual(account.eventNodeCount, 0)
        XCTAssertEqual(account.eventPageCount, 1)
        XCTAssertEqual(account.eventMappedRepositoryCount, 0)
    }

    func testGitHubPushEventsMapCaseInsensitivelyAndUseLatestTimestamp() async throws {
        let service = GitHubRepositorySearchService(
            session: githubStubSession(),
            baseURL: URL(string: "https://api.github.test")!
        )
        GitHubURLProtocolStub.handler = { request in
            try self.githubAccountResponse(request, repositoryIDs: [21])
        }
        GitHubURLProtocolStub.eventsHandler = { request in
            (self.githubResponse(url: request.url!), self.githubEventsJSON(events: [
                ("PushEvent", "OCTOCAT/REPO", "2026-08-27T12:00:00Z"),
                ("PushEvent", "octocat/repo", "2026-08-29T12:00:00Z")
            ]))
        }
        defer {
            GitHubURLProtocolStub.handler = nil
            GitHubURLProtocolStub.eventsHandler = nil
        }

        let account = try await service.loadAuthenticatedRepositories(token: "secret-token")

        XCTAssertEqual(account.eventNodeCount, 2)
        XCTAssertEqual(account.eventMappedRepositoryCount, 1)
        XCTAssertEqual(account.contributionActivity[21]?.totalCount, 0)
        XCTAssertEqual(account.contributionActivity[21]?.latestOccurredAt, ISO8601DateFormatter().date(from: "2026-08-29T12:00:00Z"))
    }

    func testGitHubUserEventsIgnorePassiveWatchAndForkEvents() async throws {
        let service = GitHubRepositorySearchService(
            session: githubStubSession(),
            baseURL: URL(string: "https://api.github.test")!
        )
        GitHubURLProtocolStub.handler = { request in
            try self.githubAccountResponse(request, repositoryIDs: [31])
        }
        GitHubURLProtocolStub.eventsHandler = { request in
            (self.githubResponse(url: request.url!), self.githubEventsJSON(events: [
                ("WatchEvent", "octocat/repo", "2026-08-29T12:00:00Z"),
                ("ForkEvent", "octocat/repo", "2026-08-30T12:00:00Z")
            ]))
        }
        defer {
            GitHubURLProtocolStub.handler = nil
            GitHubURLProtocolStub.eventsHandler = nil
        }

        let account = try await service.loadAuthenticatedRepositories(token: "secret-token")

        XCTAssertEqual(account.eventNodeCount, 2)
        XCTAssertEqual(account.eventMappedRepositoryCount, 0)
        XCTAssertNil(account.contributionActivity[31])
    }

    func testGitHubUserEventsPaginatesUntilShortPage() async throws {
        let service = GitHubRepositorySearchService(
            session: githubStubSession(),
            baseURL: URL(string: "https://api.github.test")!
        )
        nonisolated(unsafe) var requestedPages: [Int] = []
        GitHubURLProtocolStub.handler = { request in
            try self.githubAccountResponse(request, repositoryIDs: [41])
        }
        GitHubURLProtocolStub.eventsHandler = { request in
            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            let page = Int(queryItems?.first(where: { $0.name == "page" })?.value ?? "")!
            requestedPages.append(page)
            let events = page == 1
                ? (0..<100).map { _ in ("WatchEvent", "octocat/repo", "2026-08-25T12:00:00Z") }
                : [("PushEvent", "octocat/repo", "2026-08-30T12:00:00Z")]
            return (self.githubResponse(url: request.url!), self.githubEventsJSON(events: events))
        }
        defer {
            GitHubURLProtocolStub.handler = nil
            GitHubURLProtocolStub.eventsHandler = nil
        }

        let account = try await service.loadAuthenticatedRepositories(token: "secret-token")

        XCTAssertEqual(requestedPages, [1, 2])
        XCTAssertEqual(account.eventNodeCount, 101)
        XCTAssertEqual(account.eventPageCount, 2)
        XCTAssertEqual(account.eventMappedRepositoryCount, 1)
        XCTAssertEqual(account.contributionActivity[41]?.latestOccurredAt, ISO8601DateFormatter().date(from: "2026-08-30T12:00:00Z"))
    }

    func testGitHubUserEventsPreserveCompletedPagesWhenLaterPageFails() async throws {
        let service = GitHubRepositorySearchService(
            session: githubStubSession(),
            baseURL: URL(string: "https://api.github.test")!
        )
        GitHubURLProtocolStub.handler = { request in
            try self.githubAccountResponse(request, repositoryIDs: [51])
        }
        GitHubURLProtocolStub.eventsHandler = { request in
            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            let page = queryItems?.first(where: { $0.name == "page" })?.value
            if page == "1" {
                var events = [("PushEvent", "octocat/repo", "2026-08-30T12:00:00Z")]
                events.append(contentsOf: (0..<99).map { _ in
                    ("WatchEvent", "octocat/repo", "2026-08-25T12:00:00Z")
                })
                return (self.githubResponse(url: request.url!), self.githubEventsJSON(events: events))
            }
            return (
                self.githubResponse(url: request.url!, statusCode: 403),
                Data(#"{"message":"Events access denied"}"#.utf8)
            )
        }
        defer {
            GitHubURLProtocolStub.handler = nil
            GitHubURLProtocolStub.eventsHandler = nil
        }

        let account = try await service.loadAuthenticatedRepositories(token: "secret-token")

        XCTAssertEqual(account.eventNodeCount, 100)
        XCTAssertEqual(account.eventPageCount, 1)
        XCTAssertEqual(account.eventMappedRepositoryCount, 1)
        XCTAssertEqual(account.contributionActivity[51]?.totalCount, 0)
        XCTAssertEqual(account.contributionActivity[51]?.latestOccurredAt, ISO8601DateFormatter().date(from: "2026-08-30T12:00:00Z"))
        XCTAssertTrue(account.contributionWarning?.contains("Events access denied") == true)
    }

    func testGitHubContributionGraphQLRequestUsesAuthAndDecodesAllKinds() async throws {
        let service = GitHubRepositorySearchService(
            session: githubStubSession(),
            baseURL: URL(string: "https://api.github.test")!
        )
        nonisolated(unsafe) var requestCount = 0
        nonisolated(unsafe) var interactionSources: [String] = []

        GitHubURLProtocolStub.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/graphql")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try XCTUnwrap(self.githubRequestBody(request))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let query = try XCTUnwrap(object["query"] as? String)
            let variables = try XCTUnwrap(object["variables"] as? [String: String])
            if query.contains("KehaiViewerInteractions") {
                let interactionQuery = try XCTUnwrap(variables["interactionQuery"])
                interactionSources.append(String(interactionQuery.prefix { $0 != ":" }))
                XCTAssertTrue(interactionQuery.hasSuffix(":@me sort:updated-desc"))
                XCTAssertNil(variables["cursor"])
                XCTAssertTrue(query.contains("type: ISSUE"))
                XCTAssertTrue(query.contains("... on Issue"))
                XCTAssertTrue(query.contains("... on PullRequest"))
                XCTAssertTrue(query.contains("pageInfo { hasNextPage endCursor }"))
                return (self.githubResponse(url: request.url!), self.githubInteractionsJSON(nodes: [], hasNextPage: false))
            }

            XCTAssertTrue(variables.isEmpty)
            if query.contains("KehaiAuthoredPullRequests") {
                XCTAssertTrue(query.contains("pullRequests(first: 100"))
                XCTAssertTrue(query.contains("commits(last: 25)"))
                XCTAssertTrue(query.contains("committedDate"))
                XCTAssertTrue(query.contains("updatedAt"))
                return (self.githubResponse(url: request.url!), self.githubContributionsJSON())
            }

            XCTAssertTrue(query.contains("contributionsCollection"))
            XCTAssertTrue(query.contains("commitContributionsByRepository"))
            XCTAssertTrue(query.contains("pullRequestContributionsByRepository"))
            XCTAssertTrue(query.contains("pullRequestReviewContributionsByRepository"))
            XCTAssertTrue(query.contains("issueContributionsByRepository"))
            XCTAssertTrue(query.contains("databaseId"))
            return (self.githubResponse(url: request.url!), self.githubContributionsJSON())
        }
        defer { GitHubURLProtocolStub.handler = nil }

        let activity = try await service.loadContributionActivity(token: " secret-token ")

        XCTAssertEqual(requestCount, 7)
        XCTAssertEqual(interactionSources, ["involves", "author", "commenter", "assignee", "mentions"])
        XCTAssertEqual(activity[1]?.commitCount, 4)
        XCTAssertEqual(activity[1]?.pullRequestCount, 3)
        XCTAssertEqual(activity[1]?.pullRequestReviewCount, 2)
        XCTAssertEqual(activity[1]?.issueCount, 1)
        XCTAssertEqual(activity[1]?.totalCount, 10)
        XCTAssertEqual(activity[1]?.latestOccurredAt, ISO8601DateFormatter().date(from: "2026-08-24T12:00:00Z"))
    }

    func testGitHubInteractionSearchPaginatesAndMergesIssueAndPullRequestActivity() async throws {
        let service = GitHubRepositorySearchService(
            session: githubStubSession(),
            baseURL: URL(string: "https://api.github.test")!
        )
        nonisolated(unsafe) var interactionPage = 0

        GitHubURLProtocolStub.handler = { request in
            let body = try XCTUnwrap(self.githubRequestBody(request))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let query = try XCTUnwrap(object["query"] as? String)
            guard query.contains("KehaiViewerInteractions") else {
                return (self.githubResponse(url: request.url!), self.githubContributionsJSON())
            }

            interactionPage += 1
            let variables = try XCTUnwrap(object["variables"] as? [String: String])
            XCTAssertEqual(variables["interactionQuery"], "involves:@me sort:updated-desc")
            if interactionPage == 1 {
                XCTAssertNil(variables["cursor"])
                return (self.githubResponse(url: request.url!), self.githubInteractionsJSON(
                    nodes: [
                        ("Issue", 2, "2026-08-25T10:00:00Z"),
                        ("PullRequest", 1, "2026-08-25T11:00:00Z")
                    ],
                    hasNextPage: true,
                    endCursor: "cursor-1"
                ))
            }
            XCTAssertEqual(variables["cursor"], "cursor-1")
            return (self.githubResponse(url: request.url!), self.githubInteractionsJSON(
                nodes: [("Issue", 1, "2026-08-26T12:00:00Z")],
                hasNextPage: false
            ))
        }
        defer { GitHubURLProtocolStub.handler = nil }

        let activity = try await service.loadContributionActivity(token: "secret-token")

        XCTAssertEqual(interactionPage, 2)
        XCTAssertEqual(activity[1]?.totalCount, 10)
        XCTAssertEqual(activity[1]?.latestOccurredAt, ISO8601DateFormatter().date(from: "2026-08-26T12:00:00Z"))
        XCTAssertEqual(activity[2]?.totalCount, 0)
        XCTAssertEqual(activity[2]?.latestOccurredAt, ISO8601DateFormatter().date(from: "2026-08-25T10:00:00Z"))
    }

    func testGitHubInteractionSearchZeroInvolvesRunsFallbacksAndMergesCommenterResult() async throws {
        let service = GitHubRepositorySearchService(
            session: githubStubSession(),
            baseURL: URL(string: "https://api.github.test")!
        )
        nonisolated(unsafe) var interactionSources: [String] = []

        GitHubURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/user":
                return (self.githubResponse(url: request.url!), Data(#"{"login":"octocat"}"#.utf8))
            case "/user/repos":
                return (self.githubResponse(url: request.url!), self.githubRepositoryArrayJSON(ids: [1, 2]))
            case "/graphql":
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(self.githubRequestBody(request))) as? [String: Any])
                let query = try XCTUnwrap(object["query"] as? String)
                guard query.contains("KehaiViewerInteractions") else {
                    return (self.githubResponse(url: request.url!), self.githubContributionsJSON())
                }
                let variables = try XCTUnwrap(object["variables"] as? [String: String])
                let interactionQuery = try XCTUnwrap(variables["interactionQuery"])
                let source = String(interactionQuery.prefix { $0 != ":" })
                interactionSources.append(source)
                XCTAssertEqual(interactionQuery, "\(source):octocat sort:updated-desc")
                let nodes: [(String, Int64, String)]
                switch source {
                case "author":
                    nodes = [("Issue", 2, "2026-08-26T12:00:00Z")]
                case "commenter":
                    nodes = [("Issue", 2, "2026-08-27T12:00:00Z")]
                default:
                    nodes = []
                }
                return (self.githubResponse(url: request.url!), self.githubInteractionsJSON(nodes: nodes, hasNextPage: false))
            default:
                throw URLError(.badURL)
            }
        }
        defer { GitHubURLProtocolStub.handler = nil }

        let account = try await service.loadAuthenticatedRepositories(token: "secret-token")

        XCTAssertEqual(interactionSources, ["involves", "author", "commenter", "assignee", "mentions"])
        XCTAssertEqual(account.interactionRepositoryCount, 1)
        XCTAssertEqual(account.interactionNodeCount, 2)
        XCTAssertEqual(account.interactionInvolvesNodeCount, 0)
        XCTAssertEqual(account.interactionFallbackNodeCount, 2)
        XCTAssertEqual(account.interactionAuthorNodeCount, 1)
        XCTAssertEqual(account.interactionCommenterNodeCount, 1)
        XCTAssertEqual(account.interactionAssigneeNodeCount, 0)
        XCTAssertEqual(account.interactionMentionsNodeCount, 0)
        XCTAssertNil(account.contributionActivity[2])
    }

    func testGitHubRESTInteractionFallbackUsesExpectedRequestAndPaginatesMappedInventory() async throws {
        let service = GitHubRepositorySearchService(
            session: githubStubSession(),
            baseURL: URL(string: "https://api.github.test")!
        )
        nonisolated(unsafe) var restPages: [Int] = []

        GitHubURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/user":
                return (self.githubResponse(url: request.url!), Data(#"{"login":"octocat"}"#.utf8))
            case "/user/repos":
                return (self.githubResponse(url: request.url!), self.githubRepositoryArrayJSON(ids: [41]))
            case "/graphql":
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(self.githubRequestBody(request))) as? [String: Any])
                let query = try XCTUnwrap(object["query"] as? String)
                return query.contains("KehaiViewerInteractions")
                    ? (self.githubResponse(url: request.url!), self.githubInteractionsJSON(nodes: [], hasNextPage: false))
                    : (self.githubResponse(url: request.url!), self.githubContributionsJSON())
            case "/search/issues":
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
                XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Kehai")
                XCTAssertEqual(request.timeoutInterval, 30)
                let queryItems = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
                let searchQuery = try XCTUnwrap(queryItems.first(where: { $0.name == "q" })?.value)
                XCTAssertTrue(searchQuery == "involves:octocat is:issue" || searchQuery == "involves:octocat is:pull-request")
                XCTAssertEqual(queryItems.first(where: { $0.name == "sort" })?.value, "updated")
                XCTAssertEqual(queryItems.first(where: { $0.name == "order" })?.value, "desc")
                XCTAssertEqual(queryItems.first(where: { $0.name == "per_page" })?.value, "100")
                let pageValue = try XCTUnwrap(queryItems.first(where: { $0.name == "page" })?.value)
                let page = try XCTUnwrap(Int(pageValue))
                restPages.append(page)
                if searchQuery.hasSuffix("is:pull-request") {
                    return (self.githubResponse(url: request.url!), self.githubSearchIssuesJSON(totalCount: 0, items: []))
                }
                if page == 1 {
                    let items = (0..<100).map { index in
                        let repositoryURL = index == 0
                            ? "https://api.github.test/repos/other/not-loaded"
                            : "https://api.github.test/repos/octocat/repo"
                        return (repositoryURL, "2026-08-25T10:\(String(format: "%02d", index % 60)):00Z")
                    }
                    return (self.githubResponse(url: request.url!), self.githubSearchIssuesJSON(totalCount: 101, items: items))
                }
                return (self.githubResponse(url: request.url!), self.githubSearchIssuesJSON(
                    totalCount: 101,
                    items: [("https://api.github.test/repos/octocat/repo", "2026-08-27T12:00:00Z")]
                ))
            default:
                throw URLError(.badURL)
            }
        }
        defer { GitHubURLProtocolStub.handler = nil }

        let account = try await service.loadAuthenticatedRepositories(token: "secret-token")

        XCTAssertEqual(restPages, [1, 2, 1])
        XCTAssertEqual(account.interactionRESTFallbackNodeCount, 101)
        XCTAssertEqual(account.interactionRESTFallbackPageCount, 3)
        XCTAssertEqual(account.interactionRESTFallbackMappedRepositoryCount, 1)
        XCTAssertEqual(account.interactionRepositoryCount, 1)
        XCTAssertNil(account.contributionActivity[41])
        XCTAssertNil(account.contributionWarning)
    }

    func testGitHubRESTInteractionFallbackPreservesFirstPageWhenLaterPageFails() async throws {
        let service = GitHubRepositorySearchService(
            session: githubStubSession(),
            baseURL: URL(string: "https://api.github.test")!
        )

        GitHubURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/user":
                return (self.githubResponse(url: request.url!), Data(#"{"login":"octocat"}"#.utf8))
            case "/user/repos":
                return (self.githubResponse(url: request.url!), self.githubRepositoryArrayJSON(ids: [51]))
            case "/graphql":
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(self.githubRequestBody(request))) as? [String: Any])
                let query = try XCTUnwrap(object["query"] as? String)
                return query.contains("KehaiViewerInteractions")
                    ? (self.githubResponse(url: request.url!), self.githubInteractionsJSON(nodes: [], hasNextPage: false))
                    : (self.githubResponse(url: request.url!), self.githubContributionsJSON())
            case "/search/issues":
                let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                let searchQuery = queryItems?.first(where: { $0.name == "q" })?.value
                let page = queryItems?.first(where: { $0.name == "page" })?.value
                if searchQuery?.hasSuffix("is:pull-request") == true {
                    return (self.githubResponse(url: request.url!), self.githubSearchIssuesJSON(totalCount: 0, items: []))
                }
                if page == "1" {
                    let items = (0..<100).map { _ in
                        ("https://api.github.test/repos/octocat/repo", "2026-08-26T12:00:00Z")
                    }
                    return (self.githubResponse(url: request.url!), self.githubSearchIssuesJSON(totalCount: 101, items: items))
                }
                return (
                    self.githubResponse(url: request.url!, statusCode: 403),
                    Data(#"{"message":"Search access denied"}"#.utf8)
                )
            default:
                throw URLError(.badURL)
            }
        }
        defer { GitHubURLProtocolStub.handler = nil }

        let account = try await service.loadAuthenticatedRepositories(token: "secret-token")

        XCTAssertEqual(account.interactionRESTFallbackNodeCount, 100)
        XCTAssertEqual(account.interactionRESTFallbackPageCount, 2)
        XCTAssertEqual(account.interactionRESTFallbackMappedRepositoryCount, 1)
        XCTAssertNil(account.contributionActivity[51])
        XCTAssertTrue(account.contributionWarning?.contains("Search access denied") == true)
    }

    func testGitHubZeroInteractionCoverageWarnsWhenContributionsShowIssuesOrPullRequests() async throws {
        let service = GitHubRepositorySearchService(
            session: githubStubSession(),
            baseURL: URL(string: "https://api.github.test")!
        )

        GitHubURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/user":
                return (self.githubResponse(url: request.url!), Data(#"{"login":"octocat"}"#.utf8))
            case "/user/repos":
                return (self.githubResponse(url: request.url!), self.githubRepositoryArrayJSON(ids: [1]))
            case "/graphql":
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(self.githubRequestBody(request))) as? [String: Any])
                let query = try XCTUnwrap(object["query"] as? String)
                return query.contains("KehaiViewerInteractions")
                    ? (self.githubResponse(url: request.url!), self.githubInteractionsJSON(nodes: [], hasNextPage: false))
                    : (self.githubResponse(url: request.url!), self.githubContributionsJSON())
            case "/search/issues":
                return (self.githubResponse(url: request.url!), self.githubSearchIssuesJSON(totalCount: 0, items: []))
            default:
                throw URLError(.badURL)
            }
        }
        defer { GitHubURLProtocolStub.handler = nil }

        let account = try await service.loadAuthenticatedRepositories(token: "secret-token")

        XCTAssertEqual(account.interactionNodeCount, 0)
        XCTAssertEqual(account.interactionRESTFallbackNodeCount, 0)
        XCTAssertEqual(account.interactionRESTFallbackPageCount, 2)
        XCTAssertTrue(account.contributionWarning?.contains("Pull requests: Read") == true)
        XCTAssertTrue(account.contributionWarning?.contains("Issues: Read") == true)
        XCTAssertTrue(account.contributionWarning?.contains("approval/SSO") == true)
        XCTAssertEqual(account.contributionActivity[1]?.totalCount, 10)
    }

    func testGitHubInteractionSearchNonzeroInvolvesSkipsFallbacks() async throws {
        let service = GitHubRepositorySearchService(
            session: githubStubSession(),
            baseURL: URL(string: "https://api.github.test")!
        )
        nonisolated(unsafe) var interactionSources: [String] = []

        GitHubURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/user":
                return (self.githubResponse(url: request.url!), Data(#"{"login":"octocat"}"#.utf8))
            case "/user/repos":
                return (self.githubResponse(url: request.url!), self.githubRepositoryArrayJSON(ids: [1, 3]))
            case "/graphql":
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(self.githubRequestBody(request))) as? [String: Any])
                let query = try XCTUnwrap(object["query"] as? String)
                guard query.contains("KehaiViewerInteractions") else {
                    return (self.githubResponse(url: request.url!), self.githubContributionsJSON())
                }
                let variables = try XCTUnwrap(object["variables"] as? [String: String])
                let interactionQuery = try XCTUnwrap(variables["interactionQuery"])
                interactionSources.append(String(interactionQuery.prefix { $0 != ":" }))
                return (self.githubResponse(url: request.url!), self.githubInteractionsJSON(
                    nodes: [("PullRequest", 3, "2026-08-28T12:00:00Z")],
                    hasNextPage: false
                ))
            default:
                throw URLError(.badURL)
            }
        }
        defer { GitHubURLProtocolStub.handler = nil }

        let account = try await service.loadAuthenticatedRepositories(token: "secret-token")

        XCTAssertEqual(interactionSources, ["involves"])
        XCTAssertEqual(account.interactionInvolvesNodeCount, 1)
        XCTAssertEqual(account.interactionFallbackNodeCount, 0)
        XCTAssertEqual(account.interactionRepositoryCount, 1)
        XCTAssertNil(account.contributionActivity[3])
    }

    func testGitHubInteractionSearchPartialFallbackFailuresPreserveOtherResultsAndWarnings() async throws {
        let service = GitHubRepositorySearchService(
            session: githubStubSession(),
            baseURL: URL(string: "https://api.github.test")!
        )
        nonisolated(unsafe) var interactionSources: [String] = []

        GitHubURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/user":
                return (self.githubResponse(url: request.url!), Data(#"{"login":"octocat"}"#.utf8))
            case "/user/repos":
                return (self.githubResponse(url: request.url!), self.githubRepositoryArrayJSON(ids: [1, 8, 9]))
            case "/graphql":
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(self.githubRequestBody(request))) as? [String: Any])
                let query = try XCTUnwrap(object["query"] as? String)
                guard query.contains("KehaiViewerInteractions") else {
                    return (self.githubResponse(url: request.url!), self.githubContributionsJSON())
                }
                let variables = try XCTUnwrap(object["variables"] as? [String: String])
                let interactionQuery = try XCTUnwrap(variables["interactionQuery"])
                let source = String(interactionQuery.prefix { $0 != ":" })
                interactionSources.append(source)
                switch source {
                case "author":
                    return (self.githubResponse(url: request.url!), self.githubInteractionsJSON(
                        nodes: [("Issue", 8, "2026-08-25T10:00:00Z")],
                        hasNextPage: false
                    ))
                case "commenter":
                    return (self.githubResponse(url: request.url!), Data(#"{"data":null,"errors":[{"message":"Commenter search unavailable"}]}"#.utf8))
                case "assignee":
                    return (self.githubResponse(url: request.url!), self.githubInteractionsJSON(
                        nodes: [("Issue", 9, "2026-08-26T10:00:00Z")],
                        hasNextPage: false
                    ))
                case "mentions":
                    return (self.githubResponse(url: request.url!), Data(#"{"data":null,"errors":[{"message":"Mentions qualifier unsupported"}]}"#.utf8))
                default:
                    return (self.githubResponse(url: request.url!), self.githubInteractionsJSON(nodes: [], hasNextPage: false))
                }
            default:
                throw URLError(.badURL)
            }
        }
        defer { GitHubURLProtocolStub.handler = nil }

        let account = try await service.loadAuthenticatedRepositories(token: "secret-token")

        XCTAssertEqual(interactionSources, ["involves", "author", "commenter", "assignee", "mentions"])
        XCTAssertEqual(account.interactionRepositoryCount, 2)
        XCTAssertEqual(account.interactionFallbackNodeCount, 2)
        XCTAssertEqual(account.interactionAuthorNodeCount, 1)
        XCTAssertEqual(account.interactionCommenterNodeCount, 0)
        XCTAssertEqual(account.interactionAssigneeNodeCount, 1)
        XCTAssertEqual(account.interactionMentionsNodeCount, 0)
        XCTAssertNil(account.contributionActivity[8])
        XCTAssertNil(account.contributionActivity[9])
        XCTAssertTrue(account.contributionWarning?.contains("Commenter search unavailable") == true)
        XCTAssertTrue(account.contributionWarning?.contains("Mentions qualifier unsupported") == true)
    }

    func testGitHubInteractionSearchFailureKeepsContributionDataAndInventory() async throws {
        let service = GitHubRepositorySearchService(
            session: githubStubSession(),
            baseURL: URL(string: "https://api.github.test")!
        )
        nonisolated(unsafe) var interactionPage = 0

        GitHubURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/user":
                return (self.githubResponse(url: request.url!), Data(#"{"login":"octocat"}"#.utf8))
            case "/user/repos":
                return (self.githubResponse(url: request.url!), self.githubRepositoryArrayJSON(ids: [1, 8]))
            case "/graphql":
                let body = try XCTUnwrap(self.githubRequestBody(request))
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let query = try XCTUnwrap(object["query"] as? String)
                guard query.contains("KehaiViewerInteractions") else {
                    return (self.githubResponse(url: request.url!), self.githubContributionsJSON())
                }
                interactionPage += 1
                if interactionPage == 1 {
                    return (self.githubResponse(url: request.url!), self.githubInteractionsJSON(
                        nodes: [("PullRequest", 8, "2026-08-25T10:00:00Z")],
                        hasNextPage: true,
                        endCursor: "cursor-1"
                    ))
                }
                return (self.githubResponse(url: request.url!), Data(#"{"data":null,"errors":[{"message":"Interaction search unavailable"}]}"#.utf8))
            default:
                throw URLError(.badURL)
            }
        }
        defer { GitHubURLProtocolStub.handler = nil }

        let account = try await service.loadAuthenticatedRepositories(token: "secret-token")

        XCTAssertEqual(account.repositories.map(\.id), [1, 8])
        XCTAssertEqual(account.contributionActivity[1]?.totalCount, 10)
        XCTAssertNil(account.contributionActivity[8])
        XCTAssertEqual(account.contributionWarning, "Interaction search unavailable")
        XCTAssertEqual(interactionPage, 2)
    }

    func testGitHubRepositoryInventorySurvivesGraphQLErrors() async throws {
        let service = GitHubRepositorySearchService(
            session: githubStubSession(),
            baseURL: URL(string: "https://api.github.test")!
        )
        nonisolated(unsafe) var graphQLRequestCount = 0

        GitHubURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/user":
                return (self.githubResponse(url: request.url!), Data(#"{"login":"octocat"}"#.utf8))
            case "/user/repos":
                return (self.githubResponse(url: request.url!), self.githubRepositoryArrayJSON(ids: [7]))
            case "/graphql":
                graphQLRequestCount += 1
                return (self.githubResponse(url: request.url!), Data(#"{"data":null,"errors":[{"message":"Contribution access denied"}]}"#.utf8))
            default:
                throw URLError(.badURL)
            }
        }
        defer { GitHubURLProtocolStub.handler = nil }

        let account = try await service.loadAuthenticatedRepositories(token: "secret-token")

        XCTAssertEqual(graphQLRequestCount, 3)
        XCTAssertEqual(account.repositories.map(\.id), [7])
        XCTAssertTrue(account.contributionActivity.isEmpty)
        XCTAssertEqual(account.contributionWarning, "Contribution access denied")
    }

    func testGitHubServiceDecodesGraphQLErrors() async throws {
        let service = GitHubRepositorySearchService(
            session: githubStubSession(),
            baseURL: URL(string: "https://api.github.test")!
        )
        GitHubURLProtocolStub.handler = { request in
            (self.githubResponse(url: request.url!), Data(#"{"errors":[{"message":"First error"},{"message":"Second error"}]}"#.utf8))
        }
        defer { GitHubURLProtocolStub.handler = nil }

        do {
            _ = try await service.loadContributionActivity(token: "secret-token")
            XCTFail("Expected GraphQL errors")
        } catch GitHubRepositoryServiceError.graphQL(let messages) {
            XCTAssertEqual(messages, ["First error", "Second error"])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testGitHubServiceRejectsCrossOriginPagination() async throws {
        let service = GitHubRepositorySearchService(
            session: githubStubSession(),
            baseURL: URL(string: "https://api.github.test")!
        )

        GitHubURLProtocolStub.handler = { request in
            if request.url?.path == "/user" {
                return (self.githubResponse(url: request.url!), Data(#"{"login":"octocat"}"#.utf8))
            }
            let next = "<https://attacker.example/repos?page=2>; rel=\"next\""
            return (self.githubResponse(url: request.url!, headers: ["Link": next]), self.githubRepositoryArrayJSON(ids: [1]))
        }
        defer { GitHubURLProtocolStub.handler = nil }

        do {
            _ = try await service.loadAuthenticatedRepositories(token: "secret-token")
            XCTFail("Expected an invalid response for cross-origin pagination")
        } catch GitHubRepositoryServiceError.invalidResponse {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testGitHubServiceMapsAuthenticationAndRateLimitErrors() async throws {
        let service = GitHubRepositorySearchService(
            session: githubStubSession(),
            baseURL: URL(string: "https://api.github.test")!
        )

        GitHubURLProtocolStub.handler = { request in
            (self.githubResponse(url: request.url!, statusCode: 401), Data(#"{"message":"Bad credentials"}"#.utf8))
        }
        do {
            _ = try await service.loadAuthenticatedRepositories(token: "invalid")
            XCTFail("Expected invalid credentials")
        } catch GitHubRepositoryServiceError.invalidCredentials {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        GitHubURLProtocolStub.handler = { request in
            let headers = ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "2000000000"]
            return (self.githubResponse(url: request.url!, statusCode: 403, headers: headers), Data(#"{"message":"API rate limit exceeded"}"#.utf8))
        }
        defer { GitHubURLProtocolStub.handler = nil }

        do {
            _ = try await service.loadAuthenticatedRepositories(token: "valid")
            XCTFail("Expected rate limit error")
        } catch GitHubRepositoryServiceError.rateLimited(let resetAt) {
            XCTAssertEqual(resetAt, Date(timeIntervalSince1970: 2_000_000_000))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testGitHubRankingPrefersExactNameThenNameMatchThenDescription() throws {
        let repositories = try [
            githubRepository(id: 1, name: "Kehai", owner: "other", description: nil, pushedAt: "2024-01-01T00:00:00Z"),
            githubRepository(id: 2, name: "KehaiKit", owner: "other", description: nil, pushedAt: "2026-01-01T00:00:00Z"),
            githubRepository(id: 3, name: "Utilities", owner: "other", description: "Tools for Kehai", pushedAt: "2026-01-01T00:00:00Z"),
            githubRepository(id: 4, name: "Unrelated", owner: "other", description: nil, pushedAt: "2026-01-01T00:00:00Z")
        ]

        let ranked = GitHubRepositorySearchService().search(repositories, query: "kehai")

        XCTAssertEqual(ranked.map(\.id), [1, 2, 3])
    }

    func testGitHubRankingUsesPushDateAsStableTieBreak() throws {
        let repositories = try [
            githubRepository(id: 1, name: "OlderTools", owner: "octocat", description: nil, pushedAt: "2024-01-01T00:00:00Z"),
            githubRepository(id: 2, name: "NewerTools", owner: "octocat", description: nil, pushedAt: "2026-01-01T00:00:00Z")
        ]

        XCTAssertEqual(
            GitHubRepositorySearchService().search(repositories, query: "octocat").map(\.id),
            [2, 1]
        )
    }

    func testGitHubPersonalActivityRanksUnfilteredButDoesNotOverrideTextRelevance() throws {
        let exact = try githubRepository(id: 1, name: "Kehai", owner: "octocat", description: nil, pushedAt: "2024-01-01T00:00:00Z")
        let activePrefix = try githubRepository(id: 2, name: "KehaiKit", owner: "octocat", description: nil, pushedAt: "2025-01-01T00:00:00Z")
        let activity = [
            activePrefix.id: GitHubRepositoryPersonalActivity(
                contribution: nil,
                localInteraction: GitHubRepositoryLocalInteraction(
                    lastInteractedAt: ISO8601DateFormatter().date(from: "2026-08-22T00:00:00Z")!,
                    count: 5
                )
            )
        ]
        let service = GitHubRepositorySearchService()

        XCTAssertEqual(service.search([exact, activePrefix], query: "", personalActivity: activity).map(\.id), [2, 1])
        XCTAssertEqual(service.search([activePrefix, exact], query: "kehai", personalActivity: activity).map(\.id), [1, 2])
    }

    func testGitHubPersonalRankingPrefersRecentActivityOverOlderFrequency() throws {
        let recent = try githubRepository(id: 1, name: "Recent", owner: "octocat", description: nil, pushedAt: "2026-08-20T00:00:00Z")
        let frequent = try githubRepository(id: 2, name: "Frequent", owner: "octocat", description: nil, pushedAt: "2026-08-20T00:00:00Z")
        let activity = [
            recent.id: GitHubRepositoryPersonalActivity(
                contribution: GitHubRepositoryContributionActivity(
                    repositoryID: recent.id,
                    latestOccurredAt: ISO8601DateFormatter().date(from: "2026-08-23T00:00:00Z"),
                    commitCount: 1,
                    pullRequestCount: 0,
                    pullRequestReviewCount: 0,
                    issueCount: 0
                ),
                localInteraction: nil
            ),
            frequent.id: GitHubRepositoryPersonalActivity(
                contribution: GitHubRepositoryContributionActivity(
                    repositoryID: frequent.id,
                    latestOccurredAt: ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z"),
                    commitCount: 5_000,
                    pullRequestCount: 0,
                    pullRequestReviewCount: 0,
                    issueCount: 0
                ),
                localInteraction: nil
            )
        ]

        XCTAssertEqual(
            GitHubRepositorySearchService().search([frequent, recent], query: "", personalActivity: activity).map(\.id),
            [recent.id, frequent.id]
        )
    }

    func testGitHubRepositoryPushDoesNotOverridePersonalRecency() throws {
        let stalePersonalRecentPush = try githubRepository(id: 1, name: "Moneyforward", owner: "kotoba-tech", description: nil, pushedAt: "2026-08-21T00:00:00Z")
        let newerPersonalOldPush = try githubRepository(id: 2, name: "AppleTemplate", owner: "other", description: nil, pushedAt: "2026-08-01T00:00:00Z")
        let activity = [
            stalePersonalRecentPush.id: GitHubRepositoryPersonalActivity(
                contribution: GitHubRepositoryContributionActivity(
                    repositoryID: stalePersonalRecentPush.id,
                    latestOccurredAt: ISO8601DateFormatter().date(from: "2026-08-07T00:00:00Z"),
                    commitCount: 0,
                    pullRequestCount: 0,
                    pullRequestReviewCount: 0,
                    issueCount: 0
                ),
                localInteraction: nil
            ),
            newerPersonalOldPush.id: GitHubRepositoryPersonalActivity(
                contribution: GitHubRepositoryContributionActivity(
                    repositoryID: newerPersonalOldPush.id,
                    latestOccurredAt: ISO8601DateFormatter().date(from: "2026-08-12T00:00:00Z"),
                    commitCount: 1,
                    pullRequestCount: 0,
                    pullRequestReviewCount: 0,
                    issueCount: 0
                ),
                localInteraction: nil
            )
        ]

        XCTAssertEqual(
            GitHubRepositorySearchService().search([newerPersonalOldPush, stalePersonalRecentPush], query: "", personalActivity: activity).map(\.id),
            [newerPersonalOldPush.id, stalePersonalRecentPush.id]
        )
    }

    func testGitHubDistantRepositoryPushDoesNotOverrideOlderPersonalActivity() throws {
        let stalePersonalFreshPush = try githubRepository(id: 1, name: "Benchmark", owner: "kotoba-tech", description: nil, pushedAt: "2026-08-23T00:00:00Z")
        let genuinelyRecentPersonal = try githubRepository(id: 2, name: "Kehai", owner: "octocat", description: nil, pushedAt: "2026-08-20T00:00:00Z")
        let activity = [
            stalePersonalFreshPush.id: GitHubRepositoryPersonalActivity(
                contribution: GitHubRepositoryContributionActivity(
                    repositoryID: stalePersonalFreshPush.id,
                    latestOccurredAt: ISO8601DateFormatter().date(from: "2026-07-20T00:00:00Z"),
                    commitCount: 0,
                    pullRequestCount: 0,
                    pullRequestReviewCount: 0,
                    issueCount: 0
                ),
                localInteraction: nil
            ),
            genuinelyRecentPersonal.id: GitHubRepositoryPersonalActivity(
                contribution: GitHubRepositoryContributionActivity(
                    repositoryID: genuinelyRecentPersonal.id,
                    latestOccurredAt: ISO8601DateFormatter().date(from: "2026-08-22T00:00:00Z"),
                    commitCount: 1,
                    pullRequestCount: 0,
                    pullRequestReviewCount: 0,
                    issueCount: 0
                ),
                localInteraction: nil
            )
        ]

        XCTAssertEqual(
            GitHubRepositorySearchService().search([stalePersonalFreshPush, genuinelyRecentPersonal], query: "", personalActivity: activity).map(\.id),
            [genuinelyRecentPersonal.id, stalePersonalFreshPush.id]
        )
    }

    func testGitHubRepositoryWidePushDoesNotOutrankPersonalActivity() throws {
        let recentlyPushed = try githubRepository(id: 1, name: "RecentlyPushed", owner: "octocat", description: nil, pushedAt: "2026-08-23T00:00:00Z")
        let historicallyActive = try githubRepository(id: 2, name: "HistoricallyActive", owner: "octocat", description: nil, pushedAt: "2026-07-01T00:00:00Z")
        let activity = [
            historicallyActive.id: GitHubRepositoryPersonalActivity(
                contribution: GitHubRepositoryContributionActivity(
                    repositoryID: historicallyActive.id,
                    latestOccurredAt: ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z"),
                    commitCount: 5_000,
                    pullRequestCount: 0,
                    pullRequestReviewCount: 0,
                    issueCount: 0
                ),
                localInteraction: nil
            )
        ]

        XCTAssertEqual(
            GitHubRepositorySearchService().search([historicallyActive, recentlyPushed], query: "", personalActivity: activity).map(\.id),
            [historicallyActive.id, recentlyPushed.id]
        )
    }

    @MainActor
    func testGitHubLocalInteractionsPersistTimestampAndCount() {
        let suiteName = "KehaiTests.GitHubInteractions.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keyStore = APIKeyStore(service: "KehaiTests.GitHubInteractions.\(UUID().uuidString)")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = GitHubRepositoryStore(keyStore: keyStore, userDefaults: defaults)
        store.recordInteraction(repositoryID: 42)
        let first = store.localInteraction(repositoryID: 42)
        store.recordInteraction(repositoryID: 42)

        let restored = GitHubRepositoryStore(keyStore: keyStore, userDefaults: defaults)
        let interaction = restored.localInteraction(repositoryID: 42)
        XCTAssertEqual(interaction?.count, 2)
        XCTAssertNotNil(interaction?.lastInteractedAt)
        XCTAssertGreaterThanOrEqual(interaction?.lastInteractedAt ?? .distantPast, first?.lastInteractedAt ?? .distantFuture)

        XCTAssertTrue(restored.hasLocalInteractionHistory)
        restored.clearLocalInteractionHistory()
        XCTAssertFalse(restored.hasLocalInteractionHistory)
        XCTAssertNil(GitHubRepositoryStore(keyStore: keyStore, userDefaults: defaults).localInteraction(repositoryID: 42))
    }

    private func githubRequestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1_024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: bufferSize)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func githubStubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private func githubResponse(
        url: URL,
        statusCode: Int = 200,
        headers: [String: String] = [:]
    ) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    private func githubRepository(
        id: Int64,
        name: String,
        owner: String,
        description: String?,
        pushedAt: String?
    ) throws -> GitHubRepository {
        try JSONDecoder().decode(GitHubRepository.self, from: githubRepositoryJSON(
            id: id,
            name: name,
            owner: owner,
            description: description,
            pushedAt: pushedAt
        ))
    }

    private func githubRepositoryArrayJSON(ids: [Int64]) -> Data {
        let objects = ids.map { String(data: githubRepositoryJSON(id: $0), encoding: .utf8)! }
        return Data("[\(objects.joined(separator: ","))]".utf8)
    }

    private func githubAccountResponse(
        _ request: URLRequest,
        repositoryIDs: [Int64]
    ) throws -> (HTTPURLResponse, Data) {
        switch request.url?.path {
        case "/user":
            return (githubResponse(url: request.url!), Data(#"{"login":"octocat"}"#.utf8))
        case "/user/repos":
            return (githubResponse(url: request.url!), githubRepositoryArrayJSON(ids: repositoryIDs))
        case "/graphql":
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(githubRequestBody(request))) as? [String: Any])
            let query = try XCTUnwrap(object["query"] as? String)
            return query.contains("KehaiViewerInteractions")
                ? (githubResponse(url: request.url!), githubInteractionsJSON(nodes: [], hasNextPage: false))
                : (githubResponse(url: request.url!), githubContributionsJSON())
        case "/search/issues":
            return (githubResponse(url: request.url!), githubSearchIssuesJSON(totalCount: 0, items: []))
        default:
            throw URLError(.badURL)
        }
    }

    private func githubEventsJSON(events: [(type: String, repositoryName: String, createdAt: String)]) -> Data {
        let eventJSON = events.map { event in
            #"{"type":"\#(event.type)","repo":{"name":"\#(event.repositoryName)"},"created_at":"\#(event.createdAt)"}"#
        }.joined(separator: ",")
        return Data("[\(eventJSON)]".utf8)
    }

    private func githubInteractionsJSON(
        nodes: [(type: String, repositoryID: Int64, updatedAt: String)],
        hasNextPage: Bool,
        endCursor: String? = nil
    ) -> Data {
        let nodeJSON = nodes.map { node in
            #"{"__typename":"\#(node.type)","repository":{"databaseId":\#(node.repositoryID)},"updatedAt":"\#(node.updatedAt)"}"#
        }.joined(separator: ",")
        let cursorJSON = endCursor.map { #""\#($0)""# } ?? "null"
        return Data(#"{"data":{"search":{"nodes":[\#(nodeJSON)],"pageInfo":{"hasNextPage":\#(hasNextPage),"endCursor":\#(cursorJSON)}}}}"#.utf8)
    }

    private func githubSearchIssuesJSON(
        totalCount: Int,
        items: [(repositoryURL: String, updatedAt: String)]
    ) -> Data {
        let itemJSON = items.map { item in
            #"{"repository_url":"\#(item.repositoryURL)","updated_at":"\#(item.updatedAt)"}"#
        }.joined(separator: ",")
        return Data(#"{"total_count":\#(totalCount),"items":[\#(itemJSON)]}"#.utf8)
    }

    private func githubContributionsJSON() -> Data {
        Data(#"""
        {
          "data": {
            "viewer": {
              "login": "octocat",
              "pullRequests": {
                "nodes": [{
                  "repository":{"databaseId":1},
                  "updatedAt":"2026-08-26T12:00:00Z",
                  "commits":{"nodes":[
                    {"commit":{"committedDate":"2026-08-24T12:00:00Z","author":{"user":{"login":"octocat"}},"committer":{"user":{"login":"octocat"}}}},
                    {"commit":{"committedDate":"2026-08-25T12:00:00Z","author":{"user":{"login":"someone-else"}},"committer":{"user":{"login":"someone-else"}}}}
                  ]}
                }]
              },
              "contributionsCollection": {
                "commitContributionsByRepository": [{"repository":{"databaseId":1},"contributions":{"totalCount":4,"nodes":[{"occurredAt":"2026-08-20T12:00:00Z"}]}}],
                "pullRequestContributionsByRepository": [{"repository":{"databaseId":1},"contributions":{"totalCount":3,"nodes":[{"occurredAt":"2026-08-22T12:00:00Z"}]}}],
                "pullRequestReviewContributionsByRepository": [{"repository":{"databaseId":1},"contributions":{"totalCount":2,"nodes":[{"occurredAt":"2026-08-21T12:00:00Z"}]}}],
                "issueContributionsByRepository": [{"repository":{"databaseId":1},"contributions":{"totalCount":1,"nodes":[{"occurredAt":"2026-08-19T12:00:00Z"}]}}]
              }
            }
          }
        }
        """#.utf8)
    }

    private func githubRepositoryJSON(
        id: Int64,
        name: String = "repo",
        owner: String = "octocat",
        description: String? = nil,
        pushedAt: String? = nil,
        isPrivate: Bool = false,
        isFork: Bool = false,
        isArchived: Bool = false
    ) -> Data {
        let descriptionJSON = description.map { "\"\($0)\"" } ?? "null"
        let pushedAtJSON = pushedAt.map { "\"\($0)\"" } ?? "null"
        return Data("""
        {
          "id": \(id),
          "name": "\(name)",
          "full_name": "\(owner)/\(name)",
          "owner": {
            "login": "\(owner)",
            "avatar_url": "https://avatars.example/\(owner).png"
          },
          "description": \(descriptionJSON),
          "html_url": "https://github.com/\(owner)/\(name)",
          "private": \(isPrivate),
          "fork": \(isFork),
          "archived": \(isArchived),
          "pushed_at": \(pushedAtJSON)
        }
        """.utf8)
    }

}
