import CryptoKit
import Foundation

/// Signatures built into the engine, available without any database.
enum AVBuiltInSignatures {
    /// The 68-byte EICAR test string.
    static let eicar = Array("X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*".utf8)
    static let eicarName = "EICAR-Test-File"

    /// The EICAR definition: the file starts with the test string, optionally followed by
    /// whitespace (space, TAB, LF, CR, Ctrl-Z), and is at most 128 bytes long.
    static func isEICAR(_ data: AVByteView) -> Bool {
        guard data.count >= eicar.count, data.count <= 128, data.matches(eicar, at: 0) else { return false }
        for index in eicar.count..<data.count {
            switch data[index] {
            case 0x20, 0x09, 0x0A, 0x0D, 0x1A: continue
            default: return false
            }
        }
        return true
    }
}

/// Digests of one scanned object, computed on demand in a single pass over the data.
struct AVObjectDigests {
    let data: AVByteView
    private(set) var md5: [UInt8]?
    private(set) var sha1: [UInt8]?
    private(set) var sha256: [UInt8]?

    init(_ data: AVByteView) { self.data = data }

    mutating func ensure(md5 wantMD5: Bool = false, sha1 wantSHA1: Bool = false, sha256 wantSHA256: Bool = false) {
        let needMD5 = wantMD5 && md5 == nil, needSHA1 = wantSHA1 && sha1 == nil, needSHA256 = wantSHA256 && sha256 == nil
        guard needMD5 || needSHA1 || needSHA256 else { return }
        var md5Hasher = Insecure.MD5(), sha1Hasher = Insecure.SHA1(), sha256Hasher = SHA256()
        // Interleave the hashers chunk by chunk so the data is read from memory once.
        let chunk = 256 * 1024
        var offset = 0
        repeat {
            let length = min(chunk, data.count - offset)
            let piece = UnsafeRawBufferPointer(start: data.base.map { $0 + offset }, count: length)
            if needMD5 { md5Hasher.update(bufferPointer: piece) }
            if needSHA1 { sha1Hasher.update(bufferPointer: piece) }
            if needSHA256 { sha256Hasher.update(bufferPointer: piece) }
            offset += length
        } while offset < data.count
        if needMD5 { md5 = Array(md5Hasher.finalize()) }
        if needSHA1 { sha1 = Array(sha1Hasher.finalize()) }
        if needSHA256 { sha256 = Array(sha256Hasher.finalize()) }
    }
}

/// Scans one file (and everything inside it) against a loaded database. Created per scan call,
/// so it holds no shared mutable state.
final class AVObjectScanner {
    let core: AVEngineCore
    let options: AVScanOptions
    private(set) var limitsReached = false
    private(set) var encryptedMembers = 0
    private(set) var unsupportedMembers = 0
    private var extractedBytes: Int64 = 0
    private var memberCount = 0
    /// Digests of the top-level object (reused for the result's SHA-256).
    private(set) var rootDigests: AVObjectDigests?

    static let maxDetections = 64

    init(core: AVEngineCore, options: AVScanOptions) {
        self.core = core
        self.options = options
    }

    struct Level {
        var path: [String]
        /// Types of the containers this object came out of, outermost first.
        var containers: [AVContainerCode]
        var depth: Int
        var name: String

        var memberPath: String? { path.isEmpty ? nil : path.joined(separator: " › ") }

        func child(_ name: String, container: AVContainerCode) -> Level {
            Level(path: path + [name], containers: containers + [container], depth: depth + 1, name: name)
        }
    }

    /// Scans `data` and its contents. Returns detections after allow-list filtering.
    func scan(_ data: AVByteView, name: String) -> [AVDetection] {
        scanObject(data, level: Level(path: [], containers: [], depth: 0, name: name))
    }

