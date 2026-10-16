import Foundation

/// Translates ClamAV's PCRE subsignatures into ICU syntax for `NSRegularExpression`.
///
/// The subject is the scanned bytes decoded as Latin-1 (one UTF-16 unit per byte, so match
/// offsets are byte offsets). PCRE without UTF mode treats `\w`, `\d`, `\s`, `\b` and POSIX
/// classes as ASCII-only, while ICU is Unicode-aware (é would be a word character), so those are
/// rewritten into explicit ASCII sets. Python-style named groups `(?P<n>…)` / `(?P=n)` become
/// ICU's `(?<n>…)` / `\k<n>`. The `U` (ungreedy) flag is applied by swapping quantifier
/// greediness. Constructs ICU lacks (`\K`, recursion, conditionals, callouts, backtracking
/// verbs) make the signature unsupported.
enum AVRegexTranslator {
    private static let word = "A-Za-z0-9_"
    private static let notWord = "\\x00-/:-@\\[-\\^`\\{-\\xFF"
    private static let digit = "0-9"
    private static let notDigit = "\\x00-/:-\\xFF"
    private static let space = "\\t\\n\\x0B\\f\\r "
    private static let notSpace = "\\x00-\\x08\\x0E-\\x1F!-\\xFF"
    private static let posixClasses: [String: String] = [
        "alpha": "A-Za-z", "digit": "0-9", "alnum": "A-Za-z0-9", "upper": "A-Z", "lower": "a-z",
        "space": "\\t\\n\\x0B\\f\\r ", "xdigit": "0-9A-Fa-f", "word": "A-Za-z0-9_", "blank": "\\t ",
        "punct": "!-/:-@\\[-`\\{-~", "cntrl": "\\x00-\\x1F\\x7F", "print": " -~", "graph": "!-~",
    ]

