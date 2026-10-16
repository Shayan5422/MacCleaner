import Foundation

// The in-memory form of parsed ClamAV signatures, before they are compiled into the binary
// database. See AVSignatureParser for the text formats and AVPatternProgram for how patterns
// are encoded and matched.

/// One byte position of a pattern: matches input byte `b` when `b & mask == value`.
/// Exact bytes have mask 0xFF, `??` has mask 0, nibble wildcards (`a?`, `?a`) 0xF0/0x0F and a
/// case-insensitive letter 0xDF (bit 5 is the ASCII case bit, so `A`/`a` share `b & 0xDF`).
struct AVMaskedByte: Hashable, Sendable {
    var mask: UInt8
    var value: UInt8

    static let any = AVMaskedByte(mask: 0, value: 0)
    static func exact(_ byte: UInt8) -> AVMaskedByte { AVMaskedByte(mask: 0xFF, value: byte) }

    @inline(__always) func matches(_ byte: UInt8) -> Bool { byte & mask == value }

    /// Number of input bytes this position accepts.
    var cardinality: Int { 1 << (8 - mask.nonzeroBitCount) }

    /// Case-insensitive version for ASCII letters.
    var caseInsensitive: AVMaskedByte {
        guard mask == 0xFF else { return self }
        let lower = value | 0x20
        if lower >= 0x61 && lower <= 0x7A { return AVMaskedByte(mask: 0xDF, value: value & 0xDF) }
        return self
    }
}

