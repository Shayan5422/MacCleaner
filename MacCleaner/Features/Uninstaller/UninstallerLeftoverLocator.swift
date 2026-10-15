import Foundation

/// Rules for the identifiers and names apps use for their Library folders.
enum UninstallerIdentifierRules {
    /// Names too generic to attribute a folder to one app ("Google", "Data", "Helper"...).
    static let genericNames: Set<String> = [
        "google", "microsoft", "adobe", "apple", "mozilla", "jetbrains", "oracle", "intel", "nvidia", "amd",
        "data", "cache", "caches", "support", "application", "applications", "application support", "app", "apps",
        "helper", "helpers", "update", "updater", "updates", "common", "shared", "default", "user", "users",
        "library", "temp", "tmp", "log", "logs", "config", "configuration", "settings", "preferences", "prefs",
        "plugins", "plug-ins", "extensions", "resources", "documents", "files", "backup", "backups", "sync",
        "cloud", "desktop", "mac", "macos", "osx", "system", "service", "services", "agent", "daemon", "tools",
        "utility", "utilities", "launcher", "installer", "setup", "uninstaller", "crashreporter", "crashpad",
        "sentry", "electron", "chromium", "java", "python", "node", "qt", "unity", "games", "game", "player",
        "browser", "editor", "viewer", "reader", "notes", "music", "photos", "mail", "calendar", "messages",
        "safari", "finder", "terminal", "preview", "books", "news", "maps", "home", "manager", "assistant",
        "monitor", "server", "client", "network", "security", "privacy", "storage", "drive", "web", "media",
        "video", "audio", "image", "images", "fonts", "font", "local", "global", "main", "core", "kit",
        "framework", "frameworks", "bin", "lib", "share", "var", "etc", "opt", "private", "public", "test",
        "tests", "debug", "release", "beta", "dev", "developer", "info", "index", "database", "store", "keychain",
        "keychains", "accounts", "containers", "group containers", "launchagents", "launchdaemons", "receipts",
    ]

    /// At least four characters, not generic, and containing a letter.
    static func isUsableName(_ name: String) -> Bool {
        let key = normalizedName(name)
        return key.count >= 4 && !genericNames.contains(key) && key.contains(where: \.isLetter)
    }

    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// `true` for names like `com.vendor.app`: lowercase first component, at least
    /// `minimumDots` dots, and only characters allowed in bundle identifiers.
    static func isReverseDNS(_ name: String, minimumDots: Int = 2) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= minimumDots + 1, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }) else { return false }
        let first = parts[0]
        return first.count >= 2 && first.count <= 12 && first.allSatisfy { $0.isLetter && $0.isLowercase }
    }

    /// `true` when `candidate` is `identifier` or starts with `identifier + "."` (case-insensitive).
    static func matches(_ candidate: String, identifier: String) -> Bool {
        let key = candidate.lowercased()
        let id = identifier.lowercased()
        return !id.isEmpty && (key == id || key.hasPrefix(id + "."))
    }

    /// Apple's identifiers, including Shortcuts' legacy `is.workflow.*` namespace.
    static func isAppleIdentifier(_ identifier: String) -> Bool {
        let key = identifier.lowercased()
        return key == "com.apple" || key.hasPrefix("com.apple.") || key.contains(".com.apple.") || key.hasPrefix("group.com.apple")
            || key.hasPrefix("is.workflow.") || key.contains(".is.workflow.")
    }

    /// Splits app-group identifiers: "ABCDE12345.group.com.foo.app" → ("ABCDE12345", "com.foo.app"),
    /// "group.com.foo.app" → (nil, "com.foo.app"), "ABCDE12345.Office" → ("ABCDE12345", "Office").
    static func parseGroupIdentifier(_ name: String) -> (team: String?, identifier: String) {
        var team: String?
        var rest = Substring(name)
        if name.count > 11 {
            let prefix = name.prefix(10)
            let separator = name[name.index(name.startIndex, offsetBy: 10)]
            if (separator == "." || separator == "-"), prefix.allSatisfy({ ($0.isUppercase && $0.isLetter) || $0.isNumber }),
               prefix.contains(where: \.isNumber) || prefix.contains(where: \.isLetter) {
                team = String(prefix)
                rest = name.dropFirst(11)
            }
        }
        if rest.lowercased().hasPrefix("group.") { rest = rest.dropFirst("group.".count) }
        return (team, String(rest))
    }

    /// Host-specific preferences: "com.foo.app.1DE357A1-5E44-5B02-873C-A229AA4347E1" → "com.foo.app".
    static func strippingHostSuffix(_ domain: String) -> String {
        guard let dot = domain.lastIndex(of: ".") else { return domain }
        let suffix = domain[domain.index(after: dot)...]
        let isUUID = suffix.count == 36 && suffix.allSatisfy { $0.isHexDigit || $0 == "-" }
        let isMAC = suffix.count == 12 && suffix.allSatisfy(\.isHexDigit)
        return isUUID || isMAC ? String(domain[..<dot]) : domain
    }
}

