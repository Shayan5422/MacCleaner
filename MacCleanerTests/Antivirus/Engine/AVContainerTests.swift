import Foundation
import Testing
@testable import MacCleaner

/// ClamAV database containers: header parsing, RSA verification of `.cvd`, signed-index
/// verification of `.cld`, and tampering.
struct AVContainerTests {
    // MARK: Arithmetic and encoding

    @Test func bigIntegerArithmetic() throws {
        let base = try #require(AVBigUInt(decimal: "123456789012345678901234567890"))
        let modulus = try #require(AVBigUInt(decimal: "1000000007"))
        // Expected values computed independently (Python big integers).
        #expect(base.remainder(dividingBy: modulus) == AVBigUInt(UInt64(197_434_842)))
        #expect(AVBigUInt(3).power(AVBigUInt(200), modulus: modulus) == AVBigUInt(UInt64(136_318_165)))
        #expect(AVBigUInt(bigEndianBytes: [0x01, 0x00]).bigEndianBytes(count: 2) == [0x01, 0x00])
        #expect(AVBigUInt(UInt64(0x1_0000)).bigEndianBytes(count: 2) == nil)
        #expect(AVBigUInt(decimal: "12a") == nil)
    }

    @Test func clamAVBase64IsLittleEndianWithLowercaseFirst() {
        #expect(ClamAVSignatureVerifier.decodeSignature("a") == AVBigUInt(0))
        #expect(ClamAVSignatureVerifier.decodeSignature("b") == AVBigUInt(1))
        #expect(ClamAVSignatureVerifier.decodeSignature("A") == AVBigUInt(26))
        #expect(ClamAVSignatureVerifier.decodeSignature("ab") == AVBigUInt(64)) // second digit is the high one
        #expect(ClamAVSignatureVerifier.decodeSignature("a=") == nil)
    }

    // MARK: Headers

    @Test func parsesHeaders() throws {
        let directory = AVTestDirectory()
        let url = try directory.write("daily.cld", AVFixtures.header(version: 27_000, signatures: 42) + AVFixtures.tar([("x.ndb", Data())]))
        let header = try ClamAVDatabaseFile.readHeader(at: url)
        #expect(header.name == "daily")
        #expect(header.version == 27_000)
        #expect(header.signatureCount == 42)
        #expect(header.functionalityLevel == 90)
        #expect(header.builder == "tester")
        #expect(header.format == .cld)
        #expect(header.verification == nil)
        #expect(header.buildTime == Date(timeIntervalSince1970: 1_792_131_857))
        #expect(ClamAVContainer.parseBuildTime("16 Oct 2026 06-24 +0000") == Date(timeIntervalSince1970: 1_792_131_840))
        #expect(ClamAVContainer.databaseName(fromFileName: "daily-28155.cvd") == "daily")
    }

    @Test func rejectsMalformedHeaders() throws {
        let directory = AVTestDirectory()
        for (index, text) in ["not a database", "ClamAV-VDB:16 Oct 2026 06-24 +0000:x:1:90:X:X:t:1", "ClamAV-VDB:a:b"].enumerated() {
            var data = Data(text.utf8)
            data += Data(repeating: 0x20, count: 512 - data.count)
            let url = try directory.write("bad\(index).cvd", data)
            #expect(throws: AVEngineError.self) { _ = try ClamAVDatabaseFile.readHeader(at: url) }
        }
        let empty = try directory.write("empty.cvd", Data())
        #expect(throws: AVEngineError.self) { _ = try ClamAVDatabaseFile.readHeader(at: empty) }
    }

    // MARK: Local databases (.cld)

    @Test func cldWithoutIndexIsStructureOnly() throws {
        let directory = AVTestDirectory()
        let url = try directory.write("test.cld", AVFixtures.cld(files: [("test.ndb", Data("Test.A-1:0:*:0102030405\n".utf8))]))
        let header = try ClamAVDatabaseFile.verify(at: url)
        #expect(header.verification == .structureOnly)
        #expect(header.verification?.isSigned == false)
        // A damaged tar header is rejected.
        var damaged = AVFixtures.cld(files: [("test.ndb", Data("x".utf8))])
        damaged[512 + 10] ^= 0x55
        let damagedURL = try directory.write("damaged.cld", damaged)
        #expect(throws: AVEngineError.self) { _ = try ClamAVDatabaseFile.verify(at: damagedURL) }
    }

