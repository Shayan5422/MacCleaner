import Darwin
import Foundation

/// Why an item is being removed. Each purpose is allowed in different places.
enum DeletionPurpose: String, Sendable, Codable, CaseIterable {
    /// Whether items of this kind may ever be deleted without going to the Trash.
    /// Personal files, apps and app settings always go to the Trash so they can be recovered.
    var allowsPermanentDeletion: Bool {
        switch self {
        case .junk, .developerData, .privacyData: return true
        case .userFile, .application, .applicationData: return false
        }
    }

    /// Regenerable caches, logs and temporary files.
    case junk
    /// A person's own files (large files, duplicates, downloads).
    case userFile
    /// An application bundle.
    case application
    /// Preferences, caches and support files that belong to an application.
    case applicationData
    /// Browser caches, history and website data.
    case privacyData
    /// Developer tool caches and build products.
    case developerData
}

/// The result of checking whether a path may be removed.
enum SafetyVerdict: Sendable, Equatable {
    case allowed
    case denied(String)

    var isAllowed: Bool { self == .allowed }

    var reason: String? {
        if case .denied(let reason) = self { return reason }
        return nil
    }
}

/// Decides what Mac Cleaner may ever remove.
///
/// The policy is an allow-list per `DeletionPurpose` combined with a global
/// deny-list. It is evaluated right before every removal, after the item has
/// been re-identified, so a scan result can never cause deletion outside the
/// expected locations. Credentials, keychains, bookmarks, mail, messages,
/// cloud-synced folders and macOS itself are always refused.
struct SafetyPolicy: Sendable {
    let home: String
    let userTemporaryDirectory: String?
    let userCacheDirectory: String?
    let ownBundlePath: String
    let ownSupportDirectory: String

    static let current = SafetyPolicy()

    init(
        home: String = PathUtilities.resolvedPath(FileManager.default.homeDirectoryForCurrentUser.path)
            ?? FileManager.default.homeDirectoryForCurrentUser.path,
        ownBundlePath: String = Bundle.main.bundlePath,
        userTemporaryDirectory: String?? = .none,
        userCacheDirectory: String?? = .none
    ) {
        self.home = home
        self.userTemporaryDirectory = userTemporaryDirectory ?? SafetyPolicy.confstrPath(_CS_DARWIN_USER_TEMP_DIR)
        self.userCacheDirectory = userCacheDirectory ?? SafetyPolicy.confstrPath(_CS_DARWIN_USER_CACHE_DIR)
        self.ownBundlePath = ownBundlePath
        self.ownSupportDirectory = home + "/Library/Application Support/Mac Cleaner"
    }

    // MARK: - Evaluation

    /// Checks `path` (an absolute path without symlinked ancestors) for `purpose`.
    func evaluate(path rawPath: String, purpose: DeletionPurpose) -> SafetyVerdict {
        guard rawPath.hasPrefix("/") else { return .denied("Only absolute paths can be removed.") }
        let components = rawPath.split(separator: "/", omittingEmptySubsequences: false)
        if components.contains(where: { $0 == ".." || $0 == "." }) {
            return .denied("The path contains relative components.")
        }
        let path = PathUtilities.firmlinkCanonical(PathUtilities.normalize(rawPath))
        guard path.count > 1 else { return .denied("The root folder can never be removed.") }

        // No symbolic links anywhere above the item (the item itself may be a link; the link is removed, never its target).
        let parent = (path as NSString).deletingLastPathComponent
        guard let resolvedParent = PathUtilities.resolvedPath(parent) else {
            return .denied("The enclosing folder no longer exists.")
        }
        if PathUtilities.firmlinkCanonical(resolvedParent) != parent {
            return .denied("The path goes through a symbolic link, so it was not removed.")
        }

        var info = stat()
        guard lstat(path, &info) == 0 else { return .denied("The item no longer exists.") }
        if info.st_flags & (FileFlags.restricted | FileFlags.systemImmutable) != 0 {
            return .denied("The item is protected by macOS (System Integrity Protection).")
        }
        if info.st_flags & FileFlags.immutable != 0 {
            return .denied("The item is locked. Unlock it in Finder's Get Info window first.")
        }

        if let reason = globalDenyReason(path) { return .denied(reason) }

        switch purpose {
        case .junk:
            return evaluateJunk(path, owner: info.st_uid)
        case .userFile:
            return evaluateUserFile(path)
        case .application:
            return evaluateApplication(path)
        case .applicationData:
            return evaluateApplicationData(path)
        case .privacyData:
            return isInside(path, home + "/Library") ? .allowed : .denied("Privacy cleanup only touches files in your Library folder.")
        case .developerData:
            return evaluateDeveloperData(path)
        }
    }