    private func scanObject(_ data: AVByteView, level: Level) -> [AVDetection] {
        var found = [AVDetection]()
        var foundNames = Set<String>()
        func report(_ name: String, _ kind: AVThreatKind, _ source: AVSignatureSource) {
            guard foundNames.insert(name).inserted, found.count < Self.maxDetections else { return }
            if kind == .pua && !options.detectPUA { return }
            found.append(AVDetection(signatureName: name, kind: kind, source: source, memberPath: level.memberPath))
        }

        if AVBuiltInSignatures.isEICAR(data) {
            report(AVBuiltInSignatures.eicarName, .testFile, .builtIn)
        }
        var digests = AVObjectDigests(data)
        let kind = AVFileTyper.detect(data)
        var exe: AVExecutableInfo?
        if kind.isExecutable { exe = AVExecutableInfo.parse(data, kind: kind) }

        if let db = core.database {
            // Slices of a universal binary aren't looked up in the size-less SHA-256 lists:
            // those list whole samples, and hashing every slice again doubles the hashing of
            // most Mac executables. ClamAV's own hash signatures (with sizes) still apply.
            let slice = level.containers.last == .machOUniversal
            checkFileHashes(data, machO: kind == .machO || kind == .machOUniversal, sizelessLists: !slice,
                            digests: &digests, db: db, report: report)
            if kind == .pe, let exe, exe.isPE32, options.detectNonMacThreats {
                checkSectionHashes(data, exe: exe, db: db, report: report)
            }
            for match in AVBufferScanner.scanObjectBuffers(data, kind: kind, exe: exe, level: level, core: core, db: db, options: options) {
                report(match.name, match.kind, .clamav)
            }
        }

        var children = [AVDetection]()
        if options.scanArchives {
            children = scanChildren(data, kind: kind, level: level)
        }

        // A container's raw bytes include stored members, so the same signature often matches
        // both; keep the more specific detection (the member's).
        let childNames = Set(children.map(\.signatureName))
        var all = found.filter { !childNames.contains($0.signatureName) } + children
        if !all.isEmpty, let db = core.database, isAllowListed(&digests, db: db) {
            all = []
        }
        if level.depth == 0 { rootDigests = digests }
        return all
    }

    // MARK: Hashes

    /// Hash signatures, computed only when a signature of that digest type has this file's size
    /// (or any size). Wildcard-size signatures named for platforms whose files can't be Mach-O
    /// (`Win.`, `Html.`...) aren't checked against Mach-O files, which saves an MD5 of every
    /// executable (all such signatures in ClamAV's current database are Windows/HTML exploits).
    private func checkFileHashes(_ data: AVByteView, machO: Bool, sizelessLists: Bool, digests: inout AVObjectDigests,
                                 db: AVMappedDatabase, report: (String, AVThreatKind, AVSignatureSource) -> Void) {
        let size = data.count
        let useLists = sizelessLists && core.hasHashList
        let wantMD5 = (machO ? core.md5WildcardMachO : core.md5Wildcard) || db.containsSize(core.md5Sizes, size)
        let wantSHA1 = (machO ? core.sha1WildcardMachO : core.sha1Wildcard) || db.containsSize(core.sha1Sizes, size)
        let wantSHA256 = useLists || (machO ? core.sha256WildcardMachO : core.sha256Wildcard) || db.containsSize(core.sha256Sizes, size)
        guard wantMD5 || wantSHA1 || wantSHA256 else { return }
        digests.ensure(md5: wantMD5, sha1: wantSHA1, sha256: wantSHA256)
        let tables: [([UInt8]?, AVByteView)] = [(wantMD5 ? digests.md5 : nil, core.md5Table),
                                                (wantSHA1 ? digests.sha1 : nil, core.sha1Table),
                                                (wantSHA256 ? digests.sha256 : nil, core.sha256Table)]
        for (digest, table) in tables {
            guard let digest else { continue }
            for reference in db.hashMatches(table, digest: digest, size: size) {
                reportHashSignature(reference, db: db, report: report)
            }
        }
        if useLists, let sha256 = digests.sha256 {
            for source in db.hashListSources(sha256) {
                report("\(Self.sourceComponent(source)).KnownMalware", .malware, source)
            }
        }
    }

