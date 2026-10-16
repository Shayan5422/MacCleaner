import CryptoKit
import Foundation

/// ClamAV's own signature databases hold malware patterns as text, so scanning them can match
/// those patterns (an unpacked `daily.ldb`, or another antivirus app's database folder). A
/// detection in such a file is set aside only when ClamAV's signature covers every byte of it,
/// so naming malware "main.cvd" or "daily.ldb" (or adding data to a real database) doesn't hide it:
/// - a `.cvd` (or an unmodified copy saved as `.cld`) whose MD5 and RSA signature verify and
///   whose header is plain text, or
/// - an unpacked database file listed with the same size and SHA-256 in a signed `.info` index
///   in the same folder, or that `.info` file itself when nothing follows its signature.
///
/// A `.cld` rebuilt from patches doesn't qualify: only the files listed in its index are signed,
/// not the archive around them.
enum AVSignatureDatabases {
    static let containerExtensions: Set<String> = ["cvd", "cld"]
    static let unpackedExtensions: Set<String> = [
        "cbc", "cdb", "cfg", "crb", "fp", "ftm", "gdb", "hdb", "hdu", "hsb", "hsu", "idb", "ign", "ign2", "imp", "info",
        "ldb", "ldu", "mdb", "mdu", "msb", "msu", "ndb", "ndu", "pdb", "pwdb", "sfp", "wdb", "yar", "yara",
    ]

    /// A cheap check on the name, before anything is verified.
    static func isCandidate(path: String) -> Bool {
        let fileExtension = (path as NSString).pathExtension.lowercased()
        return containerExtensions.contains(fileExtension) || unpackedExtensions.contains(fileExtension)
    }

    /// true when ClamAV's signature proves `path` is an official ClamAV database file.
    static func isVerifiedDatabase(path: String,
                                   verifyContainer: (URL) -> ClamAVVerification? = engineVerification,
                                   indexVerifier: any AVCdiffVerifying = AVClamAVPSSVerifier.databaseIndex) -> Bool {
        guard isCandidate(path: path) else { return false }
        let url = URL(fileURLWithPath: path)
        let fileExtension = url.pathExtension.lowercased()
        if containerExtensions.contains(fileExtension) {
            return verifyContainer(url) == .signedContainer && hasPlainTextHeader(url)
        }
        return isListedInSignedIndex(url, verifier: indexVerifier)
    }

    static func engineVerification(_ url: URL) -> ClamAVVerification? {
        (try? ClamAVDatabaseFile.verify(at: url))?.verification
    }

    // MARK: - Unpacked databases

    struct SignedIndex {
        var files: [String: (size: Int64, sha256: String)]
        var signature: String
        /// SHA-256 of the text before the `DSIG:` line (what the signature covers).
        var signedDigest: Data
        /// Something other than white space follows the `DSIG:` line (not covered by the signature).
        var hasDataAfterSignature: Bool

        init?(_ data: Data) {
            var files: [String: (size: Int64, sha256: String)] = [:]
            var signature: String?
            var signedLength = 0
            var trailing = Data()
            var lineStart = data.startIndex
            while lineStart < data.endIndex {
                let lineEnd = data[lineStart...].firstIndex(of: 0x0A) ?? data.endIndex
                var line = String(decoding: data[lineStart..<lineEnd], as: UTF8.self)
                if line.hasSuffix("\r") { line.removeLast() }
                if line.hasPrefix("DSIG:") {
                    signature = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    signedLength = lineStart - data.startIndex
                    trailing = lineEnd < data.endIndex ? Data(data[data.index(after: lineEnd)...]) : Data()
                    break
                }
                let fields = line.split(separator: ":", omittingEmptySubsequences: false)
                if !line.hasPrefix("ClamAV-VDB:"), fields.count >= 3, let size = Int64(fields[1]), fields[2].count == 64 {
                    files[String(fields[0])] = (size, fields[2].lowercased())
                }
                lineStart = lineEnd < data.endIndex ? data.index(after: lineEnd) : data.endIndex
            }
            guard let signature, !signature.isEmpty else { return nil }
            self.files = files
            self.signature = signature
            signedDigest = Data(SHA256.hash(data: data.prefix(signedLength)))
            hasDataAfterSignature = !trailing.allSatisfy { $0 == 0x0A || $0 == 0x0D || $0 == 0x20 || $0 == 0x09 }
        }
    }

    /// The file's size and SHA-256 match a signed `.info` index in the same folder.
    static func isListedInSignedIndex(_ url: URL, verifier: any AVCdiffVerifying) -> Bool {
        let name = url.lastPathComponent
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        if name.lowercased().hasSuffix(".info") {
            guard let index = readIndex(url), !index.hasDataAfterSignature else { return false }
            return verifier.verify(sha256: index.signedDigest, signature: index.signature)
        }
        for indexURL in indexFiles(besides: url) {
            guard let index = readIndex(indexURL), let expected = index.files[name], expected.size == Int64(info.st_size) else { continue }
            guard verifier.verify(sha256: index.signedDigest, signature: index.signature) else { continue }
            if AVFileHasher.sha256(path: url.path) == expected.sha256 { return true }
        }
        return false
    }

    /// `<database>.info` first ("daily.ldb" → "daily.info"), then the folder's other indexes.
    private static func indexFiles(besides url: URL) -> [URL] {
        let directory = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let stem = name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
        let preferred = stem + ".info"
        let others = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".info") && $0 != preferred }
            .sorted()
            .prefix(4)
        return ([preferred] + others).map { directory.appendingPathComponent($0) }
    }

    private static func readIndex(_ url: URL) -> SignedIndex? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size < 4_000_000,
              let data = try? Data(contentsOf: url) else { return nil }
        return SignedIndex(data)
    }

    // MARK: - Containers

    /// The 512-byte header (which the MD5 doesn't cover) holds only printable text and padding.
    static func hasPlainTextHeader(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 512), header.count == 512 else { return false }
        return header.starts(with: Data("ClamAV-VDB:".utf8)) && header.allSatisfy { ($0 >= 0x20 && $0 <= 0x7E) || $0 == 0 }
    }
}
