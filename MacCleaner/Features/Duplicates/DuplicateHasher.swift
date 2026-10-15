import CryptoKit
import Darwin
import Foundation

/// A SHA-256 digest stored as four words (cheap to hash and compare).
struct DuplicateDigest: Hashable, Sendable {
    private var word0: UInt64
    private var word1: UInt64
    private var word2: UInt64
    private var word3: UInt64

    init(_ digest: SHA256.Digest) {
        var words: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
        digest.withUnsafeBytes { raw in
            words = (
                raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self),
                raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self),
                raw.loadUnaligned(fromByteOffset: 16, as: UInt64.self),
                raw.loadUnaligned(fromByteOffset: 24, as: UInt64.self)
            )
        }
        (word0, word1, word2, word3) = words
    }

    /// Lowercase hexadecimal, in the usual SHA-256 byte order.
    var hex: String {
        var text = ""
        text.reserveCapacity(64)
        for word in [word0, word1, word2, word3] {
            withUnsafeBytes(of: word) { bytes in
                for byte in bytes {
                    text += String(byte, radix: 16).leftPadded(to: 2)
                }
            }
        }
        return text
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}

/// Why a file couldn't be hashed.
enum DuplicateHashFailure: Error, Sendable, Equatable {
    /// The file was replaced, modified or truncated after it was scanned.
    case changed
    /// The contents are only in the cloud; reading them would download the file.
    case cloudOnly
    /// The data fork is empty (the size came from metadata or a resource fork).
    case empty
    /// A read error (`errno`), for example a permission or I/O error.
    case unreadable(Int32)
}

/// The file as it was seen during the scan. Hashing refuses to read anything else.
struct DuplicateHashTarget: Sendable {
    var path: String
    var identity: FileIdentity
    /// Modification time from the scan (seconds since 1970, as `BulkDirectoryReader` reports it).
    var modificationTime: Double
}

struct DuplicatePartialDigest: Sendable {
    var digest: DuplicateDigest
    /// Length of the data fork that was hashed.
    var dataSize: Int64
    /// The file is small enough that the whole content was hashed.
    var coversWholeFile: Bool
}

struct DuplicateFullDigest: Sendable {
    var digest: DuplicateDigest
    var dataSize: Int64
}

/// Streaming, memory-bounded SHA-256 hashing of files.
///
/// Every file is opened without following symlinks and verified to be the same
/// regular file (device, inode, modification time) that the scan found, and
/// checked again after reading, so a file replaced or edited mid-scan is never
/// reported as a duplicate. Cloud-only files are never read.
enum DuplicateHasher {
    /// Bytes read from each end of a file for the partial hash.
    static let edgeLength = 64 * 1024
    /// Read size for full hashes.
    static let chunkLength = 1024 * 1024
    /// Large files are read without filling the file cache with data that is used once.
    static let noCacheThreshold: Int64 = 16 * 1024 * 1024

    /// SHA-256 of the first and last 64 KiB. Files up to 128 KiB are hashed entirely,
    /// so their partial digest is also their full digest.
    static func partialDigest(of target: DuplicateHashTarget, cancellation: DuplicateCancellation) throws -> DuplicatePartialDigest {
        try cancellation.check()
        return try DuplicateReadPolicy.perform {
            let file = try DuplicateOpenedFile(target: target)
            defer { file.close() }
            let size = file.dataSize
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: edgeLength, alignment: 16_384)
            defer { buffer.deallocate() }
            var hasher = SHA256()

            if size <= Int64(edgeLength * 2) {
                var offset: Int64 = 0
                while offset < size {
                    let count = Int(min(Int64(edgeLength), size - offset))
                    try file.read(into: buffer, count: count, at: offset)
                    hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
                    offset += Int64(count)
                }
                try file.verifyUnchanged()
                return DuplicatePartialDigest(digest: DuplicateDigest(hasher.finalize()), dataSize: size, coversWholeFile: true)
            }

            try file.read(into: buffer, count: edgeLength, at: 0)
            hasher.update(bufferPointer: UnsafeRawBufferPointer(buffer))
            try file.read(into: buffer, count: edgeLength, at: size - Int64(edgeLength))
            hasher.update(bufferPointer: UnsafeRawBufferPointer(buffer))
            try file.verifyUnchanged()
            return DuplicatePartialDigest(digest: DuplicateDigest(hasher.finalize()), dataSize: size, coversWholeFile: false)
        }
    }

    /// SHA-256 of the whole data fork, read in 1 MiB chunks. Checks for cancellation
    /// between chunks and reports the bytes read after each one.
    static func fullDigest(
        of target: DuplicateHashTarget,
        cancellation: DuplicateCancellation,
        bytesRead: (Int) -> Void = { _ in }
    ) throws -> DuplicateFullDigest {
        try cancellation.check()
        return try DuplicateReadPolicy.perform {
            let file = try DuplicateOpenedFile(target: target)
            defer { file.close() }
            if file.dataSize >= noCacheThreshold { file.disableCaching() }
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkLength, alignment: 16_384)
            defer { buffer.deallocate() }
            var hasher = SHA256()
            var offset: Int64 = 0
            while offset < file.dataSize {
                try cancellation.check()
                let count = Int(min(Int64(chunkLength), file.dataSize - offset))
                try file.read(into: buffer, count: count, at: offset)
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
                offset += Int64(count)
                bytesRead(count)
            }
            try file.verifyUnchanged()
            return DuplicateFullDigest(digest: DuplicateDigest(hasher.finalize()), dataSize: file.dataSize)
        }
    }
}

