import Darwin
import Foundation

/// The engine's compiled database: one file, memory-mapped at load and used in place.
///
/// ```
/// header    "MCAVDB" 0 1, u32 format version, u32 section count, u64 file length, 40 bytes reserved
/// directory section count × (4-byte tag, u32 reserved, u64 offset, u64 length)
/// sections  16-byte aligned
/// ```
/// Records are fixed-size little-endian structures read with bounds-checked unaligned loads, so a
/// damaged file can make a lookup fail but can't make the engine read outside the mapping.
enum AVDatabaseFormat {
    static let magic: [UInt8] = Array("MCAVDB".utf8) + [0, 1]
    static let version: UInt32 = 1
    static let headerSize = 64
    static let directoryEntrySize = 24
    static let fileName = "engine.mcavdb"

    // Section tags.
    static let meta = "META", names = "NAME", nameOffsets = "NOFF", signatures = "SIGS", subsigs = "SUBS"
    static let patterns = "PATS", programs = "PROG", expressions = "EXPR", constraints = "CONS"
    static func prefilter(_ target: Int) -> String { String(format: "P%03d", target) }
    static func anchored(_ target: Int) -> String { String(format: "A%03d", target) }
    static func weak(_ target: Int) -> String { String(format: "W%03d", target) }
    static func deferredPrefilter(_ target: Int) -> String { String(format: "D%03d", target) }
    static func deferredList(_ target: Int) -> String { String(format: "V%03d", target) }
    static let fileMD5 = "HM05", fileSHA1 = "HS01", fileSHA256 = "HS25"
    static let fileMD5Sizes = "ZM05", fileSHA1Sizes = "ZS01", fileSHA256Sizes = "ZS25"
    static let sectionMD5 = "XM05", sectionSHA1 = "XS01", sectionSHA256 = "XS25"
    static let sectionMD5Sizes = "YM05", sectionSHA1Sizes = "YS01", sectionSHA256Sizes = "YS25"
    static let hashList = "LS25"
    static let allowMD5 = "FM05", allowSHA1 = "FS01", allowSHA256 = "FS25"

    static let signatureRecordSize = 32
    static let subsigRecordSize = 12
    static let patternRecordSize = 40
    static let constraintRecordSize = 64
    static let hashListRecordSize = 36

    /// Hash entries: digest, u32 size (`wildcardSize` = any), u32 signature.
    static func hashRecordSize(digestLength: Int) -> Int { digestLength + 8 }
    /// Allow-list entries: digest, u32 size.
    static func allowRecordSize(digestLength: Int) -> Int { digestLength + 4 }
    static let wildcardSize = UInt32.max

    /// Target types 0...12 (8 is unused by ClamAV).
    static let targetCount = 13

    // Prefilter hashing (multiplicative).
    static let bitmapMultiplier: UInt32 = 0x9E37_79B1
    static let tableMultiplier: UInt32 = 0x85EB_CA77
    static let emptySlot = UInt32.max
}

/// Signature record flags.
struct AVSignatureFlags: OptionSet, Sendable {
    let rawValue: UInt16
    static let pua = AVSignatureFlags(rawValue: 1)
    static let testFile = AVSignatureFlags(rawValue: 2)
    static let nonMac = AVSignatureFlags(rawValue: 4)
    static let logical = AVSignatureFlags(rawValue: 8)
    static let hasConstraints = AVSignatureFlags(rawValue: 16)
}

/// Pattern record flags.
struct AVPatternFlags: OptionSet, Sendable {
    let rawValue: UInt8
    static let fullword = AVPatternFlags(rawValue: 1)
    static let wide = AVPatternFlags(rawValue: 2)
}

/// Container types this engine can produce, for `Container:` / `Intermediates:` constraints.
enum AVContainerCode: UInt8, CaseIterable, Sendable {
    case any = 1, zip, gzip, posixTar, oldTar, machOUniversal, ooxmlWord, ooxmlExcel, ooxmlPowerPoint, html

