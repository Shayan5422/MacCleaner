import Foundation

/// Matches body and logical signatures against the buffers of one scanned object.
enum AVBufferScanner {
    struct Match {
        var name: String
        var kind: AVThreatKind
    }

    /// Scans the raw bytes with the object's target type, and the normalized forms that ClamAV
    /// also scans: text is normalized for target 7 (the raw bytes only get "any file"
    /// signatures), HTML is scanned raw and as two normalized versions with target 3.
    static func scanObjectBuffers(_ data: AVByteView, kind: AVFileKind, exe: AVExecutableInfo?, level: AVObjectScanner.Level,
                                  core: AVEngineCore, db: AVMappedDatabase, options: AVScanOptions) -> [Match] {
        var matches = [Match]()
        func run(_ buffer: AVByteView, target: Int, exe: AVExecutableInfo?, containers: [AVContainerCode]) {
            let pass = AVBufferPass(core: core, db: db, options: options, data: buffer, target: target, exe: exe,
                                    objectSize: data.count, containers: containers)
            matches += pass.run()
        }
        switch kind {
        case .text:
            run(data, target: 0, exe: nil, containers: level.containers)
            let normalized: AVScratchBuffer?
            switch AVFileTyper.textKind(data.slice(0, min(data.count, AVFileTyper.magicWindow)) ?? data) {
            case .utf16LittleEndian?, .utf16BigEndian?:
                let bigEndian = data.u8(0) == 0xFE
                normalized = AVTextNormalizer.narrowUTF16(data, bigEndian: bigEndian).flatMap { AVTextNormalizer.normalizeText($0.view) }
            default:
                normalized = AVTextNormalizer.normalizeText(data)
            }
            if let normalized { run(normalized.view, target: 7, exe: nil, containers: level.containers) }
        case .html:
            run(data, target: 3, exe: nil, containers: level.containers)
            if let (tagged, textOnly) = AVTextNormalizer.normalizeHTML(data) {
                run(tagged.view, target: 3, exe: nil, containers: level.containers + [.html])
                run(textOnly.view, target: 3, exe: nil, containers: level.containers + [.html])
            }
        case .machOUniversal:
            // Every slice is scanned as a Mach-O of its own (see AVObjectScanner), so the raw
            // container is only checked for patterns at fixed offsets (its header area).
            // Deviation from ClamAV, which also runs floating patterns over the whole file.
            if options.scanArchives {
                let pass = AVBufferPass(core: core, db: db, options: options, data: data, target: 9, exe: nil,
                                        objectSize: data.count, containers: level.containers)
                matches += pass.run(floating: false)
            } else {
                run(data, target: kind.target, exe: exe, containers: level.containers)
            }
        default:
            run(data, target: kind.target, exe: exe, containers: level.containers)
        }
        return matches
    }
}

/// One pass of the signature matcher over one buffer:
/// 1. the 4-byte prefilter (`P…`) over every window (a run of one byte value handled as a whole),
///    each hit's candidates screened by their `AVQuickCheck` bytes and, for patterns at a fixed
///    offset, by where that offset allows the anchor, before any matching;
/// 2. the 2-byte-keyed table (`S…`) for floating patterns without a 4-byte anchor;
/// 3. patterns at a fixed offset without an anchor (indexed by offset and first bytes, see
///    `AVAnchoredIndex`) and the few remaining weak ones;
/// 4. when a logical signature with deferred subsignatures is alive: their patterns, through a
///    per-buffer table when few (for the buffer's size), else the database's `D…` table, plus the
///    alive ones without a 4-byte anchor through a shared 2-byte-keyed pass;
/// 5. the logical expressions of the alive signatures.
final class AVBufferPass {
    let core: AVEngineCore
    let db: AVMappedDatabase
    let options: AVScanOptions
    let data: AVByteView
    let target: Int
    let exe: AVExecutableInfo?
    /// Size of the scanned object (for `FileSize:`), which differs from the buffer for normalized text.
    let objectSize: Int
    let containers: [AVContainerCode]

    /// Body signatures that matched (few, so an array beats a set).
    @exclusivity(unchecked) private var bodyMatches = [Int]()
    private let gapMemo = AVGapMemo()
    /// Logical signatures with at least one matched subsignature: usually a handful, so they're
    /// kept in parallel arrays searched linearly (with a hash index once there are many).
    @exclusivity(unchecked) private var stateSignatures = [Int]()
    @exclusivity(unchecked) private var stateList = [LogicalState]()
    /// Per state, bit `i`: subsignature `i` has every match the expression can use. Hits for
    /// such subsignatures are dropped before any other work.
    @exclusivity(unchecked) private var saturated = [UInt64]()
    @exclusivity(unchecked) private var stateIndex = SlotIndex()
    /// Logical signatures whose target description (container, file size, entry point,
    /// sections) rules them out for this buffer; their hits are dropped before any matching.
    @exclusivity(unchecked) private var ruledOut = SlotIndex()
    @exclusivity(unchecked) private var latin1: NSString?
    private static let linearStateLimit = 24

    @inline(__always)
    private func stateSlot(_ signature: Int) -> Int? {
        if stateSignatures.count <= Self.linearStateLimit {
            for (slot, candidate) in stateSignatures.enumerated() where candidate == signature { return slot }
            return nil
        }
        return stateIndex.find(signature)
    }

    private func addState(_ signature: Int, _ state: LogicalState) -> Int {
        stateSignatures.append(signature)
        stateList.append(state)
        saturated.append(0)
        let slot = stateList.count - 1
        if stateSignatures.count > Self.linearStateLimit {
            if stateIndex.isEmpty {
                for (index, candidate) in stateSignatures.enumerated() { stateIndex.insert(candidate, slot: index) }
            } else {
                stateIndex.insert(signature, slot: slot)
            }
        }
        return slot
    }