    // MARK: - Global rules

    private static let protectedExactPaths: Set<String> = [
        "/", "/Applications", "/Library", "/System", "/Users", "/Volumes", "/private", "/usr", "/bin",
        "/sbin", "/opt", "/cores", "/etc", "/var", "/tmp", "/dev", "/Network", "/Users/Shared",
        "/private/tmp", "/private/var", "/private/var/folders", "/opt/homebrew", "/usr/local",
    ]

    private static let protectedSubtrees: [String] = [
        "/System", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec", "/usr/share", "/bin", "/sbin",
        "/private/etc", "/private/var/db", "/private/var/root", "/private/var/protected", "/private/var/vm",
        "/Library/Apple", "/Library/Keychains", "/Library/Security", "/Library/Application Support/com.apple.TCC",
        "/Library/Preferences/SystemConfiguration", "/dev", "/.vol", "/.Spotlight-V100", "/.fseventsd",
        "/Library/SystemExtensions", "/Library/Extensions",
    ]

    /// Folders inside the home folder whose contents are personal data or credentials.
    private static let protectedHomeSubtrees: [String] = [
        "Library/Keychains", "Library/Mobile Documents", "Library/CloudStorage", "Library/Mail",
        "Library/Messages", "Library/Photos", "Library/Accounts", "Library/Calendars",
        "Library/Application Support/AddressBook", "Library/Application Support/com.apple.TCC",
        "Library/Application Support/CallHistoryDB", "Library/Application Support/Knowledge",
        "Library/Group Containers/group.com.apple.notes", "Library/Group Containers/group.com.apple.reminders",
        "Library/IdentityServices", "Library/PersonalizationPortrait", "Library/Sharing",
        "Library/Biome", "Library/DuetExpertCenter", "Library/Trial", "Library/Daemon Containers",
        "Library/Autosave Information",
        ".ssh", ".gnupg", ".aws", ".kube", ".docker/contexts", ".config/gh", ".netrc",
        ".Trash",
    ]

    /// File names that hold passwords, keys, payment data or bookmarks. Never removed.
    private static let protectedFileNames: Set<String> = [
        "Login Data", "Login Data-journal", "Login Data For Account", "Login Data For Account-journal",
        "Web Data", "Web Data-journal", "Bookmarks", "Bookmarks.bak", "Bookmarks.plist",
        "logins.json", "logins-backup.json", "key4.db", "key3.db", "cert9.db", "signons.sqlite",
        "places.sqlite", "places.sqlite-wal", "favicons.sqlite", "Local State",
        "Preferences", "Secure Preferences", "login.keychain-db", "metadata.keychain-db",
    ]

    /// Top-level folders in the home folder; their contents may be eligible, the folders themselves never.
    private static let homeTopLevel: Set<String> = [
        "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public",
        "Applications", "Sites", "Developer", "Projects",
    ]

    private func globalDenyReason(_ path: String) -> String? {
        if Self.protectedExactPaths.contains(path) || path == home || path == (home as NSString).deletingLastPathComponent {
            return "This folder is essential and can never be removed."
        }
        for subtree in Self.protectedSubtrees where isSameOrInside(path, subtree) {
            return "Items inside \(subtree) belong to macOS and are never removed."
        }
        if isInside(path, "/Volumes") {
            let parts = path.split(separator: "/")
            if parts.count <= 2 { return "A volume's root folder can never be removed." }
        }
        if isSameOrInside(path, "/System/Volumes") {
            return "Items on macOS system volumes are never removed."
        }
        if isSameOrInside(path, ownBundlePath) || isSameOrInside(path, ownSupportDirectory) {
            return "Mac Cleaner doesn't remove its own files."
        }
        if isInside(path, home) {
            let relative = String(path.dropFirst(home.count + 1))
            if Self.homeTopLevel.contains(relative) {
                return "Your \(relative) folder itself can never be removed."
            }
            if relative.hasPrefix("Library/"), !relative.dropFirst("Library/".count).contains("/") {
                return "Top-level Library folders are never removed, only items inside them."
            }
            for protected in Self.protectedHomeSubtrees where isSameOrInside(relative, protected) {
                return "Items in ~/\(protected) contain personal data or credentials and are never removed."
            }
        }
        let name = (path as NSString).lastPathComponent
        if Self.protectedFileNames.contains(name) {
            return "“\(name)” can contain passwords, bookmarks or keys, so it is never removed."
        }
        let lowercased = name.lowercased()
        if lowercased.hasSuffix(".keychain") || lowercased.hasSuffix(".keychain-db") {
            return "Keychains are never removed."
        }
        if path.contains(".photoslibrary/") || path.contains(".musiclibrary/") || path.contains(".tvlibrary/") {
            return "Items inside a Photos or Music library are managed by that app and never removed individually."
        }
        return nil
    }

