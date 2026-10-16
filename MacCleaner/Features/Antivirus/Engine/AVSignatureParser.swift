import Foundation

/// Why a signature line wasn't loaded. The text is used in the coverage report.
struct AVSignatureRejection: Error, Hashable, Sendable {
    var reason: String
    init(_ reason: String) { self.reason = reason }
}

/// Parses ClamAV's signature text formats (https://docs.clamav.net/manual/Signatures.html).
///
/// Body patterns ("hex signatures"):
/// * `aa` byte, `??` any byte, `a?` / `?a` nibble wildcards
/// * `*` any number of bytes, `{n}` exactly n, `{-n}` at most n, `{n-}` at least n, `{n-m}`,
///   `[n-m]` (n to m bytes, m ≤ 32 in ClamAV)
/// * `(aa|bb)` one of several bytes, `!(aa|bb)` any byte but these, `(aabb|ccdd)` fixed-length
///   multi-byte alternatives (negatable), generic alternatives of different lengths that may
///   contain `??`, nibbles and `{n}`
/// * `(B)` word boundary, `(L)` line end, `(W)` non-alphanumeric; at the start or end of a
///   pattern they test the neighbouring byte (or the start/end of the data)
/// * `~aa`, `~a?`, `~?a` single byte/nibble negation (functionality level 240)
///
/// Logical-signature modifiers: `::i` case-insensitive, `::w` wide (each literal byte followed by
/// NUL; wildcards and gaps are not widened), `::a` ASCII (with `w`: both forms), `::f` fullword.
enum AVSignatureParser {
    // MARK: - Hex patterns

    struct Modifiers: Hashable, Sendable {
        var caseInsensitive = false
        var wide = false
        var ascii = false
        var fullword = false

        static let none = Modifiers()

        init() {}

        init(text: some Sequence<UInt8>) throws {
            for c in text {
                switch c {
                case UInt8(ascii: "i"): caseInsensitive = true
                case UInt8(ascii: "w"): wide = true
                case UInt8(ascii: "a"): ascii = true
                case UInt8(ascii: "f"): fullword = true
                default: throw AVSignatureRejection("unknown subsignature modifier")
                }
            }
        }
    }

    /// Parses a body pattern into one variant, or two for `::wa` (ASCII and wide).
    static func parsePattern(_ text: UnsafeBufferPointer<UInt8>, modifiers: Modifiers = .none) throws -> [AVPatternIR] {
        var base = try parseRawPattern(text)
        if modifiers.caseInsensitive { base = makeCaseInsensitive(base) }
        base.fullword = modifiers.fullword
        var variants = [AVPatternIR]()
        if !modifiers.wide || modifiers.ascii { variants.append(base) }
        if modifiers.wide { variants.append(widen(base)) }
        return variants
    }

    static func parsePattern(_ text: String, modifiers: Modifiers = .none) throws -> [AVPatternIR] {
        var bytes = Array(text.utf8)
        return try bytes.withUnsafeMutableBufferPointer { try parsePattern(UnsafeBufferPointer($0), modifiers: modifiers) }
    }

