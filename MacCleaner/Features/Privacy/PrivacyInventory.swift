import AppKit
import Foundation

/// Files shown as one result row, before their sizes are measured.
struct PrivacyItemSpec: Sendable {
    var key: String
    var category: PrivacyCategory
    var browserID: String?
    var ownerName: String
    var profileName: String?
    var title: String
    var detail: String?
    var primaryPath: String
    var paths: [String]
    /// Readable label for each path.
    var labels: [String: String] = [:]
    var ownerBundleIdentifier: String?
}

/// A Firefox history database waiting to be inspected.
struct PrivacyFirefoxPlaces: Sendable {
    var profile: PrivacyBrowserProfile
    var path: String
}

/// Everything found on disk for one browser (names and metadata only).
struct PrivacyBrowserInventory: Sendable {
    var browser: PrivacyBrowser
    var profiles: [PrivacyBrowserProfile] = []
    var specs: [PrivacyItemSpec] = []
    var blockedLocations: [String] = []
    var firefoxPlaces: [PrivacyFirefoxPlaces] = []
    var dataFolder: String?
}

/// Accumulates the files of one result row and readable labels for its detail line.
struct PrivacySpecBuilder {
    private(set) var paths: [String] = []
    private(set) var labels: [String] = []
    private(set) var labelsByPath: [String: String] = [:]

    mutating func add(_ label: String, _ newPaths: [String]) {
        guard !newPaths.isEmpty else { return }
        paths += newPaths
        for path in newPaths { labelsByPath[path] = label }
        if !labels.contains(label) { labels.append(label) }
    }

    var detail: String? { labels.isEmpty ? nil : labels.joined(separator: ", ") }
}

/// Finds the files that make up each privacy category. It reads directory
/// listings and file metadata only, never file contents, and it never returns
/// symbolic links, excluded paths or anything on the protected-data list.
struct PrivacyInventoryCollector {
    let home: String
    let exclusions: ExclusionList
    private var claimed = Set<String>()
    private var blocked: [String] = []

    init(home: String, exclusions: ExclusionList) {
        self.home = home
        self.exclusions = exclusions
    }

    var library: String { home + "/Library" }

    // MARK: - Browsers

    mutating func inventory(for browser: PrivacyBrowser) -> PrivacyBrowserInventory {
        blocked = []
        var inventory: PrivacyBrowserInventory
        switch browser.engine {
        case .safari: inventory = safariInventory(browser)
        case .chromium: inventory = chromiumInventory(browser)
        case .firefox: inventory = firefoxInventory(browser)
        }
        inventory.blockedLocations = PathUtilities.removingNestedPaths(blocked)
        return inventory
    }

