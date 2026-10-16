import Foundation

/// Compiled form of one body pattern, stored in the database and interpreted by the matcher.
///
/// Layout (little-endian):
/// ```
/// u16 elementCount
/// u32 minLength                 shortest input the pattern can match
/// u32 elementOffset[elementCount]  (relative to the program start)
/// elements:
///   1 LIT   u16 n, n bytes                       exact bytes
///   2 MASK  u16 n, n mask bytes, n value bytes   byte & mask == value
///   3 ANY   u32 n                                n arbitrary bytes
///   4 SET   32-byte bitmap                       one byte from a set
///   5 ALT   u8 negated, u16 count, u16 minLen, u16 maxLen, count × (u16 n, n mask, n value)
///   6 GAP   u32 min, u32 max (0xFFFFFFFF = unbounded)
///   7 SPEC  u8 class (AVSpecialClass)
/// ```
/// A gap is never the first or last element.
enum AVProgramOp: UInt8 {
    case literal = 1, masked = 2, any = 3, set = 4, alternatives = 5, gap = 6, special = 7
}

/// The 4 bytes the prefilter looks for, chosen inside one LIT or MASK element.
struct AVAnchorChoice: Sendable {
    /// Element index in the program.
    var element: Int
    /// Offset of the anchor inside that element.
    var delta: Int
    /// Every 4-byte value (little-endian load) the anchor can take (case variants, nibbles).
    var variants: [UInt32]
    /// Rarity in 1/8 bits (higher is rarer).
    var score: Int
    /// Expected prefilter hits per input byte.
    var hitRate: Double
}

/// Typical byte frequencies of files on a Mac (binaries, text, media), as `-log2(p) * 8`.
/// Used to pick rare anchors. Measured on this repository's development machine over ~170 MB
/// of /usr/bin, /Applications executables, text resources and images.
enum AVByteRarity {
    static let score: [UInt8] = [
         17,  52,  60,  55,  65,  65,  69,  69,  61,  68,  63,  75,  74,  73,  76,  62,
         66,  72,  76,  72,  68,  71,  75,  74,  73,  78,  77,  79,  78,  79,  79,  70,
         40,  70,  55,  73,  73,  75,  72,  77,  58,  58,  74,  74,  56,  53,  55,  70,
         58,  54,  60,  62,  61,  63,  66,  67,  66,  66,  61,  69,  75,  59,  74,  70,
         60,  58,  71,  65,  67,  62,  72,  75,  49,  62,  79,  78,  61,  68,  70,  68,
         69,  80,  65,  65,  65,  68,  75,  73,  78,  79,  80,  71,  67,  68,  78,  59,
         73,  50,  65,  54,  56,  43,  60,  62,  59,  49,  76,  70,  53,  60,  49,  50,
         58,  74,  49,  50,  45,  55,  67,  68,  69,  65,  79,  64,  71,  64,  83,  79,
         64,  75,  79,  67,  75,  68,  80,  82,  74,  54,  80,  59,  82,  65,  83,  84,
         73,  64,  82,  84,  65,  82,  84,  78,  81,  85,  83,  85,  84,  85,  85,  82,
         76,  82,  84,  83,  83,  85,  85,  84,  74,  67,  62,  85,  84,  82,  85,  85,
         75,  83,  78,  82,  78,  79,  81,  83,  75,  74,  80,  84,  84,  80,  79,  80,
         65,  74,  80,  73,  76,  82,  78,  72,  74,  80,  84,  84,  84,  86,  85,  85,
         72,  79,  77,  82,  79,  80,  77,  79,  80,  84,  80,  84,  85,  86,  83,  77,
         64,  75,  77,  81,  81,  77,  83,  81,  61,  75,  84,  74,  81,  83,  84,  82,
         73,  79,  78,  78,  74,  80,  73,  76,  70,  63,  80,  80,  78,  70,  71,  49,
    ]

    /// Rarity of a byte sequence; runs of the same byte are much more common than independent
    /// bytes would suggest (zero padding, 0xCC fill), so repeats only count half.
    static func score(_ bytes: [UInt8]) -> Int {
        var total = 0
        for (index, byte) in bytes.enumerated() {
            let s = Int(score[Int(byte)])
            total += index > 0 && bytes[index - 1] == byte ? s / 2 : s
        }
        return total
    }
}

/// Encodes parsed patterns into programs.
enum AVProgramEncoder {
    static let unbounded = UInt32.max
    static let maxAnchorVariants = 16

    struct Encoded {
        var program: [UInt8]
        var anchor: AVAnchorChoice?
        var minLength: Int
        /// Rarity of the exact bytes at the very start of the pattern (for anchored patterns without a prefilter anchor).
        var leadingExactScore: Int
        /// Without a 4-byte anchor: the rarest literal element of at least 2 bytes, searched for
        /// directly (memmem) by the scanner instead of trying every position.
        var shortAnchorElement: Int?
    }

    private enum RunKind { case literal, masked, any }

    @inline(__always)
    private static func kind(_ byte: AVMaskedByte) -> RunKind {
        byte.mask == 0xFF ? .literal : (byte.mask == 0 ? .any : .masked)
    }

    /// Patterns already using an anchor value at which spreading starts: a scan hitting a
    /// crowded anchor has to try every pattern behind it.
    static let crowdedAnchor = 12