    static func sourceComponent(_ source: AVSignatureSource) -> String {
        switch source {
        case .clamav: return "ClamAV"
        case .malwareBazaar: return "MalwareBazaar"
        case .threatFox: return "ThreatFox"
        case .builtIn: return "BuiltIn"
        }
    }

    /// Hash records reference a name; the top bits carry PUA (28), test file (29), non-Mac (30).
    private func reportHashSignature(_ reference: Int, db: AVMappedDatabase, report: (String, AVThreatKind, AVSignatureSource) -> Void) {
        let isPUA = reference & (1 << 28) != 0, isTest = reference & (1 << 29) != 0, nonMac = reference & (1 << 30) != 0
        if nonMac && !options.detectNonMacThreats { return }
        if isPUA && !options.detectPUA { return }
        report(db.name(reference & 0x0FFF_FFFF), isTest ? .testFile : (isPUA ? .pua : .malware), .clamav)
    }

    /// PE section hashes (`.mdb`/`.msb`): the hash of each section's raw data, keyed by its size.
    private func checkSectionHashes(_ data: AVByteView, exe: AVExecutableInfo, db: AVMappedDatabase,
                                    report: (String, AVThreatKind, AVSignatureSource) -> Void) {
        for section in exe.sections where section.rawSize > 0 {
            guard let bytes = data.slice(section.rawOffset, section.rawSize) else { continue }
            let checks: [(Bool, AVByteView, () -> [UInt8])] = [
                (core.sectionMD5Wildcard || db.containsSize(core.sectionMD5Sizes, section.rawSize), core.sectionMD5Table, { AVDigest.md5(bytes) }),
                (core.sectionSHA1Wildcard || db.containsSize(core.sectionSHA1Sizes, section.rawSize), core.sectionSHA1Table, { AVDigest.sha1(bytes) }),
                (core.sectionSHA256Wildcard || db.containsSize(core.sectionSHA256Sizes, section.rawSize), core.sectionSHA256Table, { AVDigest.sha256(bytes) }),
            ]
            for (wanted, table, digest) in checks where wanted {
                for reference in db.hashMatches(table, digest: digest(), size: section.rawSize) {
                    reportHashSignature(reference, db: db, report: report)
                }
            }
        }
    }

    /// `.fp` / `.sfp`: a file whose hash (and size) is listed is never reported, nor is anything inside it.
    private func isAllowListed(_ digests: inout AVObjectDigests, db: AVMappedDatabase) -> Bool {
        let size = digests.data.count
        let needMD5 = !core.allowMD5.isEmpty, needSHA1 = !core.allowSHA1.isEmpty, needSHA256 = !core.allowSHA256.isEmpty
        guard needMD5 || needSHA1 || needSHA256 else { return false }
        digests.ensure(md5: needMD5, sha1: needSHA1, sha256: needSHA256)
        if let md5 = digests.md5, db.isAllowed(core.allowMD5, digest: md5, size: size) { return true }
        if let sha1 = digests.sha1, db.isAllowed(core.allowSHA1, digest: sha1, size: size) { return true }
        if let sha256 = digests.sha256, db.isAllowed(core.allowSHA256, digest: sha256, size: size) { return true }
        return false
    }

    // MARK: Archives

    private func scanChildren(_ data: AVByteView, kind: AVFileKind, level: Level) -> [AVDetection] {
        let isContainer: Bool
        switch kind {
        case .zip, .crx, .gzip, .posixTar, .oldTar, .machOUniversal: isContainer = true
        default: isContainer = hasTrailingZip(data)
        }
        guard isContainer else { return [] }
        guard level.depth < options.maxArchiveDepth else {
            limitsReached = true
            return []
        }
        switch kind {
        case .zip:
            return scanZip(data, level: level)
        case .crx:
            guard let offset = AVCRXReader.zipOffset(data), let zip = data.suffix(from: offset) else { return [] }
            return scanZip(zip, level: level)
        case .gzip:
            return scanGzip(data, level: level)
        case .posixTar, .oldTar:
            return scanTar(data, level: level, container: kind == .posixTar ? .posixTar : .oldTar)
        case .machOUniversal:
            return scanUniversal(data, level: level)
        default:
            return scanZip(data, level: level) // self-extracting: ZIP appended to another file
        }
    }