/// Finds the files an app keeps in Library folders.
///
/// Matching is deliberately conservative:
/// * Items named after the app's bundle identifier (or `<bundleID>.…`) or one of its
///   helpers are `.safe`.
/// * Items named like the app ("Telegram", at least four characters and not a generic
///   word) are `.review`.
/// * Anything another installed app could also own is excluded, with the reason:
///   a more specific identifier of another app, the same name, a shared vendor folder,
///   or an app group another app declares.
/// * Only entries inside the given Library folders are ever returned.
struct UninstallerLeftoverLocator: Sendable {
    var homeLibrary: String
    var systemLibrary: String?
    var receiptsDirectory: String?

    init(
        homeLibrary: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true),
        systemLibrary: URL? = URL(fileURLWithPath: "/Library", isDirectory: true),
        receiptsDirectory: URL? = URL(fileURLWithPath: "/private/var/db/receipts", isDirectory: true)
    ) {
        self.homeLibrary = PathUtilities.normalize(homeLibrary.path)
        self.systemLibrary = systemLibrary.map { PathUtilities.normalize($0.path) }
        self.receiptsDirectory = receiptsDirectory.map { PathUtilities.normalize($0.path) }
    }

    /// Locates leftovers for one app. `otherApps` are the apps that stay installed.
    func locate(for target: UninstallerAppIdentity, otherApps: [UninstallerAppIdentity]) -> UninstallerLocateResult {
        locate(for: [target], otherApps: otherApps).first ?? UninstallerLocateResult()
    }

    /// Locates leftovers for several apps, listing each Library folder once.
    func locate(for targets: [UninstallerAppIdentity], otherApps: [UninstallerAppIdentity]) -> [UninstallerLocateResult] {
        let listing = DirectoryListingCache()
        return targets.map { target in
            var scan = LocatorScan(target: target, others: otherApps.filter { $0.path != target.path }, listing: listing)
            scan.run(homeLibrary: homeLibrary, systemLibrary: systemLibrary, receiptsDirectory: receiptsDirectory)
            return scan.result
        }
    }
}

/// Lists directories once per locate call.
private final class DirectoryListingCache {
    private var entries: [String: [FileRecord]] = [:]
    private let scanner = FileSystemScanner()

    func children(of directory: String) -> [FileRecord] {
        if let cached = entries[directory] { return cached }
        let listed = ((try? scanner.children(of: directory, includeHidden: false)) ?? [])
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        entries[directory] = listed
        return listed
    }
}

private struct LocatorScan {
    enum IdentifierVerdict {
        case target(id: String, isHelper: Bool, sharedWith: String?)
        case other(String)
        case none
    }

    enum NameVerdict {
        case target(String)
        case shared(String)
        case none
    }

    let target: UninstallerAppIdentity
    let others: [UninstallerAppIdentity]
    let listing: DirectoryListingCache

    private(set) var result = UninstallerLocateResult()
    private var leftovers: [String: UninstallerLeftover] = [:]
    private var excluded: [String: UninstallerExcludedItem] = [:]
    private var referencedHelperTools = Set<String>()
    private var matchedDaemonLabels: [String] = []

    // Precomputed lookups (lowercased).
    private let targetIDs: [(id: String, isHelper: Bool)]
    private let targetJobLabels: [String]
    private let otherIDs: [(id: String, app: String)]
    private let otherNames: [String: String]
    private let otherVendorApps: [String: [String]]
    private let otherNestedNames: [String: String]
    private let otherGroups: [String: String]
    private let otherExecutables: Set<String>

