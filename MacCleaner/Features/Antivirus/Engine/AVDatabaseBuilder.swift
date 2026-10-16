import Foundation

/// How many signatures of one database file were used.
struct AVSignatureFileCoverage: Codable, Sendable, Hashable {
    /// Signatures the engine uses.
    var loaded = 0
    /// Signatures skipped because they use features this engine doesn't implement.
    var unsupported = 0
    /// Signatures deliberately left out: listed in `.ign`/`.ign2`, or retired by ClamAV for
    /// newer engines (maximum functionality level below this engine's).
    var ignored = 0
    /// Why signatures were unsupported, with counts.
    var reasons: [String: Int] = [:]
}

/// Signature coverage of a compiled database, per database file (`main.ndb`, `daily.ldb`...).
struct AVSignatureCoverage: Codable, Sendable, Hashable {
    var files: [String: AVSignatureFileCoverage] = [:]

    /// Totals per file type (`ndb`, `ldb`...), merging main and daily.
    var byType: [String: AVSignatureFileCoverage] {
        var result = [String: AVSignatureFileCoverage]()
        for (name, coverage) in files {
            let type = (name as NSString).pathExtension
            var total = result[type] ?? AVSignatureFileCoverage()
            total.loaded += coverage.loaded
            total.unsupported += coverage.unsupported
            total.ignored += coverage.ignored
            for (reason, count) in coverage.reasons { total.reasons[reason, default: 0] += count }
            result[type] = total
        }
        return result
    }
}

/// Signature names and entries to ignore (`.ign`, `.ign2`).
struct AVIgnoreList: Sendable {
    /// Names ignored whatever their definition.
    var names = Set<String>()
    /// Names ignored only while their database line has this MD5 (hex).
    var namesWithDigest = [String: Set<String>]()

    mutating func merge(_ other: AVIgnoreList) {
        names.formUnion(other.names)
        for (name, digests) in other.namesWithDigest { namesWithDigest[name, default: []].formUnion(digests) }
    }

    func ignores(_ name: String, line: () -> [UInt8]) -> Bool {
        if names.contains(name) { return true }
        if let digests = namesWithDigest[name] {
            return digests.contains(AVHex.string(AVDigest.md5(Data(line()))))
        }
        return false
    }
}

/// Compiles parsed ClamAV databases and hash lists into the engine's binary database.
///
/// Matching strategy, decided here at compile time:
/// * Every body pattern gets an *anchor*: its rarest 4-byte window of exact (or case-folded /
///   nibble, ≤ 16 variants) bytes. The scanner hashes every 4-byte window of the input into a
///   bitmap and only looks further when the bitmap bit of an anchor is set.
/// * Logical signatures only need one of their subsignatures in that main pass: the analysis in
///   `AVLogicalAnalysis.requiredSet` picks a set of "trigger" subsignatures such that the
///   signature can't match unless one of them did. The remaining ("deferred") subsignatures go
///   into a second table that is only scanned when a trigger matched in that file.
/// * Each prefilter entry carries two more bytes of its pattern at fixed distances from the
///   anchor (`AVQuickCheck`), compared before any other work: many signatures can only be
///   anchored on content that is everywhere in some files (zero runs and padding in executables,
///   a shared word in scripts). Patterns at a fixed offset also store where their anchor element
///   can sit relative to their start, so hits far from that offset are dropped right away.
/// * Patterns at a fixed offset without a usable anchor are checked directly at their offset;
///   floating patterns without one but with a 2–3 byte exact run go into a 2-byte-keyed table
///   (`S…`); the few left ("weak") are searched one by one.
final class AVDatabaseBuilder {
    /// The ClamAV functionality level this engine implements (see `AVEngine.functionalityLevel`).
    let functionalityLevel: Int
    private(set) var coverage = AVSignatureCoverage()
    var ignoreList = AVIgnoreList()

    // Names, concatenated (block-compressed when written): name i is nameBytes[nameEnds[i-1]..<nameEnds[i]].
    var nameBytes = [UInt8]()
    var nameEnds = [UInt32]()
    var nameCount: Int { nameEnds.count }

    // Body and logical signatures.
    var signatureRecords = AVBinaryWriter()
    var signatureCount = 0
    var subsigRecords = AVBinaryWriter()
    var subsigCount = 0
    var patternRecords = AVBinaryWriter()
    var patternCount = 0
    /// Per pattern: its `AVQuickCheck` bytes (stored next to its prefilter entries).
    var patternChecks = [UInt64]()
    var programBytes = AVBinaryWriter()
    var expressionBytes = AVBinaryWriter()
    var constraintRecords = AVBinaryWriter()
    var constraintCount = 0
    var pcres = [AVPCRESpec]()
    var byteCompares = [AVByteCompareSpec]()

    /// Per target: (anchor << 32 | pattern) for the main pass and for deferred subsignatures.
    var triggerAnchors = [[UInt64]](repeating: [], count: AVDatabaseFormat.targetCount)
    var deferredAnchors = [[UInt64]](repeating: [], count: AVDatabaseFormat.targetCount)
    /// How many patterns use each 4-byte anchor value (for spreading anchors, see AVProgramEncoder).
    var anchorLoad = [UInt32: Int32]()

