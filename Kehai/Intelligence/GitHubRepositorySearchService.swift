import Foundation
import Observation

struct GitHubRepository: Decodable, Identifiable, Sendable {
    let id: Int64
    let name: String
    let fullName: String
    let ownerLogin: String
    let ownerAvatarURL: URL?
    let description: String?
    let htmlURL: URL
    let isPrivate: Bool
    let isFork: Bool
    let isArchived: Bool
    let pushedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, name, owner, description, fork, archived
        case fullName = "full_name"
        case htmlURL = "html_url"
        case isPrivate = "private"
        case pushedAt = "pushed_at"
    }

    private struct Owner: Decodable {
        let login: String
        let avatarURL: URL?

        private enum CodingKeys: String, CodingKey {
            case login
            case avatarURL = "avatar_url"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        fullName = try container.decode(String.self, forKey: .fullName)
        let owner = try container.decode(Owner.self, forKey: .owner)
        ownerLogin = owner.login
        ownerAvatarURL = owner.avatarURL
        description = try container.decodeIfPresent(String.self, forKey: .description)
        htmlURL = try container.decode(URL.self, forKey: .htmlURL)
        isPrivate = try container.decode(Bool.self, forKey: .isPrivate)
        isFork = try container.decode(Bool.self, forKey: .fork)
        isArchived = try container.decode(Bool.self, forKey: .archived)

        if let value = try container.decodeIfPresent(String.self, forKey: .pushedAt) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            pushedAt = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        } else {
            pushedAt = nil
        }
    }
}

struct GitHubRepositoryContributionActivity: Codable, Equatable, Sendable {
    let repositoryID: Int64
    var latestOccurredAt: Date?
    var commitCount: Int
    var pullRequestCount: Int
    var pullRequestReviewCount: Int
    var issueCount: Int

    var totalCount: Int {
        commitCount + pullRequestCount + pullRequestReviewCount + issueCount
    }

    fileprivate static func deduplicating(
        _ left: GitHubRepositoryContributionActivity,
        _ right: GitHubRepositoryContributionActivity
    ) -> GitHubRepositoryContributionActivity {
        GitHubRepositoryContributionActivity(
            repositoryID: left.repositoryID,
            latestOccurredAt: [left.latestOccurredAt, right.latestOccurredAt].compactMap { $0 }.max(),
            commitCount: max(left.commitCount, right.commitCount),
            pullRequestCount: max(left.pullRequestCount, right.pullRequestCount),
            pullRequestReviewCount: max(left.pullRequestReviewCount, right.pullRequestReviewCount),
            issueCount: max(left.issueCount, right.issueCount)
        )
    }

    fileprivate static func combiningDistinctContributors(
        _ activities: [GitHubRepositoryContributionActivity],
        repositoryID: Int64
    ) -> GitHubRepositoryContributionActivity {
        activities.reduce(
            GitHubRepositoryContributionActivity(
                repositoryID: repositoryID,
                latestOccurredAt: nil,
                commitCount: 0,
                pullRequestCount: 0,
                pullRequestReviewCount: 0,
                issueCount: 0
            )
        ) { result, activity in
            var result = result
            result.latestOccurredAt = [result.latestOccurredAt, activity.latestOccurredAt].compactMap { $0 }.max()
            result.commitCount += activity.commitCount
            result.pullRequestCount += activity.pullRequestCount
            result.pullRequestReviewCount += activity.pullRequestReviewCount
            result.issueCount += activity.issueCount
            return result
        }
    }
}

struct GitHubRepositoryLocalInteraction: Codable, Equatable, Sendable {
    var lastInteractedAt: Date
    var count: Int
}

struct GitHubRepositoryPersonalActivity: Equatable, Sendable {
    var contribution: GitHubRepositoryContributionActivity?
    var localInteraction: GitHubRepositoryLocalInteraction?
}

enum GitHubRepositoryServiceError: LocalizedError, Sendable {
    case missingToken
    case invalidResponse
    case invalidCredentials
    case forbidden(String?)
    case rateLimited(resetAt: Date?)
    case requestFailed(statusCode: Int, message: String?)
    case graphQL([String])
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .missingToken:
            L10n.string("Enter a GitHub personal access token first.")
        case .invalidResponse:
            L10n.string("GitHub returned an invalid response.")
        case .invalidCredentials:
            L10n.string("GitHub rejected the token. Check that it is valid and try again.")
        case .forbidden(let message):
            message ?? L10n.string("GitHub denied access to these repositories. Check the token permissions.")
        case .rateLimited(let resetAt):
            if let resetAt {
                L10n.format("GitHub’s API rate limit was reached. Try again after %@.", resetAt.formatted(date: .abbreviated, time: .shortened))
            } else {
                L10n.string("GitHub’s API rate limit was reached. Try again later.")
            }
        case .requestFailed(let statusCode, let message):
            if let message, !message.isEmpty {
                L10n.format("GitHub request failed (%lld): %@", Int64(statusCode), message)
            } else {
                L10n.format("GitHub request failed (%lld).", Int64(statusCode))
            }
        case .graphQL(let messages):
            messages.first ?? L10n.string("GitHub could not load contribution activity.")
        case .decodingFailed:
            L10n.string("GitHub returned repository data in an unexpected format.")
        }
    }
}

struct GitHubRepositorySearchService: Sendable {
    struct Account: Sendable {
        let username: String
        let repositories: [GitHubRepository]
        let contributionActivity: [GitHubRepository.ID: GitHubRepositoryContributionActivity]
        let contributionWarning: String?
        let contributionRepositoryCount: Int
        let interactionRepositoryCount: Int
        let interactionNodeCount: Int
        let interactionPageCount: Int
        let interactionInvolvesNodeCount: Int
        let interactionFallbackNodeCount: Int
        let interactionAuthorNodeCount: Int
        let interactionCommenterNodeCount: Int
        let interactionAssigneeNodeCount: Int
        let interactionMentionsNodeCount: Int
        let interactionRESTFallbackNodeCount: Int
        let interactionRESTFallbackPageCount: Int
        let interactionRESTFallbackMappedRepositoryCount: Int
        let eventNodeCount: Int
        let eventPageCount: Int
        let eventMappedRepositoryCount: Int
    }

    private struct AuthenticatedUser: Decodable {
        let login: String
    }

    private struct APIError: Decodable {
        let message: String?
    }

    private struct GraphQLRequest: Encodable {
        let query: String
        let variables: [String: String]
    }

    private struct GraphQLResponse: Decodable {
        let data: GraphQLData?
        let errors: [GraphQLError]?
    }

    private struct GraphQLError: Decodable {
        let message: String
    }

    private struct GraphQLData: Decodable {
        let viewer: GraphQLViewer?
        let search: InteractionSearchConnection?
    }

    private struct GraphQLViewer: Decodable {
        let login: String
        let contributionsCollection: ContributionsCollection?
        let pullRequests: ViewerPullRequestConnection?
    }

    private struct ViewerPullRequestConnection: Decodable {
        let nodes: [ViewerPullRequest]
    }

    private struct InteractionSearchConnection: Decodable {
        let nodes: [InteractionSearchNode]
        let pageInfo: GraphQLPageInfo
    }