    /// Does subsignature `subsig` of the signature in `slot` have every match it needs?
    @inline(__always)
    private func isSaturated(_ slot: Int, _ subsig: Int) -> Bool {
        saturated[slot] & (1 &<< UInt64(truncatingIfNeeded: subsig & 63)) != 0
    }

    struct LogicalState {
        var counts: [Int]
        var needed: [Int]
        var positions: [[Int]]
        var hasDeferred: Bool
        var firstSubsig: Int
    }

    /// Signature → state slot once many logical signatures are alive: open addressing with a
    /// multiplicative hash. (A `Dictionary` spent most of the scan time hashing when a script kept
    /// hundreds of signatures alive.)
    struct SlotIndex {
        private var keys = [Int]()
        private var slots = [Int32]()
        private var mask = 0
        private(set) var count = 0

        var isEmpty: Bool { count == 0 }

        @inline(__always)
        private func bucket(_ key: Int) -> Int {
            Int(truncatingIfNeeded: (UInt64(truncatingIfNeeded: key) &* 0x9E37_79B9_7F4A_7C15) &>> 32) & mask
        }

        @inline(__always)
        func find(_ key: Int) -> Int? {
            guard count > 0 else { return nil }
            var index = bucket(key)
            while true {
                let candidate = keys[index]
                if candidate == key { return Int(slots[index]) }
                if candidate < 0 { return nil }
                index = (index &+ 1) & mask
            }
        }

        mutating func insert(_ key: Int, slot: Int) {
            if (count + 1) * 2 > keys.count { grow() }
            var index = bucket(key)
            while keys[index] >= 0, keys[index] != key { index = (index &+ 1) & mask }
            if keys[index] < 0 { count += 1 }
            keys[index] = key
            slots[index] = Int32(truncatingIfNeeded: slot)
        }

        private mutating func grow() {
            let entries = zip(keys, slots).filter { $0.0 >= 0 }
            let capacity = max(512, keys.count * 2)
            keys = [Int](repeating: -1, count: capacity)
            slots = [Int32](repeating: 0, count: capacity)
            mask = capacity - 1
            count = 0
            for (key, slot) in entries { insert(key, slot: Int(slot)) }
        }
    }

    static let maxRecordedPositions = 64

    init(core: AVEngineCore, db: AVMappedDatabase, options: AVScanOptions, data: AVByteView, target: Int,
         exe: AVExecutableInfo?, objectSize: Int, containers: [AVContainerCode]) {
        self.core = core
        self.db = db
        self.options = options
        self.data = data
        self.target = target
        self.exe = exe
        self.objectSize = objectSize
        self.containers = containers
    }