    func crowding(_ value: UInt32) -> Int { Int(anchorLoad[value] ?? 0) }

    func encode(_ pattern: AVPatternIR) throws -> AVProgramEncoder.Encoded {
        try AVProgramEncoder.encode(pattern, crowding: crowding)
    }

    /// Per target: patterns checked directly at their offset / scanned without an anchor.
    var anchoredPatterns = [[UInt32]](repeating: [], count: AVDatabaseFormat.targetCount)
    var weakPatterns = [[UInt32]](repeating: [], count: AVDatabaseFormat.targetCount)
    var deferredListPatterns = [[UInt32]](repeating: [], count: AVDatabaseFormat.targetCount)
    /// Per target: (2-byte key << 32 | pattern) for floating patterns whose longest exact run is
    /// 2–3 bytes, found in one shared pass instead of one search per pattern.
    var shortAnchors = [[UInt64]](repeating: [], count: AVDatabaseFormat.targetCount)

    /// Digest lengths of MD5, SHA-1 and SHA-256, the index used by the hash tables below.
    static let digestLengths = [16, 20, 32]
    static func digestSlot(_ length: Int) -> Int? { digestLengths.firstIndex(of: length) }

    // Hash signatures: flat records (digest, u32 size, u32 name reference), per digest type.
    var fileHashes = [AVBinaryWriter](repeating: AVBinaryWriter(), count: 3)
    var sectionHashes = [AVBinaryWriter](repeating: AVBinaryWriter(), count: 3)
    var fileHashWildcard = [Bool](repeating: false, count: 3)
    /// Some wildcard-size file hash signature could apply to a Mach-O file (by its platform name).
    var fileHashWildcardMachO = [Bool](repeating: false, count: 3)
    var sectionHashWildcard = [Bool](repeating: false, count: 3)
    var allowHashes = [AVBinaryWriter](repeating: AVBinaryWriter(), count: 3)
    var hashList = AVBinaryWriter()
    var hashListCount = 0

    var bodySignatureCount = 0
    var logicalSignatureCount = 0
    var hashSignatureCount = 0

    init(functionalityLevel: Int) {
        self.functionalityLevel = functionalityLevel
    }

    // MARK: - Coverage helpers

    func loaded(_ file: String, _ count: Int = 1) {
        coverage.files[file, default: AVSignatureFileCoverage()].loaded += count
    }

    func unsupported(_ file: String, _ reason: String, _ count: Int = 1) {
        var entry = coverage.files[file, default: AVSignatureFileCoverage()]
        entry.unsupported += count
        entry.reasons[reason, default: 0] += count
        coverage.files[file] = entry
    }

    func ignored(_ file: String, _ count: Int = 1) {
        coverage.files[file, default: AVSignatureFileCoverage()].ignored += count
    }

    func addName(_ bytes: some Collection<UInt8>) -> Int {
        nameBytes.append(contentsOf: bytes)
        nameEnds.append(UInt32(truncatingIfNeeded: nameBytes.count))
        return nameEnds.count - 1
    }

    func name(at index: Int) -> ArraySlice<UInt8> {
        let start = index == 0 ? 0 : Int(nameEnds[index - 1])
        return nameBytes[start..<Int(nameEnds[index])]
    }

    // MARK: - ClamAV databases

    /// File types that hold signatures this engine doesn't use at all.
    static let unusedFileTypes: [String: String] = [
        "cdb": "container metadata signatures aren't supported",
        "crb": "Authenticode certificate rules aren't supported",
        "cat": "Authenticode certificate rules aren't supported",
        "idb": "icon signatures aren't supported",
        "pdb": "phishing URL signatures aren't supported",
        "gdb": "phishing URL signatures aren't supported",
        "wdb": "phishing URL signatures aren't supported",
        "cbc": "bytecode signatures aren't supported",
        "yar": "YARA rules aren't supported",
        "yara": "YARA rules aren't supported",
        "imp": "PE import table hashes aren't supported",
        "pwdb": "archive passwords aren't used",
    ]

    /// Collects `.ign`/`.ign2` entries. Call for every database before `add(_:)`, because ClamAV's
    /// ignore lists (shipped in daily) apply to all databases.
    func collectIgnores(from database: ClamAVUnpackedDatabase) {
        ignoreList.merge(Self.ignoreList(in: database))
    }

