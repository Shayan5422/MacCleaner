import Foundation
import Testing
@testable import MacCleaner

/// Body signatures (`.ndb`): every element of the hex pattern syntax and every offset type.
struct AVBodySignatureTests {
    /// Random bytes with `insertions` placed at the given offsets (never starts with a file magic).
    private func buffer(_ size: Int = 4096, _ insertions: [(Int, [UInt8])] = []) -> Data {
        var data = AVFixtures.filler(size, seed: 7)
        data[0] = 0; data[1] = 1
        for (offset, bytes) in insertions { data.replaceSubrange(offset..<(offset + bytes.count), with: bytes) }
        return data
    }

    private func hex(_ text: String) -> [UInt8] { AVHex.decode(text) ?? [] }

    private func matches(_ pattern: String, offset: String = "*", target: Int = 0, _ data: Data) throws -> Bool {
        let engine = try AVFixtures.engine(["test.ndb": "Test.Sig-1:\(target):\(offset):\(pattern)\n"])
        return engine.names(data).contains("Test.Sig-1")
    }

    // MARK: Hex syntax

    @Test func exactBytes() throws {
        #expect(try matches("deadbeefcafe0102", buffer(4096, [(1000, hex("deadbeefcafe0102"))])))
        #expect(try !matches("deadbeefcafe0102", buffer(4096, [(1000, hex("deadbeefcafe0103"))])))
        // Uppercase hex digits are accepted too.
        #expect(try matches("DEADBEEFCAFE0102", buffer(4096, [(10, hex("deadbeefcafe0102"))])))
    }

    @Test func anyByteAndNibbles() throws {
        let data = buffer(4096, [(500, hex("1122334455667788"))])
        #expect(try matches("11223344??667788", data))
        #expect(try matches("1122334455?67788", data))   // high nibble 5
        #expect(try matches("11223344?5667788", data))   // low nibble 5
        #expect(try !matches("11223344?6667788", data))
        #expect(try !matches("1122334466?67788", data))
    }

    @Test func unboundedGap() throws {
        let data = buffer(8192, [(100, hex("a1a2a3a4a5")), (7000, hex("b1b2b3b4b5"))])
        #expect(try matches("a1a2a3a4a5*b1b2b3b4b5", data))
        #expect(try !matches("b1b2b3b4b5*a1a2a3a4a5", data)) // order matters
    }

    @Test func fixedAndRangedGaps() throws {
        // "c1c2c3c4" then 5 bytes, then "d1d2d3d4"
        let data = buffer(4096, [(300, hex("c1c2c3c4")), (309, hex("d1d2d3d4"))])
        #expect(try matches("c1c2c3c4{5}d1d2d3d4", data))
        #expect(try !matches("c1c2c3c4{4}d1d2d3d4", data))
        #expect(try matches("c1c2c3c4{-5}d1d2d3d4", data))
        #expect(try !matches("c1c2c3c4{-4}d1d2d3d4", data))
        #expect(try matches("c1c2c3c4{5-}d1d2d3d4", data))
        #expect(try !matches("c1c2c3c4{6-}d1d2d3d4", data))
        #expect(try matches("c1c2c3c4{3-7}d1d2d3d4", data))
        #expect(try !matches("c1c2c3c4{6-9}d1d2d3d4", data))
        #expect(try matches("c1c2c3c4[4-6]d1d2d3d4", data))
        #expect(try !matches("c1c2c3c4[0-4]d1d2d3d4", data))
        // A gap before the anchor is matched backwards.
        #expect(try matches("c1c2{7-9}d1d2d3d4", data))
    }

