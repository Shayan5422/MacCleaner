import Foundation
import Testing
@testable import MacCleanerMobile

struct FormattingTests {
    @Test func countsUseTheSingularForOne() {
        #expect(NumberFormatting.count(1, "photo") == "1 photo")
        #expect(NumberFormatting.count(0, "photo") == "0 photos")
        #expect(NumberFormatting.count(3, "match", plural: "matches") == "3 matches")
    }

    @Test func storageFractionsAndLowSpace() {
        let roomy = DeviceStorage(total: 256_000_000_000, available: 128_000_000_000)
        #expect(roomy.usedFraction == 0.5)
        #expect(!roomy.isLow)
        #expect(DeviceStorage(total: 128_000_000_000, available: 4_000_000_000).isLow)
    }
}
