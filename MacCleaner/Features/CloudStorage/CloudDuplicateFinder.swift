import CryptoKit
import Darwin
import Foundation

/// Streaming SHA-256 of a file's data that never downloads cloud content.
///
/// The file must be stored locally (not dataless) both before opening and after,
/// and on-demand downloading is turned off for the hashing thread, so if a
/// file is evicted while being read the read fails instead of downloading it.
enum CloudFileHasher {
    enum HashError: LocalizedError {
        case notStoredLocally
        case changed
        case notARegularFile
        case unreadable(Int32)

        var errorDescription: String? {
            switch self {
            case .notStoredLocally: return "The file is stored only in the cloud."
            case .changed: return "The file changed while it was being compared."
            case .notARegularFile: return "Not a regular file."
            case .unreadable(let code): return String(cString: strerror(code))
            }
        }
    }

    static let chunkSize = 1 << 20

    /// Hex SHA-256 of the file's data, or of its first `prefixBytes` bytes.
    /// - Parameters:
    ///   - expected: Identity recorded during the scan; the file must still be the same inode.
    ///   - onBytes: Called with the number of bytes read after each chunk.
    static func sha256(
        path: String,
        expected: FileIdentity? = nil,
        prefixBytes: Int64? = nil,
        isCancelled: () -> Bool = { false },
        onBytes: (Int64) -> Void = { _ in }
    ) throws -> String {
        try CloudDatalessGuard.withoutMaterialization {
            var info = stat()
            guard lstat(path, &info) == 0 else { throw HashError.unreadable(errno) }
            guard FileObjectType(mode: info.st_mode) == .regular else { throw HashError.notARegularFile }
            guard info.st_flags & FileFlags.dataless == 0 else { throw HashError.notStoredLocally }
            if let expected, FileIdentity(device: info.st_dev, inode: UInt64(info.st_ino)) != expected { throw HashError.changed }

            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw HashError.unreadable(errno) }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0 else { throw HashError.unreadable(errno) }
            guard opened.st_ino == info.st_ino, opened.st_dev == info.st_dev else { throw HashError.changed }
            guard opened.st_flags & FileFlags.dataless == 0 else { throw HashError.notStoredLocally }
            _ = fcntl(fd, F_NOCACHE, 1)

            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 16)
            defer { buffer.deallocate() }
            var hasher = SHA256()
            var remaining = prefixBytes ?? Int64.max
            while remaining > 0 {
                if isCancelled() { throw CancellationError() }
                let wanted = Int(min(Int64(chunkSize), remaining))
                let count = read(fd, buffer.baseAddress, wanted)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw HashError.unreadable(errno)
                }
                if count == 0 { break }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
                remaining -= Int64(count)
                onBytes(Int64(count))
            }
            return hex(hasher.finalize())
        }
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        let digits: [Character] = Array("0123456789abcdef")
        var result = ""
        result.reserveCapacity(64)
        for byte in digest {
            result.append(digits[Int(byte >> 4)])
            result.append(digits[Int(byte & 0x0F)])
        }
        return result
    }
}

/// Turns off on-demand downloading of cloud placeholders for the current thread
/// while `body` runs, so reading a dataless file fails instead of downloading it.
enum CloudDatalessGuard {
    static func withoutMaterialization<T>(_ body: () throws -> T) rethrows -> T {
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer {
            if previous >= 0 { setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous) }
        }
        return try body()
    }
}

/// Finds identical files among locally stored cloud files.
///
/// Files are grouped by size, then by a hash of their first 64 KB, and only
/// files that still match are hashed in full. Hard links of the same file are
/// one file, not duplicates. Files stored only in the cloud are never read.
///
/// Reading a file updates its access time on APFS, so comparison only runs
/// when the person asks for it; analysis itself reads metadata only.
struct CloudDuplicateFinder: Sendable {
    var minimumBytes: Int64 = 1_000_000
    static let prefixBytes: Int64 = 64 * 1024

    func findDuplicates(in items: [CloudFileItem], progress: CloudScanProgress? = nil) async throws -> [CloudDuplicateGroup] {
        let minimum = minimumBytes
        let groups = try await BackgroundWork.run(qos: .utility) { () throws -> [CloudDuplicateGroup] in
            try Self.findDuplicatesBlocking(in: items, minimumBytes: minimum, progress: progress)
        }
        return groups
    }

    /// Distinct, locally stored files that share a size: the only possible duplicates.
    /// Uses metadata only — nothing is read.
    static func sameSizeGroups(in items: [CloudFileItem], minimumBytes: Int64) -> [[CloudFileItem]] {
        var bySize: [Int64: [CloudFileItem]] = [:]
        for item in items where !item.isPackage && item.isStoredLocally && item.logicalSize >= minimumBytes {
            bySize[item.logicalSize, default: []].append(item)
        }
        return bySize.values.compactMap { group -> [CloudFileItem]? in
            var seen = Set<FileIdentity>()
            let distinct = group.filter { seen.insert($0.identity).inserted }
            return distinct.count > 1 ? distinct : nil
        }
    }

    static func findDuplicatesBlocking(in items: [CloudFileItem], minimumBytes: Int64, progress: CloudScanProgress?) throws -> [CloudDuplicateGroup] {
        let isCancelled = { progress?.isCancelled ?? false }
        let sizeGroups = sameSizeGroups(in: items, minimumBytes: minimumBytes)
        let prefixTotal = sizeGroups.reduce(Int64(0)) { $0 + Int64($1.count) * min(prefixBytes, $1[0].logicalSize) }
        progress?.update {
            $0.bytesToCompare = prefixTotal
            $0.bytesCompared = 0
        }

        // Stage 1: hash the first 64 KB.
        var prefixGroups: [[CloudFileItem]] = []
        for group in sizeGroups {
            if isCancelled() { throw CancellationError() }
            var byPrefix: [String: [CloudFileItem]] = [:]
            for item in group {
                guard let digest = try? CloudFileHasher.sha256(
                    path: item.path, expected: item.identity, prefixBytes: prefixBytes, isCancelled: isCancelled,
                    onBytes: { bytes in progress?.update { $0.bytesCompared += bytes } }
                ) else { continue }
                byPrefix[digest, default: []].append(item)
            }
            prefixGroups += byPrefix.values.filter { $0.count > 1 }
        }
        if isCancelled() { throw CancellationError() }

        // Stage 2: full hashes of the remaining candidates.
        let fullTotal = prefixGroups.reduce(Int64(0)) { $0 + Int64($1.count) * $1[0].logicalSize }
        progress?.update {
            $0.bytesToCompare = fullTotal
            $0.bytesCompared = 0
        }
        var result: [CloudDuplicateGroup] = []
        for group in prefixGroups {
            if isCancelled() { throw CancellationError() }
            var byDigest: [String: [CloudFileItem]] = [:]
            for item in group {
                guard let digest = try? CloudFileHasher.sha256(
                    path: item.path, expected: item.identity, isCancelled: isCancelled,
                    onBytes: { bytes in progress?.update { $0.bytesCompared += bytes } }
                ) else { continue }
                byDigest[digest, default: []].append(item)
            }
            for (digest, matches) in byDigest where matches.count > 1 {
                result.append(CloudDuplicateGroup(
                    digest: digest, size: matches[0].logicalSize,
                    items: matches.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                ))
            }
        }
        if isCancelled() { throw CancellationError() }
        return result.sorted { $0.redundantLocalBytes > $1.redundantLocalBytes }
    }
}