    /// The `.ign` (legacy `db:line:name`) and `.ign2` (`name` or `name:md5-of-the-line`) entries of a database.
    static func ignoreList(in database: ClamAVUnpackedDatabase) -> AVIgnoreList {
        var ignoreList = AVIgnoreList()
        for name in database.fileNames {
            let type = (name as NSString).pathExtension
            guard type == "ign" || type == "ign2" else { continue }
            database.withFile(name) { view in
                AVLineParser.forEachLine(view) { line in
                    let fields = AVLineParser.split(line, UInt8(ascii: ":"))
                    if type == "ign" {
                        // db:line:name (legacy); only the name matters.
                        if let last = fields.last { ignoreList.names.insert(AVLineParser.string(last)) }
                    } else if fields.count >= 2, fields[1].count == 32 {
                        ignoreList.namesWithDigest[AVLineParser.string(fields[0]), default: []].insert(AVLineParser.string(fields[1]).lowercased())
                    } else if let first = fields.first {
                        ignoreList.names.insert(AVLineParser.string(first))
                    }
                }
            }
        }
        return ignoreList
    }

    func add(_ database: ClamAVUnpackedDatabase) throws {
        for name in database.fileNames {
            let type = (name as NSString).pathExtension.lowercased()
            try database.withFile(name) { view in
                switch type {
                case "hdb", "hdu", "hsb", "hsu":
                    parseFileHashes(view, file: name, pua: type.hasSuffix("u"))
                case "mdb", "mdu", "msb", "msu":
                    parseSectionHashes(view, file: name, pua: type.hasSuffix("u"))
                case "fp", "sfp":
                    parseAllowList(view, file: name)
                case "ndb", "ndu":
                    try parseBodySignatures(view, file: name, pua: type.hasSuffix("u"))
                case "ldb", "ldu":
                    try parseLogicalSignatures(view, file: name, pua: type.hasSuffix("u"))
                case "ign", "ign2", "info", "cfg", "ftm":
                    break // ignore lists were collected first; info/cfg/ftm aren't signatures
                default:
                    if let reason = Self.unusedFileTypes[type] {
                        var count = 0
                        AVLineParser.forEachLine(view) { _ in count += 1 }
                        if count > 0 { unsupported(name, reason, count) }
                    }
                }
            }
        }
    }

    // MARK: Hash signatures

    /// `hash:size:name[:minFL[:maxFL]]` (MD5, SHA-1 or SHA-256 by length; size may be `*`).
    private func parseFileHashes(_ view: AVByteView, file: String, pua: Bool) {
        AVLineParser.forEachLine(view) { line in
            let fields = AVLineParser.split(line, UInt8(ascii: ":"))
            guard fields.count >= 3 else { unsupported(file, "malformed line"); return }
            addHash(digestField: fields[0], sizeField: fields[1], nameField: fields[2], extra: Array(fields.dropFirst(3)),
                    line: line, file: file, pua: pua, section: false)
        }
    }

    /// `size:hash:name[:minFL[:maxFL]]` — PE section hashes (size and hash are swapped).
    private func parseSectionHashes(_ view: AVByteView, file: String, pua: Bool) {
        AVLineParser.forEachLine(view) { line in
            let fields = AVLineParser.split(line, UInt8(ascii: ":"))
            guard fields.count >= 3 else { unsupported(file, "malformed line"); return }
            addHash(digestField: fields[1], sizeField: fields[0], nameField: fields[2], extra: Array(fields.dropFirst(3)),
                    line: line, file: file, pua: pua, section: true)
        }
    }

    private func addHash(digestField: UnsafeBufferPointer<UInt8>, sizeField: UnsafeBufferPointer<UInt8>, nameField: UnsafeBufferPointer<UInt8>,
                         extra: [UnsafeBufferPointer<UInt8>], line: UnsafeBufferPointer<UInt8>, file: String, pua: Bool, section: Bool) {
        guard digestField.count % 2 == 0, let slot = Self.digestSlot(digestField.count / 2) else { unsupported(file, "unknown hash type"); return }
        if let level = levelRejection(extra) {
            if level == .retired { ignored(file) } else { unsupported(file, "requires a newer engine (functionality level)") }
            return
        }
        let size: UInt32
        if sizeField.count == 1 && sizeField[0] == UInt8(ascii: "*") {
            size = AVDatabaseFormat.wildcardSize
        } else {
            guard let value = AVLineParser.number(sizeField), value < Int(UInt32.max) else { unsupported(file, "file size beyond 4 GB"); return }
            size = UInt32(value)
        }
        guard digestField.allSatisfy({ AVHex.nibble($0) != nil }) else { unsupported(file, "malformed hash"); return }
        let nameString = AVLineParser.string(nameField)
        if ignoreList.ignores(nameString, line: { Array(line) }) { ignored(file); return }
        let traits = AVSignatureNaming.traits(name: nameString, fromPUADatabase: pua, target: section ? 1 : nil)
        guard nameCount < 1 << 28, nameBytes.count < Int(UInt32.max) - 4096 else { unsupported(file, "too many signatures"); return }
        let nameIndex = addName(nameField)
        var reference = UInt32(nameIndex)
        if traits.kind == .pua { reference |= 1 << 28 }
        if traits.kind == .testFile { reference |= 1 << 29 }
        if traits.nonMac { reference |= 1 << 30 }
        if section {
            _ = AVLineParser.appendHex(digestField, to: &sectionHashes[slot])
            sectionHashes[slot].u32(size)
            sectionHashes[slot].u32(reference)
            if size == AVDatabaseFormat.wildcardSize { sectionHashWildcard[slot] = true }
        } else {
            _ = AVLineParser.appendHex(digestField, to: &fileHashes[slot])
            fileHashes[slot].u32(size)
            fileHashes[slot].u32(reference)
            if size == AVDatabaseFormat.wildcardSize {
                fileHashWildcard[slot] = true
                if AVSignatureNaming.canTargetMachO(nameString) { fileHashWildcardMachO[slot] = true }
            }
        }
        hashSignatureCount += 1
        loaded(file)
    }

