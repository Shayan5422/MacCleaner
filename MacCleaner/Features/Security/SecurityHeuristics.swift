import Foundation

// MARK: - Risky shell commands

/// A command that downloads or decodes code and runs it, found in a shell startup
/// file, a script, a cron job or inline launchd code.
struct SecurityShellRisk: Sendable, Hashable {
    enum Kind: String, Sendable, Hashable {
        case downloadPipedToInterpreter
        case decodedPayloadExecuted
        case evalOfDownload
        case downloadAndExecute
        case osascriptDownload

        var explanation: String {
            switch self {
            case .downloadPipedToInterpreter: return "Downloads code from the internet and runs it immediately (download piped into an interpreter)."
            case .decodedPayloadExecuted: return "Decodes hidden (Base64/hex encoded) code and runs it."
            case .evalOfDownload: return "Evaluates code fetched from the internet."
            case .downloadAndExecute: return "Downloads a file, makes it executable and runs it."
            case .osascriptDownload: return "Runs AppleScript that downloads from the internet."
            }
        }
    }

    var kind: Kind
    /// 1-based line number in the scanned text, when known.
    var lineNumber: Int?
    /// The offending line, trimmed and shortened for display.
    var line: String
}

/// Conservative patterns for "download/decode and execute" commands. Ordinary
/// setup lines (`eval "$(brew shellenv)"`, `source ~/.cargo/env`, `curl … | jq`)
/// don't match; comments and alias definitions are ignored.
enum SecurityShellRiskDetector {
    private static let interpreters = #"(?:sh|bash|zsh|dash|ksh|fish|python[0-9.]*|perl|ruby|osascript|node|php)"#
    private static let commandPrefix = #"(?:sudo\s+(?:-\S+\s+)*)?(?:env\s+(?:\S+=\S*\s+)*)?(?:\S*/)?"#