    @Test func alternatives() throws {
        let data = buffer(4096, [(800, hex("e1e2e3e4e5e6e7e8"))])
        #expect(try matches("e1e2e3e4(e5|f5)e6e7e8", data))
        #expect(try !matches("e1e2e3e4(f5|f6)e6e7e8", data))
        #expect(try matches("e1e2e3e4!(f5|f6)e6e7e8", data))
        #expect(try !matches("e1e2e3e4!(e5|f6)e6e7e8", data))
        // Multi-byte fixed-length alternatives and their negation.
        #expect(try matches("e1e2e3e4(0000|e5e6)e7e8", data))
        #expect(try !matches("e1e2e3e4(0000|1111)e7e8", data))
        #expect(try matches("e1e2e3e4!(0000|1111)e7e8", data))
        #expect(try !matches("e1e2e3e4!(0000|e5e6)e7e8", data))
        // Generic alternatives: different lengths, wildcards inside, an empty (optional) branch.
        #expect(try matches("e1e2e3e4(e5e6|aa)e7e8", data))
        #expect(try matches("e1e2e3e4(e5??|bbbbbb)e7e8", data))
        #expect(try matches("e1e2e3e4(e5e6e7|)e8", data))
        #expect(try matches("e1e2e3e4e5e6(ff|)e7e8", data))
        #expect(try !matches("e1e2e3e4(e5e6e7e8e9|00)", data.prefix(805)))
    }

    @Test func specialClasses() throws {
        // (B) word boundary, (L) line end, (W) non-alphanumeric, in the middle and at the edges.
        var data = buffer(4096)
        let text = Array("xx;MARKER_TEXT_ONE line\r\nNEXT".utf8)
        data.replaceSubrange(1000..<(1000 + text.count), with: text)
        #expect(try matches(AVFixtures.hex("MARKER_TEXT_ONE") + "(B)" + AVFixtures.hex("line"), data))
        #expect(try matches("(B)" + AVFixtures.hex("MARKER_TEXT_ONE"), data))
        #expect(try !matches("(B)" + AVFixtures.hex("ARKER_TEXT_ONE"), data))
        #expect(try matches(AVFixtures.hex("line") + "(L)" + AVFixtures.hex("NEXT"), data))
        #expect(try matches(AVFixtures.hex("MARKER_TEXT_ONE line") + "(L)", data))
        #expect(try !matches(AVFixtures.hex("MARKER_TEXT_ONE lin") + "(L)", data))
        #expect(try matches(AVFixtures.hex("MARKER_TEXT_ONE") + "(W)" + AVFixtures.hex("line"), data))
        #expect(try !matches(AVFixtures.hex("MARKER_TEXT_ON") + "(W)", data))
    }

    @Test func parserAcceptsNegationAndRejectsMalformedPatterns() throws {
        // ~HH negation parses (it needs functionality level 240, so real signatures using it are skipped).
        let negated = try AVSignatureParser.parsePattern("4142~4344")
        #expect(negated.count == 1)
        for bad in ["", "4", "41424", "zz11", "4142(4344", "41{5", "*414243", "414243*", "4142!4344", "41(42|(43|44))45"] {
            #expect(throws: AVSignatureRejection.self) { _ = try AVSignatureParser.parsePattern(bad) }
        }
    }

    // MARK: Offsets

    @Test func absoluteAndShiftedOffsets() throws {
        let data = buffer(4096, [(100, hex("f1f2f3f4f5f6"))])
        #expect(try matches("f1f2f3f4f5f6", offset: "100", data))
        #expect(try !matches("f1f2f3f4f5f6", offset: "99", data))
        #expect(try matches("f1f2f3f4f5f6", offset: "96,4", data))
        #expect(try !matches("f1f2f3f4f5f6", offset: "96,3", data))
        // Offset-anchored patterns without a 4-byte anchor are checked directly.
        #expect(try matches("f1f2??f4", offset: "100", data))
        #expect(try !matches("f1f2??f4", offset: "101", data))
    }

    @Test func endOfFileOffsets() throws {
        let data = buffer(4096, [(4096 - 16, hex("0a0b0c0d0e0f1011"))])
        #expect(try matches("0a0b0c0d0e0f1011", offset: "EOF-16", data))
        #expect(try !matches("0a0b0c0d0e0f1011", offset: "EOF-15", data))
        #expect(try matches("0a0b0c0d0e0f1011", offset: "EOF-20,4", data))
    }

