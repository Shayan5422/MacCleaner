import Foundation
import Testing
@testable import MacCleaner

struct UpdatesVersionComparatorTests {
    @Test(arguments: [
        // Numeric segments
        ("1.10", "1.9"), ("1.2.10", "1.2.3"), ("10", "9"), ("2.0.1", "2.0"), ("2024.10.1", "2024.9.30"),
        ("1.0.12345678901234567890", "1.0.9"), ("3", "2.99.99"),
        // Pre-releases are older than the release and than later patch releases
        ("1.2", "1.2b3"), ("1.2.1", "1.2b3"), ("1.2b10", "1.2b3"), ("1.0b1", "1.0a1"), ("1.0rc1", "1.0b1"),
        ("1.0", "1.0rc2"), ("1.0", "1.0-beta.2"), ("2.0", "2.0 beta 3"), ("1.0", "1.0.0b1"), ("1.0-rc.1", "1.0-alpha.9"),
        // Build numbers
        ("20240101", "20231201"), ("3.31.5.141153", "3.31.5.141152"),
    ])
    func newerVersionsCompareAsNewer(newer: String, older: String) {
        #expect(UpdatesVersionComparator.compare(newer, older) == .orderedDescending)
        #expect(UpdatesVersionComparator.compare(older, newer) == .orderedAscending)
        #expect(UpdatesVersionComparator.isNewer(newer, than: older))
        #expect(!UpdatesVersionComparator.isNewer(older, than: newer))
    }

    @Test(arguments: [
        ("2.0", "2.0.0"), ("1.2", "v1.2"), ("3.1", "Version 3.1"), ("2.3", "2.3 (1234)"), ("1.2.3", "1.2.3+45"),
        ("1.0", "1.0 final"), ("4.3.6", "4.3.6"), ("01.02", "1.2"), ("", ""),
    ])
    func equivalentVersionsCompareEqual(lhs: String, rhs: String) {
        #expect(UpdatesVersionComparator.compare(lhs, rhs) == .orderedSame)
        #expect(!UpdatesVersionComparator.isNewer(lhs, than: rhs))
    }

    @Test func tokenization() {
        #expect(UpdatesVersionComparator.tokens("1.2b3") == [.number("1"), .number("2"), .text("b"), .number("3")])
        #expect(UpdatesVersionComparator.tokens("v010.0") == [.number("10"), .number("0")])
        #expect(UpdatesVersionComparator.tokens("2.3 (1234)") == [.number("2"), .number("3")])
    }

    @Test func homebrewVersionsDropTheBuildSuffix() {
        #expect(UpdatesVersionComparator.homebrewDisplayVersion("4.2.1,1234") == "4.2.1")
        #expect(UpdatesVersionComparator.homebrewDisplayVersion("1.52.0") == "1.52.0")
        #expect(UpdatesHomebrew.strippingRevision("11.0_1") == "11.0")
        #expect(UpdatesHomebrew.strippingRevision("1.2_beta") == "1.2_beta")
    }
}
