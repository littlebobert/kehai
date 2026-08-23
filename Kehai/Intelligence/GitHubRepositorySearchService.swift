import Foundation
import Observation

struct GitHubRepository: Decodable, Identifiable, Sendable {
    let id: Int64
    let name: String
    let fullName: String
    let ownerLogin: String
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
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        fullName = try container.decode(String.self, forKey: .fullName)
        ownerLogin = try container.decode(Owner.self, forKey: .owner).login
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

enum GitHubRepositoryServiceError: LocalizedError, Sendable {
    case missingToken
    case invalidResponse
    case invalidCredentials
    case forbidden(String?)
    case rateLimited(resetAt: Date?)
    case requestFailed(statusCode: Int, message: String?)
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
        case .decodingFailed:
            L10n.string("GitHub returned repository data in an unexpected format.")
        }
    }
}

struct GitHubRepositorySearchService: Sendable {
    struct Account: Sendable {
        let username: String
        let repositories: [GitHubRepository]
    }

    private struct AuthenticatedUser: Decodable {
        let login: String
    }

    private struct APIError: Decodable {
        let message: String?
    }

    private let session: URLSession
    private let baseURL: URL
    private let maximumPages: Int

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

        return Account(username: user.login, repositories: repositories)
    }

    func search(_ repositories: [GitHubRepository], query: String) -> [GitHubRepository] {
        let cleanQuery = Self.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleanQuery.isEmpty else {
            return repositories.sorted(by: Self.tieBreak)
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
            left.1 == right.1 ? Self.tieBreak(left.0, right.0) : left.1 > right.1
        }
        .map(\.0)
    }

    private func isTrustedAPIURL(_ url: URL) -> Bool {
        url.scheme == "https"
            && url.host?.caseInsensitiveCompare(baseURL.host ?? "") == .orderedSame
            && url.port == baseURL.port
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
        let message = (try? JSONDecoder().decode(APIError.self, from: data))?.message
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

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func tieBreak(_ left: GitHubRepository, _ right: GitHubRepository) -> Bool {
        if left.pushedAt != right.pushedAt {
            return (left.pushedAt ?? .distantPast) > (right.pushedAt ?? .distantPast)
        }
        return left.fullName.localizedCaseInsensitiveCompare(right.fullName) == .orderedAscending
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
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastRefreshedAt: Date?

    init(
        id: String,
        keyStore: APIKeyStore,
        username: String? = nil,
        repositories: [GitHubRepository] = [],
        lastRefreshedAt: Date? = nil
    ) {
        self.id = id
        self.keyStore = keyStore
        self.username = username
        self.repositories = repositories
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

    var newToken = ""
    private(set) var connections: [GitHubRepositoryConnection]
    private(set) var isAddingConnection = false
    private var operationErrorMessage: String?

    private let service: GitHubRepositorySearchService
    private let userDefaults: UserDefaults

    init(
        keyStore: APIKeyStore = .github(),
        service: GitHubRepositorySearchService = GitHubRepositorySearchService(),
        userDefaults: UserDefaults = .standard
    ) {
        self.service = service
        self.userDefaults = userDefaults

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

        userDefaults.set(connections.map(\.id), forKey: Self.persistedConnectionIDsKey)
    }

    var repositories: [GitHubRepository] {
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
        return service.search(Array(repositoriesByID.values), query: "")
    }

    var hasSavedTokens: Bool {
        connections.contains { $0.keyStore.hasSavedKey }
    }

    var isLoading: Bool {
        isAddingConnection || connections.contains(where: \.isLoading)
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
                lastRefreshedAt: Date()
            )
            connections.append(connection)
            persistConnectionIDs()
            newToken = ""
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
        } catch {
            guard connections.contains(where: { $0.id == connectionID }) else { return }
            connection.record(error: error)
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
        service.search(repositories, query: query)
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