    private static let rules: [(SecurityShellRisk.Kind, NSRegularExpression)] = {
        let patterns: [(SecurityShellRisk.Kind, String)] = [
            (.downloadPipedToInterpreter, #"\b(?:curl|wget|fetch)\b[^;&\n]*\|\s*"# + commandPrefix + interpreters + #"\b"#),
            (.decodedPayloadExecuted, #"\b(?:base64\s+(?:-d|-D|--decode)|openssl\s+(?:enc\s+)?-?base64\s+-d|xxd\s+-r)\b[^;&\n]*\|\s*"# + commandPrefix + interpreters + #"\b"#),
            (.decodedPayloadExecuted, #"\beval\b[^\n]*base64\s+(?:-d|-D|--decode)\b"#),
            (.evalOfDownload, #"\beval\b[^\n]*(?:\$\(|`)\s*(?:\S*/)?(?:curl|wget)\b"#),
            (.evalOfDownload, #"(?:\bsource|(?:^|[;&|]\s*)\.)\s+<\(\s*(?:\S*/)?(?:curl|wget)\b"#),
            (.evalOfDownload, #"\b"# + interpreters + #"\s+(?:-\S+\s+)*<\(\s*(?:\S*/)?(?:curl|wget)\b"#),
            (.evalOfDownload, #"\b"# + interpreters + #"\s+(?:-\S+\s+)*-c\s+["']?\$\(\s*(?:\S*/)?(?:curl|wget)\b"#),
            (.evalOfDownload, #"\bpython[0-9.]*\s+-c\s+[^\n]*(?:urllib|urlopen|requests\.get)[^\n]*\bexec\b"#),
            (.downloadAndExecute, #"\b(?:curl|wget)\b[^\n]*(?:&&|;)[^\n]*\bchmod\s+(?:[ugoa]*\+x|[0-7]{3,4})\b[^\n]*(?:&&|;)\s*\S"#),
            (.osascriptDownload, #"\bosascript\b[^\n]*(?:\bcurl\b|\bwget\b|https?://)"#),
        ]
        return patterns.compactMap { kind, pattern in
            (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines])).map { (kind, $0) }
        }
    }()

    /// Every risky line in `text` (comments and alias definitions skipped).
    static func risks(in text: String, maximum: Int = 50) -> [SecurityShellRisk] {
        var results: [SecurityShellRisk] = []
        var lineNumber = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            guard results.count < maximum else { break }
            let line = String(rawLine)
            if let kind = risk(inLine: line) {
                results.append(SecurityShellRisk(kind: kind, lineNumber: lineNumber, line: displayLine(line)))
            }
        }
        return results
    }

    /// The first rule a single line matches, if any.
    static func risk(inLine rawLine: String) -> SecurityShellRisk.Kind? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("alias ") else { return nil }
        let line = stripComment(trimmed)
        guard line.count >= 6 else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        for (kind, expression) in rules where expression.firstMatch(in: line, options: [], range: range) != nil {
            return kind
        }
        return nil
    }

    /// Risk in inline code (`sh -c`, `osascript -e`), checked as a whole.
    static func risk(inInlineCode code: String) -> SecurityShellRisk.Kind? {
        for line in code.split(separator: "\n") {
            if let kind = risk(inLine: String(line)) { return kind }
        }
        // Inline code is often one long line with `;` separators; check the whole text too.
        let flattened = code.replacingOccurrences(of: "\n", with: " ; ")
        let range = NSRange(flattened.startIndex..., in: flattened)
        for (kind, expression) in rules where expression.firstMatch(in: flattened, options: [], range: range) != nil {
            return kind
        }
        return nil
    }

    /// Removes a trailing `# comment` that isn't inside quotes (keeps `$#`, `${#x}`).
    static func stripComment(_ line: String) -> String {
        var inSingle = false
        var inDouble = false
        var escaped = false
        var previous: Character = " "
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if escaped {
                escaped = false
            } else if character == "\\" && !inSingle {
                escaped = true
            } else if character == "'" && !inDouble {
                inSingle.toggle()
            } else if character == "\"" && !inSingle {
                inDouble.toggle()
            } else if character == "#" && !inSingle && !inDouble && (previous == " " || previous == "\t") {
                return String(line[..<index]).trimmingCharacters(in: .whitespaces)
            }
            previous = character
            index = line.index(after: index)
        }
        return line
    }

    static func displayLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 240 ? String(trimmed.prefix(239)) + "…" : trimmed
    }
}

// MARK: - Suspicious locations

/// A reason a program's location is unusual for legitimate software.
enum SecurityLocationIssue: Sendable, Hashable {
    case temporaryFolder(String)
    case sharedFolder
    case hiddenFolder(String)
    case randomApplicationSupportFolder(String)

    var explanation: String {
        switch self {
        case .temporaryFolder(let folder):
            return "Runs from a temporary folder (\(folder)). Installed software doesn't run from there; malware often does."
        case .sharedFolder:
            return "Runs from /Users/Shared, a folder every account can write to."
        case .hiddenFolder(let name):
            return "Runs from a hidden folder (“\(name)”), which keeps it out of sight in Finder."
        case .randomApplicationSupportFolder(let name):
            return "Runs from an Application Support folder with a random-looking name (“\(name)”), a pattern used by adware."
        }
    }
}

enum SecurityLocationHeuristics {
    static let temporaryFolders = ["/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/", "/var/folders/", "/private/var/folders/"]

    /// Hidden folders of common developer toolchains (relative to the home folder), not reported.
    static let knownToolchainFolders = [
        ".nvm/versions/", ".cargo/bin/", ".pyenv/versions/", ".pyenv/shims/", ".rbenv/versions/", ".rbenv/shims/",
        ".volta/", ".bun/bin/", ".deno/bin/", ".local/bin/", ".orbstack/", ".docker/bin/", ".rustup/toolchains/",
        ".sdkman/candidates/", ".asdf/installs/", ".asdf/shims/", ".fnm/", ".nix-profile/",
    ]

    static func issues(for path: String, home: String = LaunchdLocations.home) -> [SecurityLocationIssue] {
        var issues: [SecurityLocationIssue] = []
        if let folder = temporaryFolders.first(where: { path.hasPrefix($0) }) {
            issues.append(.temporaryFolder(String(folder.dropLast())))
        }
        if path.hasPrefix("/Users/Shared/") { issues.append(.sharedFolder) }

        let isToolchain = knownToolchainFolders.contains { path.hasPrefix(home + "/" + $0) }
        if !isToolchain, let hidden = path.split(separator: "/").first(where: { $0.hasPrefix(".") && $0 != "." && $0 != ".." }) {
            issues.append(.hiddenFolder(String(hidden)))
        }

        for base in [home + "/Library/Application Support/", "/Library/Application Support/"] where path.hasPrefix(base) {
            let remainder = path.dropFirst(base.count)
            if let first = remainder.split(separator: "/").first, remainder.contains("/"), looksRandom(String(first)) {
                issues.append(.randomApplicationSupportFolder(String(first)))
            }
        }
        return issues
    }

    private static let uuidExpression = try? NSRegularExpression(
        pattern: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, options: [.caseInsensitive]
    )

    /// `true` for names that look machine-generated: UUIDs, long hex strings, letter/digit
    /// soup ("4XFG7lqb4") or long consonant runs ("xkcdqwrtz"). Real product names don't.
    static func looksRandom(_ rawName: String) -> Bool {
        let name = rawName.hasPrefix(".") ? String(rawName.dropFirst()) : rawName
        if let uuidExpression, uuidExpression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil { return true }
        let segments = name.split(whereSeparator: { ".-_ ".contains($0) })
        for segment in segments where segment.count >= 8 {
            let characters = Array(segment)
            let digits = characters.filter(\.isNumber).count
            let letters = characters.filter(\.isLetter).count
            guard digits + letters == characters.count else { continue }

            let isHex = characters.allSatisfy(\.isHexDigit)
            if isHex && characters.count >= 12 && digits >= 2 && letters >= 2 { return true }

            var transitions = 0
            for index in 1..<characters.count where characters[index].isNumber != characters[index - 1].isNumber {
                transitions += 1
            }
            if digits >= 2 && letters >= 2 && transitions >= 3 { return true }

            if digits == 0 {
                let vowels = characters.filter { "aeiouyAEIOUY".contains($0) }.count
                if vowels == 0 { return true }
            }
        }
        return false
    }
}