    /// A ZIP central directory at the end of a file that isn't a ZIP itself (self-extractors,
    /// scripts with an appended payload).
    private func hasTrailingZip(_ data: AVByteView) -> Bool {
        guard data.count > 22, let tail = data.suffix(from: max(0, data.count - 22 - 65535)),
              let end = tail.lastIndex(of: [0x50, 0x4B, 0x05, 0x06]) else { return false }
        let eocd = data.count - tail.count + end
        guard let directorySize = data.u32le(eocd + 12).map(Int.init), directorySize > 0, eocd - directorySize >= 0 else { return false }
        return data.u32le(eocd - directorySize) == 0x0201_4B50
    }

    /// Reserves budget for one member. Returns false (and marks the scan incomplete) when a limit is hit.
    private func admitMember(size: Int) -> Bool {
        memberCount += 1
        guard memberCount <= options.maxArchiveMembers else { limitsReached = true; return false }
        guard Int64(size) <= options.maxFileSize, extractedBytes + Int64(size) <= options.maxExtractedBytes else {
            limitsReached = true
            return false
        }
        extractedBytes += Int64(size)
        return true
    }

    private var remainingExtraction: Int {
        Int(max(0, min(options.maxExtractedBytes - extractedBytes, options.maxFileSize)))
    }

    private func scanZip(_ data: AVByteView, level: Level) -> [AVDetection] {
        let listing = AVZipReader.list(data, maxEntries: max(1, options.maxArchiveMembers - memberCount + 1),
                                       measureLimit: remainingExtraction)
        if listing.hitLimit { limitsReached = true }
        let container = Self.zipContainer(listing.entries)
        var detections = [AVDetection]()
        for entry in listing.entries where !entry.isDirectory {
            if memberCount >= options.maxArchiveMembers { limitsReached = true; break }
            if entry.isEncrypted { encryptedMembers += 1; continue }
            guard let range = AVZipReader.dataRange(of: entry, in: data), let compressed = data.slice(range.offset, range.length) else { continue }
            let name = entry.name.isEmpty ? "(unnamed)" : entry.name
            switch entry.method {
            case 0:
                guard admitMember(size: compressed.count) else { continue }
                detections += scanObject(compressed, level: level.child(name, container: container))
            case 8:
                let limit = remainingExtraction
                let output = AVInflate.inflate(compressed, wrapper: .raw, limit: limit)
                if output.hitLimit {
                    memberCount += 1
                    limitsReached = true
                    continue
                }
                guard admitMember(size: output.data.count) else { continue }
                output.data.withUnsafeBytes { raw in
                    detections += scanObject(AVByteView(raw), level: level.child(name, container: container))
                }
            default:
                unsupportedMembers += 1
            }
            if detections.count >= Self.maxDetections { break }
        }
        return detections
    }

    /// Office Open XML documents are ZIP archives; ClamAV gives their members a specific container type.
    private static func zipContainer(_ entries: [AVZipEntry]) -> AVContainerCode {
        guard entries.contains(where: { $0.name == "[Content_Types].xml" }) else { return .zip }
        if entries.contains(where: { $0.name.hasPrefix("word/") }) { return .ooxmlWord }
        if entries.contains(where: { $0.name.hasPrefix("xl/") }) { return .ooxmlExcel }
        if entries.contains(where: { $0.name.hasPrefix("ppt/") }) { return .ooxmlPowerPoint }
        return .zip
    }