    /// `.fp` (MD5) and `.sfp` (SHA-1/SHA-256): `hash:size:name`; files with these hashes are never reported.
    private func parseAllowList(_ view: AVByteView, file: String) {
        AVLineParser.forEachLine(view) { line in
            let fields = AVLineParser.split(line, UInt8(ascii: ":"))
            guard fields.count >= 2 else { unsupported(file, "malformed line"); return }
            guard fields[0].count % 2 == 0, let slot = Self.digestSlot(fields[0].count / 2),
                  fields[0].allSatisfy({ AVHex.nibble($0) != nil }) else {
                unsupported(file, "unknown hash type"); return
            }
            let size: UInt32
            if fields[1].count == 1 && fields[1][0] == UInt8(ascii: "*") {
                size = AVDatabaseFormat.wildcardSize
            } else if let value = AVLineParser.number(fields[1]), value < Int(UInt32.max) {
                size = UInt32(value)
            } else {
                unsupported(file, "malformed size"); return
            }
            _ = AVLineParser.appendHex(fields[0], to: &allowHashes[slot])
            allowHashes[slot].u32(size)
            loaded(file)
        }
    }

    // MARK: Body signatures

    enum LevelRejection { case tooNew, retired }

    /// Optional `minFL[:maxFL]` fields.
    func levelRejection(_ fields: [UnsafeBufferPointer<UInt8>]) -> LevelRejection? {
        if let minField = fields.first, !minField.isEmpty, let minimum = AVLineParser.number(minField), minimum > functionalityLevel { return .tooNew }
        if fields.count >= 2, !fields[1].isEmpty, let maximum = AVLineParser.number(fields[1]), maximum < functionalityLevel { return .retired }
        return nil
    }

    /// `Name:Target:Offset:HexSignature[:MinFL[:MaxFL]]`.
    private func parseBodySignatures(_ view: AVByteView, file: String, pua: Bool) throws {
        AVLineParser.forEachLine(view) { line in
            let fields = AVLineParser.split(line, UInt8(ascii: ":"))
            guard fields.count >= 4 else { unsupported(file, "malformed line"); return }
            if let level = levelRejection(Array(fields.dropFirst(4))) {
                if level == .retired { ignored(file) } else { unsupported(file, "requires a newer engine (functionality level)") }
                return
            }
            let nameString = AVLineParser.string(fields[0])
            if ignoreList.ignores(nameString, line: { Array(line) }) { ignored(file); return }
            guard let target = AVLineParser.number(fields[1]), target >= 0, target < AVDatabaseFormat.targetCount, target != 8 else {
                unsupported(file, "unknown target type"); return
            }
            do {
                let offset = try AVSignatureParser.parseOffset(AVLineParser.string(fields[2]))
                let variants = try AVSignatureParser.parsePattern(fields[3])
                let traits = AVSignatureNaming.traits(name: nameString, fromPUADatabase: pua, target: target)
                let encoded = try variants.map { try encode($0) }
                let signature = try addSignatureRecord(name: Array(fields[0]), traits: traits, target: target, logical: false,
                                                       subsigCount: 0, expression: [], firstSubsig: 0, constraints: nil)
                for (variant, program) in zip(variants, encoded) {
                    let index = appendPattern(variant, encoded: program, offset: offset, signature: signature, subsig: nil)
                    place(index, encoded: program, offset: offset, target: target, trigger: true)
                }
                bodySignatureCount += 1
                loaded(file)
            } catch let rejection as AVSignatureRejection {
                unsupported(file, rejection.reason)
            } catch {
                unsupported(file, "malformed signature")
            }
        }
    }

