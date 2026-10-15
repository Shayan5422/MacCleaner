import Darwin
import Foundation
@testable import MacCleaner

/// A temporary folder for one test, removed (including locked files) when released.
final class DuplicateTestFixture {
    /// Resolved path (no symlinks), like the paths the scanner reports.
    let root: String

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacCleanerDuplicateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = PathUtilities.resolvedPath(base.path) ?? base.path
    }

    deinit {
        // Locked files can't be deleted; unlock everything first. Only touches this fixture's folder.
        if let enumerator = FileManager.default.enumerator(atPath: root) {
            for case let relative as String in enumerator {
                _ = chflags(root + "/" + relative, 0)
            }
        }
        try? FileManager.default.removeItem(atPath: root)
    }

    /// A safety policy that treats the fixture as the home folder, so its files count
    /// as personal files that may be moved to the Trash.
    var policy: SafetyPolicy { SafetyPolicy(home: root) }

    func path(_ relative: String) -> String { root + "/" + relative }

    @discardableResult
    func write(_ relative: String, _ data: Data) throws -> String {
        let path = path(relative)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Creates a hard link to `existing`.
    @discardableResult
    func hardLink(_ existing: String, _ relative: String) throws -> String {
        let path = try preparedPath(relative)
        guard link(existing, path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return path
    }

    /// Creates an APFS clone of `existing`; nil when the volume doesn't support clones.
    func clone(_ existing: String, _ relative: String) -> String? {
        guard let path = try? preparedPath(relative) else { return nil }
        return clonefile(existing, path, 0) == 0 ? path : nil
    }

    /// The absolute path for `relative`, with its parent folder created.
    private func preparedPath(_ relative: String) throws -> String {
        let path = path(relative)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        return path
    }

    func setDates(_ path: String, created: Date, modified: Date? = nil) throws {
        var attributes: [FileAttributeKey: Any] = [.creationDate: created]
        if let modified { attributes[.modificationDate] = modified }
        try FileManager.default.setAttributes(attributes, ofItemAtPath: path)
    }

    func options(minimumSize: Int64 = 1, kinds: DuplicateKindFilter = .all) -> DuplicateScanOptions {
        DuplicateScanOptions(roots: [root], minimumSize: minimumSize, kinds: kinds, includeHiddenFiles: false, exclusions: ExclusionList(), skipDeveloperFolders: true)
    }

    func scan(minimumSize: Int64 = 1, kinds: DuplicateKindFilter = .all) async throws -> DuplicateScanResult {
        try await DuplicateFinder(policy: policy).findDuplicates(options: options(minimumSize: minimumSize, kinds: kinds))
    }

    func target(_ path: String) throws -> DuplicateHashTarget {
        guard let entry = BulkDirectoryReader.readAttributes(path: path) else { throw POSIXError(.ENOENT) }
        return DuplicateHashTarget(path: path, identity: entry.identity, modificationTime: entry.modificationTime)
    }
}

/// Deterministic pseudo-random bytes (SplitMix64), so failures are reproducible.
func duplicateTestData(count: Int, seed: UInt64) -> Data {
    var state = seed &+ 0x9E37_79B9_7F4A_7C15
    var data = Data(count: count)
    data.withUnsafeMutableBytes { buffer in
        for index in 0..<count {
            if index % 8 == 0 {
                state &+= 0x9E37_79B9_7F4A_7C15
                var mixed = state
                mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
                mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
                state = mixed ^ (mixed >> 31)
            }
            buffer[index] = UInt8(truncatingIfNeeded: state >> UInt64((index % 8) * 8))
        }
    }
    return data
}

/// A file description for selection tests, without touching the disk.
func duplicateTestFile(
    _ path: String,
    inode: UInt64,
    created: TimeInterval,
    size: Int64 = 1_000,
    linkCount: UInt32 = 1,
    protectionReason: String? = nil,
    managedLibraryName: String? = nil
) -> DuplicateFile {
    DuplicateFile(
        path: path,
        identity: FileIdentity(device: 1, inode: inode),
        linkCount: linkCount,
        logicalSize: size,
        allocatedSize: size,
        privateSize: nil,
        cloneID: nil,
        cloneReferenceCount: 1,
        mayShareBlocks: false,
        flags: 0,
        modificationDate: Date(timeIntervalSince1970: created),
        creationDate: Date(timeIntervalSince1970: created),
        protectionReason: protectionReason,
        managedLibraryName: managedLibraryName
    )
}