    /// - Parameter floating: Run the prefilter (patterns anywhere in the buffer). Without it,
    ///   only patterns at fixed offsets are checked.
    func run(floating: Bool = true) -> [AVBufferScanner.Match] {
        // Windows/Linux executables are skipped entirely when only Mac threats are wanted.
        let tableTarget = !options.detectNonMacThreats && (target == 1 || target == 6) ? 0 : target
        let targets = tableTarget == 0 ? [0] : [0, tableTarget]

        if floating, let table = db.prefilters[tableTarget] ?? db.prefilters[0] {
            prefilterPass(table, deferred: false)
        }
        if floating, let table = db.shortPrefilters[tableTarget] ?? db.shortPrefilters[0] {
            shortPrefilterPass(table)
        }
        for t in targets {
            let index = core.anchoredIndex[t]
            if let base = data.base {
                for offset in index.offsets {
                    guard offset + 2 <= data.count else { break }
                    let key = UInt64(offset) << 16 | UInt64(UInt16(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
                    for pattern in index.keyed[key] ?? [] { checkListed(Int(pattern), deferred: false) }
                }
            }
            for pattern in index.others { checkListed(Int(pattern), deferred: false) }
            if floating {
                forEachPattern(in: db.weakLists[t]) { checkListed($0, deferred: false) }
            }
        }
        if stateList.contains(where: \.hasDeferred) {
            if let alive = aliveDeferredPatterns(limit: Self.dynamicDeferredLimit(bufferSize: data.count)) {
                // Few signatures are alive (for this buffer's size): scan only for their deferred patterns.
                dynamicDeferredPass(alive)
            } else if let table = db.deferredPrefilters[tableTarget] ?? db.deferredPrefilters[0] {
                prefilterPass(table, deferred: true)
            }
            // Patterns without a 4-byte anchor, of signatures that are alive (the lists hold
            // every signature's): those with a short exact window share one pass.
            var listed = [Int]()
            for t in targets {
                forEachPattern(in: db.deferredLists[t]) { index in
                    if !patternIsDone(index, deferred: true) { listed.append(index) }
                }
            }
            if !listed.isEmpty {
                for index in shortDeferredPass(listed) { checkListed(index, deferred: true) }
            }
        }

        var matches = [AVBufferScanner.Match]()
        for signature in bodyMatches {
            if let record = db.signature(signature) {
                matches.append(.init(name: db.name(record.nameIndex), kind: record.kind))
            }
        }
        for signature in stateSignatures.sorted() where evaluateLogical(signature) {
            if let record = db.signature(signature) {
                matches.append(.init(name: db.name(record.nameIndex), kind: record.kind))
            }
        }
        return matches
    }

    /// Calls `body` with each pattern index of a list section (u32 count, then the indices).
    @inline(__always)
    private func forEachPattern(in list: AVByteView, _ body: (Int) -> Void) {
        guard let count = list.u32le(0).map(Int.init), count > 0 else { return }
        for k in 0..<count {
            guard let index = list.u32le(4 + k * 4) else { return }
            body(Int(index))
        }
    }

    // MARK: Deferred subsignatures

    /// Above this many patterns, the database's deferred table is used instead of a per-buffer one.
    /// Setting up the per-buffer table costs about a microsecond per pattern; the database's
    /// deferred table costs several nanoseconds per input byte. Small buffers use the database's.
    static func dynamicDeferredLimit(bufferSize: Int) -> Int {
        max(512, min(16_384, bufferSize / 128))
    }

    /// Deferred (non-trigger) body patterns of the logical signatures that are alive in this
    /// buffer, or nil when there are more than `limit`.
    private func aliveDeferredPatterns(limit: Int) -> [Int]? {
        var patterns = [Int]()
        for (slot, signature) in stateSignatures.enumerated() where stateList[slot].hasDeferred {
            guard let record = db.signature(signature) else { continue }
            for id in 0..<record.subsigCount {
                guard let subsig = db.subsig(record.firstSubsig + id), subsig.kind == .body, !subsig.isTrigger else { continue }
                for k in 0..<subsig.patternCount { patterns.append(subsig.first + k) }
                if patterns.count > limit { return nil }
            }
        }
        return patterns
    }

    /// The 4-byte anchor values of a pattern (exact, case and nibble variants), or nil without one.
    private func anchorValues(_ pattern: AVMappedDatabase.Pattern) -> [UInt32]? {
        guard let element = pattern.anchorElement, let offset = pattern.program.elementOffset(element),
              let op = pattern.program.bytes.u8(offset), let length = pattern.program.bytes.u16le(offset + 1).map(Int.init),
              pattern.anchorDelta + 4 <= length else { return nil }
        if op == AVProgramOp.literal.rawValue {
            return pattern.program.bytes.u32le(offset + 3 + pattern.anchorDelta).map { [$0] }
        }
        guard op == AVProgramOp.masked.rawValue else { return nil }
        var values: [UInt32] = [0]
        for k in 0..<4 {
            guard let mask = pattern.program.bytes.u8(offset + 3 + pattern.anchorDelta + k),
                  let value = pattern.program.bytes.u8(offset + 3 + length + pattern.anchorDelta + k) else { return nil }
            // Every byte with `byte & mask == value`: the free bits take all combinations.
            let free = ~mask
            guard values.count << free.nonzeroBitCount <= AVProgramEncoder.maxAnchorVariants else { return nil }
            var choices = [UInt8]()
            var subset: UInt8 = 0
            repeat {
                choices.append((value & mask) | subset)
                subset = (subset &- free) & free
            } while subset != 0
            values = values.flatMap { prefix in choices.map { prefix | UInt32($0) << (8 * UInt32(k)) } }
        }
        return values
    }

    /// A one-off prefilter over the given patterns' anchors.
    private func dynamicDeferredPass(_ patterns: [Int]) {
        var entries = [(value: UInt32, pattern: Int32)]()
        entries.reserveCapacity(patterns.count)
        for index in patterns {
            guard let pattern = db.pattern(index), let values = anchorValues(pattern) else { continue }
            for value in values { entries.append((value, Int32(truncatingIfNeeded: index))) }
        }
        keyedPass(&entries, width: 4) { index, position in
            self.checkCandidate(index, anchorPosition: position, deferred: true)
        }
    }

    /// Deferred patterns without a 4-byte anchor that have a 2-byte window with at most four
    /// variants (an exact pair, or a case-insensitive one): found in one shared pass keyed by
    /// that window instead of one scan each. Returns the patterns it couldn't take.
    private func shortDeferredPass(_ indices: [Int]) -> [Int] {
        var keyed = [AVMappedDatabase.Pattern]()
        var entries = [(value: UInt32, pattern: Int32)]()
        var leftovers = [Int]()
        for index in indices {
            guard var pattern = db.pattern(index), !pattern.offset.isAnchored, let window = Self.shortWindow(pattern.program) else {
                leftovers.append(index)
                continue
            }
            pattern.anchorElement = window.element
            pattern.anchorDelta = window.delta
            let slot = Int32(keyed.count)
            keyed.append(pattern)
            for key in window.keys { entries.append((key, slot)) }
            shortDeferredIndices.append(index)
        }
        keyedPass(&entries, width: 2) { slot, position in
            let index = self.shortDeferredIndices[slot]
            guard !self.patternIsDone(index, deferred: true) else { return }
            let pattern = keyed[slot]
            guard let subsig = pattern.subsig, self.shouldCheck(signature: pattern.signature, subsig: subsig, deferred: true),
                  let start = self.verify(pattern, index: index, anchorPosition: position) else { return }
            self.record(pattern, start: start)
        }
        shortDeferredIndices.removeAll()
        return leftovers
    }

    /// Pattern indices of `shortDeferredPass`'s slots.
    @exclusivity(unchecked) private var shortDeferredIndices = [Int]()

    /// The rarest 2-byte window (at most 4 variants) inside a LIT or MASK element of a program.
    static func shortWindow(_ program: AVProgramView) -> (element: Int, delta: Int, keys: [UInt32])? {
        var best: (element: Int, delta: Int, keys: [UInt32], probability: Double)?
        for element in 0..<program.elementCount {
            guard let offset = program.elementOffset(element), let op = program.bytes.u8(offset),
                  op == AVProgramOp.literal.rawValue || op == AVProgramOp.masked.rawValue,
                  let length = program.bytes.u16le(offset + 1).map(Int.init), length >= 2 else { continue }
            func byte(_ k: Int) -> (mask: UInt8, value: UInt8)? {
                if op == AVProgramOp.literal.rawValue { return program.bytes.u8(offset + 3 + k).map { (0xFF, $0) } }
                guard let mask = program.bytes.u8(offset + 3 + k), let value = program.bytes.u8(offset + 3 + length + k) else { return nil }
                return (mask, value & mask)
            }
            for delta in 0...(length - 2) {
                guard let first = byte(delta), let second = byte(delta + 1),
                      (~first.mask).nonzeroBitCount + (~second.mask).nonzeroBitCount <= 2 else { continue }
                var keys = [UInt32]()
                var probability = 0.0
                for a in Self.variants(first) {
                    for b in Self.variants(second) {
                        keys.append(UInt32(a) | UInt32(b) << 8)
                        probability += exp2(-Double(Int(AVByteRarity.score[Int(a)]) + Int(AVByteRarity.score[Int(b)])) / 8)
                    }
                }
                if best == nil || probability < best!.probability { best = (element, delta, keys, probability) }
            }
        }
        return best.map { ($0.element, $0.delta, $0.keys) }
    }

    /// Every byte `b` with `b & mask == value`.
    private static func variants(_ byte: (mask: UInt8, value: UInt8)) -> [UInt8] {
        let free = ~byte.mask
        var out = [UInt8]()
        var subset: UInt8 = 0
        repeat {
            out.append(byte.value | subset)
            subset = (subset &- free) & free
        } while subset != 0
        return out
    }

    /// One pass over the buffer for a set of (key, payload) entries, keys being the 4-byte
    /// (`width` 4) or 2-byte (`width` 2) little-endian value at a position: a bitmap (≥ 32 bits
    /// per key) and an open-addressing table from key to the entries sorted by key. Calls
    /// `hit(payload, position)` for every entry whose key is at `position`.
    private func keyedPass(_ entries: inout [(value: UInt32, pattern: Int32)], width: Int, hit: (Int, Int) -> Void) {
        guard !entries.isEmpty, let base = data.base, data.count >= width else { return }
        entries.sort { $0.value < $1.value }

        var bitmapLog2 = 16
        while bitmapLog2 < 22, (1 << bitmapLog2) < entries.count * 32 { bitmapLog2 += 1 }
        var bitmap = [UInt64](repeating: 0, count: (1 << bitmapLog2) / 64)
        let bitmapShift = UInt32(32 - bitmapLog2)
        var tableLog2 = 4
        while (1 << tableLog2) < entries.count * 2 { tableLog2 += 1 }
        let tableMask = (1 << tableLog2) - 1
        let tableShift = UInt32(32 - tableLog2)
        // Slot: anchor value, first entry, entry count (count 0 = empty).
        var keys = [UInt32](repeating: 0, count: 1 << tableLog2)
        var firsts = [Int32](repeating: 0, count: 1 << tableLog2)
        var counts = [Int32](repeating: 0, count: 1 << tableLog2)
        var start = 0
        while start < entries.count {
            let value = entries[start].value
            var end = start + 1
            while end < entries.count, entries[end].value == value { end += 1 }
            let h = Int((value &* AVDatabaseFormat.bitmapMultiplier) &>> bitmapShift)
            bitmap[h &>> 6] |= 1 &<< UInt64(h & 63)
            var slot = Int((value &* AVDatabaseFormat.tableMultiplier) &>> tableShift)
            while counts[slot] != 0 { slot = (slot &+ 1) & tableMask }
            keys[slot] = value
            firsts[slot] = Int32(start)
            counts[slot] = Int32(end - start)
            start = end
        }

        let end = data.count - (width - 1)
        var position = 0
        while position < end {
            let value = width == 4 ? UInt32(littleEndian: base.loadUnaligned(fromByteOffset: position, as: UInt32.self))
                                   : UInt32(UInt16(littleEndian: base.loadUnaligned(fromByteOffset: position, as: UInt16.self)))
            let h = Int((value &* AVDatabaseFormat.bitmapMultiplier) &>> bitmapShift)
            if bitmap[h &>> 6] & (1 &<< UInt64(h & 63)) != 0 {
                var slot = Int((value &* AVDatabaseFormat.tableMultiplier) &>> tableShift)
                while counts[slot] != 0 {
                    if keys[slot] == value {
                        let first = Int(firsts[slot])
                        for k in first..<(first + Int(counts[slot])) { hit(Int(entries[k].pattern), position) }
                        break
                    }
                    slot = (slot &+ 1) & tableMask
                }
            }
            position &+= 1
        }
    }

    // MARK: Prefilter

    /// Runs of one byte value at least this long are handled as a whole (see `runCandidates`).
    static let longRunLength = 8

    /// Hashes every 4-byte window into the table's bitmap; set bits lead to candidate patterns.
    private func prefilterPass(_ table: AVPrefilterTable, deferred: Bool) {
        guard let base = data.base, data.count >= 4 else { return }
        let bitmap = table.bitmap
        let shift = table.bitmapShift
        let end = data.count - 3
        var position = 0
        var measuredRunEnd = 0
        while position < end {
            let value = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: position, as: UInt32.self))
            let h = Int((value &* AVDatabaseFormat.bitmapMultiplier) &>> shift)
            if bitmap[h &>> 6] & (1 &<< UInt64(h & 63)) != 0 {
                // Inside a long run of one byte (zero padding, fill) every window is the same.
                if position >= measuredRunEnd, value == (value & 0xFF) &* 0x0101_0101 {
                    measuredRunEnd = runEnd(from: position)
                    if measuredRunEnd - position >= Self.longRunLength {
                        runCandidates(table, value, runStart: position, runEnd: measuredRunEnd, window: 4, deferred: deferred)
                        position = measuredRunEnd - 3
                        continue
                    }
                }
                candidates(table, value, position, deferred: deferred)
            }
            position &+= 1
        }
    }

