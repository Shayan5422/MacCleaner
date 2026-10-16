import Darwin
import Foundation

// The engine's public surface (see AVEngineAPI.swift for the shared types). Implementation:
// ClamAVContainer (CVD/CLD), AVDatabaseBuilder/Writer (compiler), AVMappedDatabase (loader),
// AVObjectScanner/AVBufferScanner (matching).

/// Header of a ClamAV database container (`.cvd` / `.cld`).
struct ClamAVDatabaseHeader: Sendable, Codable, Hashable {
    /// "main", "daily"...
    var name: String
    var buildTime: Date
    var version: Int
    var signatureCount: Int
    var functionalityLevel: Int
    var builder: String
    /// `.cvd` or `.cld` (from the file name; nil when the name has neither extension).
    var format: ClamAVContainerFormat?
    /// How `ClamAVDatabaseFile.verify(at:)` established the contents' integrity. nil from `readHeader(at:)`.
    var verification: ClamAVVerification?
    /// The header's MD5 field (`X` in a locally built `.cld`).
    var md5: String?
    /// The header's digital signature field (`X` in a locally built `.cld`).
    var digitalSignature: String?

    init(name: String, buildTime: Date, version: Int, signatureCount: Int, functionalityLevel: Int, builder: String,
         format: ClamAVContainerFormat? = nil, verification: ClamAVVerification? = nil, md5: String? = nil, digitalSignature: String? = nil) {
        self.name = name
        self.buildTime = buildTime
        self.version = version
        self.signatureCount = signatureCount
        self.functionalityLevel = functionalityLevel
        self.builder = builder
        self.format = format
        self.verification = verification
        self.md5 = md5
        self.digitalSignature = digitalSignature
    }
}

/// ClamAV database container formats.
enum ClamAVContainerFormat: String, Sendable, Codable, Hashable {
    /// Downloaded database: gzip-compressed tar, signed by ClamAV.
    case cvd
    /// Local database written by freshclam after applying incremental (CDIFF) updates: plain tar.
    case cld
}

/// How a ClamAV database's integrity was established.
enum ClamAVVerification: String, Sendable, Codable, Hashable {
    /// The archive's MD5 matches its header and ClamAV's RSA signature of that MD5 verifies
    /// (every `.cvd`; a `.cld` only if it is an unmodified copy of one).
    case signedContainer
    /// A `.cld` built locally (by freshclam from signed CDIFF updates). Its header isn't signed,
    /// but the database index inside (`daily.info`) carries ClamAV's RSA-PSS signature, and every
    /// database file matched the size and SHA-256 listed in that index.
    case signedIndex
    /// A `.cld` without a signed index: only the structure was checked (header fields, tar
    /// checksums and sizes). The contents can't be traced back to ClamAV.
    case structureOnly

    var title: String {
        switch self {
        case .signedContainer: return "Signature verified"
        case .signedIndex: return "Built locally by freshclam, index signature verified"
        case .structureOnly: return "Built locally, not signed"
        }
    }

    /// The contents are covered by a ClamAV signature.
    var isSigned: Bool { self != .structureOnly }
}

enum AVEngineError: Error, LocalizedError, Sendable, Equatable {
    case notInstalled
    case invalidDatabase(String)
    case signatureMismatch(String)
    case notImplemented

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Virus definitions aren't installed yet."
        case .invalidDatabase(let detail): return "The virus definitions are damaged: \(detail)"
        case .signatureMismatch(let name): return "\(name) isn't signed by ClamAV. It was not installed."
        case .notImplemented: return "The antivirus engine isn't available in this build."
        }
    }
}

/// Reads and verifies ClamAV database containers.
enum ClamAVDatabaseFile {
    /// Parses the 512-byte header without verifying the contents.
    static func readHeader(at url: URL) throws -> ClamAVDatabaseHeader {
        try ClamAVContainer.readHeader(at: url)
    }

