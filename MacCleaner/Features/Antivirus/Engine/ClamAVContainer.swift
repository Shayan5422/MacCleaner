import Foundation

/// The contents of a verified ClamAV database container, unpacked in memory.
struct ClamAVUnpackedDatabase: @unchecked Sendable {
    var header: ClamAVDatabaseHeader
    /// The tar archive (decompressed for `.cvd`).
    let tar: Data
    /// Database files by name (`main.ndb`, `daily.ldb`...). COPYING is left out.
    let entries: [String: AVTarEntry]

    /// Calls `body` with the bytes of one database file.
    func withFile<T>(_ name: String, _ body: (AVByteView) throws -> T) rethrows -> T? {
        guard let entry = entries[name] else { return nil }
        return try tar.withUnsafeBytes { raw in
            guard let view = AVByteView(raw).slice(entry.dataOffset, entry.size) else { return nil }
            return try body(view)
        }
    }

    var fileNames: [String] { entries.keys.sorted() }
}

/// Reads ClamAV's database containers.
///
/// Layout (both formats): a 512-byte ASCII header padded with spaces,
/// `ClamAV-VDB:<build time>:<version>:<signatures>:<functionality level>:<md5>:<dsig>:<builder>:<build time in seconds>`,
/// followed by
/// * `.cvd` — a gzip-compressed tar. `md5` is the MD5 of everything after the header and
///   `dsig` ClamAV's RSA signature of that MD5 (see `ClamAVSignatureVerifier`).
/// * `.cld` — a plain tar (gzip when freshclam's `CompressLocalDatabase` is on), written by
///   freshclam after applying CDIFF updates. Its header is copied from the first line of the
///   database index `<name>.info`, where `md5` and `dsig` are `X`, so the header itself isn't
///   signed. The index is: it lists every database file with its size and SHA-256 and ends
///   with a `DSIG:` line signed with ClamAV's index key (each CDIFF replaces that line with a
///   new one made with the same key), which is what this reader verifies for `.cld` files. The
///   CDIFF files' own signatures (a different key) are checked by whoever applies them, not here.
enum ClamAVContainer {
    static let headerSize = 512
    /// Upper bound for a decompressed database (main.cvd unpacks to ~250 MB today).
    static let maxUnpackedSize = 3 << 30

    // MARK: Header

    static func parseHeader(_ view: AVByteView, fileName: String) throws -> ClamAVDatabaseHeader {
        guard let headerView = view.slice(0, min(headerSize, view.count)), headerView.count >= 11 else {
            throw AVEngineError.invalidDatabase("\(fileName) is too short to be a ClamAV database.")
        }
        var text = String(decoding: headerView.buffer, as: UTF8.self)
        while let last = text.last, last == " " || last == "\0" || last == "\n" || last == "\r" { text.removeLast() }
        guard text.hasPrefix("ClamAV-VDB:") else {
            throw AVEngineError.invalidDatabase("\(fileName) isn't a ClamAV database (missing ClamAV-VDB header).")
        }
        return try parseHeaderLine(text, fileName: fileName)
    }

    /// Parses `ClamAV-VDB:...` (from a container header or the first line of a `.info` index).
    static func parseHeaderLine(_ text: String, fileName: String) throws -> ClamAVDatabaseHeader {
        let fields = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 8, fields[0] == "ClamAV-VDB",
              let version = Int(fields[2]), version >= 0,
              let signatures = Int(fields[3]), signatures >= 0,
              let level = Int(fields[4]), level >= 0 else {
            throw AVEngineError.invalidDatabase("\(fileName) has a malformed header.")
        }
        var buildTime = parseBuildTime(fields[1])
        if fields.count >= 9, let seconds = TimeInterval(fields[8].trimmingCharacters(in: .whitespaces)), seconds > 0 {
            buildTime = Date(timeIntervalSince1970: seconds)
        }
        guard let buildTime else {
            throw AVEngineError.invalidDatabase("\(fileName) has an unreadable build time.")
        }
        var header = ClamAVDatabaseHeader(name: databaseName(fromFileName: fileName), buildTime: buildTime, version: version,
                                          signatureCount: signatures, functionalityLevel: level, builder: fields[7])
        header.md5 = fields[5]
        header.digitalSignature = fields[6]
        header.format = containerFormat(fromFileName: fileName)
        return header
    }