    /// - Parameter crowding: How many patterns already use a 4-byte anchor value. When the rarest
    ///   window is crowded, a slightly more common but less shared window is preferred.
    static func encode(_ pattern: AVPatternIR, crowding: ((UInt32) -> Int)? = nil) throws -> Encoded {
        // First pass: element boundaries (op, run slice) so the offset table can be sized.
        struct Element {
            var op: AVProgramOp
            var run: ArraySlice<AVMaskedByte> = []
            var source: AVPatternElement?
        }
        var elements = [Element]()
        elements.reserveCapacity(pattern.elements.count + 4)
        var minLength = 0
        for element in pattern.elements {
            switch element {
            case .bytes(let run):
                minLength += run.count
                var index = run.startIndex
                while index < run.endIndex {
                    let first = kind(run[index])
                    var end = index + 1
                    while end < run.endIndex, end - index < 0xFFFF {
                        let next = kind(run[end])
                        // Short exact stretches inside masked runs stay masked (fewer elements).
                        if next == first || (first == .masked && next == .literal && !longLiteralAhead(run, end)) { end += 1 } else { break }
                    }
                    let op: AVProgramOp = first == .literal ? .literal : (first == .any ? .any : .masked)
                    elements.append(Element(op: op, run: run[index..<end]))
                    index = end
                }
            case .byteSet:
                minLength += 1
                elements.append(Element(op: .set, source: element))
            case .alternatives(let alternatives, _):
                guard alternatives.count <= 0xFFFF, let shortest = alternatives.map(\.count).min(),
                      let longest = alternatives.map(\.count).max(), longest > 0, longest <= 0xFFFF else {
                    throw AVSignatureRejection("invalid alternatives")
                }
                minLength += shortest
                elements.append(Element(op: .alternatives, source: element))
            case .gap(let low, let high):
                guard low <= Int(UInt32.max - 1), (high ?? 0) <= Int(UInt32.max - 1) else { throw AVSignatureRejection("gap too large") }
                minLength += low
                elements.append(Element(op: .gap, source: element))
            case .special:
                minLength += 1
                elements.append(Element(op: .special, source: element))
            }
        }
        guard !elements.isEmpty, elements.count <= 0xFFFF else { throw AVSignatureRejection("pattern too complex") }

        var writer = AVBinaryWriter(capacity: 6 + elements.count * 4 + minLength * 2 + 16)
        writer.u16(UInt16(elements.count))
        writer.u32(UInt32(min(minLength, Int(UInt32.max))))
        let tableStart = writer.count
        writer.zeros(elements.count * 4)
        var best: AVAnchorChoice?
        for (index, element) in elements.enumerated() {
            let offset = UInt32(writer.count)
            writer.bytes[tableStart + index * 4] = UInt8(offset & 0xFF)
            writer.bytes[tableStart + index * 4 + 1] = UInt8((offset >> 8) & 0xFF)
            writer.bytes[tableStart + index * 4 + 2] = UInt8((offset >> 16) & 0xFF)
            writer.bytes[tableStart + index * 4 + 3] = UInt8(offset >> 24)
            writer.u8(element.op.rawValue)
            switch element.op {
            case .literal:
                writer.u16(UInt16(element.run.count))
                for byte in element.run { writer.u8(byte.value) }
                if let choice = bestLiteralWindow(element.run, element: index, crowding: crowding),
                   best.map({ choice.hitRate < $0.hitRate * 0.999 }) ?? true {
                    best = choice
                }
            case .masked:
                writer.u16(UInt16(element.run.count))
                for byte in element.run { writer.u8(byte.mask) }
                for byte in element.run { writer.u8(byte.value) }
                if let choice = bestMaskedWindow(element.run, element: index), best.map({ choice.hitRate < $0.hitRate * 0.999 }) ?? true {
                    best = choice
                }
            case .any:
                writer.u32(UInt32(element.run.count))
            case .set:
                guard case .byteSet(let set)? = element.source else { break }
                writer.u64(set.words.0); writer.u64(set.words.1); writer.u64(set.words.2); writer.u64(set.words.3)
            case .alternatives:
                guard case .alternatives(let alternatives, let negated)? = element.source else { break }
                writer.u8(negated ? 1 : 0)
                writer.u16(UInt16(alternatives.count))
                writer.u16(UInt16(alternatives.map(\.count).min() ?? 0))
                writer.u16(UInt16(alternatives.map(\.count).max() ?? 0))
                for alternative in alternatives {
                    writer.u16(UInt16(alternative.count))
                    for byte in alternative { writer.u8(byte.mask) }
                    for byte in alternative { writer.u8(byte.value) }
                }
            case .gap:
                guard case .gap(let low, let high)? = element.source else { break }
                writer.u32(UInt32(low))
                writer.u32(high.map(UInt32.init) ?? unbounded)
            case .special:
                guard case .special(let special)? = element.source else { break }
                writer.u8(special.rawValue)
            }
        }

        var leadingScore = 0
        if case .bytes(let run)? = pattern.elements.first {
            var previous: UInt8?
            for byte in run.prefix(8) {
                guard byte.mask == 0xFF else { break }
                let s = Int(AVByteRarity.score[Int(byte.value)])
                leadingScore += previous == byte.value ? s / 2 : s
                previous = byte.value
            }
        }
        var shortAnchor: Int?
        if best == nil {
            var bestScore = -1
            for (index, element) in elements.enumerated() where element.op == .literal && element.run.count >= 2 {
                let bytes = element.run.prefix(4).map(\.value)
                let score = AVByteRarity.score(Array(bytes))
                if score > bestScore { bestScore = score; shortAnchor = index }
            }
        }
        return Encoded(program: writer.bytes, anchor: best, minLength: minLength, leadingExactScore: leadingScore, shortAnchorElement: shortAnchor)
    }