    private struct InteractionActivityResult: Sendable {
        let activity: [GitHubRepository.ID: Date]
        let warning: String?
        let nodeCount: Int
        let pageCount: Int
        let involvesNodeCount: Int
        let authorNodeCount: Int
        let commenterNodeCount: Int
        let assigneeNodeCount: Int
        let mentionsNodeCount: Int
        let restFallbackNodeCount: Int
        let restFallbackPageCount: Int
        let restFallbackMappedRepositoryCount: Int
        let hasZeroInteractionCoverage: Bool

        var fallbackNodeCount: Int {
            authorNodeCount + commenterNodeCount + assigneeNodeCount + mentionsNodeCount
        }
    }

    private struct InteractionSearchResult: Sendable {
        let activity: [GitHubRepository.ID: Date]
        let warning: String?
        let nodeCount: Int
        let pageCount: Int
        let completedSuccessfully: Bool
    }

    private struct RESTInteractionSearchResponse: Decodable {
        let totalCount: Int
        let items: [RESTInteractionSearchItem]

        private enum CodingKeys: String, CodingKey {
            case totalCount = "total_count"
            case items
        }
    }

    private struct RESTInteractionSearchItem: Decodable {
        let repositoryURL: URL
        let updatedAt: Date

        private enum CodingKeys: String, CodingKey {
            case repositoryURL = "repository_url"
            case updatedAt = "updated_at"
        }
    }

    private struct RESTInteractionSearchResult: Sendable {
        let activity: [GitHubRepository.ID: Date]
        let warning: String?
        let nodeCount: Int
        let pageCount: Int
        let mappedRepositoryCount: Int
        let completedSuccessfully: Bool
    }

    private struct UserEvent: Decodable {
        let type: String
        let repository: UserEventRepository
        let createdAt: Date

        private enum CodingKeys: String, CodingKey {
            case type
            case repository = "repo"
            case createdAt = "created_at"
        }
    }

    private struct UserEventRepository: Decodable {
        let name: String
    }

    private struct UserEventActivityResult: Sendable {
        let activity: [GitHubRepository.ID: Date]
        let warning: String?
        let nodeCount: Int
        let pageCount: Int
        let mappedRepositoryCount: Int
    }

    private enum RESTInteractionKind: String, Sendable {
        case issue = "is:issue"
        case pullRequest = "is:pull-request"
    }

    private static let directPersonalEventTypes: Set<String> = [
        "PushEvent",
        "PullRequestEvent",
        "PullRequestReviewEvent",
        "PullRequestReviewCommentEvent",
        "IssuesEvent",
        "IssueCommentEvent",
        "CommitCommentEvent",
        "CreateEvent",
        "DeleteEvent"
    ]

    private enum InteractionSearchSource: String, CaseIterable, Sendable {
        case involves
        case author
        case commenter
        case assignee
        case mentions

        static let fallbacks: [InteractionSearchSource] = [.author, .commenter, .assignee, .mentions]
    }

    private struct InteractionSearchNode: Decodable {
        let repository: GraphQLRepository
        let updatedAt: Date
    }

    private struct GraphQLPageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    private struct ViewerPullRequest: Decodable {
        let repository: GraphQLRepository
        let updatedAt: Date
        let commits: PullRequestCommitConnection?
    }

    private struct PullRequestCommitConnection: Decodable {
        let nodes: [PullRequestCommitNode]
    }

    private struct PullRequestCommitNode: Decodable {
        let commit: PullRequestCommit
    }

    private struct PullRequestCommit: Decodable {
        let committedDate: Date
        let author: CommitActor?
        let committer: CommitActor?
    }

    private struct CommitActor: Decodable {
        let user: CommitUser?
    }

    private struct CommitUser: Decodable {
        let login: String
    }

    private struct GraphQLErrorsEnvelope: Decodable {
        let errors: [GraphQLError]
    }

    private struct ContributionsCollection: Decodable {
        let commitContributionsByRepository: [ContributionsByRepository]
        let pullRequestContributionsByRepository: [ContributionsByRepository]
        let pullRequestReviewContributionsByRepository: [ContributionsByRepository]
        let issueContributionsByRepository: [ContributionsByRepository]
    }

    private struct ContributionsByRepository: Decodable {
        let repository: GraphQLRepository
        let contributions: ContributionConnection
        let latestContributions: LatestContributionConnection?
    }

    private struct GraphQLRepository: Decodable {
        let databaseId: Int64?
    }

    private struct ContributionConnection: Decodable {
        let totalCount: Int
        let nodes: [ContributionNode]
    }

    private struct LatestContributionConnection: Decodable {
        let nodes: [ContributionNode]
    }

    private struct ContributionNode: Decodable {
        let occurredAt: Date
    }

    private let session: URLSession
    private let baseURL: URL
    private let maximumPages: Int

    private static let contributionsQuery = """
    query KehaiViewerContributions {
      viewer {
        login
        contributionsCollection {
          commitContributionsByRepository(maxRepositories: 100) {
            repository { databaseId }
            contributions(first: 1) { totalCount nodes { occurredAt } }
            latestContributions: contributions(last: 1) { nodes { occurredAt } }
          }
          pullRequestContributionsByRepository(maxRepositories: 100) {
            repository { databaseId }
            contributions(first: 1) { totalCount nodes { occurredAt } }
            latestContributions: contributions(last: 1) { nodes { occurredAt } }
          }
          pullRequestReviewContributionsByRepository(maxRepositories: 100) {
            repository { databaseId }
            contributions(first: 1) { totalCount nodes { occurredAt } }
            latestContributions: contributions(last: 1) { nodes { occurredAt } }
          }
          issueContributionsByRepository(maxRepositories: 100) {
            repository { databaseId }
            contributions(first: 1) { totalCount nodes { occurredAt } }
            latestContributions: contributions(last: 1) { nodes { occurredAt } }
          }
        }
      }
    }
    """

    private static let authoredPullRequestsQuery = """
    query KehaiAuthoredPullRequests {
      viewer {
        login
        pullRequests(first: 100, orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes {
            repository { databaseId }
            updatedAt
            commits(last: 25) {
              nodes {
                commit {
                  committedDate
                  author { user { login } }
                  committer { user { login } }
                }
              }
            }
          }
        }
      }
    }
    """

    private static let interactionsQuery = """
    query KehaiViewerInteractions($interactionQuery: String!, $cursor: String) {
      search(query: $interactionQuery, type: ISSUE, first: 100, after: $cursor) {
        nodes {
          ... on Issue {
            repository { databaseId }
            updatedAt
          }
          ... on PullRequest {
            repository { databaseId }
            updatedAt
          }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
    """