    private mutating func chromiumInventory(_ browser: PrivacyBrowser) -> PrivacyBrowserInventory {
        var inventory = PrivacyBrowserInventory(browser: browser)
        guard let supportRoot = browser.supportRoot(home: home) else { return inventory }
        let cacheRoot = browser.cacheRoot(home: home)
        let discovery = PrivacyProfileDiscovery.chromiumProfiles(supportRoot: supportRoot, cacheRoot: cacheRoot)
        if discovery.supportBlocked { noteBlocked(supportRoot) }
        if discovery.cacheBlocked, let cacheRoot { noteBlocked(cacheRoot) }
        inventory.profiles = discovery.profiles
        if PrivacyFileAccess.probe(supportRoot) == .directory {
            inventory.dataFolder = supportRoot
        } else if let cacheRoot, PrivacyFileAccess.probe(cacheRoot) == .directory {
            inventory.dataFolder = cacheRoot
        }

        let multipleProfiles = discovery.profiles.count > 1
        for profile in discovery.profiles {
            let title = rowTitle(browser, profile: profile, multipleProfiles: multipleProfiles)

            var cache = PrivacySpecBuilder()
            if let cachePath = profile.cachePath {
                // A profile's own cache folder is removed whole; a browser that keeps a
                // single profile directly in its cache folder has its contents removed.
                cache.add("Disk cache", cachePath == cacheRoot ? children(of: cachePath) : directory(cachePath))
            }
            if let data = profile.dataPath {
                cache.add("Disk cache", directory(data + "/Cache"))
                cache.add("Code cache", directory(data + "/Code Cache"))
                cache.add("GPU cache", directory(data + "/GPUCache"))
                for name in ["DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "GrShaderCache", "GraphiteDawnCache", "ShaderCache"] {
                    cache.add("Graphics cache", directory(data + "/" + name))
                }
                cache.add("Service worker cache", directory(data + "/Service Worker/CacheStorage"))
            }
            append(.cache, cache, browser: browser, profile: profile, title: title, primary: profile.cachePath, to: &inventory)

            guard let data = profile.dataPath else { continue }

            var history = PrivacySpecBuilder()
            history.add("History", database(data + "/History"))
            history.add("Visited links", database(data + "/Visited Links"))
            history.add("Top sites", database(data + "/Top Sites"))
            history.add("Address bar shortcuts", database(data + "/Shortcuts"))
            history.add("Address bar predictions", database(data + "/Network Action Predictor"))
            history.add("History index", database(data + "/History Provider Cache"))
            history.add("Archived history", database(data + "/Archived History"))
            append(.history, history, browser: browser, profile: profile, title: title, primary: nil, to: &inventory)

            var cookies = PrivacySpecBuilder()
            cookies.add("Cookies", database(data + "/Network/Cookies"))
            cookies.add("Cookies", database(data + "/Cookies"))
            append(.cookies, cookies, browser: browser, profile: profile, title: title, primary: nil, to: &inventory)

            var website = PrivacySpecBuilder()
            website.add("Local storage", directory(data + "/Local Storage"))
            website.add("IndexedDB", children(of: data + "/IndexedDB") { !$0.name.hasPrefix("chrome-extension") })
            website.add("Session storage", directory(data + "/Session Storage"))
            website.add("Web storage", directory(data + "/WebStorage"))
            website.add("File system storage", directory(data + "/File System"))
            website.add("Web databases", directory(data + "/databases"))
            append(.websiteData, website, browser: browser, profile: profile, title: title, primary: nil, to: &inventory)

            var sessions = PrivacySpecBuilder()
            sessions.add("Saved sessions", directory(data + "/Sessions"))
            for name in ["Current Session", "Current Tabs", "Last Session", "Last Tabs"] {
                sessions.add("Saved sessions", file(data + "/" + name))
            }
            append(.sessions, sessions, browser: browser, profile: profile, title: title, primary: nil, to: &inventory)
        }

        // Caches shared by all profiles.
        var shared = PrivacySpecBuilder()
        for name in ["ShaderCache", "GrShaderCache", "GraphiteDawnCache"] {
            shared.add("Graphics cache", directory(supportRoot + "/" + name))
        }
        if let cacheRoot, !discovery.profiles.contains(where: { $0.directoryName.isEmpty }) {
            let profileFolders = Set(discovery.profiles.map(\.directoryName))
            shared.add("Other caches", children(of: cacheRoot) { !profileFolders.contains($0.name) })
        }
        append(.cache, shared, browser: browser, profile: nil, title: "\(browser.name) — Shared caches", primary: nil, to: &inventory)
        return inventory
    }

