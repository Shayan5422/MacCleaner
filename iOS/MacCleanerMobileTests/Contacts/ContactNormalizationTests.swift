import Foundation
import Testing
@testable import MacCleanerMobile

struct ContactNormalizationTests {
    @Test func namesIgnoreCaseDiacriticsWidthAndWhitespace() {
        #expect(ContactNormalization.name("  José   Álvarez ") == "josealvarez")
        #expect(ContactNormalization.name("JOSE ALVAREZ") == "josealvarez")
        #expect(ContactNormalization.name("ＪＯＳＥ") == "jose")
        #expect(ContactNormalization.name("Zoë\tSaldaña") == ContactNormalization.name("zoe saldana"))
        #expect(ContactNormalization.name("") == nil)
        #expect(ContactNormalization.name(" \n ") == nil)
    }

    @Test func phoneDigitsInAnyScriptWithoutTonesOrExtensions() {
        #expect(ContactNormalization.phoneDigits("+1 (415) 555-0123") == "14155550123")
        #expect(ContactNormalization.phoneDigits("۰۹۱۲ ۳۴۵ ۶۷۸۹") == "09123456789")
        #expect(ContactNormalization.phoneDigits("+44 (0) 20 7946 0958") == "442079460958")
        #expect(ContactNormalization.phoneDigits("555-0123 ext. 45") == "5550123")
        #expect(ContactNormalization.phoneDigits("555-0123 x45") == "5550123")
        #expect(ContactNormalization.phoneDigits("555-0123,,12;3") == "5550123")
        #expect(ContactNormalization.significantDigits("0049 30 1234567") == "49301234567")
    }

    @Test(arguments: [
        ("+1 415 555 0123", "(415) 555-0123"),
        ("+1-415-555-0123", "1 415 555 0123"),
        ("+33 6 12 34 56 78", "06 12 34 56 78"),
        ("+98 912 345 6789", "0912 345 6789"),
        ("00 98 912 345 6789", "+98 912 345 6789"),
        ("۰۹۱۲ ۳۴۵ ۶۷۸۹", "+989123456789"),
        ("+44 (0) 7700 900123", "07700 900123"),
        ("12345", "12-345"),
    ])
    func sameNumberWrittenDifferently(first: String, second: String) {
        #expect(ContactNormalization.phonesMatch(first, second))
    }

    @Test(arguments: [
        ("212-555-0123", "312-555-0123"),
        ("+1 212 555 0123", "+44 212 555 0123"),
        ("555-0123", "1-555-0123"),
        ("1234", "1234"),
        ("", ""),
        ("+33 6 12 34 56 78", "+34 6 12 34 56 78"),
    ])
    func differentNumbersDontMatch(first: String, second: String) {
        #expect(!ContactNormalization.phonesMatch(first, second))
    }

    @Test func phoneBucketsAreTheLastNineDigits() {
        #expect(ContactNormalization.phoneBucket("14155550123") == "155550123")
        #expect(ContactNormalization.phoneBucket("5550123") == "5550123")
        #expect(ContactNormalization.phoneBucket("911") == nil)
    }

    @Test func emailsAreLowercasedAndTrimmed() {
        #expect(ContactNormalization.email("  Kate@Example.COM \n") == "kate@example.com")
        #expect(ContactNormalization.email("   ") == nil)
    }

    @Test func urlsAndAddressesCompareLoosely() {
        #expect(ContactNormalization.url("https://www.Apple.com/") == ContactNormalization.url("apple.com"))
        #expect(ContactNormalization.url("http://example.com/a/") == "example.com/a")
        let first = ContactAddress(street: "165 Davis Street", city: "Hillsborough", state: "CA", postalCode: "94010")
        let second = ContactAddress(label: "work", street: "165  davis street", city: "HILLSBOROUGH", state: "ca", postalCode: "94010")
        #expect(ContactNormalization.address(first) == ContactNormalization.address(second))
        #expect(ContactNormalization.address(ContactAddress()) == nil)
    }

    @Test func mergedCardsListANumberOnce() {
        #expect(ContactNormalization.samePhoneEntry("(415) 555-0123", "+1 415 555 0123"))
        #expect(ContactNormalization.samePhoneEntry("911", "911"))
        #expect(!ContactNormalization.samePhoneEntry("911", "112"))
        #expect(ContactNormalization.samePhoneEntry("Front desk", "front desk"))
    }
}
