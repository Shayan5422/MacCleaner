import Compression
import Foundation
import Testing
@testable import MacCleaner

/// Accepts any patch signature, for synthetic patches.
struct AVAcceptingVerifier: AVCdiffVerifying {
    func verify(sha256: Data, signature: String) -> Bool { true }
}

enum AVTestGzip {
    /// gzip framing around a raw DEFLATE stream from the Compression framework.
    static func compress(_ data: Data) -> Data {
        let capacity = data.count + 1_024
        var output = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { source in
            compression_encode_buffer(&output, capacity, source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        var crc = AVDefsCRC32()
        data.withUnsafeBytes { crc.update($0) }
        var gzip = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        gzip.append(contentsOf: output.prefix(written))
        withUnsafeBytes(of: crc.checksum.littleEndian) { gzip.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: data.count).littleEndian) { gzip.append(contentsOf: $0) }
        return gzip
    }

    /// A `.cdiff` with a placeholder signature (use `AVAcceptingVerifier`).
    static func cdiff(version: Int, script: String) -> Data {
        var data = Data("ClamAV-Diff:\(version):\(script.utf8.count):".utf8)
        data.append(compress(Data(script.utf8)))
        data.append(Data(":unsigned".utf8))
        return data
    }
}

@Suite("Antivirus definition formats")
struct AVDefinitionsFormatTests {
    @Test func parsesTheVersionRecord() throws {
        let info = try #require(AVClamAVTXTRecord.parse("1.4.6:63:28155:1792157340:1:90:49192:339"))
        #expect(info.clamavVersion == "1.4.6")
        #expect(info.main == 63)
        #expect(info.daily == 28155)
        #expect(info.bytecode == 339)
        #expect(info.publishedAt == Date(timeIntervalSince1970: 1_792_157_340))
        #expect(info.version(of: .daily) == 28155)
        #expect(AVClamAVTXTRecord.parse("garbage") == nil)
        #expect(AVClamAVTXTRecord.parse("1.4.6:x:28155:1") == nil)
    }

    @Test func parsesTXTRecordData() {
        let rdata = Data([5]) + Data("hello".utf8) + Data([3]) + Data("abc".utf8)
        #expect(AVDNSTXTResolver.parseTXT(rdata) == ["hello", "abc"])
        #expect(AVDNSTXTResolver.parseTXT(Data([9]) + Data("short".utf8)) == ["short"])
    }

    @Test func parsesDatabaseHeaders() throws {
        let header = try #require(AVClamAVHeaderLine.parse("ClamAV-VDB:16 Oct 2026 06-24 +0000:28155:355765:90:78e0d1:xTcK:svc.clamav-publisher:1792131857"))
        #expect(header.version == 28155)
        #expect(header.signatureCount == 355_765)
        #expect(header.functionalityLevel == 90)
        #expect(header.builder == "svc.clamav-publisher")
        #expect(header.buildTime == Date(timeIntervalSince1970: 1_792_131_857))
        let withoutTime = try #require(AVClamAVHeaderLine.parse("ClamAV-VDB:16 Dec 2025 23-18 +0000:63:3287027:90"))
        #expect(withoutTime.version == 63)
        #expect(withoutTime.buildTime != nil)
        #expect(AVClamAVHeaderLine.parse("NotClamAV:1:2:3") == nil)
    }