    private mutating func firefoxInventory(_ browser: PrivacyBrowser) -> PrivacyBrowserInventory {
        var inventory = PrivacyBrowserInventory(browser: browser)
        guard let supportRoot = browser.supportRoot(home: home) else { return inventory }
        let cacheRoot = browser.cacheRoot(home: home)
        let discovery = PrivacyProfileDiscovery.firefoxProfiles(supportRoot: supportRoot, cacheRoot: cacheRoot, home: home)
        if discovery.supportBlocked { noteBlocked(supportRoot) }
        inventory.profiles = discovery.profiles
        if PrivacyFileAccess.probe(supportRoot) == .directory { inventory.dataFolder = supportRoot }

        let multipleProfiles = discovery.profiles.count > 1
        for profile in discovery.profiles {
            let title = rowTitle(browser, profile: profile, multipleProfiles: multipleProfiles)

            var cache = PrivacySpecBuilder()
            if let cachePath = profile.cachePath { cache.add("Disk cache", directory(cachePath)) }
            if let data = profile.dataPath { cache.add("Shader cache", directory(data + "/shader-cache")) }
            append(.cache, cache, browser: browser, profile: profile, title: title, primary: profile.cachePath, to: &inventory)

            guard let data = profile.dataPath else { continue }

            var cookies = PrivacySpecBuilder()
            cookies.add("Cookies", database(data + "/cookies.sqlite"))
            append(.cookies, cookies, browser: browser, profile: profile, title: title, primary: nil, to: &inventory)

            var website = PrivacySpecBuilder()
            website.add("Site storage", children(of: data + "/storage/default") { !$0.name.hasPrefix("moz-extension") })
            website.add("Local storage", database(data + "/webappsstore.sqlite"))
            append(.websiteData, website, browser: browser, profile: profile, title: title, primary: nil, to: &inventory)

            var sessions = PrivacySpecBuilder()
            sessions.add("Saved session", file(data + "/sessionstore.jsonlz4"))
            sessions.add("Session backups", directory(data + "/sessionstore-backups"))
            append(.sessions, sessions, browser: browser, profile: profile, title: title, primary: nil, to: &inventory)

            let places = data + "/places.sqlite"
            switch PrivacyFileAccess.probe(places) {
            case .file: inventory.firefoxPlaces.append(PrivacyFirefoxPlaces(profile: profile, path: places))
            case .blocked: noteBlocked(data)
            default: break
            }
        }
        return inventory
    }

    private mutating func safariInventory(_ browser: PrivacyBrowser) -> PrivacyBrowserInventory {
        var inventory = PrivacyBrowserInventory(browser: browser)
        let safari = library + "/Safari"
        let container = library + "/Containers/com.apple.Safari/Data/Library"
        let caches = library + "/Caches/com.apple.Safari"
        if PrivacyFileAccess.probe(safari) == .directory || PrivacyFileAccess.probe(safari) == .blocked {
            inventory.dataFolder = safari
        }
        let title = browser.name

        var cache = PrivacySpecBuilder()
        cache.add("Cache", directory(caches))
        cache.add("Cache", children(of: container + "/Caches"))
        append(.cache, cache, browser: browser, profile: nil, title: title, primary: nil, to: &inventory)

        var history = PrivacySpecBuilder()
        history.add("History", database(safari + "/History.db", extraSuffixes: ["-lock"]))
        append(.history, history, browser: browser, profile: nil, title: title, primary: nil, to: &inventory)

        var downloads = PrivacySpecBuilder()
        downloads.add("Downloads list", file(safari + "/Downloads.plist"))
        append(.downloads, downloads, browser: browser, profile: nil, title: title, primary: nil, to: &inventory)

        var cookies = PrivacySpecBuilder()
        cookies.add("Cookies", file(container + "/Cookies/Cookies.binarycookies"))
        cookies.add("Cookies", file(library + "/Cookies/Cookies.binarycookies"))
        append(.cookies, cookies, browser: browser, profile: nil, title: title, primary: nil, to: &inventory)

        var website = PrivacySpecBuilder()
        website.add("Website data", children(of: container + "/WebKit/WebsiteData"))
        website.add("Local storage", directory(safari + "/LocalStorage"))
        website.add("Web databases", directory(safari + "/Databases"))
        website.add("Website data", children(of: library + "/WebKit/com.apple.Safari/WebsiteData"))
        append(.websiteData, website, browser: browser, profile: nil, title: title, primary: nil, to: &inventory)

        var sessions = PrivacySpecBuilder()
        sessions.add("Last session", file(safari + "/LastSession.plist"))
        sessions.add("Recently closed tabs", file(safari + "/RecentlyClosedTabs.plist"))
        append(.sessions, sessions, browser: browser, profile: nil, title: title, primary: nil, to: &inventory)

        // Safari's folders are protected by macOS; say so even if nothing else was probed.
        for folder in [safari, container, caches] where !blocked.contains(folder) && PrivacyFileAccess.isBlockedDirectory(folder) {
            noteBlocked(folder)
        }
        return inventory
    }