    func addSignatureRecord(name: [UInt8], traits: AVSignatureTraits, target: Int, logical: Bool, subsigCount: Int,
                            expression: [UInt8], firstSubsig: Int, constraints: AVTargetConstraints?) throws -> Int {
        var flags = AVSignatureFlags()
        if traits.kind == .pua { flags.insert(.pua) }
        if traits.kind == .testFile { flags.insert(.testFile) }
        if traits.nonMac { flags.insert(.nonMac) }
        if logical { flags.insert(.logical) }
        var constraintIndex = UInt32.max
        if let constraints, !constraints.isEmpty {
            let record = try AVStoredConstraints.encode(constraints)
            constraintRecords.append(record)
            constraintIndex = UInt32(constraintCount)
            constraintCount += 1
            flags.insert(.hasConstraints)
        }
        let exprOffset = expressionBytes.count
        expressionBytes.append(expression)
        let nameIndex = addName(name)
        signatureRecords.u32(UInt32(nameIndex))
        signatureRecords.u16(flags.rawValue)
        signatureRecords.u8(UInt8(target))
        signatureRecords.u8(UInt8(subsigCount))
        signatureRecords.u32(UInt32(exprOffset))
        signatureRecords.u32(UInt32(expression.count))
        signatureRecords.u32(UInt32(firstSubsig))
        signatureRecords.u32(constraintIndex)
        signatureRecords.u8(0) // source: ClamAV
        signatureRecords.u8(traits.kind == .pua ? 1 : (traits.kind == .testFile ? 2 : 0))
        // The required container, readable without decoding the constraint record, and whether
        // anything else (size, entry point, sections, intermediates) is constrained.
        let container = constraints?.container.flatMap(AVContainerCode.init(clamType:))
        var other = constraints ?? AVTargetConstraints()
        other.container = nil
        signatureRecords.u8(container?.rawValue ?? 0)
        signatureRecords.u8(other.isEmpty ? 0 : 1)
        signatureRecords.zeros(4)
        signatureCount += 1
        return signatureCount - 1
    }

    /// Writes an encoded pattern; returns its index.
    func appendPattern(_ pattern: AVPatternIR, encoded: AVProgramEncoder.Encoded, offset: AVOffsetSpec, signature: Int, subsig: Int?) -> Int {
        let programOffset = programBytes.count
        programBytes.append(encoded.program)
        var flags = AVPatternFlags()
        if pattern.fullword { flags.insert(.fullword) }
        if pattern.wide { flags.insert(.wide) }
        patternRecords.u32(UInt32(signature))
        patternRecords.u32(UInt32(truncatingIfNeeded: programOffset))
        patternRecords.u32(UInt32(truncatingIfNeeded: encoded.program.count))
        patternRecords.u16(UInt16(encoded.anchor?.element ?? encoded.shortAnchorElement ?? 0xFFFF))
        patternRecords.u16(UInt16(encoded.anchor?.delta ?? 0))
        patternRecords.u8(UInt8(subsig ?? 0xFF))
        patternRecords.u8(flags.rawValue)
        patternRecords.u8(offset.kind.rawValue)
        patternRecords.u8(pattern.leftAssertion?.rawValue ?? 0)
        patternRecords.i32(Int32(clamping: offset.value))
        patternRecords.u32(UInt32(clamping: offset.maxShift))
        patternRecords.u16(UInt16(clamping: offset.section))
        patternRecords.u8(pattern.rightAssertion?.rawValue ?? 0)
        patternRecords.u8(0)
        patternRecords.u32(UInt32(clamping: encoded.minLength))
        // Where the anchor element can sit relative to the pattern's start, so a hit on an
        // anchored pattern far from its offset is dropped before any matching.
        let anchorElement = encoded.anchor?.element ?? encoded.shortAnchorElement
        let bounds = anchorElement.map { AVQuickCheck.prefixBounds(program: encoded.program, before: $0) } ?? (min: 0, max: 0xFFFF)
        patternRecords.u16(bounds.min)
        patternRecords.u16(bounds.max)
        if let anchor = encoded.anchor {
            patternChecks.append(AVQuickCheck.make(program: encoded.program, anchor: anchor))
        } else if let element = encoded.shortAnchorElement {
            patternChecks.append(AVQuickCheck.make(program: encoded.program, element: element, delta: 0, covered: 2))
        } else {
            patternChecks.append(AVQuickCheck.none)
        }
        patternCount += 1
        return patternCount - 1
    }

    /// Puts a pattern into the right table for its target type.
    func place(_ index: Int, encoded: AVProgramEncoder.Encoded, offset: AVOffsetSpec, target: Int, trigger: Bool) {
        if let anchor = encoded.anchor {
            for variant in anchor.variants {
                anchorLoad[variant, default: 0] += 1
                let entry = UInt64(variant) << 32 | UInt64(index)
                if trigger { triggerAnchors[target].append(entry) } else { deferredAnchors[target].append(entry) }
            }
        } else if offset.isAnchored {
            if trigger { anchoredPatterns[target].append(UInt32(index)) } else { deferredListPatterns[target].append(UInt32(index)) }
        } else if trigger, let key = Self.shortAnchorKey(encoded) {
            shortAnchors[target].append(UInt64(key) << 32 | UInt64(index))
        } else {
            if trigger { weakPatterns[target].append(UInt32(index)) } else { deferredListPatterns[target].append(UInt32(index)) }
        }
    }

