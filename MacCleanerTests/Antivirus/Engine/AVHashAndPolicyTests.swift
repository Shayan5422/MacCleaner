import CryptoKit
import Foundation
import Testing
@testable import MacCleaner

/// Hash signatures, allow lists, ignore lists, PUA and platform gating, the built-in EICAR
/// signature and SHA-256 hash lists.
struct AVHashAndPolicyTests {
    private let sample = Data("a perfectly ordinary sample file used by the hash tests\n".utf8) + AVFixtures.filler(300, seed: 3)

    private func md5(_ data: Data) -> String { AVHex.string(Insecure.MD5.hash(data: data)) }
    private func sha1(_ data: Data) -> String { AVHex.string(Insecure.SHA1.hash(data: data)) }
    private func sha256(_ data: Data) -> String { AVHex.string(SHA256.hash(data: data)) }

    // MARK: Hash signatures

    @Test func fileHashesNeedTheRightSize() throws {
        let engine = try AVFixtures.engine([
            "t.hdb": "\(md5(sample)):\(sample.count):Test.Md5-1\n\(md5(sample)):\(sample.count + 1):Test.Md5WrongSize-1\n",
            "t.hsb": "\(sha1(sample)):\(sample.count):Test.Sha1-1:73\n\(sha256(sample)):*:Test.Sha256Wildcard-1:73\n",
        ])
        #expect(Set(engine.names(sample)) == ["Test.Md5-1", "Test.Sha1-1", "Test.Sha256Wildcard-1"])
        #expect(engine.names(sample + Data([0])).isEmpty)
    }

    @Test func wildcardMD5AppliesToEverySize() throws {
        let engine = try AVFixtures.engine(["t.hsb": "\(md5(sample)):*:Test.Md5Any-1:73\n"])
        #expect(engine.names(sample) == ["Test.Md5Any-1"])
    }

    @Test func peSectionHashes() throws {
        let section = Data("section bytes".utf8) + AVFixtures.filler(499, seed: 9)
        let pe = AVFixtures.pe(sections: [(".text", section)])
        // The section hash covers SizeOfRawData bytes (rounded up to the 512-byte file alignment).
        let raw = section + Data(count: (512 - section.count % 512) % 512)
        let engine = try AVFixtures.engine(["t.mdb": "\(raw.count):\(md5(raw)):Win.Test.Section-1\n"])
        #expect(engine.names(pe) == ["Win.Test.Section-1"])
        // ClamAV doesn't apply section hashes to 64-bit images, nor when non-Mac threats are off.
        #expect(engine.names(AVFixtures.pe(sections: [(".text", section)], pe32Plus: true)).isEmpty)
        var macOnly = AVScanOptions()
        macOnly.detectNonMacThreats = false
        #expect(engine.names(pe, options: macOnly).isEmpty)
    }

    // MARK: Allow lists

    @Test func allowListsSuppressDetections() throws {
        let body = "Test.Body-1:0:*:\(AVFixtures.hex("perfectly ordinary"))\n"
        #expect(try AVFixtures.engine(["t.ndb": body]).names(sample) == ["Test.Body-1"])
        let byMD5 = try AVFixtures.engine(["t.ndb": body, "t.fp": "\(md5(sample)):\(sample.count):Allowed-1\n"])
        #expect(byMD5.names(sample).isEmpty)
        let bySHA256 = try AVFixtures.engine(["t.ndb": body, "t.sfp": "\(sha256(sample)):\(sample.count):Allowed-2\n"])
        #expect(bySHA256.names(sample).isEmpty)
        // The size must match too.
        let wrongSize = try AVFixtures.engine(["t.ndb": body, "t.fp": "\(md5(sample)):\(sample.count + 5):Allowed-3\n"])
        #expect(wrongSize.names(sample) == ["Test.Body-1"])
    }

    @Test func allowListedArchiveSuppressesItsMembers() throws {
        let zip = AVFixtures.zip([.init(name: "inner.txt", data: sample)])
        let body = "Test.Body-1:0:*:\(AVFixtures.hex("perfectly ordinary"))\n"
        #expect(try AVFixtures.engine(["t.ndb": body]).names(zip) == ["Test.Body-1"])
        let allowed = try AVFixtures.engine(["t.ndb": body, "t.sfp": "\(sha256(zip)):\(zip.count):Allowed-Zip\n"])
        #expect(allowed.names(zip).isEmpty)
    }

    // MARK: Ignore lists

    @Test func ignoreListsDropSignatures() throws {
        let line = "Test.Ignored-1:0:*:\(AVFixtures.hex("perfectly ordinary"))"
        let lineMD5 = md5(Data(line.utf8))
        let files: [String: String] = [
            "t.ndb": line + "\nTest.Kept-1:0:*:\(AVFixtures.hex("ordinary sample"))\nTest.Legacy-1:0:*:\(AVFixtures.hex("sample file"))\n",
            "t.ign2": "Test.Ignored-1:\(lineMD5)\n",
            "t.ign": "t.ndb:3:Test.Legacy-1\n",
        ]
        #expect(try AVFixtures.engine(files).names(sample) == ["Test.Kept-1"])
        // With a digest that doesn't match the line, the signature stays.
        var stale = files
        stale["t.ign2"] = "Test.Ignored-1:00000000000000000000000000000000\n"
        #expect(Set(try AVFixtures.engine(stale).names(sample)) == ["Test.Ignored-1", "Test.Kept-1"])
    }

