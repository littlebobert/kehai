import AppKit

/// What the app strip needs to know about an installed app that is not running.
struct InstalledAppInfo: Sendable {
    let bundleIdentifier: String
    let localizedName: String
    let url: URL
    let icon: NSImage?
    /// Other names the app declares in `CFBundleAlternateNames` (e.g. ChatGPT lists
    /// "Codex", its old name). Spotlight indexes these, so search should find them too.
    var alternateNames: [String] = []
}

/// Keeps the list of launchable (installed, user-facing) apps current in the background.
///
/// Scanning the Applications folders reads every bundle's Info.plist and icon from
/// disk, which can stall for seconds under load, so presenting the mini UI must only
/// read this cached list. The folders are watched so installs and removals show up
/// without a relaunch.
@MainActor
@Observable
final class InstalledAppCatalog {
    private(set) var apps: [InstalledAppInfo] = [] {
        didSet {
            alternateNamesByBundleIdentifier = apps.reduce(into: [:]) { names, app in
                guard !app.alternateNames.isEmpty else { return }
                names[app.bundleIdentifier] = app.alternateNames
            }
        }
    }
    /// Lets running apps and their windows match the same alternate names as the installed copy.
    private(set) var alternateNamesByBundleIdentifier: [String: [String]] = [:]

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var folderWatchers: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var pendingWatchRefresh: Task<Void, Never>?

    /// Folders searched, in priority order: an app found earlier wins over a later duplicate.
    nonisolated static var defaultSearchDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appending(path: "Applications", directoryHint: .isDirectory),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true)
        ]
    }

    func start() {
        guard folderWatchers.isEmpty else { return }
        watchSearchDirectories()
        refresh()
    }

    func stop() {
        folderWatchers.forEach { $0.cancel() }
        folderWatchers.removeAll()
        pendingWatchRefresh?.cancel()
        pendingWatchRefresh = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Rebuilds the list off the main actor. Callers never wait on it.
    func refresh() {
        generation += 1
        let expectedGeneration = generation
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let directories = Self.defaultSearchDirectories
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let started = Date()
            let infos = await Task.detached(priority: .utility) {
                Self.scan(directories: directories, excludingBundleIdentifier: ownBundleIdentifier)
            }.value
            guard let self, !Task.isCancelled, self.generation == expectedGeneration else { return }
            let elapsed = Date().timeIntervalSince(started)
            if elapsed > 0.5 {
                SafeDiagnosticLog.shared.record("installed-apps: refresh slow ms=\(Int(elapsed * 1000)) count=\(infos.count)")
            }
            self.apps = infos
        }
    }

    private func watchSearchDirectories() {
        for directory in Self.defaultSearchDirectories {
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in self?.scheduleWatchRefresh() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            folderWatchers.append(source)
        }
    }

    /// Installers write many files in a row; wait for the burst to settle before rescanning.
    private func scheduleWatchRefresh() {
        pendingWatchRefresh?.cancel()
        pendingWatchRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// Finds user-facing `.app` bundles in `directories` and one level of subfolders
    /// (e.g. `/Applications/Utilities`), plus apps shipped inside another app's
    /// `Contents/Applications` (Xcode's Device Hub and Instruments), de-duplicated by
    /// bundle identifier and sorted by name.
    nonisolated static func scan(
        directories: [URL],
        excludingBundleIdentifier ownBundleIdentifier: String?,
        includeIcons: Bool = true
    ) -> [InstalledAppInfo] {
        var seen = Set<String>()
        var apps: [InstalledAppInfo] = []
        for directory in directories {
            for bundleURL in applicationBundles(in: directory, depth: 0) {
                guard let info = installedApp(at: bundleURL, includeIcon: includeIcons),
                      info.bundleIdentifier != ownBundleIdentifier,
                      seen.insert(info.bundleIdentifier).inserted else { continue }
                apps.append(info)
            }
        }
        return apps.sorted {
            $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending
        }
    }

    /// Only dot-prefixed entries are skipped, not everything with the hidden flag:
    /// Apple ships /Applications/Safari.app as a hidden symlink into the system cryptex,
    /// and Spotlight and Launchpad still list it. Symlinks are resolved first because
    /// a link's own attributes say nothing about the bundle it points to.
    private nonisolated static func applicationBundles(in directory: URL, depth: Int) -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isApplicationKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var bundles: [URL] = []
        for entry in contents where !entry.lastPathComponent.hasPrefix(".") {
            let url = entry.resolvingSymlinksInPath()
            let values = try? url.resourceValues(forKeys: keys)
            if url.pathExtension == "app", values?.isApplication == true || values?.isPackage == true {
                bundles.append(url)
                bundles.append(contentsOf: embeddedApplicationBundles(in: url))
            } else if depth < 1, values?.isDirectory == true, values?.isPackage != true {
                bundles.append(contentsOf: applicationBundles(in: url, depth: depth + 1))
            }
        }
        return bundles
    }

    /// Spotlight lists these, so search should too. Only the bundle's own
    /// `Contents/Applications` is read; private helper folders stay out.
    private nonisolated static func embeddedApplicationBundles(in bundle: URL) -> [URL] {
        let directory = bundle.appending(path: "Contents/Applications", directoryHint: .isDirectory)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return contents.filter { $0.pathExtension == "app" }
    }

    private nonisolated static func installedApp(at url: URL, includeIcon: Bool) -> InstalledAppInfo? {
        guard let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleIdentifier.isEmpty,
              bundle.executableURL != nil else { return nil }
        // Menu-bar apps like Tailscale stay: Spotlight launches them too. Faceless
        // background apps and extensions have nothing to open.
        guard !plistFlag(bundle.object(forInfoDictionaryKey: "LSBackgroundOnly")),
              bundle.object(forInfoDictionaryKey: "NSExtension") == nil else { return nil }

        let displayName = FileManager.default.displayName(atPath: url.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = url.deletingPathExtension().lastPathComponent
        let name = displayName.isEmpty ? fallbackName : displayName
        return InstalledAppInfo(
            bundleIdentifier: bundleIdentifier,
            localizedName: name,
            url: url,
            icon: includeIcon ? NSWorkspace.shared.icon(forFile: url.path) : nil,
            alternateNames: alternateNames(bundle.object(forInfoDictionaryKey: "CFBundleAlternateNames"), excluding: name)
        )
    }

    /// Drops blanks and repeats of the display name so only names that add a match remain.
    nonisolated static func alternateNames(_ value: Any?, excluding name: String) -> [String] {
        guard let names = value as? [Any] else { return [] }
        var seen: Set<String> = [name.lowercased()]
        return names.compactMap { entry in
            guard let alternate = (entry as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !alternate.isEmpty,
                  seen.insert(alternate.lowercased()).inserted else { return nil }
            return alternate
        }
    }

    /// Info.plist booleans show up as Bool, number, or "1"/"YES" strings depending on the author.
    private nonisolated static func plistFlag(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool: flag
        case let number as NSNumber: number.boolValue
        case let text as String: ["1", "yes", "true"].contains(text.lowercased())
        default: false
        }
    }
}