    private static func parseRawPattern(_ p: UnsafeBufferPointer<UInt8>) throws -> AVPatternIR {
        guard !p.isEmpty else { throw AVSignatureRejection("empty pattern") }
        var elements = [AVPatternElement]()
        var run = [AVMaskedByte]()
        run.reserveCapacity(p.count / 2)
        var left: AVSpecialClass?
        var i = 0
        let n = p.count

        func flush() {
            if !run.isEmpty { elements.append(.bytes(run)); run.removeAll(keepingCapacity: true) }
        }

        while i < n {
            let c = p[i]
            switch c {
            case UInt8(ascii: "*"):
                flush()
                elements.append(.gap(min: 0, max: nil))
                i += 1
            case UInt8(ascii: "{"):
                guard let close = index(of: UInt8(ascii: "}"), in: p, from: i + 1) else { throw AVSignatureRejection("unterminated {}") }
                let (low, high) = try parseRange(p, i + 1, close, allowOpenLow: true)
                if let high, low == high {
                    // Fixed skip: equivalent to that many `??`.
                    guard low <= 1 << 24 else { throw AVSignatureRejection("gap too large") }
                    run.append(contentsOf: repeatElement(AVMaskedByte.any, count: low))
                } else {
                    flush()
                    elements.append(.gap(min: low, max: high))
                }
                i = close + 1
            case UInt8(ascii: "["):
                guard let close = index(of: UInt8(ascii: "]"), in: p, from: i + 1) else { throw AVSignatureRejection("unterminated []") }
                let (low, high) = try parseRange(p, i + 1, close, allowOpenLow: false)
                guard let high else { throw AVSignatureRejection("[n-] range without an upper bound") }
                flush()
                elements.append(.gap(min: low, max: high))
                i = close + 1
            case UInt8(ascii: "!"):
                guard i + 1 < n, p[i + 1] == UInt8(ascii: "(") else { throw AVSignatureRejection("! not followed by (") }
                guard let close = index(of: UInt8(ascii: ")"), in: p, from: i + 2) else { throw AVSignatureRejection("unterminated !()") }
                let alternatives = try parseAlternatives(p, i + 2, close)
                guard let length = alternatives.first?.count, length > 0, alternatives.allSatisfy({ $0.count == length }),
                      alternatives.allSatisfy({ $0.allSatisfy { $0.mask == 0xFF } }) else {
                    throw AVSignatureRejection("negated alternatives must be fixed-length literals")
                }
                if length == 1 {
                    var set = AVByteSet()
                    for alternative in alternatives { set.insert(alternative[0].value) }
                    flushIfNeeded(&run, &elements)
                    elements.append(.byteSet(set.inverted))
                } else {
                    flush()
                    elements.append(.alternatives(alternatives, negated: true))
                }
                i = close + 1
            case UInt8(ascii: "("):
                if i + 2 < n, p[i + 2] == UInt8(ascii: ")"), let special = specialClass(p[i + 1]) {
                    if elements.isEmpty && run.isEmpty && left == nil {
                        left = special
                    } else {
                        flush()
                        elements.append(.special(special))
                    }
                    i += 3
                    continue
                }
                guard let close = index(of: UInt8(ascii: ")"), in: p, from: i + 1) else { throw AVSignatureRejection("unterminated ()") }
                let alternatives = try parseAlternatives(p, i + 1, close)
                guard alternatives.contains(where: { !$0.isEmpty }) else { throw AVSignatureRejection("empty alternatives") }
                if alternatives.allSatisfy({ $0.count == 1 }) {
                    var set = AVByteSet()
                    for alternative in alternatives { set.insert(matching: alternative[0]) }
                    flushIfNeeded(&run, &elements)
                    elements.append(.byteSet(set))
                } else {
                    flush()
                    elements.append(.alternatives(alternatives, negated: false))
                }
                i = close + 1
            case UInt8(ascii: "~"):
                // Single byte or nibble negation (functionality level 240).
                guard let byte = parseHexPosition(p, i + 1), byte.mask != 0 else {
                    throw AVSignatureRejection("invalid ~ negation")
                }
                var set = AVByteSet()
                set.insert(matching: byte)
                flushIfNeeded(&run, &elements)
                elements.append(.byteSet(set.inverted))
                i += 3
            default:
                guard let byte = parseHexPosition(p, i) else { throw AVSignatureRejection("invalid hex pattern") }
                run.append(byte)
                i += 2
            }
        }
        flush()

        var pattern = AVPatternIR(elements: elements, leftAssertion: left, rightAssertion: nil)
        if case .special(let special)? = pattern.elements.last {
            pattern.elements.removeLast()
            pattern.rightAssertion = special
        }
        guard pattern.elements.contains(where: { !$0.isGap }) else { throw AVSignatureRejection("pattern has no bytes to match") }
        if pattern.elements.first?.isGap == true || pattern.elements.last?.isGap == true {
            throw AVSignatureRejection("pattern starts or ends with a wildcard")
        }
        return pattern
    }

    /// Single-byte elements (sets) go into their own element; byte runs stay merged.
    private static func flushIfNeeded(_ run: inout [AVMaskedByte], _ elements: inout [AVPatternElement]) {
        if !run.isEmpty { elements.append(.bytes(run)); run.removeAll(keepingCapacity: true) }
    }