    /// The 2-byte-keyed pass for floating patterns without a 4-byte anchor (their 2–3 byte
    /// literal is the key); replaces one search per pattern.
    private func shortPrefilterPass(_ table: AVPrefilterTable) {
        guard let base = data.base, data.count >= 2 else { return }
        let bitmap = table.bitmap
        let shift = table.bitmapShift
        let end = data.count - 1
        var position = 0
        var measuredRunEnd = 0
        while position < end {
            let value = UInt32(UInt16(littleEndian: base.loadUnaligned(fromByteOffset: position, as: UInt16.self)))
            let h = Int((value &* AVDatabaseFormat.bitmapMultiplier) &>> shift)
            if bitmap[h &>> 6] & (1 &<< UInt64(h & 63)) != 0 {
                if position >= measuredRunEnd, value == (value & 0xFF) &* 0x0101 {
                    measuredRunEnd = runEnd(from: position)
                    if measuredRunEnd - position >= Self.longRunLength {
                        runCandidates(table, value, runStart: position, runEnd: measuredRunEnd, window: 2, deferred: false)
                        position = measuredRunEnd - 1
                        continue
                    }
                }
                candidates(table, value, position, deferred: false)
            }
            position &+= 1
        }
    }

    /// End (exclusive) of the run of the byte at `start`.
    private func runEnd(from start: Int) -> Int {
        guard let base = data.base, start < data.count else { return start }
        let byte = base.load(fromByteOffset: start, as: UInt8.self)
        let word = UInt64(byte) &* 0x0101_0101_0101_0101
        var end = start
        while end + 8 <= data.count, base.loadUnaligned(fromByteOffset: end, as: UInt64.self) == word { end += 8 }
        while end < data.count, base.load(fromByteOffset: end, as: UInt8.self) == byte { end += 1 }
        return end
    }