    /// The first two bytes of a pattern's short anchor (a literal element of 2–3 bytes), as the
    /// scanner loads them (little-endian), or nil without one.
    static func shortAnchorKey(_ encoded: AVProgramEncoder.Encoded) -> UInt32? {
        guard let element = encoded.shortAnchorElement else { return nil }
        return encoded.program.withUnsafeBytes { raw -> UInt32? in
            guard let view = AVProgramView(AVByteView(raw)), let offset = view.elementOffset(element),
                  view.bytes.u8(offset) == AVProgramOp.literal.rawValue, let length = view.bytes.u16le(offset + 1), length >= 2,
                  let first = view.bytes.u8(offset + 3), let second = view.bytes.u8(offset + 4) else { return nil }
            return UInt32(first) | UInt32(second) << 8
        }
    }

    /// Expected work a pattern adds to the main pass, per megabyte of input (lower is better),
    /// used to pick a logical signature's triggers.
    static func cost(of encoded: AVProgramEncoder.Encoded, offset: AVOffsetSpec) -> Double {
        if let anchor = encoded.anchor { return anchor.hitRate * Double(1 << 20) }
        if offset.isAnchored {
            // Checked at one place per file; how often it fires depends on its leading bytes.
            // Header fields, entry-point code and the first bytes of text files are common, so
            // those keep a high floor. Only a binary (non-text) start of file that isn't a known
            // file-type magic counts as rare: a pickle header, say, where a shared word like
            // "torch" would otherwise make hundreds of signatures alive in every script.
            let lead = encoded.leadingExact
            let rareStart = offset.kind == .absolute && offset.value == 0 && lead.count >= 2
                && lead.contains { $0 >= 0x80 || ($0 < 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D) }
                && !Self.commonMagics.contains { lead.starts(with: $0) || $0.starts(with: lead) }
            return max(pow(2, -Double(encoded.leadingExactScore) / 8), rareStart ? 1.0 / 65_536 : 1.0 / 16)
        }
        return 1e9 // weak: avoid as a trigger
    }

    /// Leading bytes of common file types (and text starts) seen at offset 0.
    static let commonMagics: [[UInt8]] = [
        [0x4D, 0x5A], [0x7F, 0x45, 0x4C, 0x46], [0xCA, 0xFE, 0xBA, 0xBE], [0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE],
        [0xFE, 0xED, 0xFA, 0xCF], [0xFE, 0xED, 0xFA, 0xCE], [0x50, 0x4B], [0x1F, 0x8B], [0x42, 0x5A, 0x68], [0xFD, 0x37, 0x7A, 0x58],
        [0x52, 0x61, 0x72, 0x21], [0x37, 0x7A, 0xBC, 0xAF], [0x4D, 0x53, 0x43, 0x46], [0xD0, 0xCF, 0x11, 0xE0], [0x25, 0x50, 0x44, 0x46],
        [0x7B, 0x5C, 0x72, 0x74], [0x89, 0x50, 0x4E, 0x47], [0x47, 0x49, 0x46, 0x38], [0xFF, 0xD8, 0xFF], [0x49, 0x49, 0x2A, 0x00],
        [0x4D, 0x4D, 0x00, 0x2A], [0x46, 0x57, 0x53], [0x43, 0x57, 0x53], [0x5A, 0x57, 0x53], [0x4C, 0x00, 0x00, 0x00],
        [0x23, 0x21], [0xEF, 0xBB, 0xBF], [0xFF, 0xFE], [0xFE, 0xFF], [0x3C, 0x3F, 0x78, 0x6D, 0x6C], [0x3C, 0x3F, 0x70, 0x68, 0x70],
        [0x3C, 0x21, 0x44, 0x4F, 0x43], [0x3C, 0x21, 0x64, 0x6F, 0x63], [0x3C, 0x68, 0x74, 0x6D, 0x6C], [0x3C, 0x48, 0x54, 0x4D, 0x4C],
        [0x64, 0x65, 0x78, 0x0A], [0x21, 0x3C, 0x61, 0x72, 0x63, 0x68, 0x3E], [0x00, 0x00, 0x00], [0x20, 0x20], [0x0D, 0x0A], [0x0A],
    ]

    // MARK: Logical signatures

    /// `Name;TargetDescriptionBlock;LogicalExpression;Subsig0;Subsig1;...`
    private func parseLogicalSignatures(_ view: AVByteView, file: String, pua: Bool) throws {
        AVLineParser.forEachLine(view) { line in
            let fields = AVLineParser.split(line, UInt8(ascii: ";"))
            guard fields.count >= 4 else { unsupported(file, "malformed line"); return }
            let nameString = AVLineParser.string(fields[0])
            if ignoreList.ignores(nameString, line: { Array(line) }) { ignored(file); return }
            do {
                let tdb = try AVSignatureParser.parseTargetDescription(AVLineParser.string(fields[1]))
                if let minimum = tdb.engineMin, minimum > functionalityLevel {
                    unsupported(file, "requires a newer engine (functionality level)"); return
                }
                if let maximum = tdb.engineMax, maximum < functionalityLevel { ignored(file); return }
                guard let target = tdb.target, target >= 0, target < AVDatabaseFormat.targetCount, target != 8 else {
                    unsupported(file, "unknown target type"); return
                }
                let subsigTexts = fields.dropFirst(3)
                guard subsigTexts.count <= 64 else { unsupported(file, "more than 64 subsignatures"); return }
                let expression = try AVSignatureParser.parseExpression(AVLineParser.string(fields[2]), subsigCount: subsigTexts.count)
                if expression.isTrueWithNoMatches {
                    unsupported(file, "logical expression is true without any match"); return
                }
                try addLogicalSignature(name: Array(fields[0]), tdb: tdb, target: target, expression: expression,
                                        subsigFields: Array(subsigTexts), pua: pua)
                logicalSignatureCount += 1
                loaded(file)
            } catch let rejection as AVSignatureRejection {
                unsupported(file, rejection.reason)
            } catch {
                unsupported(file, "malformed signature")
            }
        }
    }