    /// Masked runs absorb short exact stretches; a long one (≥ 6 bytes) gets its own LIT element
    /// so it can carry the anchor without case variants.
    private static func longLiteralAhead(_ run: [AVMaskedByte], _ start: Int) -> Bool {
        var count = 0
        var index = start
        while index < run.count, run[index].mask == 0xFF, count < 6 {
            count += 1
            index += 1
        }
        return count >= 6
    }

    /// Rarity of 4 consecutive exact bytes; a repeated byte only counts half.
    @inline(__always)
    private static func windowScore(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Int {
        let table = AVByteRarity.score
        var total = Int(table[Int(a)])
        total += b == a ? Int(table[Int(b)]) / 2 : Int(table[Int(b)])
        total += c == b ? Int(table[Int(c)]) / 2 : Int(table[Int(c)])
        total += d == c ? Int(table[Int(d)]) / 2 : Int(table[Int(d)])
        return total
    }

    private static func bestLiteralWindow(_ run: ArraySlice<AVMaskedByte>, element: Int, crowding: ((UInt32) -> Int)?) -> AVAnchorChoice? {
        guard run.count >= 4 else { return nil }
        let base = run.startIndex
        func value(_ delta: Int) -> UInt32 {
            UInt32(run[base + delta].value) | UInt32(run[base + delta + 1].value) << 8
                | UInt32(run[base + delta + 2].value) << 16 | UInt32(run[base + delta + 3].value) << 24
        }
        func score(_ delta: Int) -> Int {
            windowScore(run[base + delta].value, run[base + delta + 1].value, run[base + delta + 2].value, run[base + delta + 3].value)
        }
        var bestScore = -1, bestDelta = 0
        for delta in 0...(run.count - 4) {
            let windowScore = score(delta)
            if windowScore > bestScore { bestScore = windowScore; bestDelta = delta }
        }
        var bestCost = exp2(-Double(bestScore) / 8)
        // Spread patterns away from crowded anchors: cost = hit rate × (1 + sharing / 8).
        if let crowding, crowding(value(bestDelta)) >= crowdedAnchor {
            bestCost *= 1 + Double(crowding(value(bestDelta))) / 8
            for delta in 0...(run.count - 4) where delta != bestDelta {
                let windowScore = score(delta)
                let cost = exp2(-Double(windowScore) / 8) * (1 + Double(crowding(value(delta))) / 8)
                if cost < bestCost { bestCost = cost; bestDelta = delta; bestScore = windowScore }
            }
        }
        return AVAnchorChoice(element: element, delta: bestDelta, variants: [value(bestDelta)], score: bestScore, hitRate: exp2(-Double(bestScore) / 8))
    }

    /// Windows of a MASK element: exact bytes, case-folded letters (2 variants) and nibbles (16),
    /// at most `maxAnchorVariants` combinations. The most common variant's rarity is used.
    private static func bestMaskedWindow(_ run: ArraySlice<AVMaskedByte>, element: Int) -> AVAnchorChoice? {
        guard run.count >= 4 else { return nil }
        let table = AVByteRarity.score
        func choices(_ byte: AVMaskedByte) -> (count: Int, score: Int)? {
            switch byte.mask {
            case 0xFF: return (1, Int(table[Int(byte.value)]))
            case 0xDF:
                guard byte.value >= 0x41, byte.value <= 0x5A else { return nil }
                return (2, min(Int(table[Int(byte.value)]), Int(table[Int(byte.value | 0x20)])))
            case 0xF0, 0x0F:
                var lowest = Int.max
                for nibble in 0..<16 {
                    let value = byte.mask == 0xF0 ? byte.value | UInt8(nibble) : byte.value | UInt8(nibble) << 4
                    lowest = min(lowest, Int(table[Int(value)]))
                }
                return (16, lowest)
            default:
                return nil
            }
        }
        var best: (delta: Int, cost: Double, score: Int)?
        let base = run.startIndex
        for delta in 0...(run.count - 4) {
            var variants = 1, score = 0
            var valid = true
            for k in 0..<4 {
                guard let choice = choices(run[base + delta + k]) else { valid = false; break }
                variants *= choice.count
                score += choice.score
            }
            guard valid, variants <= maxAnchorVariants else { continue }
            let cost = log2(Double(variants)) - Double(score) / 8
            if let current = best, cost >= current.cost { continue }
            best = (delta, cost, score)
        }
        guard let best else { return nil }
        var values: [UInt32] = [0]
        for k in 0..<4 {
            let byte = run[base + best.delta + k]
            var options = [UInt8]()
            for value in 0...255 where byte.matches(UInt8(value)) { options.append(UInt8(value)) }
            values = values.flatMap { prefix in options.map { prefix | UInt32($0) << (8 * UInt32(k)) } }
        }
        return AVAnchorChoice(element: element, delta: best.delta, variants: values, score: best.score, hitRate: exp2(best.cost))
    }
}

/// A program in the mapped database, with bounds-checked access.
struct AVProgramView {
    let bytes: AVByteView
    let elementCount: Int
    let minLength: Int

    init?(_ bytes: AVByteView) {
        guard let count = bytes.u16le(0), let minLength = bytes.u32le(2), bytes.contains(offset: 6, length: Int(count) * 4) else { return nil }
        self.bytes = bytes
        elementCount = Int(count)
        self.minLength = Int(minLength)
    }

