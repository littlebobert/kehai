import AppKit
import CoreServices
import os
import UniformTypeIdentifiers

/// A file or folder from Spotlight's index. Built only from index metadata: Kehai never
/// opens, reads, or thumbnails the file itself.
struct FileSearchResult: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let contentType: String?
    let lastUsed: Date?
    let modified: Date?
    /// True when only the file's text matched, not its name.
    let matchedContentOnly: Bool
    let icon: NSImage?

    var url: URL { URL(fileURLWithPath: path) }
    var wasOpenedByUser: Bool { lastUsed != nil }

    /// The containing folder, with iCloud Drive named as Finder names it and the home
    /// folder shortened to "~".
    var parentDisplayPath: String {
        let parent = (path as NSString).deletingLastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let iCloudDrive = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if parent == iCloudDrive { return "iCloud Drive" }
        if parent.hasPrefix(iCloudDrive + "/") { return "iCloud Drive" + parent.dropFirst(iCloudDrive.count) }
        if parent == home { return "~" }
        if parent.hasPrefix(home + "/") { return "~" + parent.dropFirst(home.count) }
        return parent
    }

    func withIcon(_ icon: NSImage?) -> FileSearchResult {
        FileSearchResult(
            path: path,
            name: name,
            contentType: contentType,
            lastUsed: lastUsed,
            modified: modified,
            matchedContentOnly: matchedContentOnly,
            icon: icon
        )
    }

    static func == (lhs: FileSearchResult, rhs: FileSearchResult) -> Bool { lhs.path == rhs.path }
    func hash(into hasher: inout Hasher) { hasher.combine(path) }
}

/// Searches Spotlight's existing index for files by name, and by text for files the
/// user has opened before. Uses the public Metadata query API; no Full Disk Access needed.
///
/// Queries always use Spotlight's home scope. Naming Desktop, Documents, or Downloads as
/// a scope makes macOS show its folder-access prompt; the home scope doesn't, and leaves
/// out files in those folders until the user has granted Kehai access to them.
///
/// Queries are capped on the Spotlight side. Uncapped, a two-letter search over a
/// developer's home folder can match 100,000+ files and take over 20 seconds.
struct FileSearchService: Sendable {
    static let minimumQueryLength = 2
    static let minimumContentQueryLength = 3
    static let resultLimit = 20

    private static let openedNameCap = 100
    /// Larger than the results shown because ~/Library matches count toward it until
    /// `FileSearchRanking.isNoise` removes them; they can be 90% of a short query's matches.
    private static let anyNameCap = 2000
    private static let openedContentCap = 60

    func search(_ query: String) async -> [FileSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumQueryLength else { return [] }
        return await Task.detached(priority: .userInitiated) {
            Self.runSearch(trimmed)
        }.value
    }

    private nonisolated static func runSearch(_ query: String) -> [FileSearchResult] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        let nameMatch = matchExpression(attribute: "kMDItemDisplayName", words: words)
        let opened = "(kMDItemLastUsedDate == *)"
        // Files the user has opened are few and almost never build output, so they get
        // their own query instead of competing for the general query's cap.
        var querySpecs: [(text: String, cap: Int, contentOnly: Bool)] = [
            ("\(nameMatch) && \(opened)", openedNameCap, false),
            (nameMatch, anyNameCap, false)
        ]
        if query.count >= minimumContentQueryLength {
            let contentMatch = matchExpression(attribute: "kMDItemTextContent", words: words)
            querySpecs.append(("\(contentMatch) && \(opened)", openedContentCap, true))
        }

        // Each query waits on Spotlight, so running them side by side roughly halves the wait.
        let queries = querySpecs
        let batches = OSAllocatedUnfairLock(initialState: Array(repeating: [FileSearchResult](), count: queries.count))
        DispatchQueue.concurrentPerform(iterations: queries.count) { index in
            let spec = queries[index]
            let batch = execute(spec.text, cap: spec.cap, contentOnly: spec.contentOnly)
            batches.withLock { $0[index] = batch }
        }

        var candidates: [String: FileSearchResult] = [:]
        for result in batches.withLock({ $0 }).joined()
        where candidates[result.path] == nil && !FileSearchRanking.isNoise(result, homePath: home) {
            candidates[result.path] = result
        }
        let ranked = FileSearchRanking.rank(Array(candidates.values), query: query, limit: resultLimit)