    // MARK: - Purpose rules

    private func evaluateJunk(_ path: String, owner: uid_t) -> SafetyVerdict {
        let library = home + "/Library"
        let allowedRoots = [
            library + "/Caches", library + "/Logs", library + "/Saved Application State",
            library + "/Developer", library + "/Application Support/CrashReporter",
            library + "/iTunes/iPhone Software Updates", library + "/iTunes/iPad Software Updates",
            library + "/iTunes/iPod Software Updates",
            library + "/Containers/com.apple.mail/Data/Library/Mail Downloads",
        ] + [userTemporaryDirectory, userCacheDirectory].compactMap { $0 }

        if allowedRoots.contains(where: { isInside(path, $0) }) { return .allowed }

        // App containers: only their cache, log and temporary folders.
        if isInside(path, library + "/Containers") || isInside(path, library + "/Group Containers") {
            let relative = path.dropFirst(library.count)
            let parts = relative.split(separator: "/")
            if parts.count >= 4, parts.contains(where: { ["Caches", "Logs", "tmp"].contains($0) }) {
                return .allowed
            }
            return .denied("Only caches, logs and temporary files inside app containers are cleaned as junk.")
        }
        // Application Support: only well-known cache folders.
        if isInside(path, library + "/Application Support") {
            if PathUtilities.containsCacheComponent(path) { return .allowed }
            return .denied("Only cache folders inside Application Support are cleaned as junk.")
        }
        // Shared temporary folder: only items owned by this user.
        if isInside(path, "/private/tmp") || isInside(path, "/private/var/tmp") {
            return owner == getuid() ? .allowed : .denied("The temporary item belongs to another user.")
        }
        if isInside(path, "/Library/Caches") || isInside(path, "/Library/Logs") {
            return owner == getuid() ? .allowed : .denied("This system-wide item requires administrator privileges.")
        }
        return .denied("This location isn't a cache, log or temporary folder.")
    }

    private func evaluateUserFile(_ path: String) -> SafetyVerdict {
        if isInside(path, home + "/Library") {
            return .denied("Files in your Library folder are cleaned by the dedicated cleanup tools, not as personal files.")
        }
        if isInside(path, home) || isInside(path, "/Users/Shared") { return .allowed }
        if isInside(path, "/Volumes") {
            if path.contains("/Backups.backupdb/") || path.contains(".timemachine") || path.hasSuffix(".backupbundle") {
                return .denied("Time Machine backups must be managed with Time Machine.")
            }
            return .allowed
        }
        return .denied("Personal files can only be removed from your home folder or external volumes.")
    }

    private func evaluateApplication(_ path: String) -> SafetyVerdict {
        guard path.hasSuffix(".app") else { return .denied("Only application bundles can be uninstalled.") }
        if isInside(path, "/System") { return .denied("Apps that are part of macOS can't be removed.") }
        let allowed = isInside(path, "/Applications") || isInside(path, home + "/Applications")
            || isInside(path, home + "/Downloads") || isInside(path, home + "/Desktop")
            || (isInside(path, "/Volumes") && path.split(separator: "/").count > 2)
        guard allowed else { return .denied("Apps are only removed from Applications folders, Downloads, Desktop or external volumes.") }
        if path.dropFirst().contains(".app/") { return .denied("Apps embedded inside another app are removed with their parent app.") }
        return .allowed
    }

