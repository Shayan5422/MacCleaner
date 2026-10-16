import Darwin
import Foundation

/// Mac Cleaner's own working folders (the antivirus' `tmp`, the Virus Chest, Guardian's scratch
/// folder...). Another process running as the same user could replace one of them with a symbolic
/// link to, say, `~/Documents`; following that link would make Mac Cleaner, which may hold Full
/// Disk Access, change or delete what's behind it. These helpers never follow a link.
enum SecureDirectory {
    enum Failure: LocalizedError, Equatable {
        /// Something other than a folder (a file, a socket...) is in the way.
        case notADirectory(String)
        /// The folder belongs to another user.
        case wrongOwner(String)
        case cannotCreate(String, Int32)

        var errorDescription: String? {
            switch self {
            case .notADirectory(let path): return "\(PathUtilities.abbreviate(path)) isn't a folder."
            case .wrongOwner(let path): return "\(PathUtilities.abbreviate(path)) belongs to another user."
            case .cannotCreate(let path, let code): return "Couldn't create \(PathUtilities.abbreviate(path)): \(String(cString: strerror(code)))."
            }
        }
    }

    /// Makes sure `url` is a real folder owned by this user with `mode`. A symbolic link in its
    /// place is removed (only the link, never what it points to) and replaced by a new folder.
    /// Missing parent folders are created the same way.
    static func ensure(_ url: URL, mode: mode_t = 0o755) throws {
        let path = url.path
        var info = stat()
        if lstat(path, &info) == 0 {
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                guard info.st_uid == getuid() else { throw Failure.wrongOwner(path) }
            case S_IFLNK:
                guard unlink(path) == 0 else { throw Failure.cannotCreate(path, errno) }
                try create(path, mode: mode)
            default:
                throw Failure.notADirectory(path)
            }
        } else {
            let parent = (path as NSString).deletingLastPathComponent
            if parent != path, !parent.isEmpty, parent != "/" {
                var parentInfo = stat()
                if lstat(parent, &parentInfo) != 0 { try ensure(URL(fileURLWithPath: parent, isDirectory: true)) }
            }
            try create(path, mode: mode)
        }
        // Set the mode on the folder itself, through a descriptor that refuses links.
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.notADirectory(path) }
        defer { close(fd) }
        fchmod(fd, mode)
    }

    /// Creates one folder and checks that what's there now is a real folder (a link could have raced in).
    private static func create(_ path: String, mode: mode_t) throws {
        if mkdir(path, mode) != 0 && errno != EEXIST { throw Failure.cannotCreate(path, errno) }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Failure.notADirectory(path) }
    }

    /// Removes the entries of `url` (older than `age`, when given) without following links: a
    /// folder replaced by a link is left alone, and links inside it are removed, never followed.
    static func removeContents(of url: URL, olderThan age: TimeInterval? = nil, now: Date = Date()) {
        let path = url.path
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { return }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
        for name in names {
            let child = path + "/" + name
            if let age {
                var childInfo = stat()
                guard lstat(child, &childInfo) == 0 else { continue }
                let modified = Date(timeIntervalSince1970: TimeInterval(childInfo.st_mtimespec.tv_sec))
                guard now.timeIntervalSince(modified) > age else { continue }
            }
            // SafeRemover opens the parent with O_NOFOLLOW_ANY, so if the folder was swapped for a
            // link after the check above, nothing is removed.
            _ = try? SafeRemover.remove(path: child, expected: nil)
        }
    }
}