    init?(clamType: String) {
        switch clamType {
        case "CL_TYPE_ANY": self = .any
        case "CL_TYPE_ZIP": self = .zip
        case "CL_TYPE_GZ": self = .gzip
        case "CL_TYPE_POSIX_TAR": self = .posixTar
        case "CL_TYPE_OLD_TAR": self = .oldTar
        case "CL_TYPE_MACHO_UNIBIN": self = .machOUniversal
        case "CL_TYPE_OOXML_WORD": self = .ooxmlWord
        case "CL_TYPE_OOXML_XL": self = .ooxmlExcel
        case "CL_TYPE_OOXML_PPT": self = .ooxmlPowerPoint
        case "CL_TYPE_HTML": self = .html
        default: return nil
        }
    }
}

/// Appends little-endian values to a byte buffer.
struct AVBinaryWriter {
    var bytes = [UInt8]()

    init(capacity: Int = 0) { bytes.reserveCapacity(capacity) }

    var count: Int { bytes.count }

    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func i32(_ value: Int32) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func append(_ data: [UInt8]) { bytes.append(contentsOf: data) }
    mutating func append(_ data: some Sequence<UInt8>) { bytes.append(contentsOf: data) }
    mutating func zeros(_ count: Int) { bytes.append(contentsOf: repeatElement(0, count: count)) }
    mutating func align(_ alignment: Int) {
        let remainder = bytes.count % alignment
        if remainder != 0 { zeros(alignment - remainder) }
    }
}

/// Database metadata stored as JSON in the META section.
struct AVDatabaseMetadata: Codable, Sendable {
    var formatVersion: UInt32
    var engineFunctionalityLevel: Int
    var summary: AVDatabaseSummary
    var md5Wildcard = false
    var sha1Wildcard = false
    var sha256Wildcard = false
    /// Wildcard-size signatures that may apply to Mach-O files (nil in databases from before this field).
    var md5WildcardMachO: Bool?
    var sha1WildcardMachO: Bool?
    var sha256WildcardMachO: Bool?
    var sectionMD5Wildcard = false
    var sectionSHA1Wildcard = false
    var sectionSHA256Wildcard = false
    var pcres: [AVPCRESpec] = []
    var byteCompares: [AVByteCompareSpec] = []
    /// Whether each target type has patterns without a usable anchor (scanned the slow way).
    var weakTargets: [Int] = []
}

/// A memory-mapped compiled database. Immutable and safe to share between threads.
final class AVMappedDatabase: @unchecked Sendable {
    let metadata: AVDatabaseMetadata
    private let mapping: UnsafeMutableRawPointer
    private let length: Int
    let view: AVByteView
    private var sections: [String: AVByteView] = [:]

    // Cached section views for the hot paths.
    let signatureTable: AVByteView
    let subsigTable: AVByteView
    let patternTable: AVByteView
    let programs: AVByteView
    let expressions: AVByteView
    let constraintTable: AVByteView
    let names: AVByteView
    let nameOffsets: AVByteView
    let prefilters: [AVPrefilterTable?]
    let deferredPrefilters: [AVPrefilterTable?]
    let anchoredLists: [AVByteView]
    let weakLists: [AVByteView]
    let deferredLists: [AVByteView]
    let nameCount: Int
    let namesPerBlock: Int

    let signatureCount: Int
    let patternCount: Int
    let subsigCount: Int

    init(url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { throw AVEngineError.notInstalled }
            throw AVEngineError.invalidDatabase("the compiled database can't be opened (\(String(cString: strerror(errno)))).")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= AVDatabaseFormat.headerSize else {
            throw AVEngineError.invalidDatabase("the compiled database is truncated.")
        }
        let size = Int(info.st_size)
        guard let address = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), address != MAP_FAILED else {
            throw AVEngineError.invalidDatabase("the compiled database can't be mapped (\(String(cString: strerror(errno)))).")
        }
        mapping = address
        length = size
        let view = AVByteView(base: UnsafeRawPointer(address), count: size)
        self.view = view

