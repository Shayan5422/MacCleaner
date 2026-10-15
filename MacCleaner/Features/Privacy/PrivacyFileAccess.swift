import Darwin
import Foundation

/// Read-only probes that tell missing items apart from items macOS protects
/// (privacy protection answers `EPERM` instead of pretending the item is missing).
enum PrivacyFileAccess {
    enum Probe: Sendable, Equatable {
        case missing
        case blocked
        case file
        case directory
        case symlink
        case special
    }

    enum Listing: Sendable {
        case entries([FileRecord])
        case missing
        case blocked
    }

    static let sqliteCompanionSuffixes = ["-journal", "-wal", "-shm"]

    static func isPermissionError(_ code: Int32) -> Bool {
        code == EPERM || code == EACCES
    }

    /// Describes `path` without following a final symbolic link.
    static func probe(_ path: String) -> Probe {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return isPermissionError(errno) ? .blocked : .missing
        }
        switch FileObjectType(mode: info.st_mode) {
        case .regular: return .file
        case .directory: return .directory
        case .symlink: return .symlink
        case .other: return .special
        }
    }

    /// Lists a directory's children (no recursion, symbolic links are not followed).
    static func list(_ directory: String) -> Listing {
        do {
            return .entries(try FileSystemScanner().children(of: directory))
        } catch WalkError.cannotOpen(_, let code) {
            return isPermissionError(code) ? .blocked : .missing
        } catch let error as POSIXError {
            return isPermissionError(error.code.rawValue) ? .blocked : .missing
        } catch {
            return .missing
        }
    }

    /// `true` when the folder exists but macOS doesn't let Mac Cleaner list it.
    /// Reads at most one entry.
    static func isBlockedDirectory(_ path: String) -> Bool {
        switch probe(path) {
        case .blocked:
            return true
        case .directory:
            guard let directory = opendir(path) else { return isPermissionError(errno) }
            defer { closedir(directory) }
            errno = 0
            if readdir(directory) == nil { return isPermissionError(errno) }
            return false
        default:
            return false
        }
    }

    /// Allocated size of a single file, or 0.
    static func allocatedSize(of path: String) -> Int64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        return Int64(info.st_blocks) * 512
    }

    /// `path` plus the SQLite companions (journal, WAL, shared memory) that exist.
    /// Companions are always removed together with their database, because a
    /// leftover write-ahead log would be replayed into a new database.
    static func databaseFiles(_ path: String, extraSuffixes: [String] = []) -> [String] {
        ([""] + sqliteCompanionSuffixes + extraSuffixes)
            .map { path + $0 }
            .filter { probe($0) == .file }
    }
}