    static func translate(_ pattern: String, ungreedy: Bool) throws -> String {
        let chars = Array(pattern.unicodeScalars)
        var out = ""
        var index = 0
        var inClass = false
        var classStart = false
        // ICU group names may only contain ASCII letters and digits; PCRE allows underscores.
        var groupNames = [String: String]()
        func groupName(_ name: String) -> String {
            if let mapped = groupNames[name] { return mapped }
            let mapped = "g\(groupNames.count)" + name.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            groupNames[name] = mapped
            return mapped
        }
        func peek(_ offset: Int) -> Unicode.Scalar? { index + offset < chars.count ? chars[index + offset] : nil }

        while index < chars.count {
            let c = chars[index]
            if c == "\\" {
                guard let next = peek(1) else { throw AVSignatureRejection("PCRE ends with a backslash") }
                switch next {
                case "w": out += inClass ? word : "[\(word)]"
                case "W": out += inClass ? notWord : "[^\(word)]"
                case "d": out += inClass ? digit : "[0-9]"
                case "D": out += inClass ? notDigit : "[^0-9]"
                case "s": out += inClass ? space : "[\(space)]"
                case "S": out += inClass ? notSpace : "[^\(space)]"
                case "h": out += inClass ? "\\t \\xA0" : "[\\t \\xA0]"
                case "b" where !inClass: out += "(?:(?<=[\(word)])(?![\(word)])|(?<![\(word)])(?=[\(word)]))"
                case "B" where !inClass: out += "(?:(?<=[\(word)])(?=[\(word)])|(?<![\(word)])(?![\(word)]))"
                case "K": throw AVSignatureRejection("PCRE \\K isn't supported")
                case "g" where !inClass: throw AVSignatureRejection("PCRE \\g references aren't supported")
                default:
                    out.unicodeScalars.append(c)
                    out.unicodeScalars.append(next)
                }
                index += 2
                classStart = false
                continue
            }
            if inClass {
                if c == "[", peek(1) == ":", let close = (index + 2..<chars.count).first(where: { chars[$0] == ":" && $0 + 1 < chars.count && chars[$0 + 1] == "]" }) {
                    let name = String(String.UnicodeScalarView(chars[(index + 2)..<close]))
                    guard let replacement = posixClasses[name] else { throw AVSignatureRejection("unknown POSIX class in PCRE") }
                    out += replacement
                    index = close + 2
                    classStart = false
                    continue
                }
                if c == "]" && !classStart { inClass = false }
                // ICU gives `[`, `&&` and `--` special meanings inside sets; PCRE doesn't.
                if c == "[" { out += "\\[" } else if c == "&" { out += "\\&" } else { out.unicodeScalars.append(c) }
                classStart = classStart && c == "^"
                index += 1
                continue
            }
            switch c {
            case "[":
                inClass = true
                classStart = true
                out.unicodeScalars.append(c)
                if peek(1) == "^" { out += "^"; index += 1 }
                index += 1
                continue
            case "(":
                if peek(1) == "?" {
                    if peek(2) == "P" || peek(2) == "<", peek(2) == "<" ? (peek(3) != "=" && peek(3) != "!") : peek(3) == "<" {
                        // Named group (?P<name>…) or (?<name>…).
                        let nameStart = index + (peek(2) == "P" ? 4 : 3)
                        guard let close = (nameStart..<chars.count).first(where: { chars[$0] == ">" }) else {
                            throw AVSignatureRejection("unterminated PCRE group name")
                        }
                        out += "(?<" + groupName(String(String.UnicodeScalarView(chars[nameStart..<close]))) + ">"
                        index = close + 1
                        continue
                    }
                    if peek(2) == "P", peek(3) == "=" {
                        guard let close = (index + 4..<chars.count).first(where: { chars[$0] == ")" }) else {
                            throw AVSignatureRejection("unterminated PCRE back reference")
                        }
                        out += "\\k<" + groupName(String(String.UnicodeScalarView(chars[(index + 4)..<close]))) + ">"
                        index = close + 1
                        continue
                    }
                    if let third = peek(2), third == "P" || third == "R" || third == "(" || third == "C" || third == "&" || ("0"..."9").contains(third) || third == "+" || third == "|" {
                        throw AVSignatureRejection("PCRE recursion, conditionals or callouts aren't supported")
                    }
                }
                if peek(1) == "*" { throw AVSignatureRejection("PCRE backtracking verbs aren't supported") }
                out.unicodeScalars.append(c)
            case "*", "+":
                out.unicodeScalars.append(c)
                if ungreedy { index = toggleLaziness(chars, index + 1, &out); continue }
            case "?" where !isGroupModifier(chars, index):
                out.unicodeScalars.append(c)
                if ungreedy { index = toggleLaziness(chars, index + 1, &out); continue }
            case "{":
                // A quantifier {n}, {n,}, {n,m}; otherwise a literal brace.
                if let close = (index + 1..<chars.count).first(where: { chars[$0] == "}" }),
                   String(String.UnicodeScalarView(chars[(index + 1)..<close])).range(of: #"^\d+(,\d*)?$"#, options: .regularExpression) != nil {
                    out += String(String.UnicodeScalarView(chars[index...close]))
                    if ungreedy { index = toggleLaziness(chars, close + 1, &out); continue }
                    index = close + 1
                    continue
                }
                out += "\\{"
            case "}":
                // A brace that doesn't close a quantifier is a literal in PCRE; ICU rejects it.
                out += "\\}"
            default:
                out.unicodeScalars.append(c)
            }
            index += 1
        }
        guard !inClass else { throw AVSignatureRejection("unterminated character class in PCRE") }
        return out
    }

    /// `?` right after `(` is a group modifier, not a quantifier.
    private static func isGroupModifier(_ chars: [Unicode.Scalar], _ index: Int) -> Bool {
        chars[index] == "?" && index > 0 && chars[index - 1] == "("
    }

    /// With PCRE_UNGREEDY, `x*` is lazy and `x*?` greedy: drop or add the `?` after a quantifier.
    private static func toggleLaziness(_ chars: [Unicode.Scalar], _ index: Int, _ out: inout String) -> Int {
        if index < chars.count, chars[index] == "?" { return index + 1 } // lazy → greedy
        if index < chars.count, chars[index] == "+" { out += "+"; return index + 1 } // possessive stays
        out += "?"
        return index
    }

