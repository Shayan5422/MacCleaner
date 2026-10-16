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

/// One pass of the signature matcher over one buffer.
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
    /// kept in parallel arrays searched linearly (with a dictionary index once there are many).
    @exclusivity(unchecked) private var stateSignatures = [Int]()
    @exclusivity(unchecked) private var stateList = [LogicalState]()
    @exclusivity(unchecked) private var stateIndex = [Int: Int]()
    @exclusivity(unchecked) private var latin1: NSString?
    private static let linearStateLimit = 24

    @inline(__always)
    private func stateSlot(_ signature: Int) -> Int? {
        if stateSignatures.count <= Self.linearStateLimit {
            for (slot, candidate) in stateSignatures.enumerated() where candidate == signature { return slot }
            return nil
        }
        return stateIndex[signature]
    }

    private func addState(_ signature: Int, _ state: LogicalState) -> Int {
        stateSignatures.append(signature)
        stateList.append(state)
        let slot = stateList.count - 1
        if stateSignatures.count > Self.linearStateLimit {
            if stateIndex.isEmpty {
                for (index, candidate) in stateSignatures.enumerated() { stateIndex[candidate] = index }
            } else {
                stateIndex[signature] = slot
            }
        }
        return slot
    }

    struct LogicalState {
        var counts: [Int]
        var needed: [Int]
        var positions: [[Int]]
        var hasDeferred: Bool
        var firstSubsig: Int
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
        for t in targets {
            for index in patternList(db.anchoredLists[t]) { checkListed(index, deferred: false) }
            if floating {
                for index in patternList(db.weakLists[t]) { checkListed(index, deferred: false) }
            }
        }
        if stateList.contains(where: \.hasDeferred) {
            if let alive = aliveDeferredPatterns(), alive.count <= Self.dynamicDeferredLimit {
                // Few signatures are alive: scan only for their deferred patterns.
                dynamicDeferredPass(alive)
            } else if let table = db.deferredPrefilters[tableTarget] ?? db.deferredPrefilters[0] {
                prefilterPass(table, deferred: true)
            }
            for t in targets {
                for index in patternList(db.deferredLists[t]) { checkListed(index, deferred: true) }
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

    private func patternList(_ list: AVByteView) -> [Int] {
        guard let count = list.u32le(0).map(Int.init), count > 0 else { return [] }
        return (0..<count).compactMap { list.u32le(4 + $0 * 4).map(Int.init) }
    }

    // MARK: Deferred subsignatures

    /// Above this many patterns, the database's deferred table is used instead of a per-buffer one.
    static let dynamicDeferredLimit = 512

    /// Deferred (non-trigger) body patterns of the logical signatures that are alive in this buffer.
    private func aliveDeferredPatterns() -> [Int]? {
        var patterns = [Int]()
        for (slot, signature) in stateSignatures.enumerated() where stateList[slot].hasDeferred {
            guard let record = db.signature(signature) else { continue }
            for id in 0..<record.subsigCount {
                guard let subsig = db.subsig(record.firstSubsig + id), subsig.kind == .body, !subsig.isTrigger else { continue }
                for k in 0..<subsig.patternCount { patterns.append(subsig.first + k) }
                if patterns.count > Self.dynamicDeferredLimit { return nil }
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
            let byte = AVMaskedByte(mask: mask, value: value)
            let choices = (0...255).compactMap { byte.matches(UInt8($0)) ? UInt8($0) : nil }
            guard values.count * choices.count <= AVProgramEncoder.maxAnchorVariants else { return nil }
            values = values.flatMap { prefix in choices.map { prefix | UInt32($0) << (8 * UInt32(k)) } }
        }
        return values
    }

    /// A one-off prefilter (64 Ki-bit bitmap + dictionary) over the given patterns' anchors.
    private func dynamicDeferredPass(_ patterns: [Int]) {
        var byAnchor = [UInt32: [Int]]()
        var bitmap = [UInt64](repeating: 0, count: 1024)
        for index in patterns {
            guard let pattern = db.pattern(index), let values = anchorValues(pattern) else { continue }
            for value in values {
                byAnchor[value, default: []].append(index)
                let h = Int((value &* AVDatabaseFormat.bitmapMultiplier) &>> 16)
                bitmap[h &>> 6] |= 1 &<< UInt64(h & 63)
            }
        }
        guard !byAnchor.isEmpty, let base = data.base, data.count >= 4 else { return }
        bitmap.withUnsafeBufferPointer { bits in
            let end = data.count - 3
            var position = 0
            while position < end {
                let value = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: position, as: UInt32.self))
                let h = Int((value &* AVDatabaseFormat.bitmapMultiplier) &>> 16)
                if bits[h &>> 6] & (1 &<< UInt64(h & 63)) != 0, let candidates = byAnchor[value] {
                    for index in candidates { checkCandidate(index, anchorPosition: position, deferred: true) }
                }
                position &+= 1
            }
        }
    }

    // MARK: Prefilter

    /// Hashes every 4-byte window into the table's bitmap; set bits lead to candidate patterns.
    private func prefilterPass(_ table: AVPrefilterTable, deferred: Bool) {
        guard let base = data.base, data.count >= 4 else { return }
        let bitmap = table.bitmap
        let shift = table.bitmapShift
        let end = data.count - 3
        var position = 0
        while position < end {
            let value = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: position, as: UInt32.self))
            let h = Int((value &* AVDatabaseFormat.bitmapMultiplier) &>> shift)
            if bitmap[h &>> 6] & (1 &<< UInt64(h & 63)) != 0 {
                candidates(table, value, position, deferred: deferred)
            }
            position &+= 1
        }
    }

    @inline(never)
    private func candidates(_ table: AVPrefilterTable, _ value: UInt32, _ position: Int, deferred: Bool) {
        guard let (start, count) = table.lookup(value) else { return }
        for k in 0..<count {
            guard let index = table.candidate(start + k) else { return }
            checkCandidate(index, anchorPosition: position, deferred: deferred)
        }
    }

    /// Cheap filters before full verification: options, already-matched signatures, saturated counts.
    private func shouldCheck(signature: Int, subsig: Int?, deferred: Bool) -> Bool {
        guard let flags = db.signatureFlags(signature) else { return false }
        if flags.contains(.pua) && !options.detectPUA { return false }
        if flags.contains(.nonMac) && !options.detectNonMacThreats { return false }
        guard let subsig else { return !bodyMatches.contains(signature) }
        guard let slot = stateSlot(signature) else { return !deferred }
        let state = stateList[slot]
        return subsig >= state.counts.count || state.counts[subsig] < state.needed[subsig]
    }

    private func checkCandidate(_ index: Int, anchorPosition: Int, deferred: Bool) {
        let table = db.patternTable
        let base = index * AVDatabaseFormat.patternRecordSize
        // Most candidates are rejected by their anchor element (usually a literal run longer than
        // the 4-byte anchor), so test it before any bookkeeping.
        guard let programOffset = table.u32le(base + 4), let programLength = table.u32le(base + 8),
              let anchorElement = table.u16le(base + 12), let anchorDelta = table.u16le(base + 14),
              let programBytes = db.programs.slice(Int(programOffset), Int(programLength)),
              let program = AVProgramView(programBytes), let elementOffset = program.elementOffset(Int(anchorElement)) else { return }
        let runStart = anchorPosition - Int(anchorDelta)
        guard runStart >= 0, AVPatternMatcher(data).matchSimple(program, elementOffset, at: runStart) != nil else { return }

        guard let signature = table.u32le(base).map(Int.init), let subsigByte = table.u8(base + 16) else { return }
        let subsig: Int? = subsigByte == 0xFF ? nil : Int(subsigByte)
        guard shouldCheck(signature: signature, subsig: subsig, deferred: deferred), let pattern = db.pattern(index),
              let match = verify(pattern, index: index, anchorPosition: anchorPosition) else { return }
        record(pattern, start: match)
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
            // The start is pinned by the offset: rule out impossible starts before any forward search.
            if let (minPrefix, maxPrefix) = matcher.prefixLengthBounds(pattern.program, before: anchorElement) {
                let latestStart = runStart - minPrefix
                let earliestStart = maxPrefix == Int.max ? 0 : runStart - maxPrefix
                guard latestStart >= window.lowerBound, earliestStart <= window.upperBound else { return nil }
            }
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
