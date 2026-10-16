import Darwin
import Foundation

/// Code-signature checks remembered by file identity, so repeating a startup check every few
/// minutes doesn't re-verify programs that haven't changed. An app update replaces or re-signs
/// the files, which changes the identity and triggers a fresh check.
final class GuardianSignatureCache: @unchecked Sendable {
    private struct Entry {
        var identity: [Int64]
        var summary: GuardianSignatureSummary
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let evaluate: @Sendable (String) -> GuardianSignatureSummary

    init(evaluate: @escaping @Sendable (String) -> GuardianSignatureSummary = { GuardianSignatureSummary(SecurityCodeTrust.evaluate(path: $0)) }) {
        self.evaluate = evaluate
    }

    /// The signature of `path` (blocking; call off the main thread).
    func summary(for path: String) -> GuardianSignatureSummary {
        let identity = Self.identity(of: path)
        if let cached = lock.withLock({ entries[path] }), cached.identity == identity { return cached.summary }
        let summary = evaluate(path)
        lock.withLock {
            entries[path] = Entry(identity: identity, summary: summary)
            if entries.count > 4_000 { entries.removeAll(keepingCapacity: true) }
        }
        return summary
    }

    /// Device, inode, size and change times of the file, plus the parts of a bundle that change when it's re-signed.
    static func identity(of path: String) -> [Int64] {
        var parts: [Int64] = []
        func add(_ candidate: String) {
            var info = stat()
            guard stat(candidate, &info) == 0 else {
                parts.append(-1)
                return
            }
            parts.append(Int64(info.st_dev))
            parts.append(Int64(bitPattern: UInt64(info.st_ino)))
            parts.append(Int64(info.st_size))
            parts.append(Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec))
            parts.append(Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec))
        }
        add(path)
        let lowered = path.lowercased()
        if lowered.hasSuffix(".app") || lowered.hasSuffix(".appex") || lowered.hasSuffix(".bundle")
            || lowered.hasSuffix(".mdimporter") || lowered.hasSuffix(".qlgenerator") || lowered.hasSuffix(".plugin") {
            add(path + "/Contents/_CodeSignature/CodeResources")
            add(path + "/Contents/Info.plist")
        }
        return parts
    }
}