    /// Merges consecutive byte runs.
    private static func merge(_ elements: [AVPatternElement]) -> [AVPatternElement] {
        var out = [AVPatternElement]()
        out.reserveCapacity(elements.count)
        for element in elements {
            if case .bytes(let next) = element, case .bytes(let previous)? = out.last {
                out[out.count - 1] = .bytes(previous + next)
            } else {
                out.append(element)
            }
        }
        return out
    }

    private static func specialClass(_ c: UInt8) -> AVSpecialClass? {
        switch c {
        case UInt8(ascii: "B"): return .boundary
        case UInt8(ascii: "L"): return .lineMarker
        case UInt8(ascii: "W"): return .nonAlphanumeric
        default: return nil
        }
    }

    private static func index(of c: UInt8, in p: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        var i = from
        while i < p.count {
            if p[i] == c { return i }
            i += 1
        }
        return nil
    }

    /// Two characters: `aa`, `??`, `a?` or `?a`.
    @inline(__always)
    private static func parseHexPosition(_ p: UnsafeBufferPointer<UInt8>, _ i: Int) -> AVMaskedByte? {
        guard i + 1 < p.count else { return nil }
        let c1 = p[i], c2 = p[i + 1]
        let q = UInt8(ascii: "?")
        switch (c1 == q, c2 == q) {
        case (true, true): return .any
        case (false, false):
            guard let h = AVHex.nibble(c1), let l = AVHex.nibble(c2) else { return nil }
            return .exact(h << 4 | l)
        case (false, true):
            guard let h = AVHex.nibble(c1) else { return nil }
            return AVMaskedByte(mask: 0xF0, value: h << 4)
        case (true, false):
            guard let l = AVHex.nibble(c2) else { return nil }
            return AVMaskedByte(mask: 0x0F, value: l)
        }
    }

    /// `n`, `-n`, `n-`, `n-m` between `start` and `end` (exclusive).
    private static func parseRange(_ p: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int, allowOpenLow: Bool) throws -> (Int, Int?) {
        var dash: Int?
        for i in start..<end where p[i] == UInt8(ascii: "-") {
            guard dash == nil else { throw AVSignatureRejection("invalid range") }
            dash = i
        }
        func number(_ from: Int, _ to: Int) throws -> Int? {
            guard from < to else { return nil }
            var value = 0
            for i in from..<to {
                let c = p[i]
                guard c >= 0x30, c <= 0x39, value < 1 << 40 else { throw AVSignatureRejection("invalid number in range") }
                value = value * 10 + Int(c - 0x30)
            }
            return value
        }
        guard let dash else {
            guard let value = try number(start, end) else { throw AVSignatureRejection("empty range") }
            return (value, value)
        }
        let low = try number(start, dash)
        let high = try number(dash + 1, end)
        if low == nil && !allowOpenLow { throw AVSignatureRejection("range without a lower bound") }
        if low == nil && high == nil { throw AVSignatureRejection("empty range") }
        if let low, let high, high < low { throw AVSignatureRejection("range upper bound below lower bound") }
        return (low ?? 0, high)
    }

    /// Alternatives between `start` and `end`: byte strings separated by `|` that may contain
    /// `??`, nibbles and fixed `{n}` skips (generic alternates), but no nesting or gaps.
    private static func parseAlternatives(_ p: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) throws -> [[AVMaskedByte]] {
        var alternatives = [[AVMaskedByte]]()
        var current = [AVMaskedByte]()
        var i = start
        while i <= end {
            if i == end || p[i] == UInt8(ascii: "|") {
                // An empty alternative makes the group optional ("(2526|)").
                alternatives.append(current)
                current = []
                i += 1
                continue
            }
            switch p[i] {
            case UInt8(ascii: "{"):
                guard let close = index(of: UInt8(ascii: "}"), in: p, from: i + 1), close < end else { throw AVSignatureRejection("unterminated {} in alternative") }
                let (low, high) = try parseRange(p, i + 1, close, allowOpenLow: false)
                guard let high, high == low, low < 128 else { throw AVSignatureRejection("variable gap inside alternatives") }
                current.append(contentsOf: repeatElement(AVMaskedByte.any, count: low))
                i = close + 1
            case UInt8(ascii: "("), UInt8(ascii: "*"), UInt8(ascii: "["), UInt8(ascii: "!"), UInt8(ascii: "~"):
                throw AVSignatureRejection("nested alternatives or gaps inside alternatives")
            default:
                guard let byte = parseHexPosition(p, i), i + 1 < end else { throw AVSignatureRejection("invalid alternative") }
                current.append(byte)
                i += 2
            }
        }
        return alternatives
    }