    // MARK: - Recent items

    /// Recent-items lists kept by macOS (Apple menu) and by apps (Open Recent).
    mutating func recentItems() -> (specs: [PrivacyItemSpec], blocked: Bool) {
        let folder = PrivacyRecentItems.folder(home: home)
        var specs: [PrivacyItemSpec] = []
        let records: [FileRecord]
        switch PrivacyFileAccess.list(folder) {
        case .blocked: return ([], true)
        case .missing: return ([], false)
        case .entries(let entries): records = entries
        }

        var byKind: [String: [String]] = [:]
        for record in records where record.type == .regular {
            guard let kind = PrivacyRecentItems.listKind(fileName: record.name), accept(record.path) else { continue }
            byKind[kind, default: []].append(record.path)
        }
        for (kind, paths) in byKind.sorted(by: { $0.key < $1.key }) {
            let sorted = paths.sorted()
            specs.append(PrivacyItemSpec(
                key: "macos|recents|" + kind, category: .recentItems, browserID: nil, ownerName: "macOS", profileName: nil,
                title: PrivacyRecentItems.title(forKind: kind), detail: "Apple menu › Recent Items",
                primaryPath: sorted[0], paths: sorted, ownerBundleIdentifier: nil
            ))
        }

        var isBlocked = false
        let appFolder = folder + "/" + PrivacyRecentItems.applicationListsFolderName
        switch PrivacyFileAccess.list(appFolder) {
        case .blocked:
            isBlocked = true
        case .missing:
            break
        case .entries(let entries):
            var byApp: [String: [String]] = [:]
            for record in entries where record.type == .regular && (record.name as NSString).pathExtension.hasPrefix("sfl") {
                guard accept(record.path) else { continue }
                let bundleID = (record.name as NSString).deletingPathExtension
                byApp[bundleID.lowercased(), default: []].append(record.path)
            }
            for (bundleID, paths) in byApp {
                let sorted = paths.sorted()
                let original = ((sorted[0] as NSString).lastPathComponent as NSString).deletingPathExtension
                let name = PrivacyRecentItems.applicationName(bundleIdentifier: original) ?? original
                specs.append(PrivacyItemSpec(
                    key: "macos|app-recents|" + bundleID, category: .appRecentDocuments, browserID: nil,
                    ownerName: name, profileName: nil, title: name,
                    detail: "Open Recent list", primaryPath: sorted[0], paths: sorted, ownerBundleIdentifier: original
                ))
            }
        }
        specs.sort { lhs, rhs in
            if lhs.category != rhs.category { return lhs.category == .recentItems }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        return (specs, isBlocked)
    }

    // MARK: - Primitives

    private func rowTitle(_ browser: PrivacyBrowser, profile: PrivacyBrowserProfile, multipleProfiles: Bool) -> String {
        multipleProfiles ? "\(browser.name) — \(profile.displayName)" : browser.name
    }

    private mutating func append(
        _ category: PrivacyCategory,
        _ builder: PrivacySpecBuilder,
        browser: PrivacyBrowser,
        profile: PrivacyBrowserProfile?,
        title: String,
        primary: String?,
        to inventory: inout PrivacyBrowserInventory
    ) {
        guard let first = builder.paths.first else { return }
        let primaryPath = primary.flatMap { PrivacyFileAccess.probe($0) == .directory ? $0 : nil } ?? first
        let key = [browser.id, profile?.directoryName ?? "*", category.rawValue, title].joined(separator: "|")
        inventory.specs.append(PrivacyItemSpec(
            key: key, category: category, browserID: browser.id, ownerName: browser.name,
            profileName: profile?.displayName, title: title, detail: builder.detail,
            primaryPath: primaryPath, paths: builder.paths, labels: builder.labelsByPath,
            ownerBundleIdentifier: browser.primaryBundleIdentifier
        ))
    }

    /// Records a protected location once, as its folder.
    private mutating func noteBlocked(_ path: String) {
        if !blocked.contains(path) { blocked.append(path) }
    }

    /// `true` if `path` may be offered (claims it so no other row includes it).
    private mutating func accept(_ path: String) -> Bool {
        guard !claimed.contains(path), !exclusions.isExcluded(path), !PrivacyProtectedData.isProtected(path) else { return false }
        claimed.insert(path)
        return true
    }

    /// `[path]` if it is a readable folder that may be offered.
    private mutating func directory(_ path: String) -> [String] {
        switch PrivacyFileAccess.probe(path) {
        case .directory:
            if PrivacyFileAccess.isBlockedDirectory(path) {
                noteBlocked(path)
                return []
            }
            return accept(path) ? [path] : []
        case .blocked:
            noteBlocked((path as NSString).deletingLastPathComponent)
            return []
        default:
            return []
        }
    }

    /// `[path]` if it is a regular file that may be offered.
    private mutating func file(_ path: String) -> [String] {
        switch PrivacyFileAccess.probe(path) {
        case .file:
            return accept(path) ? [path] : []
        case .blocked:
            noteBlocked((path as NSString).deletingLastPathComponent)
            return []
        default:
            return []
        }
    }

    /// A database file with the journal, WAL and shared-memory files that exist.
    /// If the database itself is protected, its companions are left alone too.
    private mutating func database(_ path: String, extraSuffixes: [String] = []) -> [String] {
        if PrivacyProtectedData.isProtected(path) { return [] }
        var paths: [String] = []
        for suffix in [""] + PrivacyFileAccess.sqliteCompanionSuffixes + extraSuffixes {
            paths += file(path + suffix)
        }
        return paths
    }

    /// Children of `directory` (files and folders, never symbolic links) that may be offered.
    private mutating func children(of directory: String, where include: (FileRecord) -> Bool = { _ in true }) -> [String] {
        switch PrivacyFileAccess.list(directory) {
        case .blocked:
            noteBlocked(directory)
            return []
        case .missing:
            return []
        case .entries(let records):
            var paths: [String] = []
            for record in records.sorted(by: { $0.name < $1.name }) {
                guard record.type == .regular || record.type == .directory, include(record) else { continue }
                if accept(record.path) { paths.append(record.path) }
            }
            return paths
        }
    }
}

/// Recent-items lists maintained by macOS's shared file list service.
enum PrivacyRecentItems {
    static let applicationListsFolderName = "com.apple.LSSharedFileList.ApplicationRecentDocuments"
    private static let listPrefix = "com.apple.LSSharedFileList."

    static func folder(home: String) -> String {
        home + "/Library/Application Support/com.apple.sharedfilelist"
    }

    /// "RecentDocuments" for "com.apple.LSSharedFileList.RecentDocuments.sfl3";
    /// nil for lists that aren't recent items (Finder sidebar favorites and so on).
    static func listKind(fileName: String) -> String? {
        let ext = (fileName as NSString).pathExtension
        guard ext.hasPrefix("sfl"), fileName.hasPrefix(listPrefix + "Recent") else { return nil }
        return String((fileName as NSString).deletingPathExtension.dropFirst(listPrefix.count))
    }

    static func title(forKind kind: String) -> String {
        switch kind {
        case "RecentApplications": return "Recent applications"
        case "RecentDocuments": return "Recent documents"
        case "RecentServers": return "Recent servers"
        case "RecentHosts": return "Recent hosts"
        default: return "Recent items (\(kind.dropFirst("Recent".count)))"
        }
    }

    static func applicationName(bundleIdentifier: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        return (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
    }
}