/// An open, verified file descriptor.
private struct DuplicateOpenedFile {
    let fd: Int32
    let target: DuplicateHashTarget
    let dataSize: Int64

    init(target: DuplicateHashTarget) throws {
        let fd = open(target.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            throw code == ENOENT || code == ELOOP ? DuplicateHashFailure.changed : DuplicateHashFailure.unreadable(code)
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw DuplicateHashFailure.unreadable(code)
        }
        do {
            try Self.verify(info, matches: target)
        } catch {
            Darwin.close(fd)
            throw error
        }
        guard info.st_size > 0 else {
            Darwin.close(fd)
            throw DuplicateHashFailure.empty
        }
        self.fd = fd
        self.target = target
        self.dataSize = Int64(info.st_size)
    }

    func close() {
        Darwin.close(fd)
    }

    func disableCaching() {
        _ = fcntl(fd, F_NOCACHE, 1)
    }

    /// Reads exactly `count` bytes at `offset`.
    func read(into buffer: UnsafeMutableRawBufferPointer, count: Int, at offset: Int64) throws {
        guard let base = buffer.baseAddress else { throw DuplicateHashFailure.unreadable(EINVAL) }
        var done = 0
        while done < count {
            let result = pread(fd, base + done, count - done, off_t(offset) + off_t(done))
            if result > 0 {
                done += result
            } else if result == 0 {
                // The file got shorter after it was opened.
                throw DuplicateHashFailure.changed
            } else {
                let code = errno
                if code == EINTR { continue }
                var info = stat()
                if fstat(fd, &info) == 0, info.st_flags & FileFlags.dataless != 0 {
                    throw DuplicateHashFailure.cloudOnly
                }
                throw DuplicateHashFailure.unreadable(code)
            }
        }
    }

    /// Confirms the file wasn't modified while it was read.
    func verifyUnchanged() throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw DuplicateHashFailure.unreadable(errno) }
        try Self.verify(info, matches: target)
        guard Int64(info.st_size) == dataSize else { throw DuplicateHashFailure.changed }
    }

    private static func verify(_ info: stat, matches target: DuplicateHashTarget) throws {
        guard FileObjectType(mode: info.st_mode) == .regular,
              info.st_dev == target.identity.device,
              UInt64(info.st_ino) == target.identity.inode else {
            throw DuplicateHashFailure.changed
        }
        if info.st_flags & FileFlags.dataless != 0 { throw DuplicateHashFailure.cloudOnly }
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        guard abs(modified - target.modificationTime) < 0.000_001 else { throw DuplicateHashFailure.changed }
    }
}

/// I/O policy for reading files during a scan, applied to the current thread only.
///
/// * Cloud-only (dataless) files are never downloaded. Scans already skip files
///   flagged as dataless, but a file can be evicted to the cloud between the scan and
///   the moment it is read; with this policy the read fails instead of downloading it.
/// * Access times aren't updated, so comparing files doesn't make them all look
///   recently opened (Mac Cleaner's own old-file detection relies on access dates).
enum DuplicateReadPolicy {
    static func perform<T>(_ body: () throws -> T) rethrows -> T {
        let materialization = ThreadPolicy(
            type: IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
            value: IOPOL_MATERIALIZE_DATALESS_FILES_OFF,
            fallback: IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT
        )
        let accessTimes = ThreadPolicy(
            type: IOPOL_TYPE_VFS_ATIME_UPDATES,
            value: IOPOL_ATIME_UPDATES_OFF,
            fallback: IOPOL_ATIME_UPDATES_DEFAULT
        )
        defer {
            accessTimes.restore()
            materialization.restore()
        }
        return try body()
    }

    /// One thread-scoped policy, remembering the previous value because GCD reuses threads.
    private struct ThreadPolicy {
        let type: Int32
        let previous: Int32
        let fallback: Int32
        let isChanged: Bool

        init(type: Int32, value: Int32, fallback: Int32) {
            self.type = type
            self.fallback = fallback
            previous = getiopolicy_np(type, IOPOL_SCOPE_THREAD)
            isChanged = setiopolicy_np(type, IOPOL_SCOPE_THREAD, value) == 0
        }

        func restore() {
            guard isChanged else { return }
            _ = setiopolicy_np(type, IOPOL_SCOPE_THREAD, previous >= 0 ? previous : fallback)
        }
    }
}