    // MARK: Modifiers

    private static func makeCaseInsensitive(_ pattern: AVPatternIR) -> AVPatternIR {
        var copy = pattern
        copy.elements = pattern.elements.map { element in
            switch element {
            case .bytes(let run):
                return .bytes(run.map(\.caseInsensitive))
            case .byteSet(let set):
                var folded = set
                for byte in set.bytes {
                    let lower = byte | 0x20
                    if lower >= 0x61 && lower <= 0x7A { folded.insert(byte ^ 0x20) }
                }
                return .byteSet(folded)
            case .alternatives(let alternatives, let negated):
                if negated {
                    // Expand each negated literal into its case variants so the negation stays exact.
                    var expanded = Set<[UInt8]>()
                    for alternative in alternatives {
                        var variants: [[UInt8]] = [[]]
                        for byte in alternative {
                            let lower = byte.value | 0x20
                            let isLetter = lower >= 0x61 && lower <= 0x7A
                            variants = variants.flatMap { prefix in isLetter ? [prefix + [lower], prefix + [lower & 0xDF]] : [prefix + [byte.value]] }
                            if variants.count > 256 { break }
                        }
                        expanded.formUnion(variants)
                    }
                    return .alternatives(expanded.sorted { $0.lexicographicallyPrecedes($1) }.map { $0.map(AVMaskedByte.exact) }, negated: true)
                }
                return .alternatives(alternatives.map { $0.map(\.caseInsensitive) }, negated: false)
            default:
                return element
            }
        }
        return copy
    }

    /// `::w`: every byte position that tests something is followed by a NUL. `??` and gaps aren't widened.
    private static func widen(_ pattern: AVPatternIR) -> AVPatternIR {
        func widenRun(_ run: [AVMaskedByte]) -> [AVMaskedByte] {
            var out = [AVMaskedByte]()
            out.reserveCapacity(run.count * 2)
            for byte in run {
                out.append(byte)
                if byte.mask != 0 { out.append(.exact(0)) }
            }
            return out
        }
        var copy = pattern
        copy.wide = true
        var elements = [AVPatternElement]()
        for element in pattern.elements {
            switch element {
            case .bytes(let run):
                elements.append(.bytes(widenRun(run)))
            case .byteSet:
                elements.append(element)
                elements.append(.bytes([.exact(0)]))
            case .alternatives(let alternatives, let negated):
                elements.append(.alternatives(alternatives.map(widenRun), negated: negated))
            case .gap, .special:
                elements.append(element)
            }
        }
        copy.elements = merge(elements)
        return copy
    }

    // MARK: - Offsets

    static func parseOffset(_ text: some StringProtocol) throws -> AVOffsetSpec {
        if text == "*" { return .anywhere }
        var spec = AVOffsetSpec()
        var body = Substring(text)
        if let comma = body.firstIndex(of: ",") {
            guard let shift = Int(body[body.index(after: comma)...]), shift >= 0, shift < 1 << 31 else {
                throw AVSignatureRejection("invalid offset shift")
            }
            spec.maxShift = shift
            body = body[..<comma]
        }
        func number(_ s: Substring) throws -> Int {
            guard let value = Int(s), value >= 0, value < 1 << 31 else { throw AVSignatureRejection("invalid offset") }
            return value
        }
        if let value = Int(body), value >= 0, value < 1 << 31 {
            spec.kind = .absolute
            spec.value = value
        } else if body.hasPrefix("EOF-") {
            spec.kind = .endOfFile
            spec.value = try number(body.dropFirst(4))
        } else if body.hasPrefix("EP+") || body.hasPrefix("EP-") {
            spec.kind = .entryPoint
            let value = try number(body.dropFirst(3))
            spec.value = body.hasPrefix("EP-") ? -value : value
        } else if body.hasPrefix("SL+") || body.hasPrefix("SL-") {
            spec.kind = .lastSection
            let value = try number(body.dropFirst(3))
            spec.value = body.hasPrefix("SL-") ? -value : value
        } else if body.hasPrefix("SE") {
            spec.kind = .sectionEntire
            spec.section = try number(body.dropFirst(2))
            guard spec.maxShift == 0 else { throw AVSignatureRejection("SEx offsets can't have a shift") }
        } else if body.hasPrefix("S"), let sign = body.firstIndex(where: { $0 == "+" || $0 == "-" }) {
            spec.kind = .sectionStart
            spec.section = try number(body[body.index(after: body.startIndex)..<sign])
            let value = try number(body[body.index(after: sign)...])
            spec.value = body[sign] == "-" ? -value : value
        } else if body == "VI" {
            throw AVSignatureRejection("VI (PE version information) offsets aren't supported")
        } else if body.hasPrefix("$") {
            throw AVSignatureRejection("macro offsets aren't supported")
        } else {
            throw AVSignatureRejection("unknown offset type")
        }
        return spec
    }