    private func addLogicalSignature(name: [UInt8], tdb: AVSignatureParser.TargetDescription, target: Int, expression: AVLogicalNode,
                                     subsigFields: [UnsafeBufferPointer<UInt8>], pua: Bool) throws {
        // Containers this engine never produces make the signature unusable.
        if !tdb.constraints.isEmpty { _ = try AVStoredConstraints.encode(tdb.constraints) }
        // Parse everything first so an unsupported subsignature rejects the whole signature.
        var parsed = [AVSignatureParser.Subsignature]()
        parsed.reserveCapacity(subsigFields.count)
        for (index, field) in subsigFields.enumerated() {
            parsed.append(try AVSignatureParser.parseSubsignature(field, index: index, subsigCount: subsigFields.count))
        }

        let nameString = String(decoding: name, as: UTF8.self)
        let traits = AVSignatureNaming.traits(name: nameString, fromPUADatabase: pua, target: target)

        // Encode body patterns (before writing anything) and estimate their cost.
        var encodedPatterns = [Int: [(pattern: AVPatternIR, encoded: AVProgramEncoder.Encoded, offset: AVOffsetSpec)]]()
        var pcreTriggers = [Int: AVLogicalNode]()
        var byteCompareReferences = [Int: Int]()
        for (index, subsig) in parsed.enumerated() {
            switch subsig {
            case .body(let offset, let variants):
                encodedPatterns[index] = try variants.map { ($0, try encode($0), offset) }
            case .pcre(_, let trigger, _):
                pcreTriggers[index] = trigger
            case .byteCompare(let spec):
                byteCompareReferences[index] = spec.reference
            }
        }
        func patternCost(_ id: Int) -> Double {
            guard let list = encodedPatterns[id] else { return .infinity }
            return list.reduce(0) { $0 + Self.cost(of: $1.encoded, offset: $1.offset) }
        }
        var leafCache = [Int: Set<Int>?]()
        func leaf(_ id: Int) -> Set<Int>? {
            if let cached = leafCache[id] { return cached }
            var result: Set<Int>?
            if encodedPatterns[id] != nil {
                result = [id]
            } else if let trigger = pcreTriggers[id] {
                result = AVLogicalAnalysis.requiredSet(trigger, leaf: leaf, cost: { $0.reduce(0) { $0 + patternCost($1) } })
            } else if let reference = byteCompareReferences[id] {
                result = leaf(reference)
            }
            leafCache[id] = result
            return result
        }
        guard let triggers = AVLogicalAnalysis.requiredSet(expression, leaf: leaf, cost: { $0.reduce(0) { $0 + patternCost($1) } }) else {
            throw AVSignatureRejection("no subsignature can be searched for efficiently")
        }

        // Counts the expression (and PCRE triggers) can tell apart, so searches can stop early.
        var needed = [Int: Int]()
        AVLogicalAnalysis.neededCounts(expression, into: &needed)
        for trigger in pcreTriggers.values { AVLogicalAnalysis.neededCounts(trigger, into: &needed) }
        let positionSubsigs = Set(byteCompareReferences.values)

        let firstSubsig = subsigCount
        let signature = try addSignatureRecord(name: name, traits: traits, target: target, logical: true, subsigCount: parsed.count,
                                               expression: AVLogicalExpressionCodec.encode(expression), firstSubsig: firstSubsig,
                                               constraints: tdb.constraints)
        for (index, subsig) in parsed.enumerated() {
            var kind: UInt8 = 0
            var first = 0
            var patternTotal = 0
            switch subsig {
            case .body:
                let list = encodedPatterns[index] ?? []
                patternTotal = list.count
                for (position, entry) in list.enumerated() {
                    let patternIndex = appendPattern(entry.pattern, encoded: entry.encoded, offset: entry.offset, signature: signature, subsig: index)
                    if position == 0 { first = patternIndex }
                    place(patternIndex, encoded: entry.encoded, offset: entry.offset, target: target, trigger: triggers.contains(index))
                }
            case .pcre(let spec, _, _):
                kind = 1
                first = pcres.count
                pcres.append(spec)
            case .byteCompare(let spec):
                kind = 2
                first = byteCompares.count
                byteCompares.append(spec)
            }
            var flags: UInt8 = 0
            if triggers.contains(index) { flags |= 1 }
            if positionSubsigs.contains(index) { flags |= 2 }
            subsigRecords.u8(kind)
            subsigRecords.u8(flags)
            subsigRecords.u16(UInt16(patternTotal))
            subsigRecords.u32(UInt32(first))
            let count = needed[index] ?? 1
            subsigRecords.u32(count >= Int(UInt32.max) ? UInt32.max : UInt32(count))
            subsigCount += 1
        }
    }