    init(target: UninstallerAppIdentity, others: [UninstallerAppIdentity], listing: DirectoryListingCache) {
        self.target = target
        self.others = others
        self.listing = listing

        var ids: [(String, Bool)] = []
        if let bundle = target.bundleIdentifier, !bundle.isEmpty { ids.append((bundle.lowercased(), false)) }
        ids += target.helperIdentifiers.filter { !$0.isEmpty }.map { ($0.lowercased(), true) }
        targetIDs = ids
        targetJobLabels = target.embeddedJobLabels.map { $0.lowercased() }

        var otherIDs: [(String, String)] = []
        var names: [String: String] = [:]
        var vendors: [String: [String]] = [:]
        var nested: [String: String] = [:]
        var groups: [String: String] = [:]
        var executables = Set<String>()
        for app in others {
            let label = app.names.first ?? app.bundleIdentifier ?? (app.path as NSString).lastPathComponent
            for id in app.ownIdentifiers + app.embeddedJobLabels { otherIDs.append((id.lowercased(), label)) }
            for name in app.names { names[UninstallerIdentifierRules.normalizedName(name)] = names[UninstallerIdentifierRules.normalizedName(name)] ?? label }
            for word in app.vendorWords { vendors[word, default: []].append(label) }
            for name in LocatorScan.nestedNames(of: app) { nested[name] = nested[name] ?? label }
            for group in app.applicationGroups { groups[group.lowercased()] = groups[group.lowercased()] ?? label }
            if let executable = app.executableName { executables.insert(executable.lowercased()) }
        }
        self.otherIDs = otherIDs
        self.otherNames = names
        self.otherVendorApps = vendors
        self.otherNestedNames = nested
        self.otherGroups = groups
        self.otherExecutables = executables
    }

    // MARK: Run