        var parsed = [String: AVByteView]()
        do {
            guard view.matches(AVDatabaseFormat.magic, at: 0) else {
                throw AVEngineError.invalidDatabase("the compiled database has an unknown format.")
            }
            guard view.u32le(8) == AVDatabaseFormat.version else {
                throw AVEngineError.invalidDatabase("the compiled database was built by a different version of the app.")
            }
            guard let sectionCount = view.u32le(12).map(Int.init), sectionCount < 1024,
                  let declaredLength = view.u64le(16), declaredLength == UInt64(size) else {
                throw AVEngineError.invalidDatabase("the compiled database is truncated.")
            }
            for index in 0..<sectionCount {
                let entry = AVDatabaseFormat.headerSize + index * AVDatabaseFormat.directoryEntrySize
                guard let tagBytes = view.slice(entry, 4), let offset = view.u64le(entry + 8).flatMap({ Int(exactly: $0) }),
                      let sectionLength = view.u64le(entry + 16).flatMap({ Int(exactly: $0) }),
                      let section = view.slice(offset, sectionLength) else {
                    throw AVEngineError.invalidDatabase("the compiled database has a damaged section table.")
                }
                parsed[String(decoding: tagBytes.buffer, as: UTF8.self)] = section
            }
            guard let metaView = parsed[AVDatabaseFormat.meta] else {
                throw AVEngineError.invalidDatabase("the compiled database has no metadata.")
            }
            metadata = try JSONDecoder().decode(AVDatabaseMetadata.self, from: Data(metaView.buffer))
        } catch {
            munmap(address, size)
            if let engineError = error as? AVEngineError { throw engineError }
            throw AVEngineError.invalidDatabase("the compiled database's metadata can't be read.")
        }
        sections = parsed
        func section(_ tag: String) -> AVByteView { parsed[tag] ?? .empty }
        signatureTable = section(AVDatabaseFormat.signatures)
        subsigTable = section(AVDatabaseFormat.subsigs)
        patternTable = section(AVDatabaseFormat.patterns)
        programs = section(AVDatabaseFormat.programs)
        expressions = section(AVDatabaseFormat.expressions)
        constraintTable = section(AVDatabaseFormat.constraints)
        names = section(AVDatabaseFormat.names)
        nameOffsets = section(AVDatabaseFormat.nameOffsets)
        signatureCount = signatureTable.count / AVDatabaseFormat.signatureRecordSize
        patternCount = patternTable.count / AVDatabaseFormat.patternRecordSize
        subsigCount = subsigTable.count / AVDatabaseFormat.subsigRecordSize
        prefilters = (0..<AVDatabaseFormat.targetCount).map { AVPrefilterTable(parsed[AVDatabaseFormat.prefilter($0)]) }
        deferredPrefilters = (0..<AVDatabaseFormat.targetCount).map { AVPrefilterTable(parsed[AVDatabaseFormat.deferredPrefilter($0)]) }
        anchoredLists = (0..<AVDatabaseFormat.targetCount).map { section(AVDatabaseFormat.anchored($0)) }
        weakLists = (0..<AVDatabaseFormat.targetCount).map { section(AVDatabaseFormat.weak($0)) }
        deferredLists = (0..<AVDatabaseFormat.targetCount).map { section(AVDatabaseFormat.deferredList($0)) }
        nameCount = nameOffsets.u32le(0).map(Int.init) ?? 0
        namesPerBlock = max(1, nameOffsets.u32le(4).map(Int.init) ?? 1)
        // Hint the kernel that table lookups are random access.
        madvise(address, size, MADV_RANDOM)
    }

    deinit {
        munmap(mapping, length)
    }

    func section(_ tag: String) -> AVByteView { sections[tag] ?? .empty }

    // MARK: Records

    struct Signature {
        var nameIndex: Int
        var flags: AVSignatureFlags
        var target: Int
        var subsigCount: Int
        var expression: AVByteView
        var firstSubsig: Int
        var constraintIndex: Int?
        var source: AVSignatureSource
        var kind: AVThreatKind
    }

    func signature(_ index: Int) -> Signature? {
        let base = index * AVDatabaseFormat.signatureRecordSize
        guard index >= 0, index < signatureCount,
              let nameIndex = signatureTable.u32le(base), let flags = signatureTable.u16le(base + 4),
              let target = signatureTable.u8(base + 6), let subsigCount = signatureTable.u8(base + 7),
              let exprOffset = signatureTable.u32le(base + 8), let exprLength = signatureTable.u32le(base + 12),
              let firstSubsig = signatureTable.u32le(base + 16), let constraint = signatureTable.u32le(base + 20),
              let sourceIndex = signatureTable.u8(base + 24), let kindIndex = signatureTable.u8(base + 25) else { return nil }
        let expression = expressions.slice(Int(exprOffset), Int(exprLength)) ?? .empty
        let sources = AVSignatureSource.allCases
        let source = Int(sourceIndex) < sources.count ? sources[Int(sourceIndex)] : .clamav
        let kind: AVThreatKind = kindIndex == 1 ? .pua : (kindIndex == 2 ? .testFile : .malware)
        return Signature(nameIndex: Int(nameIndex), flags: AVSignatureFlags(rawValue: flags), target: Int(target),
                         subsigCount: Int(subsigCount), expression: expression, firstSubsig: Int(firstSubsig),
                         constraintIndex: constraint == UInt32.max ? nil : Int(constraint), source: source, kind: kind)
    }

    /// Flags only (hot path for PUA / non-Mac filtering).
    @inline(__always)
    func signatureFlags(_ index: Int) -> AVSignatureFlags? {
        signatureTable.u16le(index * AVDatabaseFormat.signatureRecordSize + 4).map(AVSignatureFlags.init(rawValue:))
    }

    /// Names are stored in DEFLATE-compressed blocks (they're only needed when something matched).
    func name(_ index: Int) -> String {
        guard index >= 0, index < nameCount else { return "Unknown" }
        let block = index / namesPerBlock
        guard let offset = nameOffsets.u32le(8 + block * 8).map(Int.init), let length = nameOffsets.u32le(12 + block * 8).map(Int.init),
              let compressed = names.slice(offset, length) else { return "Unknown" }
        let output = AVInflate.inflate(compressed, wrapper: .raw, limit: 1 << 20)
        guard output.complete else { return "Unknown" }
        let wanted = index % namesPerBlock
        var current = 0
        var lineStart = 0
        let bytes = [UInt8](output.data)
        for position in 0...bytes.count where position == bytes.count || bytes[position] == 0x0A {
            if current == wanted { return String(decoding: bytes[lineStart..<position], as: UTF8.self) }
            current += 1
            lineStart = position + 1
        }
        return "Unknown"
    }

    struct Subsig {
        enum Kind: UInt8 { case body = 0, pcre = 1, byteCompare = 2 }
        var kind: Kind
        var isTrigger: Bool
        var needsPositions: Bool
        var patternCount: Int
        var first: Int
        var neededCount: Int
    }

    func subsig(_ index: Int) -> Subsig? {
        let base = index * AVDatabaseFormat.subsigRecordSize
        guard index >= 0, index < subsigCount, let kindRaw = subsigTable.u8(base), let kind = Subsig.Kind(rawValue: kindRaw),
              let flags = subsigTable.u8(base + 1), let count = subsigTable.u16le(base + 2),
              let first = subsigTable.u32le(base + 4), let needed = subsigTable.u32le(base + 8) else { return nil }
        return Subsig(kind: kind, isTrigger: flags & 1 != 0, needsPositions: flags & 2 != 0, patternCount: Int(count),
                      first: Int(first), neededCount: needed == UInt32.max ? Int.max : Int(needed))
    }

    struct Pattern {
        var signature: Int
        var program: AVProgramView
        var anchorElement: Int?
        var anchorDelta: Int
        var subsig: Int?
        var flags: AVPatternFlags
        var offset: AVOffsetSpec
        var leftAssertion: AVSpecialClass?
        var rightAssertion: AVSpecialClass?
        var minLength: Int
    }

    func pattern(_ index: Int) -> Pattern? {
        let base = index * AVDatabaseFormat.patternRecordSize
        guard index >= 0, index < patternCount,
              let signature = patternTable.u32le(base), let progOffset = patternTable.u32le(base + 4),
              let progLength = patternTable.u32le(base + 8), let anchorElement = patternTable.u16le(base + 12),
              let anchorDelta = patternTable.u16le(base + 14), let subsig = patternTable.u8(base + 16),
              let flags = patternTable.u8(base + 17), let offsetKind = patternTable.u8(base + 18),
              let left = patternTable.u8(base + 19), let offsetValue = patternTable.u32le(base + 20),
              let maxShift = patternTable.u32le(base + 24), let section = patternTable.u16le(base + 28),
              let right = patternTable.u8(base + 30), let minLength = patternTable.u32le(base + 32),
              let programBytes = programs.slice(Int(progOffset), Int(progLength)),
              let program = AVProgramView(programBytes),
              let kind = AVOffsetSpec.Kind(rawValue: offsetKind) else { return nil }
        let offset = AVOffsetSpec(kind: kind, value: Int(Int32(bitPattern: offsetValue)), section: Int(section), maxShift: Int(maxShift))
        return Pattern(signature: Int(signature), program: program, anchorElement: anchorElement == 0xFFFF ? nil : Int(anchorElement),
                       anchorDelta: Int(anchorDelta), subsig: subsig == 0xFF ? nil : Int(subsig), flags: AVPatternFlags(rawValue: flags),
                       offset: offset, leftAssertion: AVSpecialClass(rawValue: left), rightAssertion: AVSpecialClass(rawValue: right),
                       minLength: Int(minLength))
    }

    func constraints(_ index: Int) -> AVStoredConstraints? {
        AVStoredConstraints(constraintTable.slice(index * AVDatabaseFormat.constraintRecordSize, AVDatabaseFormat.constraintRecordSize))
    }

    // MARK: Sorted tables

    /// Binary search in a table of fixed-size records sorted by their first `keyLength` bytes.
    /// Returns the index of the first record whose key equals `key`.
    func lowerBound(_ table: AVByteView, recordSize: Int, key: [UInt8]) -> Int? {
        guard recordSize > 0, let tableBase = table.base else { return nil }
        let count = table.count / recordSize
        var low = 0, high = count
        let keyLength = key.count
        return key.withUnsafeBytes { keyBytes -> Int? in
            guard let keyBase = keyBytes.baseAddress else { return nil }
            while low < high {
                let mid = (low + high) / 2
                if memcmp(tableBase + mid * recordSize, keyBase, keyLength) < 0 { low = mid + 1 } else { high = mid }
            }
            guard low < count, memcmp(tableBase + low * recordSize, keyBase, keyLength) == 0 else { return nil }
            return low
        }
    }

    /// Signatures of the hash records matching `digest` with size `size` (or the wildcard size).
    func hashMatches(_ table: AVByteView, digest: [UInt8], size: Int) -> [Int] {
        let recordSize = AVDatabaseFormat.hashRecordSize(digestLength: digest.count)
        guard var index = lowerBound(table, recordSize: recordSize, key: digest) else { return [] }
        var result = [Int]()
        let count = table.count / recordSize
        while index < count, table.matches(digest, at: index * recordSize) {
            if let recordSize32 = table.u32le(index * recordSize + digest.count), let signature = table.u32le(index * recordSize + digest.count + 4),
               recordSize32 == AVDatabaseFormat.wildcardSize || Int(recordSize32) == size {
                result.append(Int(signature))
            }
            index += 1
        }
        return result
    }

    /// `true` when `size` is in a sorted u32 size table.
    func containsSize(_ table: AVByteView, _ size: Int) -> Bool {
        guard size >= 0, size < Int(UInt32.max), let base = table.base else { return false }
        let count = table.count / 4
        var low = 0, high = count
        let target = UInt32(size)
        while low < high {
            let mid = (low + high) / 2
            let value = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: mid * 4, as: UInt32.self))
            if value < target { low = mid + 1 } else { high = mid }
        }
        return low < count && UInt32(littleEndian: base.loadUnaligned(fromByteOffset: low * 4, as: UInt32.self)) == target
    }

    /// Allow-list lookup (digest + size; the wildcard size allows any size).
    func isAllowed(_ table: AVByteView, digest: [UInt8], size: Int) -> Bool {
        let recordSize = AVDatabaseFormat.allowRecordSize(digestLength: digest.count)
        guard var index = lowerBound(table, recordSize: recordSize, key: digest) else { return false }
        let count = table.count / recordSize
        while index < count, table.matches(digest, at: index * recordSize) {
            if let stored = table.u32le(index * recordSize + digest.count), stored == AVDatabaseFormat.wildcardSize || Int(stored) == size {
                return true
            }
            index += 1
        }
        return false
    }

    /// Sources listing `digest` in the SHA-256 hash lists.
    func hashListSources(_ digest: [UInt8]) -> [AVSignatureSource] {
        let table = section(AVDatabaseFormat.hashList)
        guard var index = lowerBound(table, recordSize: AVDatabaseFormat.hashListRecordSize, key: digest) else { return [] }
        let count = table.count / AVDatabaseFormat.hashListRecordSize
        var sources = [AVSignatureSource]()
        let all = AVSignatureSource.allCases
        while index < count, table.matches(digest, at: index * AVDatabaseFormat.hashListRecordSize) {
            if let raw = table.u32le(index * AVDatabaseFormat.hashListRecordSize + 32), Int(raw) < all.count, !sources.contains(all[Int(raw)]) {
                sources.append(all[Int(raw)])
            }
            index += 1
        }
        return sources
    }
}