    @Test(.enabled(if: AVRealFiles.url("cdiff/daily-28155.cdiff") != nil))
    func verifiesARealPatchSignedByClamAV() throws {
        let data = try Data(contentsOf: #require(AVRealFiles.url("cdiff/daily-28155.cdiff")))
        let patch = try AVCdiff.open(data)
        #expect(patch.version == 28155)
        #expect(patch.script.hasPrefix("OPEN daily.info"))
        var tampered = data
        tampered[tampered.startIndex + 40] ^= 0x01
        #expect(throws: AVCdiff.Failure.badSignature) { try AVCdiff.open(tampered) }
    }

    @Test func rejectsPatchesWithForgedSignatures() {
        let forged = AVTestGzip.cdiff(version: 5, script: "OPEN daily.info\nCLOSE\n")
        #expect(throws: AVCdiff.Failure.badSignature) { try AVCdiff.open(forged) }
        #expect(throws: (any Error).self) { try AVCdiff.open(Data("not a patch".utf8)) }
    }

    @Test func appliesEveryScriptCommand() throws {
        let directory = try AVTestFolder()
        try directory.makeFile("db/daily.ndb", contents: Data("one\ntwo\nthree\nfour\n".utf8))
        try directory.makeFile("db/daily.hdb", contents: Data("h1\nh2\nh3\n".utf8))
        try directory.makeFile("db/daily.old", contents: Data("gone\n".utf8))
        let script = """
        # comment
        OPEN daily.ndb
        DEL 2 tw
        XCHG 3 thr three-replaced with spaces
        ADD five
        CLOSE
        MOVE daily.hdb daily.mdb 2 h2 3 h3
        UNLINK daily.old
        OPEN daily.new
        ADD fresh line
        CLOSE
        """
        let patch = try AVCdiff.open(AVTestGzip.cdiff(version: 7, script: script), verifier: AVAcceptingVerifier())
        #expect(patch.version == 7)
        let db = directory.child("db")
        try AVCdiff.apply(patch.script, in: db)
        #expect(try String(contentsOf: db.appendingPathComponent("daily.ndb"), encoding: .utf8) == "one\nthree-replaced with spaces\nfour\nfive\n")
        #expect(try String(contentsOf: db.appendingPathComponent("daily.hdb"), encoding: .utf8) == "h1\n")
        #expect(try String(contentsOf: db.appendingPathComponent("daily.mdb"), encoding: .utf8) == "h2\nh3\n")
        #expect(try String(contentsOf: db.appendingPathComponent("daily.new"), encoding: .utf8) == "fresh line\n")
        #expect(!FileManager.default.fileExists(atPath: db.appendingPathComponent("daily.old").path))
    }

    @Test func keepsBytesThatAreNotUTF8() throws {
        let directory = try AVTestFolder()
        var original = Data("keep\n".utf8)
        original.append(contentsOf: [0xFF, 0xFE, 0x0A])
        original.append(Data("drop me\n".utf8))
        try directory.makeFile("db/daily.fp", contents: original)
        try AVCdiff.apply("OPEN daily.fp\nDEL 3 drop\nCLOSE\n", in: directory.child("db"))
        var expected = Data("keep\n".utf8)
        expected.append(contentsOf: [0xFF, 0xFE, 0x0A])
        #expect(try Data(contentsOf: directory.child("db/daily.fp")) == expected)
    }

    @Test func refusesConflictsAndUnsafeFileNames() throws {
        let directory = try AVTestFolder()
        try directory.makeFile("db/daily.ndb", contents: Data("alpha\nbeta\n".utf8))
        let db = directory.child("db")
        #expect(throws: AVCdiff.Failure.self) { try AVCdiff.apply("OPEN daily.ndb\nDEL 2 gamma\nCLOSE\n", in: db) }
        #expect(throws: AVCdiff.Failure.self) { try AVCdiff.apply("OPEN daily.ndb\nXCHG 9 alpha x\nCLOSE\n", in: db) }
        #expect(throws: AVCdiff.Failure.self) { try AVCdiff.apply("OPEN ../escape\nADD x\nCLOSE\n", in: db) }
        #expect(throws: AVCdiff.Failure.self) { try AVCdiff.apply("OPEN daily.ndb\nADD x\n", in: db) }
        #expect(throws: AVCdiff.Failure.self) { try AVCdiff.apply("FORMAT everything\n", in: db) }
        #expect(try String(contentsOf: db.appendingPathComponent("daily.ndb"), encoding: .utf8) == "alpha\nbeta\n")
    }

    @Test(.enabled(if: AVRealFiles.hasClamAV))
    func unpacksVerifiesAndRepacksTheRealDailyDatabase() throws {
        let directory = try AVTestFolder()
        let source = try #require(AVRealFiles.url("clamav/daily.cvd"))
        let unpacked = try directory.makeDirectory("daily")
        let names = try AVClamAVLocalDatabase.unpack(source, to: URL(fileURLWithPath: unpacked))
        #expect(names.contains("daily.info"))
        let header = try AVClamAVLocalDatabase.verifyUnpacked(.daily, in: URL(fileURLWithPath: unpacked), expectedVersion: 28155)
        #expect(header.version == 28155)

        let cld = directory.child("clamav/daily.cld")
        try FileManager.default.createDirectory(at: cld.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AVClamAVLocalDatabase.pack(.daily, from: URL(fileURLWithPath: unpacked), to: cld)
        #expect(AVClamAVLocalDatabase.current(.daily, in: cld.deletingLastPathComponent())?.header.version == 28155)

        let again = try directory.makeDirectory("again")
        _ = try AVClamAVLocalDatabase.unpack(cld, to: URL(fileURLWithPath: again))
        try AVClamAVLocalDatabase.verifyUnpacked(.daily, in: URL(fileURLWithPath: again), expectedVersion: 28155)

        // A modified file no longer matches the signed index.
        try Data("tampered\n".utf8).write(to: URL(fileURLWithPath: again).appendingPathComponent("daily.wdb"))
        #expect(throws: AVClamAVLocalDatabase.Failure.self) { try AVClamAVLocalDatabase.verifyUnpacked(.daily, in: URL(fileURLWithPath: again)) }
    }

    /// Rebuilds a database that the real 28155 patch applies to, applies it and checks the
    /// result against the real signed index.
    @Test(.enabled(if: AVRealFiles.hasClamAV && AVRealFiles.url("cdiff/daily-28155.cdiff") != nil))
    func appliesTheRealPatchToTheDatabaseItWasMadeFor() throws {
        let directory = try AVTestFolder()
        let unpacked = URL(fileURLWithPath: try directory.makeDirectory("daily"))
        _ = try AVClamAVLocalDatabase.unpack(try #require(AVRealFiles.url("clamav/daily.cvd")), to: unpacked)
        let infoURL = unpacked.appendingPathComponent("daily.info")
        var lines = try String(contentsOf: infoURL, encoding: .utf8).components(separatedBy: "\n")
        let patch = try AVCdiff.open(Data(contentsOf: #require(AVRealFiles.url("cdiff/daily-28155.cdiff"))))
        // The patch replaces line 1 (starting "ClamAV-VDB:15") and line 25 (starting "DSIG:efF/zZFXlSp").
        lines[0] = "ClamAV-VDB:15 Oct 2026 previous version"
        lines[24] = "DSIG:efF/zZFXlSp-previous"
        try Data(lines.joined(separator: "\n").utf8).write(to: infoURL)
        #expect(throws: (any Error).self) { try AVClamAVLocalDatabase.verifyUnpacked(.daily, in: unpacked, expectedVersion: 28155) }

        try AVCdiff.apply(patch.script, in: unpacked)
        let header = try AVClamAVLocalDatabase.verifyUnpacked(.daily, in: unpacked, expectedVersion: 28155)
        #expect(header.version == 28155)
    }

    @Test func gzipChecksIntegrity() throws {
        let original = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let gzip = AVTestGzip.compress(original)
        var output = Data()
        try AVDefsGzip.decompress(gzip, maxOutput: 1_000_000) { output.append(contentsOf: $0) }
        #expect(output == original)
        var damaged = gzip
        damaged[damaged.count - 6] ^= 0xFF
        #expect(throws: (any Error).self) { try AVDefsGzip.decompress(damaged, maxOutput: 1_000_000) { _ in } }
        #expect(throws: AVDefsArchiveError.tooLarge) { try AVDefsGzip.decompress(gzip, maxOutput: 100) { _ in } }
        #expect(throws: AVDefsArchiveError.notGzip) { try AVDefsGzip.decompress(Data("plain".utf8), maxOutput: 100) { _ in } }
    }

    @Test func readsSingleEntryZips() async throws {
        let directory = try AVTestFolder()
        let text = Data((0..<2_000).map { String(format: "%064x", $0) + "\n" }.joined().utf8)
        let source = try directory.makeFile("full_sha256.txt", contents: text)
        let zip = directory.child("export.zip")
        let result = try await ProcessRunner.run("/usr/bin/ditto", arguments: ["-c", "-k", source, zip.path], timeout: 60)
        #expect(result.succeeded)
        let data = try Data(contentsOf: zip)
        let entries = try AVDefsZip.entries(in: data)
        let entry = try #require(entries.first { $0.name.hasSuffix(".txt") })
        let output = directory.child("out.txt")
        try AVDefsZip.extract(entry, from: data, to: output, maxOutput: 10_000_000)
        #expect(try Data(contentsOf: output) == text)
        #expect(AVFeedParser.countSHA256Lines(in: output) == 2_000)
        #expect(throws: AVDefsArchiveError.tooLarge) { try AVDefsZip.extract(entry, from: data, to: directory.child("small.txt"), maxOutput: 10) }
    }
}