    // MARK: - Logical expressions

    /// Parses a logical expression. ClamAV gives `&` and `|` the same precedence and splits at the
    /// first top-level operator, so `0&1|2` means `0&(1|2)`.
    static func parseExpression(_ text: some StringProtocol, subsigCount: Int) throws -> AVLogicalNode {
        // A few official signatures put spaces in their expressions ("0 & 1 > 200").
        let bytes = Array(text.utf8).filter { $0 != 0x20 && $0 != 0x09 }
        guard !bytes.isEmpty, bytes.count < 65536 else { throw AVSignatureRejection("empty logical expression") }
        var depth = 0
        return try parseExpression(bytes, 0, bytes.count, subsigCount: subsigCount, depth: &depth)
    }

    private static func parseExpression(_ s: [UInt8], _ start: Int, _ end: Int, subsigCount: Int, depth: inout Int) throws -> AVLogicalNode {
        depth += 1
        defer { depth -= 1 }
        guard depth < 200 else { throw AVSignatureRejection("logical expression nested too deeply") }
        guard start < end else { throw AVSignatureRejection("empty logical (sub)expression") }
        var level = 0
        for i in start..<end {
            switch s[i] {
            case UInt8(ascii: "("): level += 1
            case UInt8(ascii: ")"):
                level -= 1
                guard level >= 0 else { throw AVSignatureRejection("unbalanced parentheses") }
            case UInt8(ascii: "&"), UInt8(ascii: "|"):
                if level == 0 {
                    let lhs = try parsePrimary(s, start, i, subsigCount: subsigCount, depth: &depth)
                    let rhs = try parseExpression(s, i + 1, end, subsigCount: subsigCount, depth: &depth)
                    return s[i] == UInt8(ascii: "&") ? .and(lhs, rhs) : .or(lhs, rhs)
                }
            default:
                break
            }
        }
        guard level == 0 else { throw AVSignatureRejection("unbalanced parentheses") }
        return try parsePrimary(s, start, end, subsigCount: subsigCount, depth: &depth)
    }

    /// A subsignature number or a parenthesized expression, optionally followed by `=X`, `>X`, `<X` and `,Y`.
    private static func parsePrimary(_ s: [UInt8], _ start: Int, _ end: Int, subsigCount: Int, depth: inout Int) throws -> AVLogicalNode {
        guard start < end else { throw AVSignatureRejection("missing operand in logical expression") }
        var node: AVLogicalNode
        var cursor: Int
        if s[start] == UInt8(ascii: "(") {
            var level = 0
            var close: Int?
            for i in start..<end {
                if s[i] == UInt8(ascii: "(") { level += 1 }
                if s[i] == UInt8(ascii: ")") {
                    level -= 1
                    if level == 0 { close = i; break }
                }
            }
            guard let close else { throw AVSignatureRejection("unbalanced parentheses") }
            node = try parseExpression(s, start + 1, close, subsigCount: subsigCount, depth: &depth)
            cursor = close + 1
        } else {
            var value = 0
            cursor = start
            while cursor < end, s[cursor] >= 0x30, s[cursor] <= 0x39 {
                value = value * 10 + Int(s[cursor] - 0x30)
                guard value < 1 << 20 else { throw AVSignatureRejection("subsignature index too large") }
                cursor += 1
            }
            guard cursor > start else { throw AVSignatureRejection("invalid token in logical expression") }
            guard value < subsigCount else { throw AVSignatureRejection("logical expression refers to a missing subsignature") }
            node = .subsig(value)
        }
        guard cursor < end else { return node }
        let opChar = s[cursor]
        guard let op = AVLogicalNode.CountOperator(rawValue: opChar) else { throw AVSignatureRejection("invalid operator in logical expression") }
        cursor += 1
        func readNumber() throws -> Int {
            var value = 0
            let begin = cursor
            while cursor < end, s[cursor] >= 0x30, s[cursor] <= 0x39 {
                value = value * 10 + Int(s[cursor] - 0x30)
                guard value < 1 << 30 else { throw AVSignatureRejection("count too large") }
                cursor += 1
            }
            guard cursor > begin else { throw AVSignatureRejection("missing count in logical expression") }
            return value
        }
        let value = try readNumber()
        var distinct: Int?
        if cursor < end, s[cursor] == UInt8(ascii: ",") {
            cursor += 1
            distinct = try readNumber()
        }
        guard cursor == end else { throw AVSignatureRejection("unexpected text after count in logical expression") }
        return .count(node, op: op, value: value, distinct: distinct)
    }

