import Darwin
import Foundation

/// Where the Antivirus feature keeps its data:
///
/// ```
/// ~/Library/Application Support/Mac Cleaner/Antivirus/
/// ├── clamav/        ClamAV databases (main.cvd, daily.cvd or daily.cld), shared by freshclam and the built-in updater
/// ├── downloads/     abuse.ch feed downloads and files being downloaded or verified
/// ├── engine/        the compiled engine database (AVDatabaseCompiler output)
/// ├── intel/         threat-intelligence indicators and accumulated hash lists
/// ├── quarantine/    the Virus Chest (mode 0700)
/// ├── tmp/           work in progress on the same volume (atomic moves)
/// ├── state.json     versions, dates, ETags and the next allowed download times
/// └── history.json   recent scan summaries
/// ```
///
/// Tests pass a temporary `root`.
struct AVPaths: Sendable, Hashable {
    let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// `~/Library/Application Support/Mac Cleaner/Antivirus`, resolved through `FileManager`.
    static var standard: AVPaths {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return AVPaths(root: support.appendingPathComponent("Mac Cleaner/Antivirus", isDirectory: true))
    }

    var clamav: URL { root.appendingPathComponent("clamav", isDirectory: true) }
    var downloads: URL { root.appendingPathComponent("downloads", isDirectory: true) }
    var engine: URL { root.appendingPathComponent("engine", isDirectory: true) }
    var intel: URL { root.appendingPathComponent("intel", isDirectory: true) }
    var quarantine: URL { root.appendingPathComponent("quarantine", isDirectory: true) }
    var temporary: URL { root.appendingPathComponent("tmp", isDirectory: true) }

    var stateFile: URL { root.appendingPathComponent("state.json") }
    var historyFile: URL { root.appendingPathComponent("history.json") }
    var lastThreatsFile: URL { root.appendingPathComponent("last-threats.json") }
    var shieldLogFile: URL { root.appendingPathComponent("shield-events.json") }
    var freshclamConfig: URL { root.appendingPathComponent("freshclam.conf") }
    var freshclamLog: URL { root.appendingPathComponent("freshclam.log") }
    var updateLock: URL { root.appendingPathComponent(".update.lock") }

    /// Every path the scanners must skip: the Virus Chest and the definitions themselves.
    var rootPath: String { PathUtilities.resolvedPath(root.path) ?? root.path }

    /// Creates the folder layout. The root and the Virus Chest are private to this user (0700).
    func prepare() throws {
        let manager = FileManager.default
        for directory in [root, clamav, downloads, engine, intel, quarantine, temporary] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        chmod(root.path, 0o700)
        chmod(quarantine.path, 0o700)
        chmod(temporary.path, 0o700)
    }

    /// A fresh, empty folder inside `tmp/` (same volume as everything else, so moves are atomic).
    func makeWorkDirectory(_ prefix: String) throws -> URL {
        try prepare()
        let url = temporary.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        chmod(url.path, 0o700)
        return url
    }

    /// Removes leftovers of interrupted work (older than an hour).
    func cleanTemporary(olderThan age: TimeInterval = 3600, now: Date = Date()) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: temporary.path) else { return }
        for name in names {
            let url = temporary.appendingPathComponent(name)
            let modified = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? .distantPast
            if now.timeIntervalSince(modified) > age { try? manager.removeItem(at: url) }
        }
    }

    /// Allocated bytes of a file or folder (bounded walk, for "size on disk").
    static func diskUsage(of url: URL) -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return 0 }
        if (info.st_mode & S_IFMT) != S_IFDIR { return Int64(info.st_blocks) * 512 }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        var count = 0
        while let item = enumerator.nextObject() as? URL, count < 100_000 {
            count += 1
            total += Int64((try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// Atomic JSON files shared by the app and the background agent.
enum AVJSONFile {
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        // Dates keep full precision (ISO 8601 would drop fractions of a second).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// An exclusive, non-blocking lock shared between processes (the app and the background agent),
/// so two updates never write the definitions at the same time.
final class AVProcessLock: @unchecked Sendable {
    private let descriptor: Int32

    /// Returns nil when another process holds the lock.
    init?(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        descriptor = fd
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

/// Atomic file operations inside the Antivirus folder (everything there is on one volume).
enum AVFileOps {
    struct Failure: LocalizedError {
        var operation: String
        var code: Int32
        var errorDescription: String? { "\(operation) failed: \(String(cString: strerror(code)))." }
    }

    /// Moves `source` over `destination`, replacing it atomically (POSIX `rename`).
    static func replace(_ destination: URL, with source: URL) throws {
        guard rename(source.path, destination.path) == 0 else { throw Failure(operation: "Replacing \(destination.lastPathComponent)", code: errno) }
    }

    /// Installs the folder `staged` at `destination`. An existing folder is exchanged atomically
    /// (`RENAME_SWAP`) and returned so it can be deleted, or put back if the new one fails to load.
    static func installDirectory(_ staged: URL, at destination: URL) throws -> URL? {
        var info = stat()
        if lstat(destination.path, &info) != 0 {
            guard rename(staged.path, destination.path) == 0 else { throw Failure(operation: "Installing \(destination.lastPathComponent)", code: errno) }
            return nil
        }
        guard renamex_np(staged.path, destination.path, UInt32(RENAME_SWAP)) == 0 else {
            throw Failure(operation: "Installing \(destination.lastPathComponent)", code: errno)
        }
        return staged // now holds the previous contents
    }

    /// Puts a previous folder back after `installDirectory` (rollback).
    static func restoreDirectory(_ previous: URL, at destination: URL) throws {
        guard renamex_np(previous.path, destination.path, UInt32(RENAME_SWAP)) == 0 else {
            throw Failure(operation: "Restoring \(destination.lastPathComponent)", code: errno)
        }
    }
}
