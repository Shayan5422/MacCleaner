import Foundation
import Testing
@testable import MacCleaner

/// Containers the engine looks inside, and the limits that bound that work.
struct AVArchiveTests {
    private static let marker = "archive-payload-marker-7f3a"
    private static let signature = "Test.Archive-1:0:*:\(AVFixtures.hex(marker))\n"

    /// A member that contains the marker, padded with compressible text.
    private func payload(_ extra: Int = 4000) -> Data {
        Data("header ".utf8) + Data(Self.marker.utf8) + Data(repeating: 0x42, count: extra)
    }

    private func engine() throws -> AVEngine { try AVFixtures.engine(["t.ndb": Self.signature]) }

    private func scanFile(_ data: Data, options: AVScanOptions = AVScanOptions(), engine: AVEngine? = nil) throws -> AVFileScanResult {
        let directory = AVTestDirectory()
        let url = try directory.write("sample.bin", data)
        return try (engine ?? self.engine()).scanFile(atPath: url.path, options: options)
    }

    @Test func zipStoredAndDeflated() throws {
        let engine = try engine()
        for deflate in [false, true] {
            let zip = AVFixtures.zip([.init(name: "docs/readme.txt", data: Data("clean".utf8), deflate: deflate),
                                      .init(name: "bin/tool", data: payload(), deflate: deflate)])
            let detections = engine.scan(data: zip, name: "a.zip", options: AVScanOptions())
            #expect(detections.map(\.signatureName) == ["Test.Archive-1"])
            #expect(detections.first?.memberPath == "bin/tool")
        }
    }

    @Test func nestedArchivesReportTheFullPath() throws {
        let inner = AVFixtures.zip([.init(name: "evil.bin", data: payload())])
        let tar = AVFixtures.tar([("readme", Data("x".utf8)), ("inner.zip", inner)])
        let gz = AVFixtures.gzip(tar, name: "bundle.tar")
        let outer = AVFixtures.zip([.init(name: "bundle.tar.gz", data: gz, deflate: false)])
        let detections = try engine().scan(data: outer, name: "outer.zip", options: AVScanOptions())
        #expect(detections.first?.memberPath == "bundle.tar.gz › bundle.tar › inner.zip › evil.bin")
    }

    @Test func gzipWithoutStoredNameUsesTheFileName() throws {
        let gz = AVFixtures.gzip(payload())
        let detections = try engine().scan(data: gz, name: "notes.txt.gz", options: AVScanOptions())
        #expect(detections.first?.memberPath == "notes.txt")
    }

    @Test func oldStyleTar() throws {
        let tar = AVFixtures.tar([("payload.bin", payload())], ustar: false)
        let detections = try engine().scan(data: tar, name: "a.tar", options: AVScanOptions())
        #expect(detections.first?.memberPath == "payload.bin")
    }

    @Test func universalBinarySlices() throws {
        let fat = AVFixtures.universal([AVFixtures.machO(code: Data(count: 32)), AVFixtures.machO(code: payload(64))])
        let detections = try engine().scan(data: fat, name: "tool", options: AVScanOptions())
        #expect(detections.map(\.memberPath) == ["x86_64"])
    }