    @inline(__always)
    func elementOffset(_ index: Int) -> Int? {
        guard index >= 0, index < elementCount, let offset = bytes.u32le(6 + index * 4), Int(offset) < bytes.count else { return nil }
        return Int(offset)
    }
}

/// Matches programs against a buffer. One instance per scanned buffer; not thread-safe.
///
/// A prefilter hit fixes the position of the anchor element; the elements after it are matched
/// forward and the elements before it backward. Both directions backtrack over gaps,
/// alternatives and `(L)`; a step budget bounds the work for pathological patterns (the match
/// then counts as failed, which can only cause a missed detection, never a false one).
struct AVPatternMatcher {
    let data: UnsafeRawPointer?
    let count: Int
    var budget = 0
    static let stepBudget = 200_000
    /// Results of unbounded-gap searches for the pattern being matched (see `AVGapMemo`).
    var memo: AVGapMemo?
    /// Identifies the pattern in `memo` (pattern index << 16).
    var memoBase: UInt64 = 0

    init(_ view: AVByteView) {
        data = view.base
        count = view.count
    }

    @inline(__always)
    func byte(_ position: Int) -> UInt8 {
        data.unsafelyUnwrapped.load(fromByteOffset: position, as: UInt8.self)
    }

    /// Length of a fixed-size element, or nil for variable ones (ALT with different lengths, GAP, `(L)`).
    func fixedLength(_ program: AVProgramView, _ offset: Int) -> Int? {
        guard let op = program.bytes.u8(offset) else { return nil }
        switch AVProgramOp(rawValue: op) {
        case .literal, .masked: return program.bytes.u16le(offset + 1).map(Int.init)
        case .any: return program.bytes.u32le(offset + 1).map(Int.init)
        case .set: return 1
        case .alternatives:
            guard let minLength = program.bytes.u16le(offset + 4), let maxLength = program.bytes.u16le(offset + 6), minLength == maxLength else { return nil }
            return Int(minLength)
        case .special:
            return program.bytes.u8(offset + 1) == AVSpecialClass.lineMarker.rawValue ? nil : 1
        default:
            return nil
        }
    }

    /// Does the LIT/MASK/ANY/SET element at `offset` match at `position`? Returns its length.
    @inline(__always)
    func matchSimple(_ program: AVProgramView, _ offset: Int, at position: Int) -> Int? {
        guard let op = program.bytes.u8(offset), let data else { return nil }
        switch AVProgramOp(rawValue: op) {
        case .literal:
            guard let length = program.bytes.u16le(offset + 1).map(Int.init), position >= 0, position <= count - length,
                  let literal = program.bytes.slice(offset + 3, length), let literalBase = literal.base else { return nil }
            return memcmp(data + position, literalBase, length) == 0 ? length : nil
        case .masked:
            guard let length = program.bytes.u16le(offset + 1).map(Int.init), position >= 0, position <= count - length,
                  let masks = program.bytes.slice(offset + 3, length), let values = program.bytes.slice(offset + 3 + length, length) else { return nil }
            var index = 0
            while index + 8 <= length {
                let input = data.loadUnaligned(fromByteOffset: position + index, as: UInt64.self)
                let mask = masks.base.unsafelyUnwrapped.loadUnaligned(fromByteOffset: index, as: UInt64.self)
                let value = values.base.unsafelyUnwrapped.loadUnaligned(fromByteOffset: index, as: UInt64.self)
                if input & mask != value { return nil }
                index += 8
            }
            while index < length {
                if byte(position + index) & masks[index] != values[index] { return nil }
                index += 1
            }
            return length
        case .any:
            guard let length = program.bytes.u32le(offset + 1).map(Int.init), position >= 0, position <= count - length else { return nil }
            return length
        case .set:
            guard position >= 0, position < count, setContains(program, offset + 1, byte(position)) else { return nil }
            return 1
        case .special:
            guard position >= 0, position < count, let kind = program.bytes.u8(offset + 1) else { return nil }
            let b = byte(position)
            switch AVSpecialClass(rawValue: kind) {
            case .boundary: return AVByteSet.boundary.contains(b) ? 1 : nil
            case .nonAlphanumeric: return AVByteSet.nonAlphanumeric.contains(b) ? 1 : nil
            default: return nil
            }
        default:
            return nil
        }
    }

    @inline(__always)
    private func setContains(_ program: AVProgramView, _ bitmapOffset: Int, _ value: UInt8) -> Bool {
        guard let word = program.bytes.u64le(bitmapOffset + Int(value >> 6) * 8) else { return false }
        return word >> UInt64(value & 63) & 1 == 1
    }

    /// One alternative (u16 n, n masks, n values) at `offset`; returns (length, next offset).
    private func alternative(_ program: AVProgramView, _ offset: Int) -> (length: Int, masks: AVByteView, values: AVByteView, next: Int)? {
        guard let length = program.bytes.u16le(offset).map(Int.init),
              let masks = program.bytes.slice(offset + 2, length), let values = program.bytes.slice(offset + 2 + length, length) else { return nil }
        return (length, masks, values, offset + 2 + 2 * length)
    }

    private func alternativeMatches(_ masks: AVByteView, _ values: AVByteView, at position: Int) -> Bool {
        guard position >= 0, position <= count - masks.count else { return false }
        for index in 0..<masks.count where byte(position + index) & masks[index] != values[index] { return false }
        return true
    }

    // MARK: Forward

