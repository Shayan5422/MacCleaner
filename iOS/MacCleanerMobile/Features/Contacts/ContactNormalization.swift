import Contacts
import Foundation

/// How contact values are compared: names, phone numbers, email addresses, addresses and URLs.
enum ContactNormalization {
    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Names

    /// Case-, diacritic-, width- and whitespace-insensitive ("José  Álvarez" → "josealvarez"); nil when nothing is left.
    static func name(_ text: String) -> String? {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let squeezed = String(String.UnicodeScalarView(folded.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }))
        return squeezed.isEmpty ? nil : squeezed
    }

    // MARK: Phone numbers

    /// Numbers with fewer significant digits (service codes, typos) never match anything.
    static let minimumPhoneDigits = 5
    /// Numbers at least this long match by their last digits, so a country code or trunk prefix doesn't matter.
    static let phoneSuffixLength = 9

    /// The number's digits in ASCII, for any script's digits ("۰۹۱۲" → "0912"), without "(0)",
    /// the pause or wait tones after "," or ";", or an extension.
    static func phoneDigits(_ text: String) -> String {
        var number = Substring(text.replacingOccurrences(of: "(0)", with: ""))
        if let end = number.firstIndex(where: { $0 == "," || $0 == ";" }) {
            number = number[..<end]
        }
        if let ext = number.range(of: "ext", options: .caseInsensitive) ?? number.range(of: "x", options: .caseInsensitive) {
            number = number[..<ext.lowerBound]
        }
        var digits = ""
        for character in number {
            guard character.unicodeScalars.count == 1,
                  let scalar = character.unicodeScalars.first,
                  scalar.properties.numericType == .decimal,
                  let value = character.wholeNumberValue, (0...9).contains(value) else { continue }
            digits.append(Character(String(value)))
        }
        return digits
    }

    /// The digits that identify a number: without the leading zeros of an international ("00") or trunk ("0") prefix.
    static func significantDigits(_ text: String) -> String {
        String(phoneDigits(text).drop { $0 == "0" })
    }

    /// Whether two phone numbers are the same number written differently.
    static func phonesMatch(_ first: String, _ second: String) -> Bool {
        significantDigitsMatch(significantDigits(first), significantDigits(second))
    }

    /// Long numbers match when the shorter one is the end of the longer one: their last 9 or 10 digits,
    /// depending on the country, so "+1 415 555 0123" matches "(415) 555-0123" and "+33 6 12 34 56 78"
    /// matches "06 12 34 56 78", but "212-555-0123" doesn't match "312-555-0123". Short numbers must be identical.
    static func significantDigitsMatch(_ first: String, _ second: String) -> Bool {
        guard first.count >= minimumPhoneDigits, second.count >= minimumPhoneDigits else { return false }
        if first.count < phoneSuffixLength || second.count < phoneSuffixLength { return first == second }
        let (shorter, longer) = first.count <= second.count ? (first, second) : (second, first)
        return longer.hasSuffix(shorter)
    }

    /// The bucket a number is compared within: its last 9 significant digits (the whole number when shorter).
    /// Numbers in different buckets never match.
    static func phoneBucket(_ significant: String) -> String? {
        significant.count >= minimumPhoneDigits ? String(significant.suffix(phoneSuffixLength)) : nil
    }

    /// Whether two numbers on cards being merged are the same, so the merged card lists it once.
    static func samePhoneEntry(_ first: String, _ second: String) -> Bool {
        let firstDigits = phoneDigits(first), secondDigits = phoneDigits(second)
        if firstDigits.isEmpty || secondDigits.isEmpty {
            return trimmed(first).caseInsensitiveCompare(trimmed(second)) == .orderedSame
        }
        return firstDigits == secondDigits || phonesMatch(first, second)
    }

    // MARK: Email, addresses and URLs

    /// Lowercased and trimmed; nil when empty.
    static func email(_ text: String) -> String? {
        let normalized = trimmed(text).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    /// The address with every part compared like a name; nil for an empty address.
    static func address(_ address: ContactAddress) -> String? {
        let parts = [address.street, address.subLocality, address.city, address.subAdministrativeArea, address.state,
                     address.postalCode, address.country].map { name($0) ?? "" }
        return parts.allSatisfy(\.isEmpty) ? nil : parts.joined(separator: "|")
    }

    /// Without the scheme, "www.", case and a trailing slash ("https://www.Apple.com/" → "apple.com"); nil when empty.
    static func url(_ text: String) -> String? {
        var value = trimmed(text).lowercased()
        for prefix in ["https://", "http://"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        while value.hasSuffix("/") { value.removeLast() }
        return value.isEmpty ? nil : value
    }
}