/// Target description constraints as stored (64-byte record).
struct AVStoredConstraints {
    var fileSize: ClosedRange<UInt64>?
    var entryPoint: ClosedRange<UInt32>?
    var numberOfSections: ClosedRange<UInt16>?
    var container: AVContainerCode?
    var intermediates: [AVContainerCode]?

    init?(_ record: AVByteView?) {
        guard let record, let flags = record.u8(0) else { return nil }
        if flags & 1 != 0, let low = record.u64le(8), let high = record.u64le(16), low <= high { fileSize = low...high }
        if flags & 2 != 0, let low = record.u32le(24), let high = record.u32le(28), low <= high { entryPoint = low...high }
        if flags & 4 != 0, let low = record.u16le(32), let high = record.u16le(34), low <= high { numberOfSections = low...high }
        if flags & 8 != 0, let code = record.u8(1) { container = AVContainerCode(rawValue: code) }
        if flags & 16 != 0, let count = record.u8(2) {
            intermediates = (0..<min(Int(count), 16)).compactMap { record.u8(36 + $0).flatMap(AVContainerCode.init(rawValue:)) }
        }
    }

    static func encode(_ constraints: AVTargetConstraints) throws -> [UInt8] {
        var writer = AVBinaryWriter(capacity: AVDatabaseFormat.constraintRecordSize)
        var flags: UInt8 = 0
        if constraints.fileSize != nil { flags |= 1 }
        if constraints.entryPoint != nil { flags |= 2 }
        if constraints.numberOfSections != nil { flags |= 4 }
        var containerCode: UInt8 = 0
        if let container = constraints.container {
            guard let code = AVContainerCode(clamType: container) else {
                throw AVSignatureRejection("container type \(container) isn't extracted by this engine")
            }
            flags |= 8
            containerCode = code.rawValue
        }
        var chain = [UInt8]()
        if let intermediates = constraints.intermediates {
            for type in intermediates {
                guard let code = AVContainerCode(clamType: type) else {
                    throw AVSignatureRejection("container type \(type) isn't extracted by this engine")
                }
                chain.append(code.rawValue)
            }
            flags |= 16
        }
        writer.u8(flags)
        writer.u8(containerCode)
        writer.u8(UInt8(chain.count))
        writer.u8(0)
        writer.zeros(4)
        writer.u64(UInt64(constraints.fileSize?.lowerBound ?? 0))
        writer.u64(UInt64(clamping: constraints.fileSize?.upperBound ?? 0))
        writer.u32(UInt32(clamping: constraints.entryPoint?.lowerBound ?? 0))
        writer.u32(UInt32(clamping: constraints.entryPoint?.upperBound ?? 0))
        writer.u16(UInt16(clamping: constraints.numberOfSections?.lowerBound ?? 0))
        writer.u16(UInt16(clamping: constraints.numberOfSections?.upperBound ?? 0))
        writer.append(chain)
        writer.zeros(AVDatabaseFormat.constraintRecordSize - writer.count)
        return writer.bytes
    }
}