    /// Matches elements `index...` starting at `position`. Returns the end of the first match whose
    /// end `acceptEnd` accepts.
    mutating func forward(_ program: AVProgramView, from index: Int, at position: Int, acceptEnd: (Int) -> Bool) -> Int? {
        var i = index
        var p = position
        while i < program.elementCount {
            guard let offset = program.elementOffset(i), let op = program.bytes.u8(offset) else { return nil }
            budget -= 1
            if budget < 0 { return nil }
            switch AVProgramOp(rawValue: op) {
            case .literal, .masked, .any, .set:
                guard let length = matchSimple(program, offset, at: p) else { return nil }
                p += length
            case .special:
                guard let kind = program.bytes.u8(offset + 1) else { return nil }
                if kind == AVSpecialClass.lineMarker.rawValue {
                    guard p < count else { return nil }
                    if byte(p) == 0x0A {
                        p += 1
                    } else if byte(p) == 0x0D {
                        // CRLF or a lone CR: try the longer form first.
                        if p + 1 < count, byte(p + 1) == 0x0A, let end = forward(program, from: i + 1, at: p + 2, acceptEnd: acceptEnd) { return end }
                        p += 1
                    } else {
                        return nil
                    }
                } else {
                    guard let length = matchSimple(program, offset, at: p) else { return nil }
                    p += length
                }
            case .alternatives:
                guard let negated = program.bytes.u8(offset + 1), let altCount = program.bytes.u16le(offset + 2) else { return nil }
                var cursor = offset + 8
                if negated == 1 {
                    guard let minLength = program.bytes.u16le(offset + 4).map(Int.init), p >= 0, p <= count - minLength else { return nil }
                    for _ in 0..<altCount {
                        guard let alt = alternative(program, cursor) else { return nil }
                        if alternativeMatches(alt.masks, alt.values, at: p) { return nil }
                        cursor = alt.next
                    }
                    p += minLength
                } else {
                    for _ in 0..<altCount {
                        guard let alt = alternative(program, cursor) else { return nil }
                        if alternativeMatches(alt.masks, alt.values, at: p),
                           let end = forward(program, from: i + 1, at: p + alt.length, acceptEnd: acceptEnd) {
                            return end
                        }
                        cursor = alt.next
                    }
                    return nil
                }
            case .gap:
                guard let low = program.bytes.u32le(offset + 1), let high = program.bytes.u32le(offset + 5),
                      let nextOffset = program.elementOffset(i + 1) else { return nil }
                let first = p + Int(low)
                let unbounded = high == AVProgramEncoder.unbounded
                let last = unbounded ? count : min(count, p + Int(high))
                guard first <= last else { return nil }
                let key = memoBase | UInt64(i)
                if unbounded, let known = memo?.forward[key] {
                    // The search from `first` covers part of an earlier one: reuse its outcome.
                    if first >= known.failFrom { return nil }
                    if first >= known.successFrom, first <= known.successAt { return known.successEnd }
                }
                guard literalMayOccur(program, nextOffset, range: last - first) else {
                    if unbounded { memo?.recordForwardFailure(key, from: first) }
                    return nil
                }
                var q = first
                while q <= last {
                    guard let candidate = nextCandidate(program, nextOffset, from: q, through: last) else { break }
                    if let end = forward(program, from: i + 1, at: candidate, acceptEnd: acceptEnd) {
                        if unbounded { memo?.recordForwardSuccess(key, from: first, at: candidate, end: end) }
                        return end
                    }
                    if budget < 0 { return nil }
                    q = candidate + 1
                }
                if unbounded { memo?.recordForwardFailure(key, from: first) }
                return nil
            default:
                return nil
            }
            i += 1
        }
        return acceptEnd(p) ? p : nil
    }

    /// The first position in `from...through` where the element at `offset` could start: the
    /// literal itself is searched with memmem (so only real occurrences are tried), masked
    /// elements are tested on their first byte.
    private func nextCandidate(_ program: AVProgramView, _ offset: Int, from: Int, through: Int) -> Int? {
        guard from <= through, let data, let op = program.bytes.u8(offset) else { return nil }
        if op == AVProgramOp.literal.rawValue, let length = program.bytes.u16le(offset + 1).map(Int.init), length > 0,
           let literal = program.bytes.slice(offset + 3, min(length, 32)), let needle = literal.base {
            // The match must start at or before `through` and fit in the buffer.
            let end = min(count, through + literal.count)
            return AVFind.first(needle, literal.count, in: data, from: from, end: end)
        }
        if op == AVProgramOp.masked.rawValue, let length = program.bytes.u16le(offset + 1), length > 0,
           let mask = program.bytes.u8(offset + 3), let value = program.bytes.u8(offset + 3 + Int(length)) {
            var q = from
            let end = min(through, count - 1)
            while q <= end {
                if byte(q) & mask == value { return q }
                q += 1
            }
            return nil
        }
        return from
    }

    /// End positions in `from...through` of every occurrence of the literal element at `offset`
    /// (ascending), found with memmem; nil when the element isn't a literal or occurs too often.
    private func literalEnds(_ program: AVProgramView, _ offset: Int, from: Int, through: Int) -> [Int]? {
        guard let data, program.bytes.u8(offset) == AVProgramOp.literal.rawValue,
              let length = program.bytes.u16le(offset + 1).map(Int.init), length >= 2,
              let literal = program.bytes.slice(offset + 3, length), let needle = literal.base else { return nil }
        let firstStart = max(0, from - length)
        let lastStart = min(through, count) - length
        var ends = [Int]()
        guard firstStart <= lastStart else { return ends }
        var position = firstStart
        while position <= lastStart {
            guard let start = AVFind.first(needle, length, in: data, from: position, end: lastStart + length) else { break }
            if start + length >= from { ends.append(start + length) }
            if ends.count > 1 << 20 { return nil }
            position = start + 1
        }
        return ends
    }

