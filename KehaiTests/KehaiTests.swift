import XCTest
@testable import Kehai

private final class GitHubURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
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
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Kehai")

            if request.url?.path == "/user" {
                return (self.githubResponse(url: request.url!), Data(#"{"login":"octocat"}"#.utf8))
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
        XCTAssertEqual(repositoryPage, 2)
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