        // Icons come from the file's type, never the file, so no folder prompt can appear.
        var iconsByType: [String: NSImage] = [:]
        return ranked.map { result in
            let typeKey = result.contentType ?? UTType.data.identifier
            let icon = iconsByType[typeKey] ?? NSWorkspace.shared.icon(for: UTType(typeKey) ?? .data)
            iconsByType[typeKey] = icon
            return result.withIcon(icon)
        }
    }

    /// Every word must start a word in the attribute: "apt lea" matches "Apartment Lease.pdf".
    nonisolated static func matchExpression(attribute: String, words: [String]) -> String {
        let clauses = words.map { "(\(attribute) == \"\(escape($0))*\"cdw)" }
        return "(" + clauses.joined(separator: " && ") + ")"
    }

    /// Spotlight query strings treat `*` as a wildcard and `"`/`\` as syntax.
    nonisolated static func escape(_ word: String) -> String {
        var escaped = ""
        for character in word {
            if character == "\\" || character == "\"" || character == "*" { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    /// Attributes Spotlight returns along with each result. Reading them through the
    /// query instead of per item avoids a round trip to Spotlight per value, which made
    /// a 400-result query about seven times slower. The path can't be prefetched; it
    /// comes from the item, which already knows it.
    private nonisolated static var prefetchedAttributes: [CFString] {
        [kMDItemFSName, kMDItemContentType, kMDItemLastUsedDate, kMDItemFSContentChangeDate]
    }

    private nonisolated static func execute(
        _ queryString: String,
        cap: Int,
        contentOnly: Bool
    ) -> [FileSearchResult] {
        guard let query = MDQueryCreate(
            kCFAllocatorDefault,
            queryString as CFString,
            prefetchedAttributes as CFArray,
            nil
        ) else { return [] }
        MDQuerySetSearchScope(query, [kMDQueryScopeHome] as CFArray, 0)
        MDQuerySetMaxCount(query, cap)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }

        func value(_ attribute: CFString, at index: Int) -> AnyObject? {
            guard let raw = MDQueryGetAttributeValueOfResultAtIndex(query, attribute, index) else { return nil }
            return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
        }
        var results: [FileSearchResult] = []
        for index in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, index),
                  let path = MDItemCopyAttribute(
                      Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue(),
                      kMDItemPath
                  ) as? String else { continue }
            results.append(FileSearchResult(
                path: path,
                name: value(kMDItemFSName, at: index) as? String ?? (path as NSString).lastPathComponent,
                contentType: value(kMDItemContentType, at: index) as? String,
                lastUsed: value(kMDItemLastUsedDate, at: index) as? Date,
                modified: value(kMDItemFSContentChangeDate, at: index) as? Date,
                matchedContentOnly: contentOnly,
                icon: nil
            ))
        }
        return results
    }
}

enum FileSearchRanking {
    private static let noiseFolders: Set<String> = [
        "node_modules", "DerivedData", "Pods", "Carthage", "build", "Build", "dist",
        "vendor", "__pycache__", "site-packages", "tmp", "xcuserdata"
    ]

    private static let iCloudDriveRelativePath = "Library/Mobile Documents/com~apple~CloudDocs/"

    /// Apps belong to the Apps section. Hidden paths and app bundle contents are never
    /// useful. ~/Library holds caches and app containers, apart from iCloud Drive. Build
    /// and dependency folders are noise unless the user opened the file.
    static func isNoise(_ result: FileSearchResult, homePath: String) -> Bool {
        if result.contentType == UTType.applicationBundle.identifier { return true }
        let isInHome = result.path.hasPrefix(homePath + "/")
        let relative = isInHome
            ? String(result.path.dropFirst(homePath.count + 1))
            : result.path
        if isInHome {
            if relative.hasPrefix("Applications/") { return true }
            if relative.hasPrefix("Library/"), !relative.hasPrefix(iCloudDriveRelativePath) { return true }
        }
        let components = relative.split(separator: "/")
        if components.contains(where: { $0.hasPrefix(".") }) { return true }
        if components.dropLast().contains(where: { $0.hasSuffix(".app") }) { return true }
        if !result.wasOpenedByUser,
           components.dropLast().contains(where: { noiseFolders.contains(String($0)) }) {
            return true
        }
        return false
    }

    /// Opened before unopened, names starting with the query before names with a later
    /// word matching, name matches before text matches; most recent first within each.
    static func rank(_ results: [FileSearchResult], query: String, limit: Int) -> [FileSearchResult] {
        func tier(_ result: FileSearchResult) -> Int {
            let namePrefix = result.name.range(
                of: query,
                options: [.anchored, .caseInsensitive, .diacriticInsensitive]
            ) != nil
            return (result.matchedContentOnly ? 4 : 0)
                + (result.wasOpenedByUser ? 0 : 2)
                + (namePrefix ? 0 : 1)
        }
        let ranked = results.map { (result: $0, tier: tier($0), date: $0.lastUsed ?? $0.modified) }
        return ranked.sorted { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            switch (lhs.date, rhs.date) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.result.name.localizedStandardCompare(rhs.result.name) == .orderedAscending
            }
        }
        .prefix(limit)
        .map(\.result)
    }
}