    init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.github.com")!,
        maximumPages: Int = 100
    ) {
        self.session = session
        self.baseURL = baseURL
        self.maximumPages = min(max(maximumPages, 1), 20)
    }

    func loadAuthenticatedRepositories(token: String) async throws -> Account {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty else { throw GitHubRepositoryServiceError.missingToken }

        let userData = try await data(path: "user", token: cleanToken)
        let user: AuthenticatedUser
        do {
            user = try JSONDecoder().decode(AuthenticatedUser.self, from: userData.data)
        } catch {
            throw GitHubRepositoryServiceError.decodingFailed
        }

        var repositories: [GitHubRepository] = []
        var nextURL: URL? = repositoriesURL()
        var pageCount = 0

        var visitedURLs = Set<URL>()
        while let url = nextURL, pageCount < maximumPages {
            guard isTrustedAPIURL(url), visitedURLs.insert(url).inserted else {
                throw GitHubRepositoryServiceError.invalidResponse
            }
            let result = try await data(url: url, token: cleanToken)
            let page: [GitHubRepository]
            do {
                page = try JSONDecoder().decode([GitHubRepository].self, from: result.data)
            } catch {
                throw GitHubRepositoryServiceError.decodingFailed
            }
            repositories.append(contentsOf: page)
            nextURL = Self.nextPageURL(from: result.response)
            pageCount += 1
        }

        var contributionActivity: [GitHubRepository.ID: GitHubRepositoryContributionActivity] = [:]
        var contributionRepositoryCount = 0
        var warnings: [String] = []

        do {
            contributionActivity = try await loadViewerContributionActivity(token: cleanToken)
            contributionRepositoryCount = contributionActivity.count
        } catch {
            warnings.append(Self.message(for: error))
        }

        do {
            let authoredPullRequestActivity = try await loadAuthoredPullRequestActivity(token: cleanToken)
            Self.mergeContributionActivity(authoredPullRequestActivity, into: &contributionActivity)
        } catch {
            warnings.append(Self.message(for: error))
        }

        let repositoryIDsByFullName = Dictionary(
            repositories.map { ($0.fullName.lowercased(), $0.id) },
            uniquingKeysWith: { _, latest in latest }
        )
        let eventResult = await loadUserEventActivity(
            token: cleanToken,
            username: user.login,
            repositoryIDsByFullName: repositoryIDsByFullName
        )
        Self.mergeInteractionActivity(eventResult.activity, into: &contributionActivity)
        if let warning = eventResult.warning {
            warnings.append("Events: \(warning)")
        }

        let interactionResult = await loadInteractionActivity(
            token: cleanToken,
            username: user.login,
            repositoryIDsByFullName: repositoryIDsByFullName
        )
        if let warning = interactionResult.warning {
            warnings.append(warning)
        }
        let hasIssueOrPullRequestContributions = contributionActivity.values.contains {
            $0.pullRequestCount > 0 || $0.pullRequestReviewCount > 0 || $0.issueCount > 0
        }
        if interactionResult.hasZeroInteractionCoverage && hasIssueOrPullRequestContributions {
            warnings.append(Self.zeroInteractionCoverageWarning)
        }

        let distinctWarnings = warnings.reduce(into: [String]()) { result, warning in
            if !result.contains(warning) {
                result.append(warning)
            }
        }
        return Account(
            username: user.login,
            repositories: repositories,
            contributionActivity: contributionActivity,
            contributionWarning: distinctWarnings.isEmpty ? nil : distinctWarnings.joined(separator: "\n"),
            contributionRepositoryCount: contributionRepositoryCount,
            interactionRepositoryCount: interactionResult.activity.count,
            interactionNodeCount: interactionResult.nodeCount,
            interactionPageCount: interactionResult.pageCount,
            interactionInvolvesNodeCount: interactionResult.involvesNodeCount,
            interactionFallbackNodeCount: interactionResult.fallbackNodeCount,
            interactionAuthorNodeCount: interactionResult.authorNodeCount,
            interactionCommenterNodeCount: interactionResult.commenterNodeCount,
            interactionAssigneeNodeCount: interactionResult.assigneeNodeCount,
            interactionMentionsNodeCount: interactionResult.mentionsNodeCount,
            interactionRESTFallbackNodeCount: interactionResult.restFallbackNodeCount,
            interactionRESTFallbackPageCount: interactionResult.restFallbackPageCount,
            interactionRESTFallbackMappedRepositoryCount: interactionResult.restFallbackMappedRepositoryCount,
            eventNodeCount: eventResult.nodeCount,
            eventPageCount: eventResult.pageCount,
            eventMappedRepositoryCount: eventResult.mappedRepositoryCount
        )
    }

    func loadContributionActivity(token: String) async throws -> [GitHubRepository.ID: GitHubRepositoryContributionActivity] {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty else { throw GitHubRepositoryServiceError.missingToken }

        var result = try await loadViewerContributionActivity(token: cleanToken)
        if let authoredPullRequestActivity = try? await loadAuthoredPullRequestActivity(token: cleanToken) {
            Self.mergeContributionActivity(authoredPullRequestActivity, into: &result)
        }
        let interactionResult = await loadInteractionActivity(token: cleanToken, username: "@me", repositoryIDsByFullName: nil)
        Self.mergeInteractionActivity(interactionResult.activity, into: &result)
        return result
    }

    private func loadViewerContributionActivity(
        token: String
    ) async throws -> [GitHubRepository.ID: GitHubRepositoryContributionActivity] {
        let responseBody = try await graphQL(query: Self.contributionsQuery, variables: [:], token: token)
        guard let viewer = responseBody.data?.viewer,
              let collection = viewer.contributionsCollection else {
            throw GitHubRepositoryServiceError.decodingFailed
        }

        var result: [GitHubRepository.ID: GitHubRepositoryContributionActivity] = [:]
        Self.merge(collection.commitContributionsByRepository, into: &result, count: \.commitCount)
        Self.merge(collection.pullRequestContributionsByRepository, into: &result, count: \.pullRequestCount)
        Self.merge(collection.pullRequestReviewContributionsByRepository, into: &result, count: \.pullRequestReviewCount)
        Self.merge(collection.issueContributionsByRepository, into: &result, count: \.issueCount)
        return result
    }

    private func loadAuthoredPullRequestActivity(
        token: String
    ) async throws -> [GitHubRepository.ID: GitHubRepositoryContributionActivity] {
        let responseBody = try await graphQL(query: Self.authoredPullRequestsQuery, variables: [:], token: token)
        guard let viewer = responseBody.data?.viewer else {
            throw GitHubRepositoryServiceError.decodingFailed
        }
        var result: [GitHubRepository.ID: GitHubRepositoryContributionActivity] = [:]
        Self.mergeRecentPullRequests(viewer.pullRequests?.nodes ?? [], viewerLogin: viewer.login, into: &result)
        return result
    }

    private func loadUserEventActivity(
        token: String,
        username: String,
        repositoryIDsByFullName: [String: GitHubRepository.ID]
    ) async -> UserEventActivityResult {
        var activity: [GitHubRepository.ID: Date] = [:]
        var nodeCount = 0
        var pageCount = 0

        for page in 1...3 {
            do {
                let result = try await data(url: userEventsURL(username: username, page: page), token: token)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let events: [UserEvent]
                do {
                    events = try decoder.decode([UserEvent].self, from: result.data)
                } catch {
                    throw GitHubRepositoryServiceError.decodingFailed
                }

                pageCount += 1
                nodeCount += events.count
                for event in events where Self.directPersonalEventTypes.contains(event.type) {
                    guard let repositoryID = repositoryIDsByFullName[event.repository.name.lowercased()] else { continue }
                    activity[repositoryID] = max(activity[repositoryID] ?? .distantPast, event.createdAt)
                }

                if events.count < 100 {
                    return UserEventActivityResult(
                        activity: activity,
                        warning: nil,
                        nodeCount: nodeCount,
                        pageCount: pageCount,
                        mappedRepositoryCount: activity.count
                    )
                }
            } catch {
                return UserEventActivityResult(
                    activity: activity,
                    warning: Self.message(for: error),
                    nodeCount: nodeCount,
                    pageCount: pageCount,
                    mappedRepositoryCount: activity.count
                )
            }
        }

        return UserEventActivityResult(
            activity: activity,
            warning: nil,
            nodeCount: nodeCount,
            pageCount: pageCount,
            mappedRepositoryCount: activity.count
        )
    }

    private func loadInteractionActivity(
        token: String,
        username: String,
        repositoryIDsByFullName: [String: GitHubRepository.ID]?
    ) async -> InteractionActivityResult {
        let involves = await loadInteractionSearch(source: .involves, token: token, username: username)
        var activity = involves.activity
        var warnings = involves.warning.map { [$0] } ?? []
        var pageCount = involves.pageCount
        var counts: [InteractionSearchSource: Int] = [.involves: involves.nodeCount]
        var allGraphQLSearchesCompleted = involves.completedSuccessfully

        if involves.completedSuccessfully && involves.nodeCount == 0 {
            for source in InteractionSearchSource.fallbacks {
                let fallback = await loadInteractionSearch(source: source, token: token, username: username)
                Self.mergeInteractionDates(fallback.activity, into: &activity)
                counts[source] = fallback.nodeCount
                pageCount += fallback.pageCount
                allGraphQLSearchesCompleted = allGraphQLSearchesCompleted && fallback.completedSuccessfully
                if let warning = fallback.warning {
                    warnings.append("\(source.rawValue): \(warning)")
                }
            }
        }

        let authorNodeCount = counts[.author, default: 0]
        let commenterNodeCount = counts[.commenter, default: 0]
        let assigneeNodeCount = counts[.assignee, default: 0]
        let mentionsNodeCount = counts[.mentions, default: 0]
        let graphQLNodeCount = involves.nodeCount + authorNodeCount + commenterNodeCount + assigneeNodeCount + mentionsNodeCount
        var restResult = RESTInteractionSearchResult(
            activity: [:],
            warning: nil,
            nodeCount: 0,
            pageCount: 0,
            mappedRepositoryCount: 0,
            completedSuccessfully: false
        )
        if allGraphQLSearchesCompleted, graphQLNodeCount == 0, let repositoryIDsByFullName {
            restResult = await loadRESTInteractionSearch(
                token: token,
                username: username,
                repositoryIDsByFullName: repositoryIDsByFullName
            )
            Self.mergeInteractionDates(restResult.activity, into: &activity)
            if let warning = restResult.warning {
                warnings.append("REST fallback: \(warning)")
            }
        }

        let distinctWarnings = warnings.reduce(into: [String]()) { result, warning in
            if !result.contains(warning) {
                result.append(warning)
            }
        }
        return InteractionActivityResult(
            activity: activity,
            warning: distinctWarnings.isEmpty ? nil : distinctWarnings.joined(separator: "\n"),
            nodeCount: graphQLNodeCount,
            pageCount: pageCount,
            involvesNodeCount: involves.nodeCount,
            authorNodeCount: authorNodeCount,
            commenterNodeCount: commenterNodeCount,
            assigneeNodeCount: assigneeNodeCount,
            mentionsNodeCount: mentionsNodeCount,
            restFallbackNodeCount: restResult.nodeCount,
            restFallbackPageCount: restResult.pageCount,
            restFallbackMappedRepositoryCount: restResult.mappedRepositoryCount,
            hasZeroInteractionCoverage: allGraphQLSearchesCompleted
                && graphQLNodeCount == 0
                && restResult.completedSuccessfully
                && restResult.nodeCount == 0
        )
    }

    private func loadInteractionSearch(
        source: InteractionSearchSource,
        token: String,
        username: String
    ) async -> InteractionSearchResult {
        var activity: [GitHubRepository.ID: Date] = [:]
        var cursor: String?
        var nodeCount = 0
        var pageCount = 0

        // GitHub search exposes at most 1,000 results per query: ten 100-node pages.
        for _ in 0..<10 {
            var variables = ["interactionQuery": "\(source.rawValue):\(username) sort:updated-desc"]
            if let cursor {
                variables["cursor"] = cursor
            }

            do {
                let responseBody = try await graphQL(query: Self.interactionsQuery, variables: variables, token: token)
                guard let search = responseBody.data?.search else {
                    throw GitHubRepositoryServiceError.decodingFailed
                }
                pageCount += 1
                nodeCount += search.nodes.count
                for node in search.nodes {
                    guard let repositoryID = node.repository.databaseId else { continue }
                    activity[repositoryID] = max(activity[repositoryID] ?? .distantPast, node.updatedAt)
                }
                guard search.pageInfo.hasNextPage else {
                    return InteractionSearchResult(
                        activity: activity,
                        warning: nil,
                        nodeCount: nodeCount,
                        pageCount: pageCount,
                        completedSuccessfully: true
                    )
                }
                guard let endCursor = search.pageInfo.endCursor, endCursor != cursor else {
                    throw GitHubRepositoryServiceError.invalidResponse
                }
                cursor = endCursor
            } catch {
                return InteractionSearchResult(
                    activity: activity,
                    warning: Self.message(for: error),
                    nodeCount: nodeCount,
                    pageCount: pageCount,
                    completedSuccessfully: false
                )
            }
        }
        return InteractionSearchResult(
            activity: activity,
            warning: nil,
            nodeCount: nodeCount,
            pageCount: pageCount,
            completedSuccessfully: true
        )
    }

    private func loadRESTInteractionSearch(
        token: String,
        username: String,
        repositoryIDsByFullName: [String: GitHubRepository.ID]
    ) async -> RESTInteractionSearchResult {
        let issueResult = await loadRESTInteractionSearch(
            kind: .issue,
            token: token,
            username: username,
            repositoryIDsByFullName: repositoryIDsByFullName
        )
        let pullRequestResult = await loadRESTInteractionSearch(
            kind: .pullRequest,
            token: token,
            username: username,
            repositoryIDsByFullName: repositoryIDsByFullName
        )
        var activity = issueResult.activity
        Self.mergeInteractionDates(pullRequestResult.activity, into: &activity)
        let warnings = [issueResult.warning, pullRequestResult.warning].compactMap { $0 }
        return RESTInteractionSearchResult(
            activity: activity,
            warning: warnings.isEmpty ? nil : warnings.joined(separator: "\n"),
            nodeCount: issueResult.nodeCount + pullRequestResult.nodeCount,
            pageCount: issueResult.pageCount + pullRequestResult.pageCount,
            mappedRepositoryCount: activity.count,
            completedSuccessfully: issueResult.completedSuccessfully && pullRequestResult.completedSuccessfully
        )
    }

    private func loadRESTInteractionSearch(
        kind: RESTInteractionKind,
        token: String,
        username: String,
        repositoryIDsByFullName: [String: GitHubRepository.ID]
    ) async -> RESTInteractionSearchResult {
        var activity: [GitHubRepository.ID: Date] = [:]
        var nodeCount = 0
        var pageCount = 0

        for page in 1...10 {
            do {
                let result = try await data(
                    url: restInteractionSearchURL(username: username, kind: kind, page: page),
                    token: token
                )
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let response: RESTInteractionSearchResponse
                do {
                    response = try decoder.decode(RESTInteractionSearchResponse.self, from: result.data)
                } catch {
                    throw GitHubRepositoryServiceError.decodingFailed
                }

                pageCount += 1
                nodeCount += response.items.count
                for item in response.items {
                    guard let fullName = Self.repositoryFullName(from: item.repositoryURL),
                          let repositoryID = repositoryIDsByFullName[fullName.lowercased()] else { continue }
                    activity[repositoryID] = max(activity[repositoryID] ?? .distantPast, item.updatedAt)
                }

                let cappedTotal = min(response.totalCount, 1_000)
                guard !response.items.isEmpty,
                      response.items.count == 100,
                      nodeCount < cappedTotal else {
                    return RESTInteractionSearchResult(
                        activity: activity,
                        warning: nil,
                        nodeCount: nodeCount,
                        pageCount: pageCount,
                        mappedRepositoryCount: activity.count,
                        completedSuccessfully: true
                    )
                }
            } catch {
                return RESTInteractionSearchResult(
                    activity: activity,
                    warning: Self.message(for: error),
                    nodeCount: nodeCount,
                    pageCount: pageCount,
                    mappedRepositoryCount: activity.count,
                    completedSuccessfully: false
                )
            }
        }

        return RESTInteractionSearchResult(
            activity: activity,
            warning: nil,
            nodeCount: nodeCount,
            pageCount: pageCount,
            mappedRepositoryCount: activity.count,
            completedSuccessfully: true
        )
    }

    private func graphQL(
        query: String,
        variables: [String: String],
        token: String
    ) async throws -> GraphQLResponse {
        var request = URLRequest(url: baseURL.appending(path: "graphql"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Kehai", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(GraphQLRequest(query: query, variables: variables))

        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubRepositoryServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(for: http, data: responseData)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let responseBody: GraphQLResponse
        do {
            responseBody = try decoder.decode(GraphQLResponse.self, from: responseData)
        } catch {
            throw GitHubRepositoryServiceError.decodingFailed
        }
        if let errors = responseBody.errors, !errors.isEmpty {
            throw GitHubRepositoryServiceError.graphQL(errors.map(\.message))
        }
        return responseBody
    }

    func search(
        _ repositories: [GitHubRepository],
        query: String,
        personalActivity: [GitHubRepository.ID: GitHubRepositoryPersonalActivity] = [:]
    ) -> [GitHubRepository] {
        let cleanQuery = Self.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleanQuery.isEmpty else {
            return repositories.sorted {
                Self.personalTieBreak($0, $1, activity: personalActivity)
            }
        }

        let terms = cleanQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        return repositories.compactMap { repository -> (GitHubRepository, Int)? in
            let name = Self.normalized(repository.name)
            let fullName = Self.normalized(repository.fullName)
            let owner = Self.normalized(repository.ownerLogin)
            let description = Self.normalized(repository.description ?? "")
            let searchable = [name, fullName, owner, description].joined(separator: " ")
            guard terms.allSatisfy(searchable.contains) else { return nil }

            var score = 0
            if name == cleanQuery { score += 1_000 }
            if fullName == cleanQuery { score += 950 }
            if name.hasPrefix(cleanQuery) { score += 500 }
            if fullName.hasPrefix(cleanQuery) { score += 400 }

            for term in terms {
                if name.hasPrefix(term) { score += 120 }
                else if name.contains(term) { score += 90 }
                if fullName.contains(term) { score += 60 }
                if owner.contains(term) { score += 35 }
                if description.contains(term) { score += 10 }
            }
            return (repository, score)
        }
        .sorted { left, right in
            left.1 == right.1
                ? Self.personalTieBreak(left.0, right.0, activity: personalActivity)
                : left.1 > right.1
        }
        .map(\.0)
    }

    private static func mergeContributionActivity(
        _ source: [GitHubRepository.ID: GitHubRepositoryContributionActivity],
        into result: inout [GitHubRepository.ID: GitHubRepositoryContributionActivity]
    ) {
        for (repositoryID, activity) in source {
            if let existing = result[repositoryID] {
                result[repositoryID] = .deduplicating(existing, activity)
            } else {
                result[repositoryID] = activity
            }
        }
    }

    private static func mergeInteractionDates(
        _ source: [GitHubRepository.ID: Date],
        into result: inout [GitHubRepository.ID: Date]
    ) {
        for (repositoryID, updatedAt) in source {
            result[repositoryID] = max(result[repositoryID] ?? .distantPast, updatedAt)
        }
    }

    private static func mergeInteractionActivity(
        _ interactions: [GitHubRepository.ID: Date],
        into result: inout [GitHubRepository.ID: GitHubRepositoryContributionActivity]
    ) {
        for (repositoryID, updatedAt) in interactions {
            var activity = result[repositoryID] ?? GitHubRepositoryContributionActivity(
                repositoryID: repositoryID,
                latestOccurredAt: nil,
                commitCount: 0,
                pullRequestCount: 0,
                pullRequestReviewCount: 0,
                issueCount: 0
            )
            activity.latestOccurredAt = max(activity.latestOccurredAt ?? .distantPast, updatedAt)
            result[repositoryID] = activity
        }
    }

    private static func mergeRecentPullRequests(
        _ pullRequests: [ViewerPullRequest],
        viewerLogin: String,
        into result: inout [GitHubRepository.ID: GitHubRepositoryContributionActivity]
    ) {
        for pullRequest in pullRequests {
            guard let repositoryID = pullRequest.repository.databaseId else { continue }
            var activity = result[repositoryID] ?? GitHubRepositoryContributionActivity(
                repositoryID: repositoryID,
                latestOccurredAt: nil,
                commitCount: 0,
                pullRequestCount: 0,
                pullRequestReviewCount: 0,
                issueCount: 0
            )
            let authoredCommitDates = (pullRequest.commits?.nodes ?? []).compactMap { node -> Date? in
                let authorMatches = node.commit.author?.user?.login.caseInsensitiveCompare(viewerLogin) == .orderedSame
                let committerMatches = node.commit.committer?.user?.login.caseInsensitiveCompare(viewerLogin) == .orderedSame
                return authorMatches || committerMatches ? node.commit.committedDate : nil
            }
            guard let latestAuthoredCommit = authoredCommitDates.max() else { continue }
            activity.latestOccurredAt = max(activity.latestOccurredAt ?? .distantPast, latestAuthoredCommit)
            result[repositoryID] = activity
        }
    }

    private static func merge(
        _ groups: [ContributionsByRepository],
        into result: inout [GitHubRepository.ID: GitHubRepositoryContributionActivity],
        count: WritableKeyPath<GitHubRepositoryContributionActivity, Int>
    ) {
        for group in groups {
            guard let repositoryID = group.repository.databaseId else { continue }
            var activity = result[repositoryID] ?? GitHubRepositoryContributionActivity(
                repositoryID: repositoryID,
                latestOccurredAt: nil,
                commitCount: 0,
                pullRequestCount: 0,
                pullRequestReviewCount: 0,
                issueCount: 0
            )
            activity[keyPath: count] = max(activity[keyPath: count], group.contributions.totalCount)
            activity.latestOccurredAt = [
                activity.latestOccurredAt,
                group.contributions.nodes.map(\.occurredAt).max(),
                group.latestContributions?.nodes.map(\.occurredAt).max()
            ]
            .compactMap { $0 }
            .max()
            result[repositoryID] = activity
        }
    }

    private func isTrustedAPIURL(_ url: URL) -> Bool {
        url.scheme == "https"
            && url.host?.caseInsensitiveCompare(baseURL.host ?? "") == .orderedSame
            && url.port == baseURL.port
    }

    private func userEventsURL(username: String, page: Int) -> URL {
        var components = URLComponents(
            url: baseURL.appending(path: "users").appending(path: username).appending(path: "events"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "page", value: String(page))
        ]
        return components.url!
    }

    private func restInteractionSearchURL(
        username: String,
        kind: RESTInteractionKind,
        page: Int
    ) -> URL {
        var components = URLComponents(url: baseURL.appending(path: "search/issues"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: "involves:\(username) \(kind.rawValue)"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "page", value: String(page))
        ]
        return components.url!
    }

    private static func repositoryFullName(from repositoryURL: URL) -> String? {
        let components = repositoryURL.pathComponents.filter { $0 != "/" }
        guard let repositoriesIndex = components.lastIndex(of: "repos"),
              components.count == repositoriesIndex + 3 else { return nil }
        return "\(components[repositoriesIndex + 1])/\(components[repositoriesIndex + 2])"
    }

    private func repositoriesURL() -> URL {
        var components = URLComponents(url: baseURL.appending(path: "user/repos"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member"),
            URLQueryItem(name: "sort", value: "pushed"),
            URLQueryItem(name: "direction", value: "desc"),
            URLQueryItem(name: "per_page", value: "100")
        ]
        return components.url!
    }

    private func data(path: String, token: String) async throws -> (data: Data, response: HTTPURLResponse) {
        try await data(url: baseURL.appending(path: path), token: token)
    }

    private func data(url: URL, token: String) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Kehai", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubRepositoryServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(for: http, data: data)
        }
        return (data, http)
    }

    private static func error(for response: HTTPURLResponse, data: Data) -> GitHubRepositoryServiceError {
        let graphQLErrors = (try? JSONDecoder().decode(GraphQLErrorsEnvelope.self, from: data))?.errors
        let message = (try? JSONDecoder().decode(APIError.self, from: data))?.message
            ?? graphQLErrors?.first?.message
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
        let isRateLimited = response.statusCode == 429
            || remaining == "0"
            || message?.localizedCaseInsensitiveContains("rate limit") == true

        if isRateLimited {
            let resetAt = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
                .flatMap(TimeInterval.init)
                .map(Date.init(timeIntervalSince1970:))
            return .rateLimited(resetAt: resetAt)
        }
        switch response.statusCode {
        case 401:
            return .invalidCredentials
        case 403:
            return .forbidden(message)
        default:
            if let graphQLErrors, !graphQLErrors.isEmpty {
                return .graphQL(graphQLErrors.map(\.message))
            }
            return .requestFailed(statusCode: response.statusCode, message: message)
        }
    }

    private static func nextPageURL(from response: HTTPURLResponse) -> URL? {
        guard let link = response.value(forHTTPHeaderField: "Link") else { return nil }
        for entry in link.split(separator: ",") {
            let parts = entry.split(separator: ";", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, parts[1].contains("rel=\"next\"") else { continue }
            return URL(string: parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "<>")))
        }
        return nil
    }

    private static let zeroInteractionCoverageWarning = L10n.string(
        "GitHub returned contribution counts but no issue or pull request interactions. A fine-grained token may need Pull requests: Read and Issues: Read, or organization approval/SSO authorization."
    )

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func personalTieBreak(
        _ left: GitHubRepository,
        _ right: GitHubRepository,
        activity: [GitHubRepository.ID: GitHubRepositoryPersonalActivity]
    ) -> Bool {
        let leftActivity = activity[left.id]
        let rightActivity = activity[right.id]
        let leftHasPersonalActivity = hasPersonalActivity(leftActivity)
        let rightHasPersonalActivity = hasPersonalActivity(rightActivity)
        if leftHasPersonalActivity != rightHasPersonalActivity { return leftHasPersonalActivity }

        let leftLatest = rankActivityDate(for: left, activity: leftActivity)
        let rightLatest = rankActivityDate(for: right, activity: rightActivity)
        if leftLatest != rightLatest { return leftLatest > rightLatest }

        let leftCount = personalActivityCount(leftActivity)
        let rightCount = personalActivityCount(rightActivity)
        if leftCount != rightCount { return leftCount > rightCount }

        if left.pushedAt != right.pushedAt {
            return (left.pushedAt ?? .distantPast) > (right.pushedAt ?? .distantPast)
        }
        return left.fullName.localizedCaseInsensitiveCompare(right.fullName) == .orderedAscending
    }

    static func personalActivityScore(
        for repository: GitHubRepository,
        activity: GitHubRepositoryPersonalActivity?
    ) -> TimeInterval {
        rankActivityDate(for: repository, activity: activity).timeIntervalSince1970
    }

    static func rankActivityDate(
        for repository: GitHubRepository,
        activity: GitHubRepositoryPersonalActivity?
    ) -> Date {
        latestPersonalActivity(activity) ?? repository.pushedAt ?? .distantPast
    }

    private static func latestPersonalActivity(_ activity: GitHubRepositoryPersonalActivity?) -> Date? {
        [activity?.contribution?.latestOccurredAt, activity?.localInteraction?.lastInteractedAt]
            .compactMap { $0 }
            .max()
    }

    private static func personalActivityCount(_ activity: GitHubRepositoryPersonalActivity?) -> Int {
        (activity?.contribution?.totalCount ?? 0) + (activity?.localInteraction?.count ?? 0) * 3
    }

    private static func hasPersonalActivity(_ activity: GitHubRepositoryPersonalActivity?) -> Bool {
        (activity?.contribution?.totalCount ?? 0) > 0
            || (activity?.localInteraction?.count ?? 0) > 0
            || latestPersonalActivity(activity) != nil
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

@MainActor
@Observable
final class GitHubRefreshSettings {
    private static let intervalMinutesKey = "github.repositoryRefreshIntervalMinutes"

    static let availableIntervals = [5, 15, 30, 60, 120, 240]
    static let defaultIntervalMinutes = 30

    private let defaults: UserDefaults

    var intervalMinutes: Int {
        didSet {
            guard Self.availableIntervals.contains(intervalMinutes) else {
                intervalMinutes = Self.defaultIntervalMinutes
                return
            }
            defaults.set(intervalMinutes, forKey: Self.intervalMinutesKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.integer(forKey: Self.intervalMinutesKey)
        intervalMinutes = Self.availableIntervals.contains(saved) ? saved : Self.defaultIntervalMinutes
    }

    var timeInterval: TimeInterval {
        TimeInterval(intervalMinutes * 60)
    }
}

@MainActor
@Observable
final class GitHubRepositoryConnection: Identifiable {
    let id: String
    let keyStore: APIKeyStore
    private(set) var username: String?
    private(set) var repositories: [GitHubRepository]
    private(set) var contributionActivity: [GitHubRepository.ID: GitHubRepositoryContributionActivity]
    private(set) var contributionWarning: String?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastRefreshedAt: Date?

    init(
        id: String,
        keyStore: APIKeyStore,
        username: String? = nil,
        repositories: [GitHubRepository] = [],
        contributionActivity: [GitHubRepository.ID: GitHubRepositoryContributionActivity] = [:],
        contributionWarning: String? = nil,
        lastRefreshedAt: Date? = nil
    ) {
        self.id = id
        self.keyStore = keyStore
        self.username = username
        self.repositories = repositories
        self.contributionActivity = contributionActivity
        self.contributionWarning = contributionWarning
        self.lastRefreshedAt = lastRefreshedAt
    }

    fileprivate func beginLoading() -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        errorMessage = nil
        return true
    }

    fileprivate func finishLoading() {
        isLoading = false
    }

    fileprivate func update(with account: GitHubRepositorySearchService.Account, refreshedAt: Date) {
        username = account.username
        repositories = account.repositories
        contributionActivity = account.contributionActivity
        contributionWarning = account.contributionWarning
        errorMessage = nil
        lastRefreshedAt = refreshedAt
    }

    fileprivate func record(error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

@MainActor
@Observable
final class GitHubRepositoryStore {
    private static let legacyConnectionID = "legacy"
    private static let connectionServicePrefix = "com.justin.Kehai.github.connection."
    private static let persistedConnectionIDsKey = "com.justin.Kehai.github.connectionIDs"
    private static let localInteractionsKey = "com.justin.Kehai.github.localInteractions"

    var newToken = ""
    private(set) var connections: [GitHubRepositoryConnection]
    private(set) var isAddingConnection = false
    private var operationErrorMessage: String?

    private let service: GitHubRepositorySearchService
    private let userDefaults: UserDefaults
    private let legacyKeyStore: APIKeyStore
    private var localInteractions: [GitHubRepository.ID: GitHubRepositoryLocalInteraction]
    private var hasHydratedStoredState = false
    private var isHydratingStoredState = false

    init(
        keyStore: APIKeyStore = .github(),
        service: GitHubRepositorySearchService = GitHubRepositorySearchService(),
        userDefaults: UserDefaults = .standard,
        loadsStoredState: Bool = true
    ) {
        self.service = service
        self.userDefaults = userDefaults
        legacyKeyStore = keyStore
        localInteractions = [:]
        connections = []

        guard loadsStoredState else { return }
        loadLocalInteractions()
        var persistedIDs = userDefaults.stringArray(forKey: Self.persistedConnectionIDsKey) ?? []
        if keyStore.hasSavedKey, !persistedIDs.contains(Self.legacyConnectionID) {
            persistedIDs.insert(Self.legacyConnectionID, at: 0)
        }

        var seenIDs = Set<String>()
        connections = persistedIDs.compactMap { id in
            guard seenIDs.insert(id).inserted, Self.isValidConnectionID(id) else { return nil }
            let connectionKeyStore = id == Self.legacyConnectionID
                ? keyStore
                : APIKeyStore(service: Self.connectionServicePrefix + id)
            guard connectionKeyStore.hasSavedKey else { return nil }
            return GitHubRepositoryConnection(id: id, keyStore: connectionKeyStore)
        }

        persistConnectionIDsIfChanged(from: persistedIDs)
        hasHydratedStoredState = true
    }

    func hydrate() async {
        guard !hasHydratedStoredState, !isHydratingStoredState else { return }
        isHydratingStoredState = true
        defer { isHydratingStoredState = false }

        loadLocalInteractions()
        await legacyKeyStore.hydrate()

        var persistedIDs = userDefaults.stringArray(forKey: Self.persistedConnectionIDsKey) ?? []
        if legacyKeyStore.hasSavedKey, !persistedIDs.contains(Self.legacyConnectionID) {
            persistedIDs.insert(Self.legacyConnectionID, at: 0)
        }

        var seenIDs = Set<String>()
        var hydratedConnections: [GitHubRepositoryConnection] = []
        for id in persistedIDs {
            guard seenIDs.insert(id).inserted, Self.isValidConnectionID(id) else { continue }
            let connectionKeyStore: APIKeyStore
            if id == Self.legacyConnectionID {
                connectionKeyStore = legacyKeyStore
            } else {
                connectionKeyStore = APIKeyStore(
                    service: Self.connectionServicePrefix + id,
                    loadsStoredKey: false
                )
                await connectionKeyStore.hydrate()
            }
            guard connectionKeyStore.hasSavedKey else { continue }
            hydratedConnections.append(GitHubRepositoryConnection(id: id, keyStore: connectionKeyStore))
        }

        connections = hydratedConnections
        persistConnectionIDsIfChanged(from: persistedIDs)
        hasHydratedStoredState = true
    }

    var repositories: [GitHubRepository] {
        service.search(mergedRepositories, query: "", personalActivity: personalActivity)
    }

    var contributionActivity: [GitHubRepository.ID: GitHubRepositoryContributionActivity] {
        var activitiesByRepositoryAndContributor: [GitHubRepository.ID: [String: GitHubRepositoryContributionActivity]] = [:]
        for connection in connections {
            let contributor = connection.username?.lowercased() ?? connection.id
            for (repositoryID, activity) in connection.contributionActivity {
                if let existing = activitiesByRepositoryAndContributor[repositoryID]?[contributor] {
                    activitiesByRepositoryAndContributor[repositoryID]?[contributor] = .deduplicating(existing, activity)
                } else {
                    activitiesByRepositoryAndContributor[repositoryID, default: [:]][contributor] = activity
                }
            }
        }

        return activitiesByRepositoryAndContributor.mapValues { activitiesByContributor in
            let repositoryID = activitiesByContributor.values.first!.repositoryID
            return .combiningDistinctContributors(Array(activitiesByContributor.values), repositoryID: repositoryID)
        }
    }

    var personalActivity: [GitHubRepository.ID: GitHubRepositoryPersonalActivity] {
        let contributions = contributionActivity
        let repositoryIDs = Set(contributions.keys).union(localInteractions.keys)
        return Dictionary(uniqueKeysWithValues: repositoryIDs.map { repositoryID in
            (
                repositoryID,
                GitHubRepositoryPersonalActivity(
                    contribution: contributions[repositoryID],
                    localInteraction: localInteractions[repositoryID]
                )
            )
        })
    }

    var hasSavedTokens: Bool {
        connections.contains { $0.keyStore.hasSavedKey }
    }

    var hasLocalInteractionHistory: Bool {
        !localInteractions.isEmpty
    }

    var isLoading: Bool {
        isHydratingStoredState || isAddingConnection || connections.contains(where: \.isLoading)
    }

    var errorMessage: String? {
        operationErrorMessage ?? connections.compactMap(\.errorMessage).first
    }

    var lastRefreshedAt: Date? {
        connections.compactMap(\.lastRefreshedAt).max()
    }


    func addConnection() async {
        guard !isLoading else { return }
        let token = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            operationErrorMessage = GitHubRepositoryServiceError.missingToken.errorDescription
            return
        }

        isAddingConnection = true
        operationErrorMessage = nil
        defer { isAddingConnection = false }

        do {
            let account = try await service.loadAuthenticatedRepositories(token: token)
            let id = UUID().uuidString
            let connectionKeyStore = APIKeyStore(service: Self.connectionServicePrefix + id)
            connectionKeyStore.apiKey = token
            connectionKeyStore.save()

            guard connectionKeyStore.saveError == nil, connectionKeyStore.hasSavedKey else {
                operationErrorMessage = connectionKeyStore.saveError
                    ?? L10n.string("Could not save the GitHub token.")
                connectionKeyStore.discardUnsavedChanges()
                return
            }

            let connection = GitHubRepositoryConnection(
                id: id,
                keyStore: connectionKeyStore,
                username: account.username,
                repositories: account.repositories,
                contributionActivity: account.contributionActivity,
                contributionWarning: account.contributionWarning,
                lastRefreshedAt: Date()
            )
            connections.append(connection)
            persistConnectionIDs()
            newToken = ""
            recordRefreshDiagnostics(account, event: "connection added")
        } catch {
            operationErrorMessage = Self.message(for: error)
        }
    }

    func refreshAll() async {
        guard !isAddingConnection else { return }
        operationErrorMessage = nil
        let connectionIDs = connections.map(\.id)
        for id in connectionIDs {
            await refresh(connectionID: id)
        }
    }

    func refresh(connectionID: GitHubRepositoryConnection.ID) async {
        guard let connection = connections.first(where: { $0.id == connectionID }),
              connection.beginLoading() else { return }
        let token = connection.keyStore.apiKey
        defer { connection.finishLoading() }

        do {
            let account = try await service.loadAuthenticatedRepositories(token: token)
            guard connections.contains(where: { $0.id == connectionID }) else { return }
            connection.update(with: account, refreshedAt: Date())
            recordRefreshDiagnostics(account, event: "refresh completed")
        } catch {
            guard connections.contains(where: { $0.id == connectionID }) else { return }
            connection.record(error: error)
            SafeDiagnosticLog.shared.record("github: refresh failed")
        }
    }

    func refresh(_ connection: GitHubRepositoryConnection) async {
        await refresh(connectionID: connection.id)
    }

    func removeConnection(id: GitHubRepositoryConnection.ID) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        let connection = connections.remove(at: index)
        connection.keyStore.apiKey = ""
        connection.keyStore.save()
        operationErrorMessage = connection.keyStore.saveError
        persistConnectionIDs()
    }

    func removeConnection(_ connection: GitHubRepositoryConnection) {
        removeConnection(id: connection.id)
    }

    func search(_ query: String) -> [GitHubRepository] {
        service.search(mergedRepositories, query: query, personalActivity: personalActivity)
    }

    func recordInteraction(repositoryID: GitHubRepository.ID) {
        var interaction = localInteractions[repositoryID] ?? GitHubRepositoryLocalInteraction(
            lastInteractedAt: Date(),
            count: 0
        )
        interaction.lastInteractedAt = Date()
        interaction.count += 1
        localInteractions[repositoryID] = interaction
        persistLocalInteractions()
    }

    func localInteraction(repositoryID: GitHubRepository.ID) -> GitHubRepositoryLocalInteraction? {
        localInteractions[repositoryID]
    }

    func clearLocalInteractionHistory() {
        let clearedCount = localInteractions.count
        localInteractions.removeAll()
        userDefaults.removeObject(forKey: Self.localInteractionsKey)
        SafeDiagnosticLog.shared.record("github: local ranking history reset entries=\(clearedCount)")
    }

    private func recordRefreshDiagnostics(
        _ account: GitHubRepositorySearchService.Account,
        event: String
    ) {
        SafeDiagnosticLog.shared.record(
            "github: \(event) repos=\(account.repositories.count) personalized=\(account.contributionActivity.count) contributions=\(account.contributionRepositoryCount) interactions=\(account.interactionRepositoryCount) interaction-nodes=\(account.interactionNodeCount) interaction-pages=\(account.interactionPageCount) involves-nodes=\(account.interactionInvolvesNodeCount) fallback-nodes=\(account.interactionFallbackNodeCount) author-nodes=\(account.interactionAuthorNodeCount) commenter-nodes=\(account.interactionCommenterNodeCount) assignee-nodes=\(account.interactionAssigneeNodeCount) mentions-nodes=\(account.interactionMentionsNodeCount) rest-fallback-nodes=\(account.interactionRESTFallbackNodeCount) rest-fallback-pages=\(account.interactionRESTFallbackPageCount) rest-fallback-mapped-repos=\(account.interactionRESTFallbackMappedRepositoryCount) event-nodes=\(account.eventNodeCount) event-pages=\(account.eventPageCount) event-mapped-repos=\(account.eventMappedRepositoryCount) contribution-warning=\(account.contributionWarning != nil)"
        )
        let rankingEntries = rankingSnapshot(limit: 50)
        for start in stride(from: 0, to: rankingEntries.count, by: 10) {
            let end = min(start + 10, rankingEntries.count)
            SafeDiagnosticLog.shared.record(
                "github-rank-\(start + 1)-\(end): \(rankingEntries[start..<end].joined(separator: " "))"
            )
        }
    }

    private func rankingSnapshot(limit: Int) -> [String] {
        let now = Date()
        return repositories.prefix(limit).enumerated().map { offset, repository in
            let activity = personalActivity[repository.id]
            let contribution = activity?.contribution
            let local = activity?.localInteraction
            return "p\(offset + 1){repo=\(repository.fullName),ra=\(ageMinutes(GitHubRepositorySearchService.rankActivityDate(for: repository, activity: activity), now: now)),pa=\(ageMinutes(contribution?.latestOccurredAt, now: now)),pc=\(contribution?.totalCount ?? 0),la=\(ageMinutes(local?.lastInteractedAt, now: now)),lc=\(local?.count ?? 0),push=\(ageMinutes(repository.pushedAt, now: now))}"
        }
    }

    private func ageMinutes(_ date: Date?, now: Date) -> String {
        guard let date else { return "none" }
        return String(max(0, Int(now.timeIntervalSince(date) / 60)))
    }

    private var mergedRepositories: [GitHubRepository] {
        var repositoriesByID: [GitHubRepository.ID: GitHubRepository] = [:]
        for repository in connections.flatMap(\.repositories) {
            if let existing = repositoriesByID[repository.id] {
                if (repository.pushedAt ?? .distantPast) > (existing.pushedAt ?? .distantPast) {
                    repositoriesByID[repository.id] = repository
                }
            } else {
                repositoriesByID[repository.id] = repository
            }
        }
        return Array(repositoriesByID.values)
    }

    private func loadLocalInteractions() {
        guard let data = userDefaults.data(forKey: Self.localInteractionsKey),
              let saved = try? JSONDecoder().decode(
                [GitHubRepository.ID: GitHubRepositoryLocalInteraction].self,
                from: data
              ) else {
            localInteractions = [:]
            return
        }
        localInteractions = saved
    }

    private func persistLocalInteractions() {
        guard let data = try? JSONEncoder().encode(localInteractions) else { return }
        userDefaults.set(data, forKey: Self.localInteractionsKey)
    }

    private func persistConnectionIDsIfChanged(from persistedIDs: [String]) {
        let normalizedIDs = connections.map(\.id)
        guard normalizedIDs != persistedIDs else { return }
        userDefaults.set(normalizedIDs, forKey: Self.persistedConnectionIDsKey)
    }

    private func persistConnectionIDs() {
        userDefaults.set(connections.map(\.id), forKey: Self.persistedConnectionIDsKey)
    }

    private static func isValidConnectionID(_ id: String) -> Bool {
        id == legacyConnectionID || UUID(uuidString: id) != nil
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