/// A set of byte values (single-byte alternatives `(aa|bb)`, `!(...)`, `~HH`, special classes).
struct AVByteSet: Hashable, Sendable {
    var words: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)

    static func == (lhs: AVByteSet, rhs: AVByteSet) -> Bool {
        lhs.words.0 == rhs.words.0 && lhs.words.1 == rhs.words.1 && lhs.words.2 == rhs.words.2 && lhs.words.3 == rhs.words.3
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(words.0); hasher.combine(words.1); hasher.combine(words.2); hasher.combine(words.3)
    }

    mutating func insert(_ byte: UInt8) {
        let bit = UInt64(1) << UInt64(byte & 63)
        switch byte >> 6 {
        case 0: words.0 |= bit
        case 1: words.1 |= bit
        case 2: words.2 |= bit
        default: words.3 |= bit
        }
    }

    func contains(_ byte: UInt8) -> Bool {
        let bit = UInt64(1) << UInt64(byte & 63)
        switch byte >> 6 {
        case 0: return words.0 & bit != 0
        case 1: return words.1 & bit != 0
        case 2: return words.2 & bit != 0
        default: return words.3 & bit != 0
        }
    }

    mutating func insert(matching byte: AVMaskedByte) {
        for value in 0...255 where AVMaskedByte(mask: byte.mask, value: byte.value).matches(UInt8(value)) {
            insert(UInt8(value))
        }
    }

    var inverted: AVByteSet {
        var copy = self
        copy.words = (~words.0, ~words.1, ~words.2, ~words.3)
        return copy
    }

    var count: Int {
        words.0.nonzeroBitCount + words.1.nonzeroBitCount + words.2.nonzeroBitCount + words.3.nonzeroBitCount
    }

    var bytes: [UInt8] { (0...255).compactMap { contains(UInt8($0)) ? UInt8($0) : nil } }

    /// Bytes ClamAV's `(B)` accepts as a word boundary. ClamAV's own table isn't documented;
    /// this engine treats every byte that isn't an ASCII letter, digit or `_` as a boundary.
    static let boundary: AVByteSet = {
        var set = AVByteSet()
        for value in 0...255 {
            let c = UInt8(value)
            let isWord = (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
            if !isWord { set.insert(c) }
        }
        return set
    }()

    /// `(W)`: any byte that isn't an ASCII letter or digit.
    static let nonAlphanumeric: AVByteSet = {
        var set = AVByteSet()
        for value in 0...255 {
            let c = UInt8(value)
            let isAlnum = (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
            if !isAlnum { set.insert(c) }
        }
        return set
    }()
}

/// The special character classes of the body signature format.
enum AVSpecialClass: UInt8, Sendable {
    /// `(B)`: a word boundary (or the start/end of the data).
    case boundary = 1
    /// `(L)`: CR, CRLF or LF (or the start/end of the data).
    case lineMarker = 2
    /// `(W)`: a non-alphanumeric character (or the start/end of the data).
    case nonAlphanumeric = 3
}

/// One element of a body pattern.
enum AVPatternElement: Hashable, Sendable {
    /// A fixed run of byte positions (literals, `??`, nibble wildcards, case-insensitive letters).
    case bytes([AVMaskedByte])
    /// One byte from a set.
    case byteSet(AVByteSet)
    /// One of several byte strings (each may contain masked positions). When `negated`, all
    /// alternatives have the same length and the element matches that many bytes that are none of them.
    case alternatives([[AVMaskedByte]], negated: Bool)
    /// Any number of bytes in `min...max` (`max == nil`: unbounded, as `*` and `{n-}`).
    case gap(min: Int, max: Int?)
    /// A special class in the middle of a pattern (consumes one byte; `(L)` one or two).
    case special(AVSpecialClass)

    var isGap: Bool {
        if case .gap = self { return true }
        return false
    }
}

/// A parsed body pattern.
struct AVPatternIR: Hashable, Sendable {
    var elements: [AVPatternElement]
    /// `(B)`, `(L)` or `(W)` at the very start: a condition on the byte before the match.
    var leftAssertion: AVSpecialClass?
    /// The same at the very end: a condition on the byte after the match.
    var rightAssertion: AVSpecialClass?
    /// `::f`: the match must be delimited by non-alphanumeric characters (or the data's ends).
    var fullword = false
    /// The pattern was widened (`::w`), so `fullword` checks UTF-16LE neighbours.
    var wide = false
}

/// Where a body pattern must start (ClamAV's offset field).
struct AVOffsetSpec: Hashable, Sendable {
    enum Kind: UInt8, Sendable {
        /// `*`: anywhere.
        case any = 0
        /// `n`: absolute offset from the start.
        case absolute = 1
        /// `EOF-n`.
        case endOfFile = 2
        /// `EP+n` / `EP-n`: relative to the executable's entry point (file offset).
        case entryPoint = 3
        /// `Sx+n`: relative to the start of section `x` (counted from 0).
        case sectionStart = 4
        /// `SEx`: anywhere inside section `x` (start at the section's start, shift its size).
        case sectionEntire = 5
        /// `SL+n`: relative to the start of the last section.
        case lastSection = 6
    }

    var kind: Kind = .any
    /// The `n` (signed for `EP-n`, `EOF-n` stores n).
    var value: Int = 0
    var section: Int = 0
    /// `n,maxshift`: the pattern may start anywhere in `[offset, offset + maxShift]`.
    var maxShift: Int = 0

    static let anywhere = AVOffsetSpec()

    var isAnchored: Bool { kind != .any }
    /// Needs entry point or section information (PE, ELF or Mach-O).
    var needsExecutableInfo: Bool { kind == .entryPoint || kind == .sectionStart || kind == .sectionEntire || kind == .lastSection }
}

/// A logical expression over subsignature match counts.
indirect enum AVLogicalNode: Hashable, Sendable {
    case subsig(Int)
    case and(AVLogicalNode, AVLogicalNode)
    case or(AVLogicalNode, AVLogicalNode)
    /// `A=X`, `A>X`, `A<X`, optionally `,Y` (at least Y different subsignatures of A matched).
    case count(AVLogicalNode, op: CountOperator, value: Int, distinct: Int?)

    enum CountOperator: UInt8, Sendable {
        case equal = 0x3D   // '='
        case greater = 0x3E // '>'
        case less = 0x3C    // '<'
    }

    /// Every subsignature referenced anywhere below this node.
    var subsigs: Set<Int> {
        switch self {
        case .subsig(let id): return [id]
        case .and(let a, let b), .or(let a, let b): return a.subsigs.union(b.subsigs)
        case .count(let child, _, _, _): return child.subsigs
        }
    }

    /// The expression's value when no subsignature matched (all counts zero). A signature that
    /// is true here would match every file of its target type.
    var isTrueWithNoMatches: Bool {
        switch self {
        case .subsig: return false
        case .and(let a, let b): return a.isTrueWithNoMatches && b.isTrueWithNoMatches
        case .or(let a, let b): return a.isTrueWithNoMatches || b.isTrueWithNoMatches
        case .count(_, let op, let value, let distinct):
            if let distinct, distinct > 0 { return false }
            switch op {
            case .equal: return value == 0
            case .greater: return false // 0 > value is never true for value >= 0
            case .less: return value > 0
            }
        }
    }
}

/// Target description block constraints of a logical signature (besides Target and Engine).
struct AVTargetConstraints: Hashable, Sendable, Codable {
    var fileSize: ClosedRange<Int>?
    var entryPoint: ClosedRange<Int>?
    var numberOfSections: ClosedRange<Int>?
    /// The scanned data must come from a container of this type (`CL_TYPE_ZIP`...).
    /// `CL_TYPE_ANY` means "only top-level files".
    var container: String?
    /// Container chain, outermost first; the last one is the immediate container. `CL_TYPE_ANY` is a wildcard.
    var intermediates: [String]?

    var isEmpty: Bool { fileSize == nil && entryPoint == nil && numberOfSections == nil && container == nil && intermediates == nil }
}

/// A PCRE subsignature (`[offset:]Trigger/regex/flags`).
struct AVPCRESpec: Hashable, Sendable, Codable {
    var subsig: Int
    /// Trigger expression, serialized (AVLogicalExpression encoding).
    var trigger: [UInt8]
    /// The regular expression translated to ICU syntax for NSRegularExpression.
    var pattern: String
    var caseInsensitive = false
    var dotAll = false
    var multiline = false
    var extended = false
    var anchored = false
    var ungreedy = false
    var global = false
    var rolling = false
    var encompass = false
    var offsetKind: UInt8 = 0
    var offsetValue = 0
    var offsetSection = 0
    var maxShift = 0
    /// Bytes every match contains (see `AVRegexTranslator.requiredLiteral`).
    var requiredLiteral: [UInt8]?
    /// The pattern has an inline `(?i)`-style option, so the literal check must ignore case.
    var inlineCaseless = false
}

/// A byte-compare subsignature (`id(>>offset#options#comparisons)`).
struct AVByteCompareSpec: Hashable, Sendable, Codable {
    enum Encoding: UInt8, Sendable, Codable { case hex, decimal, automatic, binary }
    struct Comparison: Hashable, Sendable, Codable {
        var op: UInt8 // '<' '>' '='
        var value: UInt64
    }
    var subsig: Int
    var reference: Int
    var offset: Int
    var encoding: Encoding
    var littleEndian: Bool
    var exact: Bool
    var length: Int
    var comparisons: [Comparison]
}

/// What a signature reports.
struct AVSignatureTraits: Hashable, Sendable {
    var kind: AVThreatKind
    /// Named for Windows or Linux (`Win.`, `Unix.`, `PUA.Win.`...), or targets PE/ELF.
    var nonMac: Bool
}

/// Naming conventions of ClamAV's official databases.
enum AVSignatureNaming {
    /// `PUA.` names and signatures from the `u` databases (.ndu, .ldu, .hdu...) are PUA.
    static func traits(name: String, fromPUADatabase: Bool, target: Int?) -> AVSignatureTraits {
        let kind: AVThreatKind
        if isTestFile(name) {
            kind = .testFile
        } else if fromPUADatabase || name.hasPrefix("PUA.") {
            kind = .pua
        } else {
            kind = .malware
        }
        let nonMacTarget = target == 1 || target == 6
        return AVSignatureTraits(kind: kind, nonMac: nonMacTarget || isNonMacPlatform(name))
    }

    /// `Eicar-Test-Signature`, `Clamav.Test.File-6`, `Win.Test.EICAR_HDB-1`... ("Test" category).
    /// Malware families that merely carry "Eicar" in their name (`Win.Malware.Eicar-…`) stay malware.
    static func isTestFile(_ name: String) -> Bool {
        if name.hasPrefix("Eicar-Test") || name.hasPrefix("Clamav.Test.") { return true }
        let parts = name.split(separator: ".", maxSplits: 2)
        return parts.count >= 2 && parts[1] == "Test"
    }

    /// Platforms whose files can't be Mach-O executables (used to skip wildcard-size hash
    /// signatures for Mach-O files). Unknown or generic names count as possibly Mach-O.
    static let nonMachOPlatforms: Set<Substring> = [
        "Win", "Unix", "Html", "Js", "Doc", "Xls", "Ppt", "Pdf", "Email", "Java", "Andr", "Php", "Asp", "Vbs", "Swf",
        "Img", "Rtf", "Txt", "Xml", "Ps1", "Ios", "Legacy",
    ]

    static func canTargetMachO(_ name: String) -> Bool {
        var platform = name.prefix { $0 != "." }
        if platform == "PUA" { platform = name.dropFirst(4).prefix { $0 != "." } }
        guard name.contains(".") else { return true }
        return !nonMachOPlatforms.contains(platform)
    }

    /// The platform is the first dot-separated component (the second after `PUA.`).
    static func isNonMacPlatform(_ name: String) -> Bool {
        var platform = name.prefix { $0 != "." }
        if platform == "PUA" {
            platform = name.dropFirst(4).prefix { $0 != "." }
        }
        return platform == "Win" || platform == "Unix"
    }
}