    @inline(never)
    private func candidates(_ table: AVPrefilterTable, _ value: UInt32, _ position: Int, deferred: Bool) {
        guard let (start, count) = table.lookup(value), let base = data.base else { return }
        let size = data.count
        for k in 0..<count {
            // Two bytes at fixed distances from the anchor come first: most hits on anchors that
            // are common in some files (zero runs, padding, a shared word) end here.
            guard AVQuickCheck.passes(table.check(start + k), base: base, count: size, at: position) else { continue }
            guard let index = table.candidate(start + k) else { return }
            checkCandidate(index, anchorPosition: position, deferred: deferred)
        }
    }

    /// All windows inside a run of one byte (`runStart..<runEnd`, `window` bytes each) have the
    /// same value, so each candidate is only tried where it can match: a check byte that the
    /// run's byte fails can only pass where it falls outside the run, which leaves a few
    /// positions at the run's edges. Candidates without such a check are tried everywhere until
    /// their signature has what it needs.
    @inline(never)
    private func runCandidates(_ table: AVPrefilterTable, _ value: UInt32, runStart: Int, runEnd: Int, window: Int, deferred: Bool) {
        guard let (start, count) = table.lookup(value), let base = data.base else { return }
        let byte = UInt8(truncatingIfNeeded: value)
        let size = data.count
        let last = runEnd - window
        for k in 0..<count {
            let packed = table.check(start + k)
            var low = runStart, high = last
            var shift: UInt64 = 0
            while shift < 64 {
                let field = packed &>> shift
                let mask = UInt8(truncatingIfNeeded: field &>> 24)
                if mask == 0 { break }
                if byte & mask != UInt8(truncatingIfNeeded: field &>> 16) {
                    let distance = Int(Int16(truncatingIfNeeded: field))
                    if distance >= 0 { low = max(low, runEnd - distance) } else { high = min(high, runStart - distance - 1) }
                }
                shift += 32
            }
            guard low <= high, let index = table.candidate(start + k), !patternIsDone(index, deferred: deferred) else { continue }
            for position in low...high where AVQuickCheck.passes(packed, base: base, count: size, at: position) {
                checkCandidate(index, anchorPosition: position, deferred: deferred)
                if patternIsDone(index, deferred: deferred) { break }
            }
        }
    }

    /// Nothing more to find for this pattern in this buffer: its body signature already matched,
    /// its subsignature has every match it needs, its signature is ruled out, or (in the
    /// deferred pass) its signature isn't alive.
    private func patternIsDone(_ index: Int, deferred: Bool) -> Bool {
        let base = index * AVDatabaseFormat.patternRecordSize
        guard let signature = db.patternTable.u32le(base).map(Int.init), let subsig = db.patternTable.u8(base + 16) else { return true }
        if subsig == 0xFF { return bodyMatches.contains(signature) }
        guard let slot = stateSlot(signature) else { return deferred || (!ruledOut.isEmpty && ruledOut.find(signature) != nil) }
        return isSaturated(slot, Int(subsig))
    }

    /// Cheap filters before full verification: options, already-matched signatures, saturated
    /// counts, and target-description conditions that rule the signature out for this buffer.
    private func shouldCheck(signature: Int, subsig: Int?, deferred: Bool) -> Bool {
        guard let flags = db.signatureFlags(signature) else { return false }
        if flags.contains(.pua) && !options.detectPUA { return false }
        if flags.contains(.nonMac) && !options.detectNonMacThreats { return false }
        guard let subsig else { return !bodyMatches.contains(signature) }
        guard let slot = stateSlot(signature) else {
            guard !deferred else { return false }
            // Container, file size, entry point and section conditions don't depend on matches:
            // check them on the signature's first hit (the container from the signature record,
            // the rest decoded only when present) and remember a failure as a state.
            if flags.contains(.hasConstraints) {
                let holds = containerRuleHolds(signature)
                    && (db.signatureContainerRule(signature)?.hasOthers == false || otherConstraintsHold(signature))
                if !holds {
                    ruledOut.insert(signature, slot: 0)
                    return false
                }
            }
            return true
        }
        return !isSaturated(slot, subsig)
    }

    /// The container a signature requires (from its record), if any, is this buffer's.
    @inline(__always)
    private func containerRuleHolds(_ signature: Int) -> Bool {
        guard let rule = db.signatureContainerRule(signature), rule.container != 0 else { return true }
        if rule.container == AVContainerCode.any.rawValue { return containers.isEmpty }
        return containers.last?.rawValue == rule.container
    }

    /// The constraint record's conditions (decoded).
    private func otherConstraintsHold(_ signature: Int) -> Bool {
        guard let record = db.signature(signature), let index = record.constraintIndex else { return true }
        guard let constraints = db.constraints(index) else { return false }
        return constraintsHold(constraints)
    }