    // MARK: - Target description block

    struct TargetDescription: Sendable {
        var target: Int?
        var engineMin: Int?
        var engineMax: Int?
        var constraints = AVTargetConstraints()
    }

    static func parseTargetDescription(_ text: String) throws -> TargetDescription {
        var description = TargetDescription()
        for item in text.split(separator: ",") {
            guard let colon = item.firstIndex(of: ":") else { throw AVSignatureRejection("malformed target description") }
            let key = item[..<colon]
            let value = item[item.index(after: colon)...]
            switch key {
            case "Target":
                guard let target = Int(value) else { throw AVSignatureRejection("invalid Target") }
                description.target = target
            case "Engine":
                let (low, high) = try range(value)
                description.engineMin = low
                description.engineMax = high
            case "FileSize":
                let (low, high) = try range(value)
                description.constraints.fileSize = low...(high ?? Int.max)
            case "EntryPoint":
                let (low, high) = try range(value)
                description.constraints.entryPoint = low...(high ?? Int.max)
            case "NumberOfSections":
                let (low, high) = try range(value)
                description.constraints.numberOfSections = low...(high ?? Int.max)
            case "Container":
                description.constraints.container = String(value)
            case "Intermediates":
                let chain = value.split(separator: ">").map(String.init)
                guard !chain.isEmpty, chain.count <= 16 else { throw AVSignatureRejection("invalid Intermediates") }
                description.constraints.intermediates = chain
            case "IconGroup1", "IconGroup2":
                throw AVSignatureRejection("icon matching (IconGroup) isn't supported")
            case "HandlerType":
                throw AVSignatureRejection("HandlerType rescans aren't supported")
            default:
                throw AVSignatureRejection("unknown target description field")
            }
        }
        return description
    }

    /// `x-y`, `x-` or `x`.
    private static func range(_ text: Substring) throws -> (Int, Int?) {
        if let dash = text.firstIndex(of: "-") {
            guard let low = Int(text[..<dash]), low >= 0 else { throw AVSignatureRejection("invalid range") }
            let highText = text[text.index(after: dash)...]
            if highText.isEmpty { return (low, nil) }
            guard let high = Int(highText), high >= low else { throw AVSignatureRejection("invalid range") }
            return (low, high)
        }
        guard let value = Int(text), value >= 0 else { throw AVSignatureRejection("invalid range") }
        return (value, value)
    }

    // MARK: - Subsignatures of logical signatures

    enum Subsignature {
        case body(offset: AVOffsetSpec, variants: [AVPatternIR])
        case pcre(AVPCRESpec, trigger: AVLogicalNode, offset: AVOffsetSpec)
        case byteCompare(AVByteCompareSpec)
    }

    static func parseSubsignature(_ text: Substring, index: Int, subsigCount: Int) throws -> Subsignature {
        var bytes = Array(text.utf8)
        return try bytes.withUnsafeMutableBufferPointer { try parseSubsignature(UnsafeBufferPointer($0), index: index, subsigCount: subsigCount) }
    }

