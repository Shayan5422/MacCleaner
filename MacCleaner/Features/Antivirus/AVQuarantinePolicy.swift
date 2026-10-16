import Darwin
import Foundation

/// Decides what may be moved into the Virus Chest. macOS itself, Mac Cleaner's own files,
/// personal data stores (keychains, Mail, Messages, Photos libraries) and essential folders
/// are always refused. Items owned by root or another user need an administrator; Mac Cleaner
/// explains that instead of asking for elevated privileges.
struct AVQuarantinePolicy: Sendable {
    enum Verdict: Equatable, Sendable {
        case allowed
        case refused(String)
        case needsAdministrator(String)
    }

    var home: String
    var ownBundlePath: String
    var ownDataDirectory: String
    var currentUser: uid_t = getuid()

    static func live() -> AVQuarantinePolicy {
        let home = PathUtilities.resolvedPath(FileManager.default.homeDirectoryForCurrentUser.path) ?? FileManager.default.homeDirectoryForCurrentUser.path
        return AVQuarantinePolicy(home: home, ownBundlePath: Bundle.main.bundlePath, ownDataDirectory: home + "/Library/Application Support/Mac Cleaner")
    }

    private static let essentialPaths: Set<String> = [
        "/", "/Applications", "/Library", "/System", "/Users", "/Volumes", "/private", "/usr", "/bin", "/sbin", "/opt", "/cores",
        "/etc", "/var", "/tmp", "/dev", "/Network", "/Users/Shared", "/private/tmp", "/private/var", "/private/var/folders",
        "/private/var/tmp", "/opt/homebrew", "/usr/local", "/Applications/Utilities",
    ]

    private static let systemSubtrees = [
        "/private/etc", "/private/var/root", "/private/var/protected", "/Library/Keychains", "/Library/Security",
        "/Library/Application Support/com.apple.TCC", "/System/Volumes", "/.vol",
    ]

    private static let homeTopLevel: Set<String> = [
        "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public", "Applications", "Sites",
    ]

    private static let personalStores = [
        "Library/Keychains", "Library/Mail", "Library/Messages", "Library/Accounts", "Library/Calendars", "Library/Photos",
        "Library/Application Support/AddressBook", "Library/Application Support/com.apple.TCC", "Library/Safari",
    ]

    func evaluate(_ rawPath: String) -> Verdict {
        guard rawPath.hasPrefix("/") else { return .refused("Only absolute paths can be moved.") }
        if rawPath.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) {
            return .refused("The path contains relative components.")
        }
        let path = PathUtilities.firmlinkCanonical(PathUtilities.normalize(rawPath))
        let name = (path as NSString).lastPathComponent

        if Self.essentialPaths.contains(path) || path == home || path == (home as NSString).deletingLastPathComponent {
            return .refused("“\(name)” is an essential folder and is never moved.")
        }
        if AVScanScope.isSystemPath(path) || Self.systemSubtrees.contains(where: { PathUtilities.isSameOrDescendant(path, of: $0) }) {
            return .refused("“\(name)” is part of macOS, which protects its own files.")
        }
        if PathUtilities.isSameOrDescendant(path, of: ownBundlePath) || PathUtilities.isSameOrDescendant(path, of: ownDataDirectory) {
            return .refused("This is part of Mac Cleaner itself.")
        }
        let parts = path.split(separator: "/")
        if parts.count == 2 && parts[0] == "Volumes" { return .refused("A drive's top folder is never moved.") }
        if parts.count == 2 && parts[0] == "Library" { return .refused("Top-level Library folders are never moved.") }
        if PathUtilities.isDescendant(path, of: home) {
            let relative = String(path.dropFirst(home.count + 1))
            if Self.homeTopLevel.contains(relative) { return .refused("Your \(relative) folder itself is never moved.") }
            if relative.hasPrefix("Library/"), !relative.dropFirst("Library/".count).contains("/") {
                return .refused("Top-level Library folders are never moved, only items inside them.")
            }
            if Self.personalStores.contains(where: { PathUtilities.isSameOrDescendant(relative, of: $0) }) {
                return .refused("“\(name)” is part of a personal data store managed by macOS. Remove the item through the app that owns it.")
            }
        }
        if path.contains(".photoslibrary/") || path.contains(".musiclibrary/") {
            return .refused("Items inside a Photos or Music library are managed by that app.")
        }

        let parent = (path as NSString).deletingLastPathComponent
        guard let resolvedParent = PathUtilities.resolvedPath(parent) else { return .refused("The enclosing folder no longer exists.") }
        if PathUtilities.firmlinkCanonical(resolvedParent) != parent {
            return .refused("The path goes through a symbolic link, so it wasn't moved.")
        }

        var info = stat()
        guard lstat(path, &info) == 0 else { return .refused("The item no longer exists.") }
        if info.st_flags & (FileFlags.restricted | FileFlags.systemImmutable) != 0 {
            return .refused("macOS protects this item (System Integrity Protection).")
        }
        if info.st_flags & FileFlags.immutable != 0 {
            return .refused("The item is locked. Unlock it in Finder's Get Info window first.")
        }

        var parentInfo = stat()
        guard lstat(parent, &parentInfo) == 0 else { return .refused("The enclosing folder no longer exists.") }
        let owner = Self.userName(info.st_uid)
        let ownedByOther = info.st_uid != currentUser
        let stickyParent = parentInfo.st_mode & S_ISVTX != 0
        let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        if access(parent, W_OK) != 0 || (stickyParent && ownedByOther && parentInfo.st_uid != currentUser) || (isDirectory && ownedByOther && access(path, W_OK) != 0) {
            let who = owner.map { $0 == "root" ? "the system (root)" : "another user (\($0))" } ?? "another user"
            return .needsAdministrator(ownedByOther
                ? "“\(name)” belongs to \(who), so moving it needs an administrator. Reveal it in Finder and move it to the Trash there; Finder asks for your password."
                : "Mac Cleaner can't change the folder that contains “\(name)”. Reveal it in Finder and move it to the Trash there; Finder asks for your password.")
        }
        return .allowed
    }

    static func userName(_ uid: uid_t) -> String? {
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else { return nil }
        return String(cString: name)
    }
}