    // MARK: - SHA-256 lists

    /// Text with one hex SHA-256 per line (`#` comments; extra columns after the hash are ignored),
    /// or a ZIP archive holding such a text file (as MalwareBazaar distributes its full list).
    func addHashList(_ data: Data, source: AVSignatureSource) {
        let sourceIndex = UInt32(AVSignatureSource.allCases.firstIndex(of: source) ?? 0)
        data.withUnsafeBytes { raw in
            let view = AVByteView(raw)
            if AVZipReader.looksLikeZip(view) {
                let listing = AVZipReader.list(view, maxEntries: 16)
                for entry in listing.entries where !entry.isDirectory && !entry.isEncrypted {
                    guard let range = AVZipReader.dataRange(of: entry, in: view), let compressed = view.slice(range.offset, range.length) else { continue }
                    if entry.method == 0 {
                        addHashListText(compressed, source: sourceIndex)
                    } else if entry.method == 8 {
                        let output = AVInflate.inflate(compressed, wrapper: .raw, limit: 1 << 31)
                        output.data.withUnsafeBytes { addHashListText(AVByteView($0), source: sourceIndex) }
                    }
                }
            } else {
                addHashListText(view, source: sourceIndex)
            }
        }
    }

    private func addHashListText(_ view: AVByteView, source: UInt32) {
        AVLineParser.forEachLine(view) { line in
            var end = 0
            while end < line.count, AVHex.nibble(line[end]) != nil { end += 1 }
            guard end == 64, let base = line.baseAddress else { return }
            let field = UnsafeBufferPointer(start: base, count: 64)
            let start = hashList.count
            if AVLineParser.appendHex(field, to: &hashList) {
                hashList.u32(source)
                hashListCount += 1
            } else {
                hashList.bytes.removeSubrange(start...)
            }
        }
    }
}

// MARK: - Text helpers

/// Line and field parsing over raw database bytes (no per-field String allocation).
enum AVLineParser {
    /// Calls `body` for each non-empty line that isn't a `#` comment (CR/LF trimmed).
    static func forEachLine(_ view: AVByteView, _ body: (UnsafeBufferPointer<UInt8>) throws -> Void) rethrows {
        guard let base = view.base?.assumingMemoryBound(to: UInt8.self) else { return }
        var start = 0
        let count = view.count
        while start < count {
            var end = start
            if let found = memchr(base + start, 0x0A, count - start) {
                end = UnsafeRawPointer(found).assumingMemoryBound(to: UInt8.self) - base
            } else {
                end = count
            }
            var lineEnd = end
            while lineEnd > start, base[lineEnd - 1] == 0x0D || base[lineEnd - 1] == 0x20 { lineEnd -= 1 }
            if lineEnd > start, base[start] != UInt8(ascii: "#") {
                try body(UnsafeBufferPointer(start: base + start, count: lineEnd - start))
            }
            start = end + 1
        }
    }

    /// Splits a line at `separator` (the fields point into the line).
    static func split(_ line: UnsafeBufferPointer<UInt8>, _ separator: UInt8) -> [UnsafeBufferPointer<UInt8>] {
        guard let base = line.baseAddress else { return [] }
        var fields = [UnsafeBufferPointer<UInt8>]()
        fields.reserveCapacity(8)
        var start = 0
        for index in 0..<line.count where line[index] == separator {
            fields.append(UnsafeBufferPointer(start: base + start, count: index - start))
            start = index + 1
        }
        fields.append(UnsafeBufferPointer(start: base + start, count: line.count - start))
        return fields
    }

    static func string(_ field: UnsafeBufferPointer<UInt8>) -> String {
        String(decoding: field, as: UTF8.self)
    }

    /// A non-negative decimal number, or nil.
    static func number(_ field: UnsafeBufferPointer<UInt8>) -> Int? {
        guard !field.isEmpty, field.count < 19 else { return nil }
        var value = 0
        for c in field {
            guard c >= 0x30, c <= 0x39 else { return nil }
            value = value * 10 + Int(c - 0x30)
        }
        return value
    }

    /// Decodes hex directly into a writer.
    static func appendHex(_ field: UnsafeBufferPointer<UInt8>, to writer: inout AVBinaryWriter) -> Bool {
        guard field.count % 2 == 0 else { return false }
        var index = 0
        while index < field.count {
            guard let high = AVHex.nibble(field[index]), let low = AVHex.nibble(field[index + 1]) else { return false }
            writer.u8(high << 4 | low)
            index += 2
        }
        return true
    }
}