    /// For a gap search over a long range: `false` when the literal element at `offset` can't
    /// occur anywhere in the buffer (its 4-byte windows aren't all present).
    private func literalMayOccur(_ program: AVProgramView, _ offset: Int, range: Int) -> Bool {
        guard range >= AVPresenceFilter.farSearch, let memo, let data, program.bytes.u8(offset) == AVProgramOp.literal.rawValue,
              let length = program.bytes.u16le(offset + 1).map(Int.init), length >= 4,
              let literal = program.bytes.slice(offset + 3, min(length, 32)) else { return true }
        return memo.mayContain(literal, in: AVByteView(base: data, count: count))
    }

    /// The last end position in `notBefore...endingAtOrBefore` where the element at `offset` could
    /// end, testing its last byte (exact or masked) when it has one.
    private func previousCandidate(_ program: AVProgramView, _ offset: Int, endingAtOrBefore latest: Int, notBefore earliest: Int) -> Int? {
        guard latest >= earliest, let op = program.bytes.u8(offset) else { return nil }
        var mask: UInt8 = 0, value: UInt8 = 0
        if op == AVProgramOp.literal.rawValue, let length = program.bytes.u16le(offset + 1), length > 0,
           let last = program.bytes.u8(offset + 3 + Int(length) - 1) {
            mask = 0xFF; value = last
        } else if op == AVProgramOp.masked.rawValue, let length = program.bytes.u16le(offset + 1), length > 0,
                  let m = program.bytes.u8(offset + 3 + Int(length) - 1), let v = program.bytes.u8(offset + 3 + 2 * Int(length) - 1) {
            mask = m; value = v
        } else {
            return latest
        }
        var q = min(latest, count)
        let floor = max(earliest, 1)
        if mask == 0xFF, let data {
            // Exact last byte: test 8 bytes at a time (SWAR "has byte" trick), high to low.
            let pattern = UInt64(value) &* 0x0101_0101_0101_0101
            while q - 8 >= floor {
                let word = data.loadUnaligned(fromByteOffset: q - 8, as: UInt64.self) ^ pattern
                let zeros = (word &- 0x0101_0101_0101_0101) & ~word & 0x8080_8080_8080_8080
                if zeros != 0 {
                    // The highest matching byte in this word (little-endian: highest address = top byte).
                    let highest = (63 - zeros.leadingZeroBitCount) / 8
                    // The trick can flag a false byte below a true one, never above: verify downwards.
                    var k = highest
                    while k >= 0 {
                        if byte(q - 8 + k) == value { return q - 8 + k + 1 }
                        k -= 1
                    }
                }
                q -= 8
            }
        }
        while q >= floor {
            if byte(q - 1) & mask == value { return q }
            q -= 1
        }
        return nil
    }

    /// Every end position at which elements `0..<index` match (and the start each gives),
    /// for answering out-of-order backward gap queries.
    /// The work is linear in the buffer size (its own step budget), and the table is only kept
    /// when it was built completely.
    private mutating func allEnds(_ program: AVProgramView, before index: Int, previousOffset: Int, acceptStart: (Int) -> Bool) -> AVGapMemo.EndTable? {
        let savedBudget = budget
        budget = max(AVPatternMatcher.stepBudget, count * 4)
        defer { budget = savedBudget }
        var table = AVGapMemo.EndTable()
        var q = count
        while q >= 1 {
            guard let candidate = previousCandidate(program, previousOffset, endingAtOrBefore: q, notBefore: 1) else { break }
            if let start = backward(program, before: index, endingAt: candidate, acceptStart: acceptStart) {
                guard table.ends.count < AVGapMemo.EndTable.capacity else { return nil }
                table.ends.append(candidate)
                table.starts.append(start)
            }
            if budget < 0 { return nil }
            q = candidate - 1
        }
        table.ends.reverse()
        table.starts.reverse()
        return table
    }

    /// Minimum and maximum total length of elements `0..<index` (max is Int.max with an unbounded gap).
    func prefixLengthBounds(_ program: AVProgramView, before index: Int) -> (Int, Int)? {
        var low = 0, high = 0
        for element in 0..<index {
            guard let offset = program.elementOffset(element), let op = program.bytes.u8(offset) else { return nil }
            switch AVProgramOp(rawValue: op) {
            case .gap:
                guard let minimum = program.bytes.u32le(offset + 1), let maximum = program.bytes.u32le(offset + 5) else { return nil }
                low += Int(minimum)
                high = maximum == AVProgramEncoder.unbounded || high == Int.max ? Int.max : high + Int(maximum)
            case .alternatives:
                guard let minimum = program.bytes.u16le(offset + 4), let maximum = program.bytes.u16le(offset + 6) else { return nil }
                low += Int(minimum)
                if high != Int.max { high += Int(maximum) }
            case .special:
                low += 1
                if high != Int.max { high += 2 }
            default:
                guard let length = fixedLength(program, offset) else { return nil }
                low += length
                if high != Int.max { high += length }
            }
        }
        return (low, high)
    }

    // MARK: Backward