    /// "16 Dec 2025 23-18 +0000" (ClamAV writes the time with a dash so the header stays colon-separated).
    static func parseBuildTime(_ text: String) -> Date? {
        let parts = text.split(separator: " ")
        guard parts.count >= 4, let day = Int(parts[0]), let year = Int(parts[2]) else { return nil }
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let monthIndex = months.firstIndex(of: parts[1].prefix(3).lowercased()) else { return nil }
        let time = parts[3].split(separator: "-")
        guard time.count == 2, let hour = Int(time[0]), let minute = Int(time[1]) else { return nil }
        var offsetSeconds = 0
        if parts.count >= 5, let zone = Int(parts[4]) {
            offsetSeconds = (zone / 100 * 3600 + zone % 100 * 60)
        }
        var components = DateComponents()
        components.year = year
        components.month = monthIndex + 1
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone(secondsFromGMT: offsetSeconds)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        return calendar.date(from: components)
    }

    /// "main.cvd" → "main", "daily-28155.cld" → "daily".
    static func databaseName(fromFileName fileName: String) -> String {
        var stem = (fileName as NSString).lastPathComponent
        if let dot = stem.firstIndex(of: ".") { stem = String(stem[..<dot]) }
        if let dash = stem.lastIndex(of: "-"), stem[stem.index(after: dash)...].allSatisfy(\.isNumber), dash != stem.startIndex {
            stem = String(stem[..<dash])
        }
        return stem
    }