/// One target type's prefilter: a bitmap over hashed 4-byte anchors and a hash table from
/// anchor value to the patterns that use it.
struct AVPrefilterTable {
    let bitmap: UnsafePointer<UInt64>
    let bitmapShift: UInt32
    let slots: UnsafeRawPointer
    let slotMask: Int
    let tableShift: UInt32
    let candidates: AVByteView
    let anchorCount: Int

    init?(_ section: AVByteView?) {
        guard let section, let bitmapLog2 = section.u32le(0), let tableLog2 = section.u32le(4),
              let candidateCount = section.u32le(8).map(Int.init), let anchorCount = section.u32le(12),
              bitmapLog2 >= 6, bitmapLog2 <= 32, tableLog2 >= 1, tableLog2 <= 30 else { return nil }
        let bitmapBytes = (1 << Int(bitmapLog2)) / 8
        let slotBytes = (1 << Int(tableLog2)) * 8
        guard let bitmapView = section.slice(16, bitmapBytes), let bitmapBase = bitmapView.base,
              let slotView = section.slice(16 + bitmapBytes, slotBytes), let slotBase = slotView.base,
              let candidates = section.slice(16 + bitmapBytes + slotBytes, candidateCount * 4) else { return nil }
        bitmap = bitmapBase.assumingMemoryBound(to: UInt64.self)
        bitmapShift = 32 - bitmapLog2
        slots = slotBase
        slotMask = (1 << Int(tableLog2)) - 1
        tableShift = 32 - tableLog2
        self.candidates = candidates
        self.anchorCount = Int(anchorCount)
    }

    /// Pattern indices registered for an anchor value (`count` entries starting at the returned index).
    @inline(__always)
    func lookup(_ value: UInt32) -> (start: Int, count: Int)? {
        var slot = Int((value &* AVDatabaseFormat.tableMultiplier) &>> tableShift)
        var probes = 0
        while probes <= slotMask {
            let key = UInt32(littleEndian: slots.loadUnaligned(fromByteOffset: slot * 8, as: UInt32.self))
            let start = UInt32(littleEndian: slots.loadUnaligned(fromByteOffset: slot * 8 + 4, as: UInt32.self))
            if start == AVDatabaseFormat.emptySlot { return nil }
            if key == value {
                guard let count = candidates.u32le(Int(start) * 4) else { return nil }
                return (Int(start) + 1, Int(count))
            }
            slot = (slot + 1) & slotMask
            probes += 1
        }
        return nil
    }

    @inline(__always)
    func candidate(_ index: Int) -> Int? {
        candidates.u32le(index * 4).map(Int.init)
    }
}