    /// Matches elements `0..<index` so that they end at `end` (exclusive). Returns the start of
    /// the first match whose start `acceptStart` accepts. `startWindow` (where the pattern may
    /// start, from its offset) bounds how far back gaps are searched.
    mutating func backward(_ program: AVProgramView, before index: Int, endingAt end: Int, startWindow: ClosedRange<Int>? = nil,
                           acceptStart: (Int) -> Bool) -> Int? {
        var i = index - 1
        var e = end
        while i >= 0 {
            guard let offset = program.elementOffset(i), let op = program.bytes.u8(offset) else { return nil }
            budget -= 1
            if budget < 0 { return nil }
            switch AVProgramOp(rawValue: op) {
            case .literal, .masked, .any:
                guard let length = fixedLength(program, offset), e - length >= 0, matchSimple(program, offset, at: e - length) != nil else { return nil }
                e -= length
            case .set:
                guard e >= 1, matchSimple(program, offset, at: e - 1) != nil else { return nil }
                e -= 1
            case .special:
                guard let kind = program.bytes.u8(offset + 1), e >= 1 else { return nil }
                if kind == AVSpecialClass.lineMarker.rawValue {
                    let last = byte(e - 1)
                    if last == 0x0A {
                        if e >= 2, byte(e - 2) == 0x0D, let start = backward(program, before: i, endingAt: e - 2, startWindow: startWindow, acceptStart: acceptStart) { return start }
                        e -= 1
                    } else if last == 0x0D {
                        e -= 1
                    } else {
                        return nil
                    }
                } else {
                    guard matchSimple(program, offset, at: e - 1) != nil else { return nil }
                    e -= 1
                }
            case .alternatives:
                guard let negated = program.bytes.u8(offset + 1), let altCount = program.bytes.u16le(offset + 2) else { return nil }
                var cursor = offset + 8
                if negated == 1 {
                    guard let length = program.bytes.u16le(offset + 4).map(Int.init), e - length >= 0 else { return nil }
                    for _ in 0..<altCount {
                        guard let alt = alternative(program, cursor) else { return nil }
                        if alternativeMatches(alt.masks, alt.values, at: e - length) { return nil }
                        cursor = alt.next
                    }
                    e -= length
                } else {
                    for _ in 0..<altCount {
                        guard let alt = alternative(program, cursor) else { return nil }
                        if e - alt.length >= 0, alternativeMatches(alt.masks, alt.values, at: e - alt.length),
                           let start = backward(program, before: i, endingAt: e - alt.length, startWindow: startWindow, acceptStart: acceptStart) {
                            return start
                        }
                        cursor = alt.next
                    }
                    return nil
                }
            case .gap:
                guard let low = program.bytes.u32le(offset + 1), let high = program.bytes.u32le(offset + 5) else { return nil }
                var latest = e - Int(low)
                let unbounded = high == AVProgramEncoder.unbounded
                var earliest = unbounded ? 0 : max(0, e - Int(high))
                // The elements before the gap span between minPrefix and maxPrefix bytes, so with a
                // known start window only ends in [window.lower + minPrefix, window.upper + maxPrefix] can work.
                if let startWindow, let (minPrefix, maxPrefix) = prefixLengthBounds(program, before: i) {
                    earliest = max(earliest, startWindow.lowerBound + minPrefix)
                    if maxPrefix < Int.max / 2, startWindow.upperBound < Int.max / 2 { latest = min(latest, startWindow.upperBound + maxPrefix) }
                }
                guard latest >= earliest, let previousOffset = program.elementOffset(i - 1) else { return nil }
                let key = memoBase | UInt64(i)
                // The start-window restriction depends only on the pattern's offset, which is the
                // same for every search of this gap in this buffer, so results can be reused.
                let memoize = unbounded
                guard literalMayOccur(program, previousOffset, range: latest - earliest) else {
                    if memoize { memo?.backward[key] = .init(searchedTo: count, best: nil) }
                    return nil
                }
                // With an unbounded gap, every end position up to `latest` is a candidate. Anchor hits
                // come in increasing order, so earlier searches already covered [0, searchedTo]:
                // only the part above it is new. Out-of-order queries (nested gaps) switch the gap
                // to a table of every end position that works.
                var floor = earliest
                var known: AVGapMemo.Backward?
                if memoize, let entry = memo?.backward[key] {
                    if let table = entry.allEnds {
                        return table.last(atOrBelow: latest, atLeast: earliest)
                    }
                    if latest <= entry.searchedTo {
                        if let best = entry.best, best.candidate <= latest { return best.start }
                        if entry.best == nil { return nil }
                        // Below a known success: nothing is known there. Build the full table once.
                        guard let table = allEnds(program, before: i, previousOffset: previousOffset, acceptStart: acceptStart) else { return nil }
                        memo?.backward[key] = .init(searchedTo: count, best: nil, allEnds: table)
                        return table.last(atOrBelow: latest, atLeast: earliest)
                    }
                    floor = entry.searchedTo + 1
                    known = entry
                }
                if let ends = literalEnds(program, previousOffset, from: floor, through: latest) {
                    // The element before the gap is a literal: try its occurrences, highest first.
                    for candidate in ends.reversed() {
                        if let start = backward(program, before: i, endingAt: candidate, startWindow: startWindow, acceptStart: acceptStart) {
                            if memoize { memo?.backward[key] = .init(searchedTo: latest, best: (candidate, start)) }
                            return start
                        }
                        if budget < 0 { return nil }
                    }
                } else {
                    var q = latest
                    while q >= floor {
                        guard let candidate = previousCandidate(program, previousOffset, endingAtOrBefore: q, notBefore: floor) else { break }
                        if let start = backward(program, before: i, endingAt: candidate, startWindow: startWindow, acceptStart: acceptStart) {
                            if memoize { memo?.backward[key] = .init(searchedTo: latest, best: (candidate, start)) }
                            return start
                        }
                        if budget < 0 { return nil }
                        q = candidate - 1
                    }
                }
                if memoize {
                    let best = known?.best
                    memo?.backward[key] = .init(searchedTo: latest, best: best)
                    return best?.start
                }
                return nil
            default:
                return nil
            }
            i -= 1
        }
        return acceptStart(e) ? e : nil
    }
}

/// Memo of unbounded-gap (`*`, `{n-}`) searches while matching one buffer.
///
/// Searching for what follows a `*` scans to the end of the buffer, and a frequent anchor
/// would repeat that scan for every occurrence (quadratic time). Keyed by pattern and gap
/// element, so the work per pattern and buffer stays linear:
/// * forward: if nothing matched from q, nothing matches from any later q'; if the first match
///   from q was at c, it's also the first match from any q' in q...c;
/// * backward: the searched range [0, searchedTo] and the highest candidate in it that matched
///   are kept, so a later search only looks at end positions above `searchedTo`.
final class AVGapMemo {
    struct Forward {
        /// Searches starting at or past this position fail.
        var failFrom: Int
        /// A search starting at `successFrom` first succeeded at `successAt`, giving `successEnd`.
        var successFrom: Int
        var successAt: Int
        var successEnd: Int
    }

