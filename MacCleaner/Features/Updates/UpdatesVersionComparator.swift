import Foundation

/// Compares version strings the way developers, update feeds and stores write them.
///
/// * Numeric segments compare as numbers (`1.10` is newer than `1.9`), at any length.
/// * Missing trailing segments count as zero (`2.1` equals `2.1.0`).
/// * Letters after a number mark a pre-release (`1.2b3` is older than `1.2` and `1.2.1`);
///   `alpha < beta < preview < rc`, other words compare alphabetically.
/// * Decorations are ignored: a leading `v`/`Version`, build numbers in parentheses
///   (`2.3 (1234)`) and semantic-version build metadata (`1.2.3+45`).
enum UpdatesVersionComparator {
    enum Token: Hashable, Sendable {
        /// Digits without leading zeros ("0" for zero).
        case number(String)
        /// Lowercased letters.
        case text(String)
    }

    /// `true` when `candidate` is strictly newer than `installed`.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        compare(candidate, installed) == .orderedDescending
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        compare(tokens: tokens(lhs), tokens(rhs))
    }

    /// Splits a version into number and word tokens after removing decorations.
    static func tokens(_ version: String) -> [Token] {
        let cleaned = normalize(version)
        var result: [Token] = []
        var digits = ""
        var letters = ""

        func flushDigits() {
            guard !digits.isEmpty else { return }
            let trimmed = digits.drop { $0 == "0" }
            result.append(.number(trimmed.isEmpty ? "0" : String(trimmed)))
            digits = ""
        }
        func flushLetters() {
            guard !letters.isEmpty else { return }
            let word = letters.lowercased()
            if !ignoredWords.contains(word) { result.append(.text(word)) }
            letters = ""
        }

        for scalar in cleaned.unicodeScalars {
            if ("0"..."9").contains(scalar) {
                flushLetters()
                digits.unicodeScalars.append(scalar)
            } else if CharacterSet.letters.contains(scalar) {
                flushDigits()
                letters.unicodeScalars.append(scalar)
            } else {
                flushDigits()
                flushLetters()
            }
        }
        flushDigits()
        flushLetters()
        return result
    }

    /// Homebrew writes some versions as `version,build` (for example `4.2.1,1234`).
    /// The part before the comma is the version people see in the app.
    static func homebrewDisplayVersion(_ version: String) -> String {
        guard let comma = version.firstIndex(of: ",") else { return version }
        return String(version[..<comma])
    }

    // MARK: - Implementation

    /// Words that never change a version's meaning.
    private static let ignoredWords: Set<String> = ["v", "version", "ver", "build", "release", "final", "stable", "ga"]

    /// Ordering of common pre-release words; unknown words sort alphabetically after these.
    private static let preReleaseRank: [String: Int] = [
        "dev": 0, "nightly": 0, "snapshot": 0, "canary": 0,
        "a": 1, "alpha": 1,
        "b": 2, "beta": 2,
        "pre": 3, "preview": 3,
        "c": 4, "rc": 4,
    ]

    private static func normalize(_ version: String) -> String {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        // Semantic-version build metadata never affects precedence.
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
        // Build numbers shown in parentheses or brackets: "2.3 (1234)".
        text = removingEnclosed(text, open: "(", close: ")")
        text = removingEnclosed(text, open: "[", close: "]")
        return text
    }

    private static func removingEnclosed(_ text: String, open: Character, close: Character) -> String {
        guard text.contains(open) else { return text }
        var output = ""
        var depth = 0
        for character in text {
            if character == open {
                depth += 1
                output.append(" ")
            } else if character == close, depth > 0 {
                depth -= 1
            } else if depth == 0 {
                output.append(character)
            }
        }
        return output
    }

    private static func compare(tokens lhs: [Token], _ rhs: [Token]) -> ComparisonResult {
        var index = 0
        while index < max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : nil
            let right = index < rhs.count ? rhs[index] : nil
            index += 1
            switch (left, right) {
            case let (.number(a)?, .number(b)?):
                let result = compareNumbers(a, b)
                if result != .orderedSame { return result }
            case let (.text(a)?, .text(b)?):
                let result = compareWords(a, b)
                if result != .orderedSame { return result }
            case (.number?, .text?):
                // "1.2.1" vs "1.2b1": a release segment beats a pre-release marker.
                return .orderedDescending
            case (.text?, .number?):
                return .orderedAscending
            case let (.number(a)?, nil):
                // Trailing zeros don't make a version newer: "2.1.0" == "2.1".
                if a != "0" { return .orderedDescending }
            case let (nil, .number(b)?):
                if b != "0" { return .orderedAscending }
            case (.text?, nil):
                // "1.2b3" vs "1.2": the pre-release is older.
                return .orderedAscending
            case (nil, .text?):
                return .orderedDescending
            case (nil, nil):
                return .orderedSame
            }
        }
        return .orderedSame
    }

    private static func compareNumbers(_ lhs: String, _ rhs: String) -> ComparisonResult {
        // Both are digit strings without leading zeros, so length decides first.
        if lhs.count != rhs.count { return lhs.count < rhs.count ? .orderedAscending : .orderedDescending }
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private static func compareWords(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        switch (preReleaseRank[lhs], preReleaseRank[rhs]) {
        case let (a?, b?):
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
            return lhs < rhs ? .orderedAscending : .orderedDescending
        case (_?, nil):
            return .orderedAscending
        case (nil, _?):
            return .orderedDescending
        case (nil, nil):
            return lhs < rhs ? .orderedAscending : .orderedDescending
        }
    }
}
