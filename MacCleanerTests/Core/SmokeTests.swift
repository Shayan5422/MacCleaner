import Foundation
import Testing
@testable import MacCleaner

struct SmokeTests {
    @Test func byteFormattingIsReadable() {
        #expect(ByteFormatting.string(0) == "Zero KB")
    }

    @Test func countsUseTheSingularForOne() {
        #expect(NumberFormatting.count(1, "file") == "1 file")
        #expect(NumberFormatting.count(0, "file") == "0 files")
        #expect(NumberFormatting.count(12_345, "file") == 12_345.formatted(.number) + " files")
        #expect(NumberFormatting.count(1, "process", plural: "processes") == "1 process")
        #expect(NumberFormatting.count(3, "process", plural: "processes") == "3 processes")
    }
}