    private func scanGzip(_ data: AVByteView, level: Level) -> [AVDetection] {
        let output = AVGzipReader.decompress(data, limit: remainingExtraction)
        if output.hitLimit {
            memberCount += 1
            limitsReached = true
            return []
        }
        guard !output.data.isEmpty, admitMember(size: output.data.count) else { return [] }
        var name = AVGzipReader.originalName(data) ?? ""
        if name.isEmpty {
            let base = (level.name as NSString).lastPathComponent
            if base.lowercased().hasSuffix(".tgz") { name = String(base.dropLast(4)) + ".tar" }
            else if base.lowercased().hasSuffix(".gz") { name = String(base.dropLast(3)) }
            else { name = "(decompressed)" }
        }
        return output.data.withUnsafeBytes { raw in
            scanObject(AVByteView(raw), level: level.child(name, container: .gzip))
        }
    }

    private func scanTar(_ data: AVByteView, level: Level, container: AVContainerCode) -> [AVDetection] {
        let listing = AVTarReader.list(data, maxEntries: max(1, options.maxArchiveMembers - memberCount + 1))
        if listing.hitLimit { limitsReached = true }
        var detections = [AVDetection]()
        for entry in listing.entries {
            guard let member = data.slice(entry.dataOffset, entry.size) else { continue }
            guard admitMember(size: member.count) else { continue }
            detections += scanObject(member, level: level.child(entry.name, container: container))
            if detections.count >= Self.maxDetections { break }
        }
        return detections
    }

    private func scanUniversal(_ data: AVByteView, level: Level) -> [AVDetection] {
        guard let slices = AVFatMachOReader.slices(data) else { return [] }
        var detections = [AVDetection]()
        for slice in slices {
            guard let member = data.slice(slice.offset, slice.size) else { continue }
            memberCount += 1
            guard memberCount <= options.maxArchiveMembers else { limitsReached = true; break }
            detections += scanObject(member, level: level.child(slice.architecture, container: .machOUniversal))
        }
        return detections
    }
}

/// Shared, immutable state of a loaded engine: the mapped database and cached table views.
final class AVEngineCore: @unchecked Sendable {
    let database: AVMappedDatabase?
    let regexes: AVRegexCache
    let byteCompares: [AVByteCompareSpec]

    let md5Table: AVByteView, sha1Table: AVByteView, sha256Table: AVByteView
    let md5Sizes: AVByteView, sha1Sizes: AVByteView, sha256Sizes: AVByteView
    let sectionMD5Table: AVByteView, sectionSHA1Table: AVByteView, sectionSHA256Table: AVByteView
    let sectionMD5Sizes: AVByteView, sectionSHA1Sizes: AVByteView, sectionSHA256Sizes: AVByteView
    let allowMD5: AVByteView, allowSHA1: AVByteView, allowSHA256: AVByteView
    let md5Wildcard: Bool, sha1Wildcard: Bool, sha256Wildcard: Bool
    let md5WildcardMachO: Bool, sha1WildcardMachO: Bool, sha256WildcardMachO: Bool
    let sectionMD5Wildcard: Bool, sectionSHA1Wildcard: Bool, sectionSHA256Wildcard: Bool
    let hasHashList: Bool
    /// Per target: the anchored-list patterns, indexed (see `AVAnchoredIndex`).
    let anchoredIndex: [AVAnchoredIndex]