    /// Checks the header, the MD5 of the archive and ClamAV's digital signature (`.cvd`), or the
    /// tar structure and the signed database index (`.cld`). The result's `verification` says which.
    static func verify(at url: URL) throws -> ClamAVDatabaseHeader {
        try ClamAVContainer.verify(at: url)
    }
}

/// Builds the engine's database from downloaded files.
enum AVDatabaseCompiler {
    /// Verifies and compiles `inputs` into `directory`, replacing its previous contents only
    /// when compilation succeeds. Blocks; run it off the main actor.
    ///
    /// The database is written to a temporary file in `directory` and renamed over
    /// `engine.mcavdb`, so a running engine keeps its (still mapped) old database and a failed
    /// compile leaves the previous one untouched. When several containers have the same name
    /// (`daily.cvd` and `daily.cld`), the highest version is used.
    static func compile(
        _ inputs: AVDatabaseInputs,
        into directory: URL,
        progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }
    ) throws -> AVDatabaseSummary {
        // Pass 1: verify every container and read its ignore lists, keeping only headers (an
        // unpacked main database is ~250 MB). When several containers have the same name
        // (daily.cvd and daily.cld), the highest version wins.
        let fileCount = max(1, inputs.clamavFiles.count)
        var selected = [String: (url: URL, header: ClamAVDatabaseHeader, ignores: AVIgnoreList)]()
        for (index, url) in inputs.clamavFiles.enumerated() {
            progress(0.02 + 0.2 * Double(index) / Double(fileCount), "Verifying \(url.lastPathComponent)")
            let database = try ClamAVContainer.unpack(at: url)
            let header = database.header
            if let existing = selected[header.name], existing.header.version > header.version
                || (existing.header.version == header.version && existing.header.verification == .signedContainer) {
                continue
            }
            selected[header.name] = (url, header, AVDatabaseBuilder.ignoreList(in: database))
        }
        // daily first, like ClamAV (its allow and ignore lists are meant to override main).
        let ordered = selected.values.sorted { lhs, rhs in
            if (lhs.header.name == "daily") != (rhs.header.name == "daily") { return lhs.header.name == "daily" }
            return lhs.header.name < rhs.header.name
        }

        // Pass 2: compile one database at a time.
        let builder = AVDatabaseBuilder(functionalityLevel: AVEngine.functionalityLevel)
        for entry in ordered { builder.ignoreList.merge(entry.ignores) }
        for (index, entry) in ordered.enumerated() {
            progress(0.25 + 0.45 * Double(index) / Double(max(1, ordered.count)), "Reading \(entry.header.name) signatures")
            let database = try ClamAVContainer.unpack(at: entry.url)
            try builder.add(database)
        }
        for (index, list) in inputs.sha256Lists.enumerated() {
            progress(0.7 + 0.1 * Double(index) / Double(max(1, inputs.sha256Lists.count)), "Reading \(list.source.title) hashes")
            let data: Data
            do { data = try Data(contentsOf: list.url, options: .mappedIfSafe) } catch {
                throw AVEngineError.invalidDatabase("\(list.url.lastPathComponent) can't be read: \(error.localizedDescription)")
            }
            builder.addHashList(data, source: list.source)
        }

        var summary = AVDatabaseSummary(
            builtAt: Date(),
            clamavVersions: Dictionary(uniqueKeysWithValues: ordered.map { ($0.header.name, $0.header.version) }),
            clamavBuildDates: Dictionary(uniqueKeysWithValues: ordered.map { ($0.header.name, $0.header.buildTime) }),
            signatureCount: builder.hashSignatureCount + builder.bodySignatureCount + builder.logicalSignatureCount,
            unsupportedSignatureCount: builder.coverage.files.values.reduce(0) { $0 + $1.unsupported },
            hashSignatureCount: builder.hashSignatureCount,
            bodySignatureCount: builder.bodySignatureCount,
            logicalSignatureCount: builder.logicalSignatureCount,
            hashListCount: builder.hashListCount)
        summary.coverage = builder.coverage
        summary.clamavVerification = Dictionary(uniqueKeysWithValues: ordered.compactMap { entry in
            entry.header.verification.map { (entry.header.name, $0) }
        })
        summary.engineFunctionalityLevel = AVEngine.functionalityLevel

        progress(0.85, "Writing the database")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw AVEngineError.invalidDatabase("the database folder can't be created: \(error.localizedDescription)")
        }
        let destination = directory.appendingPathComponent(AVDatabaseFormat.fileName)
        let temporary = directory.appendingPathComponent(".\(AVDatabaseFormat.fileName)-\(UUID().uuidString).tmp")
        do {
            try builder.write(to: temporary, summary: summary)
            // Make sure what was written loads before it replaces anything.
            _ = try AVMappedDatabase(url: temporary)
            guard rename(temporary.path, destination.path) == 0 else {
                throw AVEngineError.invalidDatabase("the database can't be installed (\(String(cString: strerror(errno)))).")
            }
        } catch {
            unlink(temporary.path)
            throw error
        }
        progress(1, "Done")
        return summary
    }

    /// The summary of the database installed in `directory`, read without loading it.
    static func installedSummary(in directory: URL) -> AVDatabaseSummary? {
        (try? AVMappedDatabase(url: directory.appendingPathComponent(AVDatabaseFormat.fileName)))?.metadata.summary
    }
}