    @Test func chromeExtensionAndSelfExtractingZip() throws {
        let zip = AVFixtures.zip([.init(name: "background.js", data: payload())])
        var crx = Data("Cr24".utf8)
        crx += withUnsafeBytes(of: UInt32(3).littleEndian) { Data($0) }
        crx += withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) }
        crx += Data(count: 16) + zip
        let engine = try engine()
        #expect(engine.scan(data: crx, name: "ext.crx", options: AVScanOptions()).first?.memberPath == "background.js")
        // A ZIP appended to a shell script is opened too.
        let script = Data("#!/bin/sh\nexit 0\n".utf8)
        let sfx = AVFixtures.zip([.init(name: "payload/run.bin", data: payload())], prefix: script)
        #expect(engine.scan(data: sfx, name: "installer.sh", options: AVScanOptions()).first?.memberPath == "payload/run.bin")
    }

    @Test func officeDocumentsGetTheirContainerType() throws {
        let docx = AVFixtures.zip([.init(name: "[Content_Types].xml", data: Data("<Types/>".utf8)),
                                   .init(name: "word/document.xml", data: payload())])
        let engine = try AVFixtures.engine(["t.ldb": "Doc.Test.Ooxml-1;Engine:81-255,Container:CL_TYPE_OOXML_WORD,Target:0;0;\(AVFixtures.hex(Self.marker))\n"])
        #expect(engine.names(docx) == ["Doc.Test.Ooxml-1"])
        let plainZip = AVFixtures.zip([.init(name: "word/document.xml", data: payload())])
        #expect(engine.names(plainZip).isEmpty)
    }

    @Test func damagedCentralDirectoryFallsBackToLocalHeaders() throws {
        var zip = AVFixtures.zip([.init(name: "a.bin", data: payload())])
        zip.removeLast(30) // cut into the central directory / end record
        #expect(try engine().scan(data: zip, name: "cut.zip", options: AVScanOptions()).first?.memberPath == "a.bin")
    }

    @Test func zip64EndOfCentralDirectory() throws {
        // Rewrite the end record as ZIP64: 0xFFFF entries and 0xFFFFFFFF sizes, real values in the ZIP64 record.
        let zip = AVFixtures.zip([.init(name: "big.bin", data: payload())])
        let view = zip.withUnsafeBytes { Array($0) }
        let endOffset = zip.count - 22
        let directorySize = Int(UInt32(view[endOffset + 12]) | UInt32(view[endOffset + 13]) << 8 | UInt32(view[endOffset + 14]) << 16 | UInt32(view[endOffset + 15]) << 24)
        let directoryOffset = Int(UInt32(view[endOffset + 16]) | UInt32(view[endOffset + 17]) << 8 | UInt32(view[endOffset + 18]) << 16 | UInt32(view[endOffset + 19]) << 24)
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).littleEndian) { Data($0) } }
        func le64(_ v: Int) -> Data { withUnsafeBytes(of: UInt64(v).littleEndian) { Data($0) } }
        var out = zip.prefix(endOffset)
        let zip64End = out.count
        out += Data([0x50, 0x4B, 0x06, 0x06]) + le64(44) + le16(45) + le16(45) + le32(0) + le32(0)
        out += le64(1) + le64(1) + le64(directorySize) + le64(directoryOffset)
        out += Data([0x50, 0x4B, 0x06, 0x07]) + le32(0) + le64(zip64End) + le32(1)
        out += Data([0x50, 0x4B, 0x05, 0x06]) + le16(0) + le16(0) + le16(0xFFFF) + le16(0xFFFF) + le32(-1) + le32(-1) + le16(0)
        let listing = Data(out).withUnsafeBytes { AVZipReader.list(AVByteView($0), maxEntries: 10) }
        #expect(listing.entries.map(\.name) == ["big.bin"])
        #expect(try engine().scan(data: Data(out), name: "z64.zip", options: AVScanOptions()).first?.memberPath == "big.bin")
    }

    @Test func encryptedAndUnsupportedMembersAreFlagged() throws {
        let zip = AVFixtures.zip([.init(name: "secret.bin", data: payload(), encrypted: true),
                                  .init(name: "lzma.bin", data: AVFixtures.filler(100), deflate: false, method: 14),
                                  .init(name: "ok.txt", data: Data("fine".utf8))])
        let result = try scanFile(zip)
        #expect(result.detections.isEmpty)
        #expect(result.encryptedMembers == 1)
        #expect(result.unsupportedMembers == 1)
    }

    // MARK: Limits

    @Test func depthLimit() throws {
        var data = payload()
        for level in 0..<4 { data = AVFixtures.zip([.init(name: "level\(level).bin", data: data)]) }
        var options = AVScanOptions()
        options.maxArchiveDepth = 2
        let shallow = try scanFile(data, options: options)
        #expect(shallow.detections.isEmpty)
        #expect(shallow.limitsReached)
        options.maxArchiveDepth = 4
        let deep = try scanFile(data, options: options)
        #expect(deep.detections.count == 1)
        #expect(!deep.limitsReached)
    }

    @Test func memberCountLimit() throws {
        let members = (0..<6).map { AVFixtures.ZipMember(name: "f\($0).bin", data: $0 == 5 ? payload() : Data("x\($0)".utf8)) }
        var options = AVScanOptions()
        options.maxArchiveMembers = 3
        let limited = try scanFile(AVFixtures.zip(members), options: options)
        #expect(limited.detections.isEmpty)
        #expect(limited.limitsReached)
        options.maxArchiveMembers = 10
        #expect(try scanFile(AVFixtures.zip(members), options: options).detections.count == 1)
    }

    @Test func zipBombIsCutOffByTheExtractionLimit() throws {
        // 64 MB of zeros compresses to ~64 KB; ten of them claim 640 MB.
        let zeros = Data(count: 64 << 20)
        let members = (0..<10).map { AVFixtures.ZipMember(name: "zeros\($0)", data: zeros) }
        let bomb = AVFixtures.zip(members)
        #expect(bomb.count < 2 << 20)
        var options = AVScanOptions()
        options.maxExtractedBytes = 100 << 20
        let result = try scanFile(bomb, options: options)
        #expect(result.limitsReached)
        #expect(result.detections.isEmpty)
    }

    @Test func archivesAreSkippedWhenDisabled() throws {
        var options = AVScanOptions()
        options.scanArchives = false
        let zip = AVFixtures.zip([.init(name: "a.bin", data: payload())])
        #expect(try scanFile(zip, options: options).detections.isEmpty)
    }

    @Test func malformedArchivesDontCrash() throws {
        let engine = try engine()
        let valid = AVFixtures.zip([.init(name: "a.bin", data: payload()), .init(name: "b.bin", data: payload(10))])
        let tar = AVFixtures.tar([("a", payload())])
        let gz = AVFixtures.gzip(payload())
        let fat = AVFixtures.universal([AVFixtures.machO(code: payload(16))])
        // Truncations and byte flips at many positions must never crash or hang.
        for sample in [valid, tar, gz, fat] {
            for cut in stride(from: 0, to: sample.count, by: max(1, sample.count / 40)) {
                _ = engine.scan(data: sample.prefix(cut), name: "cut", options: AVScanOptions())
                var flipped = sample
                flipped[cut] ^= 0xFF
                _ = engine.scan(data: flipped, name: "flip", options: AVScanOptions())
            }
        }
        // Absurd sizes and offsets in headers.
        var bogus = AVFixtures.zip([.init(name: "a.bin", data: payload())])
        bogus.replaceSubrange((bogus.count - 6)..<(bogus.count - 2), with: [0xFF, 0xFF, 0xFF, 0x7F])
        _ = engine.scan(data: bogus, name: "bogus", options: AVScanOptions())
        var fatBogus = Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2])
        fatBogus += Data([0x01, 0, 0, 0x07, 0, 0, 0, 3, 0x7F, 0xFF, 0xFF, 0xFF, 0x7F, 0xFF, 0xFF, 0xFF, 0, 0, 0, 12])
        _ = engine.scan(data: fatBogus, name: "fat", options: AVScanOptions())
    }
}