    private func checkCandidate(_ index: Int, anchorPosition: Int, deferred: Bool) {
        let table = db.patternTable
        let base = index * AVDatabaseFormat.patternRecordSize
        guard let signatureValue = table.u32le(base), let anchorDelta = table.u16le(base + 14),
              let subsigByte = table.u8(base + 16), let offsetKind = table.u8(base + 18) else { return }
        let runStart = anchorPosition - Int(anchorDelta)
        guard runStart >= 0 else { return }
        // Nothing to find: a subsignature with every match it needs, a ruled-out signature, a
        // deferred subsignature of a signature that isn't alive, a body signature already found.
        if subsigByte != 0xFF {
            if let slot = stateSignatures.isEmpty ? nil : stateSlot(Int(signatureValue)) {
                if isSaturated(slot, Int(subsigByte)) { return }
            } else if deferred || (!ruledOut.isEmpty && ruledOut.find(Int(signatureValue)) != nil) {
                return
            }
        } else if !bodyMatches.isEmpty, bodyMatches.contains(Int(signatureValue)) {
            return
        }
        // A pattern at a fixed offset: its anchor must be where that offset allows.
        if offsetKind != AVOffsetSpec.Kind.any.rawValue, !anchorFitsOffset(table, base, kind: offsetKind, runStart: runStart) {
            return
        }
        // The anchor element (usually a literal run longer than the 4-byte anchor), before any bookkeeping.
        guard let programOffset = table.u32le(base + 4), let programLength = table.u32le(base + 8),
              let anchorElement = table.u16le(base + 12),
              let programBytes = db.programs.slice(Int(programOffset), Int(programLength)),
              let program = AVProgramView(programBytes), let elementOffset = program.elementOffset(Int(anchorElement)),
              AVPatternMatcher(data).matchSimple(program, elementOffset, at: runStart) != nil else { return }

        let subsig: Int? = subsigByte == 0xFF ? nil : Int(subsigByte)
        guard shouldCheck(signature: Int(signatureValue), subsig: subsig, deferred: deferred), let pattern = db.pattern(index),
              let match = verify(pattern, index: index, anchorPosition: anchorPosition) else { return }
        record(pattern, start: match)
    }

    /// For a pattern at a fixed offset (pattern record at `base`): can its anchor element start
    /// at `runStart`, given the window its offset allows and the stored range of distances
    /// between the pattern's start and that element?
    @inline(__always)
    private func anchorFitsOffset(_ table: AVByteView, _ base: Int, kind: UInt8, runStart: Int) -> Bool {
        guard let kind = AVOffsetSpec.Kind(rawValue: kind), let value = table.u32le(base + 20), let maxShift = table.u32le(base + 24),
              let section = table.u16le(base + 28), let minPrefix = table.u16le(base + 36), let maxPrefix = table.u16le(base + 38) else { return false }
        let offset = AVOffsetSpec(kind: kind, value: Int(Int32(bitPattern: value)), section: Int(section), maxShift: Int(maxShift))
        guard let window = startWindow(offset), runStart >= window.lowerBound + Int(minPrefix) else { return false }
        return maxPrefix == 0xFFFF || runStart <= window.upperBound + Int(maxPrefix)
    }

    // MARK: Verification

    /// Where the pattern may start, from its offset field. nil when it can't apply (no entry
    /// point or section in this file, offset before the start...).
    private func startWindow(_ offset: AVOffsetSpec) -> ClosedRange<Int>? {
        let base: Int
        switch offset.kind {
        case .any:
            return 0...max(0, data.count)
        case .absolute:
            base = offset.value
        case .endOfFile:
            base = data.count - offset.value
        case .entryPoint:
            guard let entry = exe?.entryPoint else { return nil }
            base = entry + offset.value
        case .sectionStart:
            guard let sections = exe?.sections, offset.section < sections.count else { return nil }
            base = sections[offset.section].rawOffset + offset.value
        case .sectionEntire:
            guard let sections = exe?.sections, offset.section < sections.count else { return nil }
            let section = sections[offset.section]
            return section.rawOffset...(section.rawOffset + section.rawSize)
        case .lastSection:
            guard let last = exe?.sections.last else { return nil }
            base = last.rawOffset + offset.value
        }
        guard base >= 0, base <= data.count else { return nil }
        return base...(base + offset.maxShift)
    }

    private func verify(_ pattern: AVMappedDatabase.Pattern, index: Int, anchorPosition: Int) -> Int? {
        guard let anchorElement = pattern.anchorElement, let elementOffset = pattern.program.elementOffset(anchorElement),
              let window = startWindow(pattern.offset) else { return nil }
        let runStart = anchorPosition - pattern.anchorDelta
        var matcher = AVPatternMatcher(data)
        guard runStart >= 0, let runLength = matcher.matchSimple(pattern.program, elementOffset, at: runStart) else { return nil }
        // Linear work in the buffer is always allowed; the budget only stops exponential cases.
        matcher.budget = max(AVPatternMatcher.stepBudget, data.count)
        matcher.memo = gapMemo
        matcher.memoBase = UInt64(index) << 16
        if pattern.offset.isAnchored {
            // The start is pinned by the offset (checkCandidate already ruled out anchor
            // positions the offset can't reach): match backward first, within the window.
            guard let start = matcher.backward(pattern.program, before: anchorElement, endingAt: runStart, startWindow: window,
                                               acceptStart: { window.contains($0) && self.leftSideAccepts(pattern, $0) }) else { return nil }
            guard matcher.forward(pattern.program, from: anchorElement + 1, at: runStart + runLength,
                                  acceptEnd: { self.rightSideAccepts(pattern, $0) }) != nil else { return nil }
            return start
        }
        guard matcher.forward(pattern.program, from: anchorElement + 1, at: runStart + runLength, acceptEnd: { self.rightSideAccepts(pattern, $0) }) != nil else {
            return nil
        }
        return matcher.backward(pattern.program, before: anchorElement, endingAt: runStart,
                                acceptStart: { window.contains($0) && self.leftSideAccepts(pattern, $0) })
    }