/// A loaded, ready-to-scan engine. Thread-safe.
final class AVEngine: AVFileScanning, @unchecked Sendable {
    /// The ClamAV functionality level this engine implements. Signatures that need a higher
    /// level (`Engine:` / min_flevel) are skipped; ones retired below it (max_flevel) are ignored.
    static let functionalityLevel = 200

    let summary: AVDatabaseSummary
    let core: AVEngineCore

    private init(summary: AVDatabaseSummary, core: AVEngineCore) {
        self.summary = summary
        self.core = core
    }

    /// Loads a database compiled by `AVDatabaseCompiler` (memory-mapped, fast).
    static func load(from directory: URL) throws -> AVEngine {
        let database = try AVMappedDatabase(url: directory.appendingPathComponent(AVDatabaseFormat.fileName))
        return AVEngine(summary: database.metadata.summary, core: AVEngineCore(database: database))
    }

    /// An engine without definitions: detects the EICAR test file (also inside archives) only.
    static func builtIn() -> AVEngine {
        let summary = AVDatabaseSummary(builtAt: Date(timeIntervalSince1970: 0), clamavVersions: [:], clamavBuildDates: [:],
                                        signatureCount: 0, unsupportedSignatureCount: 0, hashSignatureCount: 0,
                                        bodySignatureCount: 0, logicalSignatureCount: 0, hashListCount: 0)
        return AVEngine(summary: summary, core: AVEngineCore(database: nil))
    }

    /// `true` when definitions are loaded (false for `builtIn()`).
    var hasDatabase: Bool { core.database != nil }

    /// Signature coverage of the loaded database (loaded / unsupported per database file).
    var coverage: AVSignatureCoverage? { summary.coverage }

    func scanFile(atPath path: String, options: AVScanOptions) -> AVFileScanResult {
        // Scans usually run in long loops on worker threads: drain Foundation's autoreleased
        // objects (regular expression matching, string bridging) after every file.
        autoreleasepool { scanFileUnpooled(atPath: path, options: options) }
    }