    @Test func cldMayBeCompressed() throws {
        let tar = AVFixtures.tar([("test.ndb", Data("Test.A-1:0:*:0102030405\n".utf8))])
        let directory = AVTestDirectory()
        let url = try directory.write("test.cld", AVFixtures.header() + AVFixtures.gzip(tar))
        #expect(try ClamAVDatabaseFile.verify(at: url).verification == .structureOnly)
    }

    // MARK: Real databases

    /// `.cvd` → `.cld` the way freshclam stores it: the same header followed by the uncompressed tar.
    private func makeCLD(fromCVD url: URL) throws -> Data {
        let cvd = try Data(contentsOf: url)
        let tar = cvd.dropFirst(512).withUnsafeBytes { AVGzipReader.decompress(AVByteView($0), limit: 1 << 31).data }
        return cvd.prefix(512) + tar
    }

    @Test(.enabled(if: AVRealDatabase.isAvailable)) func realCVDsVerify() throws {
        for url in [AVRealDatabase.mainCVD, AVRealDatabase.dailyCVD].compactMap({ $0 }) {
            let header = try ClamAVDatabaseFile.verify(at: url)
            #expect(header.verification == .signedContainer)
            #expect(header.format == .cvd)
            #expect(header.functionalityLevel == 90)
        }
        let main = try ClamAVDatabaseFile.verify(at: try #require(AVRealDatabase.mainCVD))
        #expect(main.name == "main")
        #expect(main.version == 63)
        #expect(main.signatureCount == 3_287_027)
    }

    @Test(.enabled(if: AVRealDatabase.isAvailable)) func tamperedCVDsAreRejected() throws {
        let original = try Data(contentsOf: try #require(AVRealDatabase.dailyCVD))
        let directory = AVTestDirectory()

        // A flipped byte in the archive: the MD5 no longer matches.
        var flipped = original
        flipped[100_000] ^= 0x01
        let flippedURL = try directory.write("daily.cvd", flipped)
        #expect(throws: AVEngineError.self) { _ = try ClamAVDatabaseFile.verify(at: flippedURL) }

        // A changed header MD5.
        var header = String(decoding: original.prefix(512), as: UTF8.self)
        let fields = header.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var badMD5 = fields
        badMD5[5] = String(repeating: "0", count: 32)
        header = badMD5.joined(separator: ":")
        let badMD5URL = try directory.write("md5/daily.cvd", Data(header.utf8).prefix(512) + original.dropFirst(512))
        #expect(throws: AVEngineError.self) { _ = try ClamAVDatabaseFile.verify(at: badMD5URL) }

        // A changed signature: the MD5 matches but RSA verification fails.
        var badSignature = fields
        let signature = Array(badSignature[6])
        badSignature[6] = String(signature.dropLast()) + (signature.last == "a" ? "b" : "a")
        let badSignatureURL = try directory.write("dsig/daily.cvd", Data(badSignature.joined(separator: ":").utf8).prefix(512) + original.dropFirst(512))
        #expect(throws: AVEngineError.signatureMismatch("daily.cvd")) { _ = try ClamAVDatabaseFile.verify(at: badSignatureURL) }

        // Modified contents with a recomputed MD5: still rejected by the signature.
        var modified = original
        modified[original.count - 10] ^= 0x01
        let newMD5 = AVHex.string(AVDigest.md5(modified.dropFirst(512)))
        var forged = fields
        forged[5] = newMD5
        let forgedURL = try directory.write("forged/daily.cvd", Data(forged.joined(separator: ":").utf8).prefix(512) + modified.dropFirst(512))
        #expect(throws: AVEngineError.signatureMismatch("daily.cvd")) { _ = try ClamAVDatabaseFile.verify(at: forgedURL) }
    }

    @Test(.enabled(if: AVRealDatabase.bytecodeCVD != nil)) func smallCLDBuiltFromCVDLoadsIdentically() throws {
        let cvd = try #require(AVRealDatabase.bytecodeCVD)
        let directory = AVTestDirectory()
        let cldURL = try directory.write("bytecode.cld", try makeCLD(fromCVD: cvd))
        let header = try ClamAVDatabaseFile.verify(at: cldURL)
        #expect(header.verification == .signedIndex)
        #expect(try ClamAVDatabaseFile.verify(at: cvd).verification == .signedContainer)
        let fromCVD = try AVDatabaseCompiler.compile(AVDatabaseInputs(clamavFiles: [cvd]), into: directory.file("cvd"))
        let fromCLD = try AVDatabaseCompiler.compile(AVDatabaseInputs(clamavFiles: [cldURL]), into: directory.file("cld"))
        #expect(fromCLD.clamavVersions == fromCVD.clamavVersions)
        #expect(fromCLD.signatureCount == fromCVD.signatureCount)
        #expect(fromCLD.unsupportedSignatureCount == fromCVD.unsupportedSignatureCount)
        #expect(fromCLD.coverage == fromCVD.coverage)
        #expect(fromCLD.clamavVerification == ["bytecode": .signedIndex])
        _ = try AVEngine.load(from: directory.file("cld"))
    }

    /// The same with daily (slow in Debug builds: two full compiles of ~360,000 signatures).
    @Test(.enabled(if: AVRealDatabase.isAvailable)) func dailyCLDBuiltFromCVDCompilesIdentically() throws {
        let dailyCVD = try #require(AVRealDatabase.dailyCVD)
        let directory = AVTestDirectory()
        let cldURL = try directory.write("daily.cld", try makeCLD(fromCVD: dailyCVD))

        let header = try ClamAVDatabaseFile.verify(at: cldURL)
        #expect(header.verification == .signedIndex)
        #expect(header.format == .cld)
        #expect(header.name == "daily")
        #expect(header.version == 28155)

        let fromCVD = try AVDatabaseCompiler.compile(AVDatabaseInputs(clamavFiles: [dailyCVD]), into: directory.file("cvd"))
        let fromCLD = try AVDatabaseCompiler.compile(AVDatabaseInputs(clamavFiles: [cldURL]), into: directory.file("cld"))
        #expect(fromCLD.signatureCount == fromCVD.signatureCount)
        #expect(fromCLD.hashSignatureCount == fromCVD.hashSignatureCount)
        #expect(fromCLD.bodySignatureCount == fromCVD.bodySignatureCount)
        #expect(fromCLD.logicalSignatureCount == fromCVD.logicalSignatureCount)
        #expect(fromCLD.unsupportedSignatureCount == fromCVD.unsupportedSignatureCount)
        #expect(fromCLD.coverage == fromCVD.coverage)
        #expect(fromCLD.clamavVersions == ["daily": 28155])
        #expect(fromCVD.clamavVerification == ["daily": .signedContainer])
        #expect(fromCLD.clamavVerification == ["daily": .signedIndex])
        // The two compiled engines behave the same.
        let eicar = Data(AVBuiltInSignatures.eicar)
        let a = try AVEngine.load(from: directory.file("cvd")).names(eicar)
        let b = try AVEngine.load(from: directory.file("cld")).names(eicar)
        #expect(a == b)
    }

    @Test(.enabled(if: AVRealDatabase.isAvailable)) func tamperedCLDsAreRejected() throws {
        let cld = try makeCLD(fromCVD: try #require(AVRealDatabase.dailyCVD))
        let directory = AVTestDirectory()
        let listing = cld.dropFirst(512).withUnsafeBytes { AVTarReader.list(AVByteView($0), maxEntries: 100) }
        let ndb = try #require(listing.entries.first { $0.name == "daily.ndb" })
        let info = try #require(listing.entries.first { $0.name == "daily.info" })

        // A signature file changed after the index was signed.
        var changedFile = cld
        changedFile[512 + ndb.dataOffset + 5] ^= 0x01
        let changedURL = try directory.write("a/daily.cld", changedFile)
        #expect(throws: AVEngineError.self) { _ = try ClamAVDatabaseFile.verify(at: changedURL) }

        // The index itself changed: its signature no longer verifies.
        var changedIndex = cld
        changedIndex[512 + info.dataOffset + 20] ^= 0x01
        let indexURL = try directory.write("b/daily.cld", changedIndex)
        #expect(throws: AVEngineError.signatureMismatch("daily.cld")) { _ = try ClamAVDatabaseFile.verify(at: indexURL) }
    }

    @Test(.enabled(if: AVRealDatabase.bytecodeCVD != nil)) func newerContainerOfTheSameNameWins() throws {
        let cvd = try #require(AVRealDatabase.bytecodeCVD)
        let version = try ClamAVDatabaseFile.readHeader(at: cvd).version
        let directory = AVTestDirectory()
        // An older (version 1) local database next to the real one: the real one is compiled.
        let old = try directory.write("old/bytecode.cld", AVFixtures.cld(files: [("bytecode.ndb", Data("Old.Sig-1:0:*:0102030405\n".utf8))]))
        let summary = try AVDatabaseCompiler.compile(AVDatabaseInputs(clamavFiles: [old, cvd]), into: directory.file("db"))
        #expect(summary.clamavVersions == ["bytecode": version])
        #expect(summary.bodySignatureCount == 0)
    }
}