    /// Classifies and parses one subsignature, working on the raw bytes (the common body case
    /// never builds Swift strings except for a short offset).
    static func parseSubsignature(_ field: UnsafeBufferPointer<UInt8>, index: Int, subsigCount: Int) throws -> Subsignature {
        var firstSlash: Int?
        var doubleColon: Int?
        var firstColon: Int?
        var hasDollar = false
        for position in 0..<field.count {
            switch field[position] {
            case UInt8(ascii: "$"):
                hasDollar = true
            case UInt8(ascii: "/"):
                if firstSlash == nil { firstSlash = position }
            case UInt8(ascii: ":"):
                if doubleColon == nil, position + 1 < field.count, field[position + 1] == UInt8(ascii: ":") {
                    doubleColon = position
                } else if firstColon == nil, doubleColon == nil {
                    firstColon = position
                }
            default:
                break
            }
        }
        let text = { String(decoding: field, as: UTF8.self) }
        if field.starts(with: Array("fuzzy_img#".utf8)) {
            throw AVSignatureRejection("image fuzzy hashes aren't supported")
        }
        if hasDollar && firstSlash == nil { // `${min-max}MACRO$`; hex patterns never contain `$`
            throw AVSignatureRejection("macro subsignatures aren't supported")
        }
        if firstSlash != nil {
            let string = text()
            guard let slash = string.firstIndex(of: "/") else { throw AVSignatureRejection("malformed PCRE") }
            return try parsePCRE(Substring(string), firstSlash: slash, index: index)
        }
        // Byte compare: digits followed by "(>>" or "(<<".
        var digits = 0
        while digits < field.count, field[digits] >= 0x30, field[digits] <= 0x39 { digits += 1 }
        if digits > 0, digits + 2 < field.count, field[digits] == UInt8(ascii: "("),
           (field[digits + 1] == UInt8(ascii: ">") && field[digits + 2] == UInt8(ascii: ">")) ||
           (field[digits + 1] == UInt8(ascii: "<") && field[digits + 2] == UInt8(ascii: "<")) {
            let string = text()
            guard let open = string.firstIndex(of: "(") else { throw AVSignatureRejection("malformed byte compare") }
            return .byteCompare(try parseByteCompare(Substring(string), open: open, index: index))
        }
        guard let base = field.baseAddress else { throw AVSignatureRejection("empty subsignature") }
        var modifiers = Modifiers.none
        var bodyEnd = field.count
        if let doubleColon {
            modifiers = try Modifiers(text: UnsafeBufferPointer(start: base + doubleColon + 2, count: field.count - doubleColon - 2))
            bodyEnd = doubleColon
        }
        var offset = AVOffsetSpec.anywhere
        var bodyStart = 0
        if let firstColon, firstColon < bodyEnd {
            offset = try parseOffset(String(decoding: UnsafeBufferPointer(start: base, count: firstColon), as: UTF8.self))
            bodyStart = firstColon + 1
        }
        let variants = try parsePattern(UnsafeBufferPointer(start: base + bodyStart, count: bodyEnd - bodyStart), modifiers: modifiers)
        return .body(offset: offset, variants: variants)
    }

