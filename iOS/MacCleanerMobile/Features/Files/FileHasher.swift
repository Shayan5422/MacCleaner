import CryptoKit
import Foundation

/// SHA-256 of files, read in chunks so memory stays flat however large the file is.
enum FileHasher {
    /// Bytes from the start of a file that the quick comparison reads.
    static let partialLength = 64 * 1024
    static let chunkLength = 1024 * 1024

    /// SHA-256 of the first 64 KB, or of the whole file when it's smaller (then it's also the full digest).
    static func partialDigest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: partialLength) ?? Data()
        return hex(SHA256.hash(data: data))
    }

    /// SHA-256 of the whole file. Stops with `CancellationError` when the task is cancelled.
    static func fullDigest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try autoreleasepool { try handle.read(upToCount: chunkLength) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