    static func containerFormat(fromFileName fileName: String) -> ClamAVContainerFormat? {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "cvd": return .cvd
        case "cld": return .cld
        default: return nil
        }
    }

    // MARK: Reading files

    static func readHeader(at url: URL) throws -> ClamAVDatabaseHeader {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch {
            throw AVEngineError.invalidDatabase("\(url.lastPathComponent) can't be opened: \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: headerSize)) ?? Data()
        return try data.withUnsafeBytes { try parseHeader(AVByteView($0), fileName: url.lastPathComponent) }
    }

    static func load(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw AVEngineError.invalidDatabase("\(url.lastPathComponent) can't be read: \(error.localizedDescription)")
        }
    }

    // MARK: Verification

    /// Verifies a container and returns its header with `verification` set.
    /// For `.cvd` this checks the MD5 and the RSA signature (fast: no decompression).
    /// For `.cld` it unpacks the tar and checks its structure and signed index.
    static func verify(at url: URL) throws -> ClamAVDatabaseHeader {
        let data = try load(url)
        let fileName = url.lastPathComponent
        let header = try data.withUnsafeBytes { try parseHeader(AVByteView($0), fileName: fileName) }
        if try verifySignedContainer(data, header: header, fileName: fileName) {
            var verified = header
            verified.verification = .signedContainer
            if verified.format == nil { verified.format = .cvd }
            return verified
        }
        if header.format == .cvd {
            throw AVEngineError.signatureMismatch(fileName)
        }
        return try unpackLocal(data, header: header, fileName: fileName).header
    }

    /// Verifies and unpacks a container in memory.
    static func unpack(at url: URL) throws -> ClamAVUnpackedDatabase {
        let data = try load(url)
        let fileName = url.lastPathComponent
        return try unpack(data, fileName: fileName)
    }

    static func unpack(_ data: Data, fileName: String) throws -> ClamAVUnpackedDatabase {
        var header = try data.withUnsafeBytes { try parseHeader(AVByteView($0), fileName: fileName) }
        if try verifySignedContainer(data, header: header, fileName: fileName) {
            header.verification = .signedContainer
            if header.format == nil { header.format = .cvd }
            let tar = try decompressPayload(data, fileName: fileName)
            return try index(tar: tar, header: header, fileName: fileName, requireIndexSignature: false)
        }
        if header.format == .cvd {
            throw AVEngineError.signatureMismatch(fileName)
        }
        return try unpackLocal(data, header: header, fileName: fileName)
    }

    /// `true` when the header MD5 matches the payload and ClamAV's RSA signature verifies.
    /// Throws when the MD5 is present but wrong for a `.cvd` (damaged download).
    private static func verifySignedContainer(_ data: Data, header: ClamAVDatabaseHeader, fileName: String) throws -> Bool {
        guard let md5 = header.md5, md5.count == 32, AVHex.decode(md5) != nil else { return false }
        guard data.count > headerSize else {
            throw AVEngineError.invalidDatabase("\(fileName) has no contents after its header.")
        }
        let actual = data.withUnsafeBytes { raw -> String in
            AVHex.string(AVDigest.md5(UnsafeRawBufferPointer(rebasing: raw[headerSize...])))
        }
        guard actual == md5.lowercased() else {
            if header.format == .cld { return false } // a rebuilt .cld may keep a stale header
            throw AVEngineError.invalidDatabase("\(fileName) is incomplete or damaged (its checksum doesn't match).")
        }
        guard let signature = header.digitalSignature,
              ClamAVSignatureVerifier.verifyCVDSignature(md5Hex: md5, signature: signature) else {
            if header.format == .cld { return false }
            throw AVEngineError.signatureMismatch(fileName)
        }
        return true
    }

    private static func decompressPayload(_ data: Data, fileName: String) throws -> Data {
        try data.withUnsafeBytes { raw -> Data in
            guard let payload = AVByteView(raw).suffix(from: headerSize) else {
                throw AVEngineError.invalidDatabase("\(fileName) has no contents after its header.")
            }
            guard AVGzipReader.looksLikeGzip(payload) else {
                throw AVEngineError.invalidDatabase("\(fileName) isn't compressed as expected.")
            }
            let output = AVGzipReader.decompress(payload, limit: maxUnpackedSize)
            guard output.complete, !output.hitLimit else {
                throw AVEngineError.invalidDatabase("\(fileName) can't be decompressed.")
            }
            return output.data
        }
    }

    /// A `.cld` (or anything that isn't a signed `.cvd`): plain or gzip tar after the header.
    private static func unpackLocal(_ data: Data, header: ClamAVDatabaseHeader, fileName: String) throws -> ClamAVUnpackedDatabase {
        var header = header
        header.format = header.format ?? .cld
        let tar: Data = try data.withUnsafeBytes { raw -> Data in
            guard let payload = AVByteView(raw).suffix(from: headerSize), payload.count > 0 else {
                throw AVEngineError.invalidDatabase("\(fileName) has no contents after its header.")
            }
            if AVGzipReader.looksLikeGzip(payload) {
                let output = AVGzipReader.decompress(payload, limit: maxUnpackedSize)
                guard output.complete, !output.hitLimit else {
                    throw AVEngineError.invalidDatabase("\(fileName) can't be decompressed.")
                }
                return output.data
            }
            return Data(UnsafeRawBufferPointer(rebasing: raw[headerSize...]))
        }
        return try index(tar: tar, header: header, fileName: fileName, requireIndexSignature: true)
    }

    /// Lists the tar and, for local builds, verifies the signed `.info` index.
    private static func index(tar: Data, header: ClamAVDatabaseHeader, fileName: String, requireIndexSignature: Bool) throws -> ClamAVUnpackedDatabase {
        var header = header
        let listing = tar.withUnsafeBytes { AVTarReader.list(AVByteView($0), maxEntries: 4096) }
        guard !listing.damaged, !listing.hitLimit, !listing.entries.isEmpty else {
            throw AVEngineError.invalidDatabase("\(fileName) contains a damaged archive.")
        }
        var entries = [String: AVTarEntry]()
        for entry in listing.entries {
            let name = (entry.name as NSString).lastPathComponent
            guard !name.isEmpty, name != "COPYING" else { continue }
            guard entries[name] == nil else {
                throw AVEngineError.invalidDatabase("\(fileName) lists \(name) twice.")
            }
            entries[name] = entry
        }

        // The index is named after the database ("daily.info"); fall back to the only .info file.
        let infoNames = entries.keys.filter { $0.hasSuffix(".info") }
        let infoName = entries["\(header.name).info"] != nil ? "\(header.name).info" : (infoNames.count == 1 ? infoNames[0] : nil)
        if let infoName {
            let realName = String(infoName.dropLast(5))
            if realName != header.name { header.name = realName }
        }
        // freshclam 1.5 keeps the patches it applied, with their detached signatures, in the `.cld`
        // ("daily-28156.cdiff", "daily-28156.cdiff.sign"). The signed index doesn't list them and they
        // hold no signatures, so they're left out; any other unlisted file is still refused below.
        entries = entries.filter { !isAppliedPatchRecord($0.key, database: header.name) }
        var unpacked = ClamAVUnpackedDatabase(header: header, tar: tar, entries: entries)
        guard requireIndexSignature else {
            unpacked.header = header
            return unpacked
        }

        guard let infoName, let index = unpacked.withFile(infoName, { parseIndex($0) }) ?? nil, let signature = index.signature else {
            header.verification = .structureOnly
            unpacked.header = header
            return unpacked
        }
        guard ClamAVSignatureVerifier.verifyIndexSignature(messageDigest: index.signedDigest, signature: signature) else {
            throw AVEngineError.signatureMismatch(fileName)
        }
        // Every database file must be listed with the right size and SHA-256, and every listed file present.
        for (name, entry) in entries where name != infoName {
            guard let expected = index.files[name] else {
                throw AVEngineError.invalidDatabase("\(fileName) contains \(name), which its signed index doesn't list.")
            }
            let digest = unpacked.withFile(name) { AVDigest.sha256($0) } ?? []
            guard entry.size == expected.size, digest == expected.sha256 else {
                throw AVEngineError.invalidDatabase("\(name) in \(fileName) doesn't match its signed index.")
            }
        }
        for name in index.files.keys where entries[name] == nil {
            throw AVEngineError.invalidDatabase("\(fileName) is missing \(name).")
        }
        // The signed index's own header line is authoritative for version and counts.
        if let line = index.headerLine, var signedHeader = try? parseHeaderLine(line, fileName: fileName) {
            signedHeader.name = header.name
            signedHeader.md5 = header.md5
            signedHeader.digitalSignature = header.digitalSignature
            signedHeader.format = header.format
            header = signedHeader
        }
        header.verification = .signedIndex
        unpacked.header = header
        return unpacked
    }

    /// `<database>-<version>.cdiff` or `<database>-<version>.cdiff.sign`: a patch freshclam applied
    /// to the `.cld`, or its detached signature.
    static func isAppliedPatchRecord(_ name: String, database: String) -> Bool {
        guard !database.isEmpty, name.hasPrefix(database + "-") else { return false }
        var rest = name.dropFirst(database.count + 1)
        if rest.hasSuffix(".sign") { rest = rest.dropLast(5) }
        guard rest.hasSuffix(".cdiff") else { return false }
        let version = rest.dropLast(6)
        return !version.isEmpty && version.allSatisfy { $0.isASCII && $0.isNumber }
    }

    struct Index {
        var headerLine: String?
        var files: [String: (size: Int, sha256: [UInt8])]
        var signature: String?
        /// SHA-256 of the index text before the `DSIG:` line (what the signature covers).
        var signedDigest: [UInt8]
    }

    /// Parses `<name>.info`: an optional `ClamAV-VDB:` header line, `file:size:sha256` lines and `DSIG:<signature>`.
    static func parseIndex(_ view: AVByteView) -> Index? {
        var files = [String: (size: Int, sha256: [UInt8])]()
        var headerLine: String?
        var signature: String?
        var signedLength = view.count
        var lineStart = 0
        while lineStart < view.count {
            var lineEnd = lineStart
            while lineEnd < view.count, view[lineEnd] != 0x0A { lineEnd += 1 }
            var line = String(decoding: UnsafeRawBufferPointer(start: view.base.map { $0 + lineStart }, count: lineEnd - lineStart), as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.hasPrefix("DSIG:") {
                signature = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                signedLength = lineStart
                break
            } else if line.hasPrefix("ClamAV-VDB:") {
                headerLine = line
            } else if !line.isEmpty {
                let parts = line.split(separator: ":", omittingEmptySubsequences: false)
                if parts.count >= 3, let size = Int(parts[1]), let digest = AVHex.decode(String(parts[2])), digest.count == 32 {
                    files[String(parts[0])] = (size, digest)
                }
            }
            lineStart = lineEnd + 1
        }
        guard let signedView = view.slice(0, signedLength) else { return nil }
        return Index(headerLine: headerLine, files: files, signature: signature, signedDigest: AVDigest.sha256(signedView))
    }
}
