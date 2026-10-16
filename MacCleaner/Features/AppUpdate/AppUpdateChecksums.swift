import CryptoKit
import Foundation

/// SHA-256 checksums of release files.
enum AppUpdateChecksums {
    /// Parses `shasum -a 256` output: one `<64 hex>  <file name>` per line (`*name` in binary
    /// mode). Returns lowercase hex by file name; malformed lines are ignored.
    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let hash = trimmed[..<space].lowercased()
            var name = trimmed[space...].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            // Only the file name counts; a path ("build/Mac-Cleaner-1.0.dmg") is reduced to it.
            name = (name as NSString).lastPathComponent
            guard isSHA256(hash), !name.isEmpty else { continue }
            result[name] = hash
        }
        return result
    }

    static func isSHA256(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// SHA-256 of a file (lowercase hex), read in 1 MB chunks.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Checks `file` against the checksum published for `fileName`, and against
    /// GitHub's own digest when the release reports one.
    static func verify(file: URL, fileName: String, checksumFile: String, githubDigest: String?) throws {
        guard let expected = parse(checksumFile)[fileName] else { throw AppUpdateError.checksumNotListed(fileName) }
        if let githubDigest, githubDigest.lowercased() != expected { throw AppUpdateError.checksumsDisagree }
        let actual = try sha256(of: file)
        guard actual == expected else { throw AppUpdateError.checksumMismatch }
    }
}
