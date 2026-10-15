import Darwin
import Foundation
@testable import MacCleaner

/// A temporary folder tree for one test, removed when the test finishes.
/// Paths are fully resolved (`/private/var/...`) so they match what the
/// scanner and the safety policy see on disk.
final class TemporaryTree {
    let root: String

    init(_ name: String = "MacCleanerTests") throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = PathUtilities.resolvedPath(base.path) ?? base.path
    }

    deinit {
        // Clear immutable flags a test may have set, then remove everything.
        if let enumerator = FileManager.default.enumerator(atPath: root) {
            for case let relative as String in enumerator {
                chflags(root + "/" + relative, 0)
            }
        }
        try? FileManager.default.removeItem(atPath: root)
    }

    func path(_ relative: String) -> String {
        relative.isEmpty ? root : root + "/" + relative
    }

    @discardableResult
    func makeDirectory(_ relative: String) throws -> String {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
        return full
    }

    /// Writes `size` bytes of a repeating pattern (incompressible enough for APFS).
    @discardableResult
    func makeFile(_ relative: String, size: Int = 10_000, byte: UInt8 = 0x5A, modified: Date? = nil) throws -> String {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var data = Data(count: size)
        data.withUnsafeMutableBytes { buffer in
            for index in 0..<size { buffer[index] = byte &+ UInt8(truncatingIfNeeded: index % 251) }
        }
        try data.write(to: URL(fileURLWithPath: full))
        if let modified { try setModified(full, modified) }
        return full
    }

    func setModified(_ path: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        var times = [timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0), timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0)]
        _ = utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW)
    }
}

/// A `SafetyPolicy` whose home folder is a temporary tree. The real temporary
/// folders are left out, because the test tree itself lives inside them.
func makePolicy(home: String) -> SafetyPolicy {
    SafetyPolicy(home: home, ownBundlePath: "/Applications/Mac Cleaner.app", userTemporaryDirectory: .some(nil), userCacheDirectory: .some(nil))
}
