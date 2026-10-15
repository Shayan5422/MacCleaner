import Foundation

/// Disk usage of a file or a set of files.
///
/// Sizes are measured so the same storage is never counted twice inside one
/// measurement: hard links count once, and APFS clones that share blocks count
/// their shared data once per clone family.
struct DiskUsage: Sendable, Hashable, Codable {
    /// Logical length of the data ("size" in Finder).
    var logicalBytes: Int64 = 0
    /// Space allocated on disk ("on disk" in Finder), without double counting.
    var allocatedBytes: Int64 = 0
    /// Conservative estimate of the space freed if every measured file is deleted.
    /// Excludes blocks shared with clones outside the set and hard links that
    /// have other names outside the set.
    var reclaimableBytes: Int64 = 0
    /// Logical bytes of files whose data lives only in the cloud (dataless placeholders).
    var cloudOnlyBytes: Int64 = 0
    var fileCount: Int = 0
    var directoryCount: Int = 0
    /// Directories that could not be read (permissions, privacy protection, I/O errors).
    var unreadableDirectoryCount: Int = 0

    static let zero = DiskUsage()

    /// The size shown to people by default: what the data occupies on disk.
    var displayBytes: Int64 { allocatedBytes }

    var isEmpty: Bool { fileCount == 0 && allocatedBytes == 0 }

    static func + (lhs: DiskUsage, rhs: DiskUsage) -> DiskUsage {
        var sum = lhs
        sum += rhs
        return sum
    }

    static func += (lhs: inout DiskUsage, rhs: DiskUsage) {
        lhs.logicalBytes += rhs.logicalBytes
        lhs.allocatedBytes += rhs.allocatedBytes
        lhs.reclaimableBytes += rhs.reclaimableBytes
        lhs.cloudOnlyBytes += rhs.cloudOnlyBytes
        lhs.fileCount += rhs.fileCount
        lhs.directoryCount += rhs.directoryCount
        lhs.unreadableDirectoryCount += rhs.unreadableDirectoryCount
    }
}

/// Accumulates `DiskUsage` from raw entries while de-duplicating hard links and
/// APFS clones. Thread-safe: walkers on several threads add batches concurrently.
final class UsageAccumulator: @unchecked Sendable {
    private struct CloneKey: Hashable {
        var device: Int32
        var cloneID: UInt64
    }

    private struct CloneFamily {
        var membersSeen: UInt32
        var sharedBytes: Int64
    }

    private let lock = NSLock()
    private var usage = DiskUsage()
    private var hardLinksSeen: [FileIdentity: UInt32] = [:]
    private var cloneFamilies: [CloneKey: CloneFamily] = [:]

    init() {}

    var current: DiskUsage {
        lock.withLock { usage }
    }

    func add(_ entries: [RawDirectoryEntry]) {
        lock.withLock {
            for entry in entries { addLocked(entry) }
        }
    }

    func add(_ entry: RawDirectoryEntry) {
        lock.withLock { addLocked(entry) }
    }

    func addDirectory(unreadable: Bool = false) {
        lock.withLock {
            usage.directoryCount += 1
            if unreadable { usage.unreadableDirectoryCount += 1 }
        }
    }

    /// Records a directory that could not be read without counting it as a scanned directory.
    func addUnreadableDirectory() {
        lock.withLock { usage.unreadableDirectoryCount += 1 }
    }

    private func addLocked(_ entry: RawDirectoryEntry) {
        switch entry.type {
        case .directory:
            usage.directoryCount += 1
            return
        case .symlink, .other:
            // Symlinks and special files occupy no data blocks on APFS.
            usage.fileCount += 1
            return
        case .regular:
            break
        }

        if entry.linkCount > 1 {
            let seen = (hardLinksSeen[entry.identity] ?? 0) + 1
            hardLinksSeen[entry.identity] = seen
            if seen == 1 {
                usage.fileCount += 1
                usage.logicalBytes += entry.logicalSize
                usage.allocatedBytes += entry.allocatedSize
                if entry.isDataless { usage.cloudOnlyBytes += entry.logicalSize }
            }
            // Space is only freed once every name of a hard-linked file is removed.
            if seen == entry.linkCount {
                usage.reclaimableBytes += entry.exclusiveAllocatedSize
            }
            return
        }

        usage.fileCount += 1
        usage.logicalBytes += entry.logicalSize
        if entry.isDataless { usage.cloudOnlyBytes += entry.logicalSize }

        guard entry.mayShareBlocks, let cloneID = entry.cloneID, let privateSize = entry.privateSize else {
            usage.allocatedBytes += entry.allocatedSize
            usage.reclaimableBytes += entry.allocatedSize
            return
        }

        // APFS clone: private blocks always count; shared blocks count once per family.
        let exclusive = min(privateSize, entry.allocatedSize)
        let shared = max(0, entry.allocatedSize - exclusive)
        let key = CloneKey(device: entry.device, cloneID: cloneID)
        var family = cloneFamilies[key] ?? CloneFamily(membersSeen: 0, sharedBytes: shared)
        family.membersSeen += 1
        cloneFamilies[key] = family

        usage.allocatedBytes += exclusive
        usage.reclaimableBytes += exclusive
        if family.membersSeen == 1 {
            usage.allocatedBytes += family.sharedBytes
        }
        // Shared blocks are freed only when the whole family is inside this set.
        if family.membersSeen == entry.cloneReferenceCount {
            usage.reclaimableBytes += family.sharedBytes
        }
    }
}
