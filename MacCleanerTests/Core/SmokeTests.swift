import Foundation
import Testing
@testable import MacCleaner

struct SmokeTests {
    @Test func byteFormattingIsReadable() {
        #expect(ByteFormatting.string(0) == "Zero KB")
    }
}