    /// `[offset:]trigger/regex/[flags]`. The trigger may only refer to earlier subsignatures.
    private static func parsePCRE(_ text: Substring, firstSlash: Substring.Index, index: Int) throws -> Subsignature {
        let prefix = text[..<firstSlash]
        var triggerText = prefix
        var offset = AVOffsetSpec.anywhere
        if let colon = prefix.lastIndex(of: ":") {
            offset = try parseOffset(prefix[..<colon])
            triggerText = prefix[prefix.index(after: colon)...]
        }
        guard let lastSlash = text.lastIndex(of: "/"), lastSlash > firstSlash else { throw AVSignatureRejection("unterminated PCRE") }
        let regex = String(text[text.index(after: firstSlash)..<lastSlash])
        let flags = text[text.index(after: lastSlash)...]
        guard !regex.isEmpty else { throw AVSignatureRejection("empty PCRE") }
        guard index > 0 else { throw AVSignatureRejection("a PCRE subsignature needs an earlier trigger") }
        let trigger = try parseExpression(triggerText, subsigCount: index)
        var spec = AVPCRESpec(subsig: index, trigger: AVLogicalExpressionCodec.encode(trigger), pattern: regex)
        for flag in flags {
            switch flag {
            case "g": spec.global = true
            case "r": spec.rolling = true
            case "e": spec.encompass = true
            case "i": spec.caseInsensitive = true
            case "s": spec.dotAll = true
            case "m": spec.multiline = true
            case "x": spec.extended = true
            case "A": spec.anchored = true
            case "U": spec.ungreedy = true
            case "E": break // PCRE_DOLLAR_ENDONLY: approximated by ICU's default `$`
            default: throw AVSignatureRejection("unsupported PCRE flag")
            }
        }
        spec.pattern = try AVRegexTranslator.translate(regex, ungreedy: spec.ungreedy)
        spec.requiredLiteral = AVRegexTranslator.requiredLiteral(regex, extended: spec.extended)
        spec.inlineCaseless = regex.range(of: #"\(\?[a-zA-Z]*i"#, options: .regularExpression) != nil
        guard AVRegexTranslator.compile(spec) != nil else {
            throw AVSignatureRejection("PCRE uses syntax ICU regular expressions don't support")
        }
        spec.offsetKind = offset.kind.rawValue
        spec.offsetValue = offset.value
        spec.offsetSection = offset.section
        spec.maxShift = offset.maxShift
        return .pcre(spec, trigger: trigger, offset: offset)
    }

    /// `id(>>offset#[h|d|a|i][l|b][e]length#comparison[,comparison])`.
    private static func parseByteCompare(_ text: Substring, open: Substring.Index, index: Int) throws -> AVByteCompareSpec {
        guard let reference = Int(text[..<open]), reference < index, text.hasSuffix(")") else {
            throw AVSignatureRejection("invalid byte compare reference")
        }
        let inner = text[text.index(after: open)..<text.index(before: text.endIndex)]
        let parts = inner.split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw AVSignatureRejection("malformed byte compare") }
        let offsetText = parts[0]
        guard offsetText.count > 2 else { throw AVSignatureRejection("malformed byte compare offset") }
        let negative = offsetText.hasPrefix("<<")
        guard negative || offsetText.hasPrefix(">>"), let magnitude = parseNumber(offsetText.dropFirst(2)) else {
            throw AVSignatureRejection("malformed byte compare offset")
        }
        var options = Substring(parts[1])
        guard let typeChar = options.first else { throw AVSignatureRejection("malformed byte compare options") }
        let encoding: AVByteCompareSpec.Encoding
        switch typeChar {
        case "h": encoding = .hex
        case "d": encoding = .decimal
        case "a": encoding = .automatic
        case "i": encoding = .binary
        default: throw AVSignatureRejection("unknown byte compare type")
        }
        options = options.dropFirst()
        var littleEndian = false
        if options.first == "l" { littleEndian = true; options = options.dropFirst() } else if options.first == "b" { options = options.dropFirst() }
        var exact = encoding == .binary
        if options.first == "e" { exact = true; options = options.dropFirst() }
        guard let length = parseNumber(options), length > 0, length <= 64 else { throw AVSignatureRejection("invalid byte compare length") }
        if encoding == .binary { guard [1, 2, 4, 8].contains(length) else { throw AVSignatureRejection("invalid binary byte compare length") } }
        if encoding == .decimal && littleEndian { throw AVSignatureRejection("little-endian decimal byte compare") }
        var comparisons = [AVByteCompareSpec.Comparison]()
        for item in parts[2].split(separator: ",") {
            guard let op = item.first, "<>=".contains(op), let value = parseNumber(item.dropFirst()) else {
                throw AVSignatureRejection("malformed byte compare comparison")
            }
            comparisons.append(.init(op: UInt8(ascii: op.unicodeScalars.first ?? "="), value: UInt64(value)))
        }
        guard !comparisons.isEmpty, comparisons.count <= 2 else { throw AVSignatureRejection("byte compare needs one or two comparisons") }
        return AVByteCompareSpec(subsig: index, reference: reference, offset: negative ? -magnitude : magnitude, encoding: encoding,
                                 littleEndian: littleEndian, exact: exact, length: length, comparisons: comparisons)
    }

    /// Decimal or `0x` hex.
    private static func parseNumber(_ text: some StringProtocol) -> Int? {
        if text.hasPrefix("0x") || text.hasPrefix("0X") {
            return Int(text.dropFirst(2), radix: 16)
        }
        return Int(text)
    }
}