    private func scanFileUnpooled(atPath path: String, options: AVScanOptions) -> AVFileScanResult {
        var info = stat()
        guard lstat(path, &info) == 0 else { return AVFileScanResult(path: path, skipped: .unreadable(Self.errorText(errno))) }
        guard info.st_mode & S_IFMT == S_IFREG else { return AVFileScanResult(path: path, skipped: .notRegularFile) }
        // Reading a cloud-only file would download it, so it's never opened.
        guard info.st_flags & Self.datalessFlag == 0 else { return AVFileScanResult(path: path, skipped: .dataless) }
        guard Int64(info.st_size) <= options.maxFileSize else { return AVFileScanResult(path: path, skipped: .tooLarge) }

        // O_NOFOLLOW: a symlink swapped in after lstat isn't followed. O_NONBLOCK: a FIFO swapped
        // in can't block the scan (it's rejected by the fstat check below).
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return AVFileScanResult(path: path, skipped: .unreadable(Self.errorText(errno))) }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0 else { return AVFileScanResult(path: path, skipped: .unreadable(Self.errorText(errno))) }
        guard opened.st_mode & S_IFMT == S_IFREG, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
            return AVFileScanResult(path: path, skipped: .notRegularFile)
        }
        guard opened.st_flags & Self.datalessFlag == 0 else { return AVFileScanResult(path: path, skipped: .dataless) }
        guard Int64(opened.st_size) <= options.maxFileSize else { return AVFileScanResult(path: path, skipped: .tooLarge) }

        // Large files on the Mac's internal volumes are memory-mapped (their pages stay clean,
        // evictable file cache instead of process memory). Everything else is read with pread:
        // with a mapping, an I/O error on an external or network volume would crash the process.
        // On APFS, pages past a concurrent truncation read as zeros rather than faulting.
        // macOS has no O_NOATIME, so reading may update the access time.
        let size = Int(opened.st_size)
        var total = 0
        let base: UnsafeRawPointer
        var mapped: UnsafeMutableRawPointer?
        var buffer: AVScratchBuffer?
        defer {
            if let mapped { munmap(mapped, size) }
            withExtendedLifetime(buffer) {}
        }
        if size >= Self.mapThreshold, Self.internalVolumes.contains(opened.st_dev),
           let address = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), address != MAP_FAILED {
            mapped = address
            base = UnsafeRawPointer(address)
            total = size
        } else {
            guard let scratch = AVScratchBuffer(capacity: size) else {
                return AVFileScanResult(path: path, skipped: .unreadable(Self.errorText(ENOMEM)))
            }
            buffer = scratch
            let storage = scratch.base
            base = UnsafeRawPointer(storage)
            while total < size {
                let result = pread(fd, storage + total, min(size - total, 16 << 20), off_t(total))
                if result < 0 {
                    if errno == EINTR { continue }
                    return AVFileScanResult(path: path, skipped: .unreadable(Self.errorText(errno)))
                }
                if result == 0 { break } // the file shrank while reading: scan what's there
                total += result
            }
        }

        let view = AVByteView(base: base, count: total)
        let scanner = AVObjectScanner(core: core, options: options)
        let detections = scanner.scan(view, name: (path as NSString).lastPathComponent)
        var result = AVFileScanResult(path: path, detections: detections, bytesScanned: Int64(total), limitsReached: scanner.limitsReached)
        result.encryptedMembers = scanner.encryptedMembers
        result.unsupportedMembers = scanner.unsupportedMembers
        if !detections.isEmpty {
            var digests = scanner.rootDigests ?? AVObjectDigests(view)
            digests.ensure(sha256: true)
            result.sha256 = digests.sha256.map(AVHex.string)
        }
        return result
    }

    /// Scans bytes that aren't a file on disk (an archive member, a download in memory).
    func scan(data: Data, name: String, options: AVScanOptions) -> [AVDetection] {
        autoreleasepool {
            data.withUnsafeBytes { raw in
                AVObjectScanner(core: core, options: options).scan(AVByteView(raw), name: name)
            }
        }
    }

    /// `SF_DATALESS` from <sys/stat.h>: the file's contents are in the cloud only.
    static let datalessFlag: UInt32 = 0x4000_0000

    /// Files at least this large on internal volumes are mapped instead of read.
    static let mapThreshold = 4 << 20

    /// Devices of the system and data volumes of the startup disk.
    static let internalVolumes: Set<Int32> = {
        var devices = Set<Int32>()
        for path in ["/", "/System/Volumes/Data"] {
            var info = stat()
            if stat(path, &info) == 0 { devices.insert(info.st_dev) }
        }
        return devices
    }()

    private static func errorText(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