    /// Patterns without an anchor: tried at every allowed start position (fixed offsets) or,
    /// for the few floating ones, across the buffer.
    private func checkListed(_ index: Int, deferred: Bool) {
        guard let pattern = db.pattern(index), shouldCheck(signature: pattern.signature, subsig: pattern.subsig, deferred: deferred),
              let window = startWindow(pattern.offset) else { return }
        // Floating patterns with a short anchor (a literal of 2-3 bytes): find its occurrences
        // and verify around each, like a prefilter hit.
        if !pattern.offset.isAnchored, let element = pattern.anchorElement, let offset = pattern.program.elementOffset(element),
           pattern.program.bytes.u8(offset) == AVProgramOp.literal.rawValue,
           let length = pattern.program.bytes.u16le(offset + 1).map(Int.init), length >= 2,
           let literal = pattern.program.bytes.slice(offset + 3, length), let needle = literal.base, let base = data.base {
            var position = 0
            while position + length <= data.count {
                guard let at = AVFind.first(needle, length, in: base, from: position, end: data.count) else { return }
                if let start = verify(pattern, index: index, anchorPosition: at) {
                    record(pattern, start: start)
                    guard let subsig = pattern.subsig, let slot = stateSlot(pattern.signature), subsig < stateList[slot].counts.count,
                          stateList[slot].counts[subsig] < stateList[slot].needed[subsig] else { return }
                }
                position = at + 1
            }
            return
        }
        var matcher = AVPatternMatcher(data)
        matcher.memo = gapMemo
        matcher.memoBase = UInt64(index) << 16
        let last = min(window.upperBound, data.count - pattern.minLength)
        guard window.lowerBound <= last else { return }
        var start = window.lowerBound
        let firstElement = pattern.program.elementOffset(0)
        while start <= last {
            // Skip ahead to plausible starts using the first byte of a leading literal.
            if let firstElement, pattern.program.bytes.u8(firstElement) == AVProgramOp.literal.rawValue,
               let first = pattern.program.bytes.u8(firstElement + 3), let base = data.base {
                guard let found = memchr(base + start, Int32(first), last - start + 1) else { return }
                start = UnsafeRawPointer(found) - base
            }
            matcher.budget = max(AVPatternMatcher.stepBudget, data.count)
            if leftSideAccepts(pattern, start),
               matcher.forward(pattern.program, from: 0, at: start, acceptEnd: { self.rightSideAccepts(pattern, $0) }) != nil {
                record(pattern, start: start)
                guard let subsig = pattern.subsig, let slot = stateSlot(pattern.signature), subsig < stateList[slot].counts.count,
                      stateList[slot].counts[subsig] < stateList[slot].needed[subsig] else { return }
            }
            start += 1
        }
    }

    // MARK: Boundaries

    @inline(__always)
    private static func isAlphanumeric(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }

    private static func assertionHolds(_ assertion: AVSpecialClass, _ byte: UInt8) -> Bool {
        switch assertion {
        case .boundary: return AVByteSet.boundary.contains(byte)
        case .lineMarker: return byte == 0x0A || byte == 0x0D
        case .nonAlphanumeric: return AVByteSet.nonAlphanumeric.contains(byte)
        }
    }

    private func leftSideAccepts(_ pattern: AVMappedDatabase.Pattern, _ start: Int) -> Bool {
        if let assertion = pattern.leftAssertion, start > 0, !Self.assertionHolds(assertion, data[start - 1]) { return false }
        if pattern.flags.contains(.fullword) {
            if pattern.flags.contains(.wide) {
                if start >= 2, data[start - 1] == 0, Self.isAlphanumeric(data[start - 2]) { return false }
            } else if start >= 1, Self.isAlphanumeric(data[start - 1]) {
                return false
            }
        }
        return true
    }

    private func rightSideAccepts(_ pattern: AVMappedDatabase.Pattern, _ end: Int) -> Bool {
        if let assertion = pattern.rightAssertion, end < data.count, !Self.assertionHolds(assertion, data[end]) { return false }
        if pattern.flags.contains(.fullword) {
            if pattern.flags.contains(.wide) {
                if end + 1 < data.count, data[end + 1] == 0, Self.isAlphanumeric(data[end]) { return false }
            } else if end < data.count, Self.isAlphanumeric(data[end]) {
                return false
            }
        }
        return true
    }

    // MARK: Recording

    private func record(_ pattern: AVMappedDatabase.Pattern, start: Int) {
        guard let subsig = pattern.subsig else {
            if !bodyMatches.contains(pattern.signature) { bodyMatches.append(pattern.signature) }
            return
        }
        var slot = stateSlot(pattern.signature)
        if slot == nil {
            guard let state = makeState(pattern.signature) else { return }
            slot = addState(pattern.signature, state)
        }
        guard let slot, subsig < stateList[slot].counts.count else { return }
        stateList[slot].counts[subsig] += 1
        if stateList[slot].counts[subsig] >= stateList[slot].needed[subsig] {
            saturated[slot] |= 1 &<< UInt64(truncatingIfNeeded: subsig & 63)
        }
        if stateList[slot].positions[subsig].count < Self.maxRecordedPositions,
           db.subsig(stateList[slot].firstSubsig + subsig)?.needsPositions == true {
            stateList[slot].positions[subsig].append(start)
        }
    }

    private func makeState(_ signature: Int) -> LogicalState? {
        guard let record = db.signature(signature), record.flags.contains(.logical) else { return nil }
        var needed = [Int]()
        var hasDeferred = false
        for id in 0..<record.subsigCount {
            guard let subsig = db.subsig(record.firstSubsig + id) else { return nil }
            needed.append(max(1, subsig.neededCount))
            if subsig.kind == .body && !subsig.isTrigger { hasDeferred = true }
        }
        return LogicalState(counts: Array(repeating: 0, count: record.subsigCount), needed: needed,
                            positions: Array(repeating: [], count: record.subsigCount), hasDeferred: hasDeferred,
                            firstSubsig: record.firstSubsig)
    }