    private func evaluateApplicationData(_ path: String) -> SafetyVerdict {
        let libraries = [home + "/Library", "/Library"]
        guard libraries.contains(where: { isInside(path, $0) }) else {
            return .denied("App support files are only removed from Library folders.")
        }
        let relative: Substring
        if isInside(path, home + "/Library") {
            relative = path.dropFirst((home + "/Library/").count)
        } else {
            relative = path.dropFirst("/Library/".count)
        }
        guard relative.contains("/") else {
            return .denied("Top-level Library folders are never removed.")
        }
        let protectedLibrarySubtrees = ["Keychains", "Apple", "Security", "Accounts", "Mail", "Messages"]
        if let first = relative.split(separator: "/").first, protectedLibrarySubtrees.contains(String(first)) {
            return .denied("Items in Library/\(first) are never removed.")
        }
        return .allowed
    }

    private func evaluateDeveloperData(_ path: String) -> SafetyVerdict {
        // Folders that are caches themselves: the folder and anything inside it may be removed.
        let cacheRoots = [
            ".npm", ".gradle/caches", ".gradle/wrapper/dists", ".gradle/daemon", ".m2/repository", ".pnpm-store",
            ".yarn/berry/cache", ".android/cache", ".bun/install/cache",
            "Library/Application Support/Code/Cache", "Library/Application Support/Code/CachedData",
        ].map { home + "/" + $0 }
        if cacheRoots.contains(where: { isSameOrInside(path, $0) }) { return .allowed }
        // Folders that also hold tools or settings: only items inside them.
        let containerRoots = [
            "Library/Developer", "Library/Caches", "Library/Logs", ".cache", "Library/pnpm", ".local/share/pnpm",
            ".cargo/registry", ".cargo/git", "go/pkg/mod", ".cocoapods/repos", ".swiftpm", ".deno",
        ].map { home + "/" + $0 } + [userTemporaryDirectory, userCacheDirectory].compactMap { $0 }
        if containerRoots.contains(where: { isInside(path, $0) }) { return .allowed }
        return .denied("This isn't a known developer cache location.")
    }

    // MARK: - Helpers

    private func isInside(_ path: String, _ ancestor: String) -> Bool {
        PathUtilities.isDescendant(path, of: ancestor)
    }

    private func isSameOrInside(_ path: String, _ ancestor: String) -> Bool {
        PathUtilities.isSameOrDescendant(path, of: ancestor)
    }

    private static func confstrPath(_ name: Int32) -> String? {
        let length = confstr(name, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(name, &buffer, length) > 0 else { return nil }
        let path = String(nulTerminated: buffer)
        return PathUtilities.resolvedPath(path).map(PathUtilities.normalize) ?? PathUtilities.normalize(path)
    }
}

extension PathUtilities {
    /// Folder names that conventionally hold regenerable cache data.
    static let cacheComponentNames: Set<String> = [
        "Cache", "Caches", "cache", "caches", "Code Cache", "GPUCache", "ShaderCache", "GrShaderCache",
        "GraphiteDawnCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "CacheStorage", "CachedData", "Crashpad",
        "component_crx_cache", "extensions_crx_cache", "Service Worker", "blob_storage", "VideoDecodeStats",
        "optimization_guide_model_store", "Media Cache", "media-cache", "logs", "Logs", "crashpad",
        "CachedExtensionVSIXs", "CachedProfilesData", "Partitions",
    ]

    /// `true` if any component below the Library folder is a well-known cache folder name.
    static func containsCacheComponent(_ path: String) -> Bool {
        path.split(separator: "/").contains { cacheComponentNames.contains(String($0)) }
    }

    /// Firmlinked roots of the data volume (see `/usr/share/firmlinks`).
    private static let firmlinkRoots = ["Applications", "Library", "Users", "Volumes", "private", "opt", "cores", "usr/local"]

    /// Maps `/System/Volumes/Data/Users/...` to the canonical `/Users/...` form.
    static func firmlinkCanonical(_ path: String) -> String {
        let dataRoot = "/System/Volumes/Data"
        guard path.hasPrefix(dataRoot + "/") else { return path }
        let remainder = String(path.dropFirst(dataRoot.count))
        for root in firmlinkRoots where isSameOrDescendant(remainder, of: "/" + root) {
            return remainder
        }
        return path
    }
}