    @Test func entryPointAndSectionOffsetsInPE() throws {
        let code = Data(hex("5589e583ec10b8010203048b45fc"))
        let second = Data(hex("cafed00d") + [UInt8](repeating: 0x90, count: 60) + hex("0badf00d"))
        let pe = AVFixtures.pe(sections: [(".text", code), (".data", second)], entryOffsetInFirstSection: 3)
        let info = try #require(AVExecutableInfo.parse(pe.withUnsafeBytes { AVByteView($0) }, kind: .pe))
        #expect(info.entryPoint == 0x400 + 3)
        #expect(info.sections.count == 2)
        #expect(try matches("83ec10b801020304", offset: "EP+0", target: 1, pe))
        #expect(try matches("5589e583ec10b801", offset: "EP-3", target: 1, pe))
        #expect(try !matches("83ec10b801020304", offset: "EP+1", target: 1, pe))
        #expect(try matches("cafed00d90909090", offset: "S1+0", target: 1, pe))
        #expect(try matches("90909090", offset: "S1+4", target: 1, pe))
        #expect(try matches("0badf00d", offset: "SE1", target: 1, pe))
        #expect(try !matches("0badf00d", offset: "SE0", target: 1, pe))
        #expect(try matches("cafed00d", offset: "SL+0", target: 1, pe))
        // Target 1 signatures don't apply to other file types.
        #expect(try !matches("cafed00d90909090", target: 1, buffer(4096, [(64, hex("cafed00d90909090"))])))
    }

    @Test func entryPointAndSectionOffsetsInMachO() throws {
        let code = Data(hex("fd7bbfa9fd030091") + [UInt8](repeating: 0x1F, count: 32) + hex("c0035fd6"))
        let macho = AVFixtures.machO(code: code)
        let info = try #require(AVExecutableInfo.parse(macho.withUnsafeBytes { AVByteView($0) }, kind: .machO))
        #expect(info.entryPoint == 0x400)
        #expect(try matches("fd7bbfa9fd030091", offset: "EP+0", target: 9, macho))
        #expect(try matches("fd7bbfa9fd030091", offset: "S0+0", target: 9, macho))
        #expect(try matches("c0035fd6", offset: "SE0", target: 9, macho))
        #expect(try !matches("fd7bbfa9fd030091", offset: "EP+4", target: 9, macho))
        // Mach-O signatures also apply to every slice of a universal binary.
        let fat = AVFixtures.universal([AVFixtures.machO(code: Data(count: 64)), macho])
        let engine = try AVFixtures.engine(["t.ndb": "Osx.Test.Slice-1:9:EP+0:fd7bbfa9fd030091\n"])
        let detections = engine.scan(data: fat, name: "fat", options: AVScanOptions())
        #expect(detections.map(\.signatureName) == ["Osx.Test.Slice-1"])
        #expect(detections.first?.memberPath == "x86_64")
    }

    // MARK: Functionality levels

    @Test func functionalityLevelsGateSignatures() throws {
        let data = buffer(4096, [(64, hex("1a2b3c4d5e6f"))])
        let (engine, summary) = try AVFixtures.compile(["t.ndb": """
            Test.Old-1:0:*:1a2b3c4d5e6f:20:30
            Test.Future-1:0:*:1a2b3c4d5e6f:999
            Test.Current-1:0:*:1a2b3c4d5e6f:51:255
            Test.NoMax-1:0:*:1a2b3c4d5e6f:51
            """])
        #expect(Set(engine.names(data)) == ["Test.Current-1", "Test.NoMax-1"])
        let coverage = try #require(summary.coverage?.files["t.ndb"])
        #expect(coverage.loaded == 2)
        #expect(coverage.unsupported == 1)
        #expect(coverage.ignored == 1)
    }
}