    // MARK: Logical signatures

    private func evaluateLogical(_ signature: Int) -> Bool {
        guard let record = db.signature(signature), let slot = stateSlot(signature) else { return false }
        let state = stateList[slot]
        if let index = record.constraintIndex {
            guard let constraints = db.constraints(index), constraintsHold(constraints) else { return false }
        }
        var computed = [Int: Int]()
        func count(_ id: Int) -> Int {
            guard id >= 0, id < state.counts.count else { return 0 }
            if let value = computed[id] { return value }
            guard let subsig = db.subsig(record.firstSubsig + id) else { return 0 }
            var value = 0
            switch subsig.kind {
            case .body:
                value = state.counts[id]
            case .pcre:
                computed[id] = 0 // guards against a trigger referring back to itself
                value = pcreCount(subsig.first, count: count)
            case .byteCompare:
                computed[id] = 0
                if subsig.first < core.byteCompares.count {
                    let spec = core.byteCompares[subsig.first]
                    value = byteCompareCount(spec, positions: spec.reference < state.positions.count ? state.positions[spec.reference] : [])
                }
            }
            computed[id] = value
            return value
        }
        return AVLogicalExpressionCodec.evaluate(record.expression, count: count)
    }

    private func constraintsHold(_ constraints: AVStoredConstraints) -> Bool {
        if let range = constraints.fileSize, !range.contains(UInt64(objectSize)) { return false }
        if let range = constraints.entryPoint {
            guard let entry = exe?.entryPoint, entry >= 0, entry <= Int(UInt32.max), range.contains(UInt32(entry)) else { return false }
        }
        if let range = constraints.numberOfSections {
            guard let sections = exe?.sections, sections.count <= Int(UInt16.max), range.contains(UInt16(sections.count)) else { return false }
        }
        if let container = constraints.container {
            if container == .any {
                guard containers.isEmpty else { return false } // CL_TYPE_ANY: top-level files only
            } else {
                guard containers.last == container else { return false }
            }
        }
        if let chain = constraints.intermediates {
            guard chain.count <= containers.count else { return false }
            for (expected, actual) in zip(chain.reversed(), containers.reversed()) where expected != .any && expected != actual {
                return false
            }
        }
        return true
    }

    private func pcreCount(_ index: Int, count: (Int) -> Int) -> Int {
        guard let spec = core.regexes.spec(index), data.count <= AVRegexMatcher.maxSubjectLength else { return 0 }
        guard spec.trigger.withUnsafeBytes({ AVLogicalExpressionCodec.evaluate(AVByteView($0), count: count) }) else { return 0 }
        let offset = AVOffsetSpec(kind: AVOffsetSpec.Kind(rawValue: spec.offsetKind) ?? .any, value: spec.offsetValue,
                                  section: spec.offsetSection, maxShift: spec.maxShift)
        guard let window = startWindow(offset) else { return 0 }
        let start = offset.kind == .any ? 0 : window.lowerBound
        if let literal = spec.requiredLiteral,
           !AVRegexMatcher.contains(literal, in: data, from: start, caseInsensitive: spec.caseInsensitive || spec.inlineCaseless) {
            return 0
        }
        guard let regex = core.regexes.regex(index) else { return 0 }
        if latin1 == nil, let base = data.base {
            latin1 = NSString(bytes: base, length: data.count, encoding: String.Encoding.isoLatin1.rawValue)
        }
        guard let subject = latin1 else { return 0 }
        return AVRegexMatcher.count(regex, spec: spec, subject: subject, start: start)
    }

    /// Byte compare: reads a number near each match of the reference subsignature and compares it.
    private func byteCompareCount(_ spec: AVByteCompareSpec, positions: [Int]) -> Int {
        for position in positions {
            let (start, overflow) = position.addingReportingOverflow(spec.offset)
            guard !overflow, start >= 0, start < data.count else { continue }
            let available = min(spec.length, data.count - start)
            if available < spec.length && (spec.exact || spec.encoding == .binary) { continue }
            guard let bytes = data.slice(start, available), let value = Self.decodeNumber(bytes, spec: spec) else { continue }
            let holds = spec.comparisons.allSatisfy { comparison in
                switch comparison.op {
                case UInt8(ascii: "<"): return value < comparison.value
                case UInt8(ascii: ">"): return value > comparison.value
                default: return value == comparison.value
                }
            }
            if holds { return 1 }
        }
        return 0
    }

    private static func decodeNumber(_ bytes: AVByteView, spec: AVByteCompareSpec) -> UInt64? {
        switch spec.encoding {
        case .binary:
            var value: UInt64 = 0
            for index in 0..<bytes.count {
                let byte = UInt64(bytes[spec.littleEndian ? bytes.count - 1 - index : index])
                value = value << 8 | byte
            }
            return value
        case .hex, .decimal, .automatic:
            var text = String(decoding: bytes.buffer, as: UTF8.self)
            var radix = spec.encoding == .hex ? 16 : 10
            if spec.encoding == .automatic, text.lowercased().hasPrefix("0x") { radix = 16; text = String(text.dropFirst(2)) }
            if spec.littleEndian, radix == 16 {
                // Little-endian hex: byte pairs in reverse order.
                var pairs = [String]()
                var characters = Array(text)
                if characters.count % 2 == 1 { characters.insert("0", at: 0) }
                for index in stride(from: 0, to: characters.count, by: 2) { pairs.append(String(characters[index..<index + 2])) }
                text = pairs.reversed().joined()
            }
            let digits = text.prefix { $0.isHexDigit && (radix == 16 || $0.isNumber) }
            if spec.exact && digits.count != text.count { return nil }
            return UInt64(digits, radix: radix)
        }
    }
}