    // MARK: PUA and platforms

    @Test func puaSignaturesAreGated() throws {
        let engine = try AVFixtures.engine([
            "t.ndu": "Osx.Adware.Bundler-1:0:*:\(AVFixtures.hex("perfectly ordinary"))\n",
            "t.ndb": "PUA.Osx.Tool.Thing-1:0:*:\(AVFixtures.hex("ordinary sample"))\n",
        ])
        let detections = engine.scan(data: sample, name: "s", options: AVScanOptions())
        #expect(Set(detections.map(\.signatureName)) == ["Osx.Adware.Bundler-1", "PUA.Osx.Tool.Thing-1"])
        #expect(detections.allSatisfy { $0.kind == .pua && $0.source == .clamav })
        var noPUA = AVScanOptions()
        noPUA.detectPUA = false
        #expect(engine.names(sample, options: noPUA).isEmpty)
    }

    @Test func nonMacThreatsAreGated() throws {
        let pe = AVFixtures.pe(sections: [(".text", Data("windows-only-marker".utf8) + Data(count: 64))])
        let engine = try AVFixtures.engine([
            "t.ndb": """
                Win.Trojan.Named-1:0:*:\(AVFixtures.hex("perfectly ordinary"))
                Osx.Trojan.Named-1:0:*:\(AVFixtures.hex("ordinary sample"))
                Html.Exploit.Generic-1:1:*:\(AVFixtures.hex("windows-only-marker"))
                """,
        ])
        #expect(Set(engine.names(sample)) == ["Win.Trojan.Named-1", "Osx.Trojan.Named-1"])
        #expect(engine.names(pe) == ["Html.Exploit.Generic-1"])
        var macOnly = AVScanOptions()
        macOnly.detectNonMacThreats = false
        #expect(engine.names(sample, options: macOnly) == ["Osx.Trojan.Named-1"])
        #expect(engine.names(pe, options: macOnly).isEmpty)
    }

    // MARK: EICAR

    @Test func builtInEICARWithoutDefinitions() throws {
        let engine = AVEngine.builtIn()
        #expect(!engine.hasDatabase)
        let eicar = Data(AVBuiltInSignatures.eicar)
        let detections = engine.scan(data: eicar, name: "eicar.com", options: AVScanOptions())
        #expect(detections == [AVDetection(signatureName: "EICAR-Test-File", kind: .testFile, source: .builtIn, memberPath: nil)])
        #expect(engine.names(eicar + Data("  \r\n\u{1A}".utf8)) == ["EICAR-Test-File"])
        #expect(engine.names(eicar + Data("x".utf8)).isEmpty)
        #expect(engine.names(eicar + Data(repeating: 0x20, count: 61)).isEmpty) // over 128 bytes
        #expect(engine.names(Data("x".utf8) + eicar).isEmpty)
        // Inside archives too.
        let zip = AVFixtures.zip([.init(name: "eicar.com", data: eicar)])
        #expect(engine.scan(data: AVFixtures.zip([.init(name: "eicar.zip", data: zip, deflate: false)]), name: "z", options: AVScanOptions())
                    .first?.memberPath == "eicar.zip › eicar.com")
    }

    // MARK: SHA-256 lists

    @Test func sha256Lists() throws {
        let list = "# MalwareBazaar recent\n#\n\(sha256(sample))\n\(String(repeating: "ab", count: 32))\nnot-a-hash\n"
        let engine = try AVFixtures.engine(["t.ndb": "Test.Unused-1:0:*:0102030405060708\n"], hashLists: [(list, .malwareBazaar)])
        #expect(engine.summary.hashListCount == 2)
        let detections = engine.scan(data: sample, name: "s", options: AVScanOptions())
        #expect(detections == [AVDetection(signatureName: "MalwareBazaar.KnownMalware", kind: .malware, source: .malwareBazaar, memberPath: nil)])
        // Members of archives are looked up too, and allow lists apply.
        let zip = AVFixtures.zip([.init(name: "sample.bin", data: sample)])
        #expect(engine.scan(data: zip, name: "z", options: AVScanOptions()).first?.memberPath == "sample.bin")
        let allowed = try AVFixtures.engine(["t.sfp": "\(sha256(sample)):\(sample.count):Allowed\n"], hashLists: [(list, .threatFox)])
        #expect(allowed.names(sample).isEmpty)
    }

    @Test func zippedHashList() throws {
        let text = "\(sha256(sample))\n"
        let zip = AVFixtures.zip([.init(name: "full_sha256.txt", data: Data(text.utf8))])
        let builder = AVDatabaseBuilder(functionalityLevel: AVEngine.functionalityLevel)
        builder.addHashList(zip, source: .malwareBazaar)
        #expect(builder.hashListCount == 1)
    }
}