    /// A byte string every match of the (original PCRE) pattern must contain, if one can be
    /// found cheaply: the longest run of literal characters at the top level (outside groups and
    /// classes, not made optional by `*`, `?` or `{0,…}`). nil with top-level alternation, the `x`
    /// flag, or no run of at least 4 bytes. Scanning skips the regex when the literal is absent.
    static func requiredLiteral(_ pattern: String, extended: Bool) -> [UInt8]? {
        guard !extended else { return nil }
        let chars = Array(pattern.unicodeScalars)
        var runs = [[UInt8]]()
        var run = [UInt8]()
        var index = 0
        func endRun() {
            if !run.isEmpty { runs.append(run); run = [] }
        }
        /// Skips a group or class starting at `index`; returns the index after it.
        func skipBracketed(_ start: Int) -> Int? {
            var depth = 0
            var position = start
            var inClass = false
            while position < chars.count {
                let c = chars[position]
                if c == "\\" { position += 2; continue }
                if inClass {
                    if c == "]" && position > start + 1 { inClass = false; if depth == 0 { return position + 1 } }
                } else if c == "[" {
                    inClass = true
                    if position + 1 < chars.count, chars[position + 1] == "]" { position += 1 }
                    if position + 1 < chars.count, chars[position + 1] == "^" { position += 1 }
                } else if c == "(" {
                    depth += 1
                } else if c == ")" {
                    depth -= 1
                    if depth == 0 { return position + 1 }
                }
                position += 1
            }
            return nil
        }
        /// Applies a quantifier after a literal: optional repeats drop the character.
        func quantifier(at position: Int, lastWasLiteral: Bool) -> Int {
            guard position < chars.count else { return position }
            let q = chars[position]
            var next = position
            var optional = false
            switch q {
            case "*", "?": optional = true; next = position + 1
            case "+": next = position + 1
            case "{":
                guard let close = (position..<chars.count).first(where: { chars[$0] == "}" }) else { return position }
                let body = String(String.UnicodeScalarView(chars[(position + 1)..<close]))
                guard let minimum = Int(body.split(separator: ",", omittingEmptySubsequences: false).first ?? "") else { return position }
                optional = minimum == 0
                next = close + 1
            default:
                return position
            }
            if lastWasLiteral && optional, !run.isEmpty { run.removeLast() }
            endRun()
            // Lazy or possessive suffix.
            if next < chars.count, chars[next] == "?" || chars[next] == "+" { next += 1 }
            return next
        }
        while index < chars.count {
            let c = chars[index]
            switch c {
            case "|":
                return nil // top-level alternation: nothing is required
            case "(", "[":
                endRun()
                guard let after = skipBracketed(index) else { return nil }
                index = quantifier(at: after, lastWasLiteral: false)
            case ".", "^", "$":
                endRun()
                index = quantifier(at: index + 1, lastWasLiteral: false)
            case "\\":
                guard index + 1 < chars.count else { return nil }
                let e = chars[index + 1]
                var literal: UInt8?
                var length = 2
                switch e {
                case "x":
                    if index + 2 < chars.count, chars[index + 2] == "{" {
                        if let close = (index..<chars.count).first(where: { chars[$0] == "}" }),
                           let value = UInt32(String(String.UnicodeScalarView(chars[(index + 3)..<close])), radix: 16), value < 256 {
                            literal = UInt8(value)
                            length = close - index + 1
                        }
                    } else if index + 3 < chars.count, let value = UInt8(String(String.UnicodeScalarView(chars[(index + 2)...(index + 3)])), radix: 16) {
                        literal = value
                        length = 4
                    }
                case "n": literal = 0x0A
                case "r": literal = 0x0D
                case "t": literal = 0x09
                case "f": literal = 0x0C
                case "e": literal = 0x1B
                case "a": literal = 0x07
                default:
                    if e.isASCII, !("A"..."Z").contains(e), !("a"..."z").contains(e), !("0"..."9").contains(e) {
                        literal = UInt8(e.value) // escaped punctuation
                    }
                }
                if let literal {
                    run.append(literal)
                    index = quantifier(at: index + length, lastWasLiteral: true)
                } else {
                    endRun()
                    index = quantifier(at: index + length, lastWasLiteral: false)
                }
            case "*", "+", "?", "{":
                // A quantifier with nothing (literal) before it, or a brace that isn't one.
                let next = quantifier(at: index, lastWasLiteral: false)
                if next == index {
                    if c == "{" { run.append(UInt8(ascii: "{")) } else { endRun() }
                    index += 1
                } else {
                    index = next
                }
            default:
                guard c.isASCII else { endRun(); index += 1; continue }
                run.append(UInt8(c.value))
                index = quantifier(at: index + 1, lastWasLiteral: true)
            }
        }
        endRun()
        guard let best = runs.max(by: { $0.count < $1.count }), best.count >= 4 else { return nil }
        return best
    }