    struct Backward {
        var searchedTo: Int
        /// The highest end position ≤ searchedTo from which the elements before the gap matched.
        var best: (candidate: Int, start: Int)?
        /// Every end position that works (built when queries arrive out of order).
        var allEnds: EndTable?
    }

    /// Sorted end positions with the start of the match each gives.
    struct EndTable {
        static let capacity = 1 << 18
        var ends = [Int]()
        var starts = [Int]()

        /// The start for the highest end in `atLeast...atOrBelow`.
        func last(atOrBelow latest: Int, atLeast earliest: Int) -> Int? {
            var low = 0, high = ends.count
            while low < high {
                let mid = (low + high) / 2
                if ends[mid] <= latest { low = mid + 1 } else { high = mid }
            }
            guard low > 0, ends[low - 1] >= earliest else { return nil }
            return starts[low - 1]
        }
    }

    private(set) var forward = [UInt64: Forward]()
    private var farSearches = 0
    private var presence: AVPresenceFilter?

    /// `false` when some 4-byte window of `literal` occurs nowhere in `data`, so a search for it
    /// can be skipped. The filter is only built once a buffer needs several far searches.
    func mayContain(_ literal: AVByteView, in data: AVByteView) -> Bool {
        farSearches += 1
        if presence == nil {
            guard farSearches >= AVPresenceFilter.buildAfter else { return true }
            presence = AVPresenceFilter(data)
        }
        return presence?.mayContain(literal) ?? true
    }
    var backward = [UInt64: Backward]() {
        didSet { if backward.count > Self.capacity { backward.removeAll(keepingCapacity: true) } }
    }
    static let capacity = 1 << 16

    func recordForwardFailure(_ key: UInt64, from position: Int) {
        if forward.count > Self.capacity { forward.removeAll(keepingCapacity: true) }
        var entry = forward[key] ?? Forward(failFrom: .max, successFrom: .max, successAt: -1, successEnd: -1)
        entry.failFrom = min(entry.failFrom, position)
        forward[key] = entry
    }

    func recordForwardSuccess(_ key: UInt64, from position: Int, at candidate: Int, end: Int) {
        if forward.count > Self.capacity { forward.removeAll(keepingCapacity: true) }
        var entry = forward[key] ?? Forward(failFrom: .max, successFrom: .max, successAt: -1, successEnd: -1)
        entry.successFrom = position
        entry.successAt = candidate
        entry.successEnd = end
        forward[key] = entry
    }
}

/// Which 4-byte values occur in a buffer (a Bloom filter with one hash), used to rule out
/// searches for literals that can't be there. All of a literal's 4-byte windows must be present.
final class AVPresenceFilter {
    /// Searches over at least this many bytes are "far".
    static let farSearch = 32 * 1024
    /// Far searches in one buffer before the filter is worth building (one pass over the buffer).
    static let buildAfter = 8
    private static let multiplier: UInt32 = 0x2545_F491

    private let storage: AVScratchBuffer?
    private let words: UnsafeMutablePointer<UInt64>
    private let wordCount: Int
    private let shift: UInt32

    init(_ data: AVByteView) {
        var log2 = 16
        while log2 < 25, (1 << log2) < data.count * 2 { log2 += 1 }
        // A failed mapping leaves a 1-word filter that accepts everything (fail open).
        storage = AVScratchBuffer(capacity: (1 << log2) / 8)
        if let storage {
            wordCount = (1 << log2) / 64
            shift = UInt32(32 - log2)
            words = storage.base.bindMemory(to: UInt64.self, capacity: wordCount)
        } else {
            wordCount = 1
            shift = 26
            words = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
            words.initialize(to: ~0)
        }
        guard let base = data.base, data.count >= 4 else { return }
        var position = 0
        let end = data.count - 3
        while position < end {
            let value = base.loadUnaligned(fromByteOffset: position, as: UInt32.self)
            let h = Int((value &* Self.multiplier) &>> shift)
            words[h &>> 6] |= 1 &<< UInt64(h & 63)
            position &+= 1
        }
    }

    deinit {
        if storage == nil { words.deallocate() }
    }

    func mayContain(_ literal: AVByteView) -> Bool {
        guard let base = literal.base, literal.count >= 4 else { return true }
        var position = 0
        while position + 4 <= literal.count {
            let value = base.loadUnaligned(fromByteOffset: position, as: UInt32.self)
            let h = Int((value &* Self.multiplier) &>> shift)
            if words[h &>> 6] & (1 &<< UInt64(h & 63)) == 0 { return false }
            position += 1
        }
        return true
    }
}