    init(database: AVMappedDatabase?) {
        self.database = database
        let metadata = database?.metadata
        regexes = AVRegexCache(specs: metadata?.pcres ?? [])
        byteCompares = metadata?.byteCompares ?? []
        func section(_ tag: String) -> AVByteView { database?.section(tag) ?? .empty }
        md5Table = section(AVDatabaseFormat.fileMD5)
        sha1Table = section(AVDatabaseFormat.fileSHA1)
        sha256Table = section(AVDatabaseFormat.fileSHA256)
        md5Sizes = section(AVDatabaseFormat.fileMD5Sizes)
        sha1Sizes = section(AVDatabaseFormat.fileSHA1Sizes)
        sha256Sizes = section(AVDatabaseFormat.fileSHA256Sizes)
        sectionMD5Table = section(AVDatabaseFormat.sectionMD5)
        sectionSHA1Table = section(AVDatabaseFormat.sectionSHA1)
        sectionSHA256Table = section(AVDatabaseFormat.sectionSHA256)
        sectionMD5Sizes = section(AVDatabaseFormat.sectionMD5Sizes)
        sectionSHA1Sizes = section(AVDatabaseFormat.sectionSHA1Sizes)
        sectionSHA256Sizes = section(AVDatabaseFormat.sectionSHA256Sizes)
        allowMD5 = section(AVDatabaseFormat.allowMD5)
        allowSHA1 = section(AVDatabaseFormat.allowSHA1)
        allowSHA256 = section(AVDatabaseFormat.allowSHA256)
        md5Wildcard = metadata?.md5Wildcard ?? false
        sha1Wildcard = metadata?.sha1Wildcard ?? false
        sha256Wildcard = metadata?.sha256Wildcard ?? false
        md5WildcardMachO = metadata?.md5WildcardMachO ?? md5Wildcard
        sha1WildcardMachO = metadata?.sha1WildcardMachO ?? sha1Wildcard
        sha256WildcardMachO = metadata?.sha256WildcardMachO ?? sha256Wildcard
        sectionMD5Wildcard = metadata?.sectionMD5Wildcard ?? false
        sectionSHA1Wildcard = metadata?.sectionSHA1Wildcard ?? false
        sectionSHA256Wildcard = metadata?.sectionSHA256Wildcard ?? false
        hasHashList = !section(AVDatabaseFormat.hashList).isEmpty
        anchoredIndex = (0..<AVDatabaseFormat.targetCount).map { target in
            database.map { AVAnchoredIndex(database: $0, list: $0.anchoredLists[target]) } ?? AVAnchoredIndex()
        }
    }
}

/// The patterns checked at their fixed offset (no prefilter anchor), built at load: those at
/// an absolute offset that start with two exact bytes are keyed by (offset, those bytes), so a
/// file costs one lookup per distinct offset instead of one try per pattern (a family of
/// signatures may contribute hundreds of `0:8002`-style alternatives).
struct AVAnchoredIndex: Sendable {
    /// `offset << 16 | first two bytes (little-endian)` → pattern indices.
    var keyed: [UInt64: [Int32]] = [:]
    /// The distinct offsets in `keyed`, ascending.
    var offsets: [Int] = []
    /// Every other pattern of the list.
    var others: [Int32] = []

    init() {}

    init(database: AVMappedDatabase, list: AVByteView) {
        guard let count = list.u32le(0).map(Int.init) else { return }
        var offsetSet = Set<Int>()
        for k in 0..<count {
            guard let value = list.u32le(4 + k * 4) else { break }
            let index = Int(value)
            guard let pattern = database.pattern(index), pattern.offset.kind == .absolute, pattern.offset.maxShift == 0,
                  pattern.offset.value >= 0, pattern.offset.value < 1 << 40,
                  let first = pattern.program.elementOffset(0), pattern.program.bytes.u8(first) == AVProgramOp.literal.rawValue,
                  let length = pattern.program.bytes.u16le(first + 1), length >= 2,
                  let b0 = pattern.program.bytes.u8(first + 3), let b1 = pattern.program.bytes.u8(first + 4) else {
                others.append(Int32(truncatingIfNeeded: index))
                continue
            }
            let key = UInt64(pattern.offset.value) << 16 | UInt64(b0) | UInt64(b1) << 8
            keyed[key, default: []].append(Int32(truncatingIfNeeded: index))
            offsetSet.insert(pattern.offset.value)
        }
        offsets = offsetSet.sorted()
    }
}