    /// Options for a translated pattern. `.useUnixLineSeparators` makes `.`, `^` and `$` treat
    /// only LF as a line end, as PCRE does (Latin-1 0x85 would otherwise be NEL).
    static func options(_ spec: AVPCRESpec) -> NSRegularExpression.Options {
        var options: NSRegularExpression.Options = [.useUnixLineSeparators]
        if spec.caseInsensitive { options.insert(.caseInsensitive) }
        if spec.dotAll { options.insert(.dotMatchesLineSeparators) }
        if spec.multiline { options.insert(.anchorsMatchLines) }
        if spec.extended { options.insert(.allowCommentsAndWhitespace) }
        return options
    }

    static func compile(_ spec: AVPCRESpec) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: spec.pattern, options: options(spec))
    }
}

/// Lazily compiled regular expressions of a loaded database. Thread-safe.
final class AVRegexCache: @unchecked Sendable {
    private let lock = NSLock()
    private var compiled: [Int: NSRegularExpression] = [:]
    private var failed = Set<Int>()
    private let specs: [AVPCRESpec]

    init(specs: [AVPCRESpec]) {
        self.specs = specs
    }

    func spec(_ index: Int) -> AVPCRESpec? {
        index >= 0 && index < specs.count ? specs[index] : nil
    }

    func regex(_ index: Int) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let regex = compiled[index] { return regex }
        if failed.contains(index) { return nil }
        guard let spec = spec(index), let regex = AVRegexTranslator.compile(spec) else {
            failed.insert(index)
            return nil
        }
        compiled[index] = regex
        return regex
    }
}

/// Runs a PCRE subsignature over a buffer.
enum AVRegexMatcher {
    /// Buffers larger than this aren't searched with regular expressions (ClamAV has a similar
    /// `PCREMaxFileSize` limit).
    static let maxSubjectLength = 64 << 20
    /// Time budget per evaluation. ClamAV bounds PCRE work with match and recursion limits
    /// (`PCREMatchLimit`, `PCRERecMatchLimit`); a regex that runs out of budget counts as not
    /// matching, here as there.
    static let timeLimit: TimeInterval = 0.005

    /// `true` when `literal` occurs in `data[start...]` (ASCII case-insensitively when asked).
    static func contains(_ literal: [UInt8], in data: AVByteView, from start: Int, caseInsensitive: Bool) -> Bool {
        guard let base = data.base, start >= 0, start <= data.count, data.count - start >= literal.count, !literal.isEmpty else { return false }
        if !caseInsensitive {
            return literal.withUnsafeBytes { needle in
                guard let pointer = needle.baseAddress else { return false }
                return AVFind.first(pointer, literal.count, in: base, from: start, end: data.count) != nil
            }
        }
        func lower(_ c: UInt8) -> UInt8 { c >= 0x41 && c <= 0x5A ? c | 0x20 : c }
        let folded = literal.map(lower)
        let first = folded[0]
        let firstUpper = first >= 0x61 && first <= 0x7A ? first & 0xDF : first
        var position = start
        let last = data.count - literal.count
        while position <= last {
            let c = data[position]
            if c == first || c == firstUpper {
                var k = 1
                while k < folded.count, lower(data[position + k]) == folded[k] { k += 1 }
                if k == folded.count { return true }
            }
            position += 1
        }
        return false
    }

    /// Number of matches (at most one unless the `g` flag is set).
    static func count(_ regex: NSRegularExpression, spec: AVPCRESpec, subject: NSString, start: Int) -> Int {
        let length = subject.length
        guard start >= 0, start <= length else { return 0 }
        var end = length
        if spec.encompass, spec.maxShift > 0 { end = min(length, start + spec.maxShift) }
        var options: NSRegularExpression.MatchingOptions = [.reportProgress, .withTransparentBounds]
        // Without the rolling flag a PCRE at an offset only matches there (ClamAV's auto-anchoring).
        if spec.anchored || (spec.offsetKind != AVOffsetSpec.Kind.any.rawValue && !spec.rolling) { options.insert(.anchored) }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeLimit * 1e9)
        var matches = 0
        var timedOut = false
        regex.enumerateMatches(in: subject as String, options: options, range: NSRange(location: start, length: end - start)) { result, _, stop in
            if result != nil {
                matches += 1
                if !spec.global { stop.pointee = true }
            } else if DispatchTime.now().uptimeNanoseconds > deadline {
                timedOut = true
                stop.pointee = true
            }
        }
        return timedOut && !spec.global ? 0 : matches
    }
}