    mutating func run(homeLibrary: String, systemLibrary: String?, receiptsDirectory: String?) {
        let user = homeLibrary
        scanGeneral(user + "/Application Support", kind: .applicationSupport, systemWide: false, allowNames: true, allowVendorFolders: true)
        scanGeneral(user + "/Caches", kind: .caches, systemWide: false, allowNames: true, allowVendorFolders: true)
        scanPreferences(user + "/Preferences", systemWide: false)
        scanPreferences(user + "/Preferences/ByHost", systemWide: false)
        scanIdentifierEntries(user + "/Containers", kind: .containers, protected: true)
        scanGroupEntries(user + "/Group Containers", kind: .groupContainers, protected: true)
        scanGroupEntries(user + "/Application Scripts", kind: .applicationScripts, protected: false)
        scanGeneral(user + "/Logs", kind: .logs, systemWide: false, allowNames: true, allowVendorFolders: false)
        scanCrashReports(user + "/Logs/DiagnosticReports")
        scanSuffixed(user + "/Saved Application State", kind: .savedState, suffix: ".savedState")
        scanSuffixed(user + "/HTTPStorages", kind: .webData, suffix: ".binarycookies", allowPlainName: true)
        scanIdentifierEntries(user + "/WebKit", kind: .webData, protected: false)
        scanSuffixed(user + "/Cookies", kind: .webData, suffix: ".binarycookies")
        scanLaunchJobs(user + "/LaunchAgents", kind: .launchAgents, systemWide: false)
        scanRecentDocuments(user + "/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments")

        if let system = systemLibrary {
            scanGeneral(system + "/Application Support", kind: .applicationSupport, systemWide: true, allowNames: true, allowVendorFolders: true)
            scanGeneral(system + "/Caches", kind: .caches, systemWide: true, allowNames: true, allowVendorFolders: false)
            scanPreferences(system + "/Preferences", systemWide: true)
            scanLaunchJobs(system + "/LaunchAgents", kind: .launchAgents, systemWide: true)
            scanLaunchJobs(system + "/LaunchDaemons", kind: .launchDaemons, systemWide: true)
            scanPrivilegedHelpers(system + "/PrivilegedHelperTools")
        }
        if let receiptsDirectory { scanReceipts(receiptsDirectory) }

        result.leftovers = leftovers.values.sorted { lhs, rhs in
            lhs.kind != rhs.kind ? lhs.kind < rhs.kind : lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
        result.excluded = excluded.values.filter { leftovers[$0.path] == nil }.sorted { $0.path < $1.path }
    }

    // MARK: Verdicts

    func identifierVerdict(_ candidate: String, extraTargetIDs: [String] = []) -> IdentifierVerdict {
        let key = candidate.lowercased()
        var best: (id: String, isHelper: Bool)?
        for entry in targetIDs + extraTargetIDs.map({ ($0, true) }) where key == entry.id || key.hasPrefix(entry.id + ".") {
            if entry.id.count > (best?.id.count ?? 0) { best = entry }
        }
        guard let best else { return .none }
        var bestOther: (id: String, app: String)?
        for entry in otherIDs where key == entry.id || key.hasPrefix(entry.id + ".") {
            if entry.id.count > (bestOther?.id.count ?? 0) { bestOther = entry }
        }
        // A more specific (or identical, e.g. a second copy of the app) identifier of another app wins.
        if let bestOther, bestOther.id.count >= best.id.count { return .other(bestOther.app) }
        let shared = otherIDs.first { $0.id.hasPrefix(best.id + ".") }?.app
        return .target(id: best.id, isHelper: best.isHelper, sharedWith: shared)
    }

    func nameVerdict(_ entryName: String) -> NameVerdict {
        let key = UninstallerIdentifierRules.normalizedName(entryName)
        guard let name = target.names.first(where: { UninstallerIdentifierRules.normalizedName($0) == key }),
              UninstallerIdentifierRules.isUsableName(name) else { return .none }
        if let other = otherNames[key] { return .shared("Another installed app, \(other), has the same name.") }
        if target.vendorWords.contains(key), let other = otherVendorApps[key]?.first {
            return .shared("Shared by apps from the same developer, such as \(other).")
        }
        return .target(name)
    }

    /// The app's names, also without a leading vendor word ("Google Chrome" → "Chrome").
    static func nestedNames(of app: UninstallerAppIdentity) -> [String] {
        var names = Set(app.names.map(UninstallerIdentifierRules.normalizedName))
        for name in app.names {
            let lowered = UninstallerIdentifierRules.normalizedName(name)
            for vendor in app.vendorWords where lowered.hasPrefix(vendor + " ") {
                names.insert(String(lowered.dropFirst(vendor.count + 1)))
            }
        }
        return names.filter(UninstallerIdentifierRules.isUsableName)
    }

    // MARK: Collection

    private mutating func add(
        _ record: FileRecord,
        kind: UninstallerLeftoverKind,
        reason: UninstallerMatchReason,
        safety: CleanupSafety,
        systemWide: Bool,
        protected: Bool = false,
        label: String? = nil,
        note: String? = nil
    ) {
        let leftover = UninstallerLeftover(
            path: record.path, kind: kind, reason: reason, safety: safety, isSystemWide: systemWide,
            isProtectedAppData: protected, launchLabel: label, usage: nil, snapshot: record.snapshot,
            modificationDate: record.modificationDate, note: note
        )
        if let existing = leftovers[record.path], existing.safety <= safety { return }
        leftovers[record.path] = leftover
    }

    private mutating func exclude(_ path: String, kind: UninstallerLeftoverKind, reason: String) {
        if excluded[path] == nil { excluded[path] = UninstallerExcludedItem(path: path, kind: kind, reason: reason) }
    }

    /// Adds an identifier match, or records why it was excluded. Returns true if the entry was handled.
    @discardableResult
    private mutating func applyIdentifier(_ identifier: String, record: FileRecord, kind: UninstallerLeftoverKind, systemWide: Bool, protected: Bool = false) -> Bool {
        switch identifierVerdict(identifier) {
        case .target(let id, let isHelper, let sharedWith):
            let reason: UninstallerMatchReason = isHelper ? .helperIdentifier(id) : .bundleIdentifier(target.bundleIdentifier ?? id)
            // An exact match is the app's own item even when another app's identifier extends it
            // (for example web-app shims "com.google.Chrome.app.…" next to Chrome).
            if let sharedWith, identifier.lowercased() != id {
                add(record, kind: kind, reason: reason, safety: .review, systemWide: systemWide, protected: protected,
                    note: "\(sharedWith) uses a related identifier, so check that this isn't shared.")
            } else {
                add(record, kind: kind, reason: reason, safety: .safe, systemWide: systemWide, protected: protected)
            }
            return true
        case .other(let app):
            if targetIDs.contains(where: { UninstallerIdentifierRules.matches(identifier, identifier: $0.id) }) {
                exclude(record.path, kind: kind, reason: "Belongs to \(app), which stays installed.")
            }
            return true
        case .none:
            return false
        }
    }

    // MARK: Folder rules

    /// Application Support, Caches, Logs: identifier names, app names and vendor folders.
    private mutating func scanGeneral(_ root: String, kind: UninstallerLeftoverKind, systemWide: Bool, allowNames: Bool, allowVendorFolders: Bool) {
        for record in listing.children(of: root) {
            if applyIdentifier(record.name, record: record, kind: kind, systemWide: systemWide) { continue }
            guard allowNames else { continue }
            switch nameVerdict(record.name) {
            case .target(let name):
                add(record, kind: kind, reason: .appName(name), safety: .review, systemWide: systemWide)
                continue
            case .shared(let reason):
                exclude(record.path, kind: kind, reason: reason)
            case .none:
                break
            }
            let key = UninstallerIdentifierRules.normalizedName(record.name)
            if allowVendorFolders, record.type == .directory, target.vendorWords.contains(key) {
                scanVendorFolder(record, kind: kind, systemWide: systemWide)
            }
        }
    }

    /// Inside a vendor folder ("Google"), only a sub-folder named after the app ("Chrome") is considered.
    private mutating func scanVendorFolder(_ folder: FileRecord, kind: UninstallerLeftoverKind, systemWide: Bool) {
        let ownNames = Set(LocatorScan.nestedNames(of: target))
        guard !ownNames.isEmpty else { return }
        for child in listing.children(of: folder.path) {
            let key = UninstallerIdentifierRules.normalizedName(child.name)
            guard ownNames.contains(key) else { continue }
            if let other = otherNestedNames[key] ?? otherNames[key] {
                exclude(child.path, kind: kind, reason: "Another installed app, \(other), uses the same name.")
                continue
            }
            add(child, kind: kind, reason: .vendorFolder(vendor: folder.name, name: child.name), safety: .review, systemWide: systemWide)
        }
    }

    private mutating func scanPreferences(_ root: String, systemWide: Bool) {
        let isByHost = root.hasSuffix("/ByHost")
        for record in listing.children(of: root) {
            if record.type == .directory {
                if applyIdentifier(record.name, record: record, kind: .preferences, systemWide: systemWide) { continue }
                if case .target(let name) = nameVerdict(record.name) {
                    add(record, kind: .preferences, reason: .appName(name), safety: .review, systemWide: systemWide)
                }
                continue
            }
            var domain = record.name
            for suffix in [".plist.lockfile", ".plist"] where domain.hasSuffix(suffix) {
                domain = String(domain.dropLast(suffix.count))
                break
            }
            guard domain != record.name || record.name.hasSuffix(".plist") else { continue }
            if isByHost { domain = UninstallerIdentifierRules.strippingHostSuffix(domain) }
            applyIdentifier(domain, record: record, kind: .preferences, systemWide: systemWide)
        }
    }

    private mutating func scanIdentifierEntries(_ root: String, kind: UninstallerLeftoverKind, protected: Bool) {
        for record in listing.children(of: root) where record.type == .directory {
            applyIdentifier(record.name, record: record, kind: kind, systemWide: false, protected: protected)
        }
    }

    private mutating func scanSuffixed(_ root: String, kind: UninstallerLeftoverKind, suffix: String, allowPlainName: Bool = false) {
        for record in listing.children(of: root) {
            let identifier: String
            if record.name.hasSuffix(suffix) {
                identifier = String(record.name.dropLast(suffix.count))
            } else if allowPlainName {
                identifier = record.name
            } else {
                continue
            }
            applyIdentifier(identifier, record: record, kind: kind, systemWide: false)
        }
    }

    private mutating func scanRecentDocuments(_ root: String) {
        for record in listing.children(of: root) where record.type == .regular {
            let ext = (record.name as NSString).pathExtension.lowercased()
            guard ext.hasPrefix("sfl") else { continue }
            applyIdentifier((record.name as NSString).deletingPathExtension, record: record, kind: .recentDocuments, systemWide: false)
        }
    }

    /// Group Containers and Application Scripts: app-group identifiers.
    private mutating func scanGroupEntries(_ root: String, kind: UninstallerLeftoverKind, protected: Bool) {
        for record in listing.children(of: root) where record.type == .directory {
            let name = record.name
            if UninstallerIdentifierRules.isAppleIdentifier(name) { continue }
            let lowered = name.lowercased()

            // Plain bundle identifiers (Application Scripts of extensions).
            if kind == .applicationScripts, applyIdentifier(name, record: record, kind: kind, systemWide: false, protected: protected) { continue }

            let parsed = UninstallerIdentifierRules.parseGroupIdentifier(name)
            let declaredByTarget = target.applicationGroups.contains { $0.lowercased() == lowered }
            let verdict = identifierVerdict(parsed.identifier)
            let namedAfterTarget: Bool
            switch verdict {
            case .target: namedAfterTarget = true
            case .other(let app):
                if declaredByTarget || targetIDs.contains(where: { UninstallerIdentifierRules.matches(parsed.identifier, identifier: $0.id) }) {
                    exclude(record.path, kind: kind, reason: "Belongs to \(app), which stays installed.")
                }
                continue
            case .none: namedAfterTarget = false
            }
            guard namedAfterTarget || declaredByTarget || isVendorGroup(parsed) else { continue }

            if let other = otherGroups[lowered] {
                exclude(record.path, kind: kind, reason: "Also used by \(other), which stays installed.")
                continue
            }
            // Apps from the same team can share groups. If their entitlements are unknown, be careful.
            let sameTeam = others.filter { parsed.team != nil && $0.teamIdentifier == parsed.team }
            let reason = UninstallerMatchReason.appGroup(name)

            if namedAfterTarget {
                if case .target(let id, _, let sharedWith?) = verdict, parsed.identifier.lowercased() != id {
                    add(record, kind: kind, reason: reason, safety: .review, systemWide: false, protected: protected,
                        note: "\(sharedWith) uses a related identifier, so check that this isn't shared.")
                } else if let unknown = sameTeam.first(where: { !$0.entitlementsKnown }) {
                    add(record, kind: kind, reason: reason, safety: .review, systemWide: false, protected: protected,
                        note: "\(unknown.names.first ?? "Another app") is from the same developer and might share it.")
                } else {
                    add(record, kind: kind, reason: reason, safety: .safe, systemWide: false, protected: protected)
                }
            } else if let other = sameTeam.first, !declaredByTarget || !other.entitlementsKnown {
                exclude(record.path, kind: kind, reason: "Probably shared with \(other.names.first ?? "another app") from the same developer.")
            } else {
                add(record, kind: kind, reason: reason, safety: .review, systemWide: false, protected: protected,
                    note: declaredByTarget ? "Declared by the app, but not named after it." : "A developer-wide group for this app's team.")
            }
        }
    }

    /// "TEAMID.com.vendor" for an app "com.vendor.app" signed by TEAMID.
    private func isVendorGroup(_ parsed: (team: String?, identifier: String)) -> Bool {
        guard let team = parsed.team, team == target.teamIdentifier, let bundle = target.bundleIdentifier?.lowercased() else { return false }
        let prefix = parsed.identifier.lowercased()
        return prefix.split(separator: ".").count >= 2 && bundle.hasPrefix(prefix + ".")
    }

    private mutating func scanLaunchJobs(_ root: String, kind: UninstallerLeftoverKind, systemWide: Bool) {
        // Job files may be symbolic links into the app bundle; the link itself is the leftover.
        for record in listing.children(of: root) where (record.type == .regular || record.type == .symlink) && record.name.hasSuffix(".plist") {
            guard let plist = UninstallerInventory.plistDictionary(at: record.path) else { continue }
            let stem = String(record.name.dropLast(".plist".count))
            let label = (plist["Label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? stem
            var programs: [String] = []
            if let program = plist["Program"] as? String { programs.append(program) }
            programs += plist["ProgramArguments"] as? [String] ?? []
            if let bundleProgram = plist["BundleProgram"] as? String { programs.append(bundleProgram) }
            let paths = programs.filter { $0.hasPrefix("/") }.map(PathUtilities.normalize)
            var associated = plist["AssociatedBundleIdentifiers"] as? [String] ?? []
            if let single = plist["AssociatedBundleIdentifiers"] as? String { associated.append(single) }

            let labelVerdict = identifierVerdict(label, extraTargetIDs: targetJobLabels)
            let stemVerdict = identifierVerdict(stem, extraTargetIDs: targetJobLabels)
            let associatedWithTarget = associated.contains { id in targetIDs.contains { $0.id == id.lowercased() } }
            let runsTarget = paths.contains { PathUtilities.isSameOrDescendant($0, of: target.path) }
            var isTarget = runsTarget || associatedWithTarget
            if case .target = labelVerdict { isTarget = true }
            if case .target = stemVerdict { isTarget = true }
            guard isTarget else { continue }

            var sharedWith: String?
            if case .other(let app) = labelVerdict { sharedWith = app }
            if case .other(let app) = stemVerdict { sharedWith = sharedWith ?? app }
            if sharedWith == nil {
                sharedWith = others.first { other in
                    paths.contains { PathUtilities.isSameOrDescendant($0, of: other.path) }
                        || associated.contains { id in other.ownIdentifiers.contains { $0.caseInsensitiveCompare(id) == .orderedSame } }
                }?.names.first
            }
            if let sharedWith {
                exclude(record.path, kind: kind, reason: "Also starts \(sharedWith), which stays installed.")
                continue
            }
            add(record, kind: kind, reason: .launchJob(label), safety: .safe, systemWide: systemWide, label: label)
            if kind == .launchDaemons {
                matchedDaemonLabels.append(label.lowercased())
                for path in paths where path.hasPrefix("/Library/PrivilegedHelperTools/") || path.contains("/PrivilegedHelperTools/") {
                    referencedHelperTools.insert(path)
                }
            }
        }
    }

    private mutating func scanPrivilegedHelpers(_ root: String) {
        for record in listing.children(of: root) where record.type == .regular || record.type == .symlink {
            if referencedHelperTools.contains(record.path) || referencedHelperTools.contains("/Library/PrivilegedHelperTools/" + record.name) {
                add(record, kind: .privilegedHelpers, reason: .referencedByJob(record.name), safety: .safe, systemWide: true)
                continue
            }
            switch identifierVerdict(record.name, extraTargetIDs: targetJobLabels + matchedDaemonLabels) {
            case .target(let id, _, let sharedWith):
                add(record, kind: .privilegedHelpers, reason: .referencedByJob(id), safety: sharedWith == nil ? .safe : .review, systemWide: true)
            case .other(let app):
                if targetIDs.contains(where: { UninstallerIdentifierRules.matches(record.name, identifier: $0.id) }) {
                    exclude(record.path, kind: .privilegedHelpers, reason: "Belongs to \(app), which stays installed.")
                }
            case .none:
                break
            }
        }
    }

    private mutating func scanCrashReports(_ root: String) {
        guard let executable = target.executableName, UninstallerIdentifierRules.isUsableName(executable),
              !otherExecutables.contains(executable.lowercased()) else { return }
        let extensions: Set<String> = ["ips", "crash", "diag", "spin", "hang"]
        for record in listing.children(of: root) where record.type == .regular {
            guard record.name.hasPrefix(executable + "-") || record.name.hasPrefix(executable + "_"),
                  extensions.contains((record.name as NSString).pathExtension.lowercased()) else { continue }
            add(record, kind: .crashReports, reason: .executableName(executable), safety: .safe, systemWide: false)
        }
    }

    /// Installer receipts are kept by macOS in a protected folder; they're listed for information only.
    private mutating func scanReceipts(_ root: String) {
        guard let bundle = target.bundleIdentifier?.lowercased(), !bundle.isEmpty else { return }
        let components = bundle.split(separator: ".")
        let vendorPrefix = components.count >= 3 ? components.prefix(2).joined(separator: ".") : nil
        let squashedNames = target.names.map(LocatorScan.squash).filter { $0.count >= 4 }
        var packages: [String] = []
        for record in listing.children(of: root) where record.name.hasSuffix(".plist") {
            let package = String(record.name.dropLast(".plist".count))
            let key = package.lowercased()
            if UninstallerIdentifierRules.matches(key, identifier: bundle) {
                packages.append(package)
            } else if let vendorPrefix, key.hasPrefix(vendorPrefix + "."), squashedNames.contains(where: { LocatorScan.squash(key).contains($0) }) {
                packages.append(package)
            }
        }
        result.receipts = packages
    }

    private static func squash(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}
