import Foundation
import Testing
@testable import MacCleaner

/// Logical signatures (`.ldb`): expressions, counts, modifiers, PCRE, byte compare and the
/// target description block.
struct AVLogicalSignatureTests {
    private func binary(_ parts: [(Int, String)], size: Int = 8192) -> Data {
        var data = AVFixtures.filler(size, seed: 11)
        data[0] = 0; data[1] = 2
        for (offset, text) in parts {
            let bytes = Array(text.utf8)
            data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
        return data
    }

    private func h(_ text: String) -> String { AVFixtures.hex(text) }

    private func detects(_ ldb: String, _ data: Data, options: AVScanOptions = AVScanOptions()) throws -> Bool {
        let engine = try AVFixtures.engine(["t.ldb": ldb + "\n"])
        return !engine.scan(data: data, name: "sample", options: options).isEmpty
    }

    // MARK: Expressions

    @Test func andOrAndParentheses() throws {
        let sig = "Test.Logic-1;Engine:51-255,Target:0;0&(1|2);\(h("alpha-marker"));\(h("bravo-marker"));\(h("charlie-marker"))"
        #expect(try detects(sig, binary([(100, "alpha-marker"), (900, "charlie-marker")])))
        #expect(try detects(sig, binary([(100, "alpha-marker"), (900, "bravo-marker")])))
        #expect(try !detects(sig, binary([(100, "alpha-marker")])))
        #expect(try !detects(sig, binary([(100, "bravo-marker"), (900, "charlie-marker")])))
    }

    @Test func equalPrecedenceSplitsAtTheFirstOperator() throws {
        // ClamAV reads 0&1|2 as 0&(1|2), not (0&1)|2.
        let sig = "Test.Prec-1;Engine:51-255,Target:0;0&1|2;\(h("first-token"));\(h("second-token"));\(h("third-token"))"
        #expect(try !detects(sig, binary([(100, "third-token")])))
        #expect(try detects(sig, binary([(100, "first-token"), (500, "third-token")])))
    }

    @Test func countModifiers() throws {
        func data(_ copies: Int) -> Data { binary((0..<copies).map { (200 + $0 * 100, "repeat-me") }) }
        let base = "Test.Count-1;Engine:51-255,Target:0;"
        let repeated = h("repeat-me")
        #expect(try detects(base + "0>2;\(repeated)", data(3)))
        #expect(try !detects(base + "0>2;\(repeated)", data(2)))
        #expect(try detects(base + "0=2;\(repeated)", data(2)))
        #expect(try !detects(base + "0=2;\(repeated)", data(3)))
        #expect(try detects(base + "0<3&1;\(repeated);\(h("other-one"))", binary([(100, "repeat-me"), (900, "other-one")])))
        #expect(try !detects(base + "0<3&1;\(repeated);\(h("other-one"))", binary([(100, "repeat-me"), (300, "repeat-me"), (500, "repeat-me"), (900, "other-one")])))
        // 1=0: subsignature 1 must not match.
        let negation = base + "0&1=0;\(h("present-one"));\(h("absent-one"))"
        #expect(try detects(negation, binary([(100, "present-one")])))
        #expect(try !detects(negation, binary([(100, "present-one"), (400, "absent-one")])))
    }

    @Test func blockCountsWithDistinctMinimum() throws {
        // (0|1|2)>2,2: more than 2 matches in total, from at least 2 different subsignatures.
        let sig = "Test.Block-1;Engine:51-255,Target:0;(0|1|2)>2,2;\(h("token-aa"));\(h("token-bb"));\(h("token-cc"))"
        #expect(try detects(sig, binary([(100, "token-aa"), (300, "token-aa"), (500, "token-bb")])))
        #expect(try !detects(sig, binary([(100, "token-aa"), (300, "token-aa"), (500, "token-aa"), (700, "token-aa")])))
        #expect(try !detects(sig, binary([(100, "token-aa"), (500, "token-bb")])))
    }

    @Test func expressionsTrueWithoutMatchesAreRejected() throws {
        let (_, summary) = try AVFixtures.compile(["t.ldb": "Test.Always-1;Engine:51-255,Target:0;0=0;\(h("never-there"))\n"])
        #expect(summary.coverage?.files["t.ldb"]?.unsupported == 1)
    }

    @Test func spacesInExpressionsAreTolerated() throws {
        let sig = "Test.Spaces-1;Engine:51-255,Target:0;0 & 1 > 1;\(h("space-a"));\(h("space-b"))"
        #expect(try detects(sig, binary([(100, "space-a"), (300, "space-b"), (600, "space-b")])))
    }

    // MARK: Subsignature offsets and modifiers

    @Test func subsignatureOffsets() throws {
        let sig = "Test.Off-1;Engine:51-255,Target:0;0&1;100:\(h("at-hundred"));EOF-20:\(h("near-the-end"))"
        var data = binary([(100, "at-hundred")])
        data.replaceSubrange((data.count - 20)..<(data.count - 8), with: Array("near-the-end".utf8))
        #expect(try detects(sig, data))
        #expect(try !detects(sig, binary([(101, "at-hundred")])))
    }

    @Test func caseInsensitiveModifier() throws {
        let sig = "Test.Nocase-1;Engine:81-255,Target:0;0;\(h("evilpayload"))::i"
        #expect(try detects(sig, binary([(300, "EvIlPaYlOaD")])))
        #expect(try !detects("Test.Case-1;Engine:81-255,Target:0;0;\(h("evilpayload"))", binary([(300, "EvIlPaYlOaD")])))
    }

    @Test func wideAndAsciiModifiers() throws {
        let wide = Data("s\0e\0c\0r\0e\0t\0s\0".utf8)
        var data = binary([(300, "ascii-secrets")])
        data.replaceSubrange(2000..<(2000 + wide.count), with: wide)
        let wideOnly = "Test.Wide-1;Engine:81-255,Target:0;0;\(h("secrets"))::w"
        let both = "Test.WideAscii-1;Engine:81-255,Target:0;0>1;\(h("secrets"))::wa"
        #expect(try detects(wideOnly, data))
        #expect(try !detects(wideOnly, binary([(300, "ascii-secrets")])))
        #expect(try detects(both, data)) // one ASCII + one wide match
    }

    @Test func fullwordModifier() throws {
        let sig = "Test.Word-1;Engine:81-255,Target:0;0;\(h("token"))::f"
        #expect(try detects(sig, binary([(300, " token ")])))
        #expect(try detects(sig, binary([(300, "(token)")])))
        #expect(try !detects(sig, binary([(300, "tokens ")])))
        #expect(try !detects(sig, binary([(300, " xtoken ")])))
        #expect(try detects("Test.WordNocase-1;Engine:81-255,Target:0;0;\(h("token"))::if", binary([(300, " TOKEN.")])))
    }

    // MARK: PCRE

    @Test func pcreWithTrigger() throws {
        let sig = "Test.Pcre-1;Engine:81-255,Target:0;0&1;\(h("eval("));0/eval\\(base64_decode\\([\\x22\\x27][A-Za-z0-9+\\/=]{8,}/"
        #expect(try detects(sig, binary([(400, "eval(base64_decode('QUJDREVGR0hJSktM')")])))
        #expect(try !detects(sig, binary([(400, "eval(base64_decode('QUJD')")])))
        // The regex only runs when its trigger matched.
        #expect(try !detects("Test.Pcre-2;Engine:81-255,Target:0;0&1;\(h("never-here"));0/payload[0-9]+/", binary([(400, "payload123")])))
    }

    @Test func pcreFlagsAndNamedGroups() throws {
        let caseless = "Test.PcreI-1;Engine:81-255,Target:0;0&1;\(h("marker"));0/hello\\s+world/i"
        #expect(try detects(caseless, binary([(100, "marker"), (400, "HeLLo   WORLD")])))
        // A ";" inside a PCRE must be written \x3B (the line is split at ";").
        let backref = "Test.PcreRef-1;Engine:81-255,Target:0;0&1;\(h("var "));0/var (?P<name_1>[a-z]{3,8})=1\\x3B(?P=name_1)\\+\\+/"
        #expect(try detects(backref, binary([(400, "var abcd=1;abcd++")])))
        #expect(try !detects(backref, binary([(400, "var abcd=1;abce++")])))
        // \w is ASCII-only like PCRE (Latin-1 é is not a word character).
        let word = "Test.PcreW-1;Engine:81-255,Target:0;0&1;\(h("key:"));0/key:\\w{4}/"
        var latin = binary([(400, "key:")])
        latin.replaceSubrange(404..<408, with: [0xE9, 0xE9, 0xE9, 0xE9])
        #expect(try !detects(word, latin))
        #expect(try detects(word, binary([(400, "key:abcd")])))
    }

    @Test func pcreOffsetsAnchorAtTheOffset() throws {
        // With an offset and no "r" flag, the regex must match at the offset.
        let sig = "Test.PcreOff-1;Engine:81-255,Target:0;0&1;\(h("tag"));200:0/tag=[0-9]+/"
        #expect(try detects(sig, binary([(200, "tag=42")])))
        #expect(try !detects(sig, binary([(300, "tag=42")])))
        let rolling = "Test.PcreRoll-1;Engine:81-255,Target:0;0&1;\(h("tag"));200:0/tag=[0-9]+/r"
        #expect(try detects(rolling, binary([(300, "tag=42")])))
    }

    @Test func pcreTranslation() throws {
        #expect(try AVRegexTranslator.translate("(?P<a_b>x)(?P=a_b)", ungreedy: false) == "(?<g0ab>x)\\k<g0ab>")
        #expect(try AVRegexTranslator.translate("a+b*?c{2,3}", ungreedy: true) == "a+?b*c{2,3}?")
        #expect(try AVRegexTranslator.translate("[\\w-]", ungreedy: false) == "[A-Za-z0-9_-]")
        #expect(try AVRegexTranslator.translate("x{y}", ungreedy: false) == "x\\{y\\}")
        #expect(throws: AVSignatureRejection.self) { _ = try AVRegexTranslator.translate("a\\Kb", ungreedy: false) }
        // Required literals let the scanner skip a regex when its fixed text isn't there.
        func literal(_ pattern: String) -> String? { AVRegexTranslator.requiredLiteral(pattern, extended: false).map { String(decoding: $0, as: UTF8.self) } }
        #expect(literal("<script.+var.{0,50}function\\(\\).{0,50}Symbol\\.species\\]\\(\\)") == "Symbol.species]()")
        #expect(literal("abc|defgh") == nil)
        #expect(literal("ab(cdefgh)ij") == nil)
        #expect(literal("hello?world") == "world")
        #expect(literal("x\\x3Bfooo") == "x;fooo")
        #expect(literal("a{0,3}bcde") == "bcde")
        #expect(literal("[abc]defg+") == "defg")
        #expect(literal("{\"config\":1,\"id\":\"[A-Z]{16}\"") == "{\"config\":1,\"id\":\"")
        #expect(literal("{{{{") == "{{{{") // braces that aren't quantifiers terminate
        #expect(throws: AVSignatureRejection.self) { _ = try AVRegexTranslator.translate("(?R)", ungreedy: false) }
    }

    // MARK: Byte compare

    @Test func byteCompare() throws {
        // Subsignature 0 is "LEN=" followed by a 2-byte length; match when > 512.
        let little = "Test.Bcmp-1;Engine:101-255,Target:0;0&1;\(h("LEN="));0(>>4#il2#>512)"
        let bigEndian = "Test.Bcmp-2;Engine:101-255,Target:0;0&1;\(h("LEN="));0(>>4#ib2#>512)"
        var data = binary([(500, "LEN=")])
        data[504] = 0x00; data[505] = 0x04 // little-endian 1024, big-endian 4
        #expect(try detects(little, data))
        #expect(try !detects(bigEndian, data))
        data[504] = 0x10; data[505] = 0x00 // little-endian 16, big-endian 4096
        #expect(try !detects(little, data))
        #expect(try detects(bigEndian, data))
        let decimal = "Test.BcmpDec-1;Engine:101-255,Target:0;0&1;\(h("size: "));0(>>6#de3#=123)"
        #expect(try detects(decimal, binary([(500, "size: 123")])))
        #expect(try !detects(decimal, binary([(500, "size: 124")])))
    }

    // MARK: Target description block

    @Test func fileSizeConstraint() throws {
        let sig = "Test.Size-1;Engine:51-255,FileSize:1000-5000,Target:0;0;\(h("sized-marker"))"
        #expect(try detects(sig, binary([(100, "sized-marker")], size: 4000)))
        #expect(try !detects(sig, binary([(100, "sized-marker")], size: 6000)))
    }

    @Test func containerConstraint() throws {
        // Compressible filler, so the marker isn't stored verbatim in the ZIP's own bytes.
        let marker = Data("inner-zip-marker".utf8) + Data(repeating: 0x41, count: 2000)
        let zip = AVFixtures.zip([.init(name: "a.bin", data: marker)])
        let zipOnly = "Test.InZip-1;Engine:51-255,Container:CL_TYPE_ZIP,Target:0;0;\(h("inner-zip-marker"))"
        let rootOnly = "Test.Root-1;Engine:51-255,Container:CL_TYPE_ANY,Target:0;0;\(h("inner-zip-marker"))"
        #expect(try detects(zipOnly, zip))
        #expect(try !detects(zipOnly, marker))
        #expect(try detects(rootOnly, marker))
        #expect(try !detects(rootOnly, zip))
        // Containers this engine never extracts make the signature unsupported.
        let (_, summary) = try AVFixtures.compile(["t.ldb": "Test.Ole-1;Engine:51-255,Container:CL_TYPE_MSOLE2,Target:0;0;\(h("abcdefgh"))\n"])
        #expect(summary.coverage?.files["t.ldb"]?.reasons.keys.contains { $0.contains("CL_TYPE_MSOLE2") } == true)
    }

    @Test func intermediatesConstraint() throws {
        let marker = Data("deep-member-marker".utf8) + AVFixtures.filler(100)
        let inner = AVFixtures.zip([.init(name: "x.bin", data: marker)])
        let outer = AVFixtures.gzip(inner, name: "inner.zip")
        let sig = "Test.Chain-1;Engine:90-255,Intermediates:CL_TYPE_GZ>CL_TYPE_ZIP,Target:0;0;\(h("deep-member-marker"))"
        #expect(try detects(sig, outer))
        #expect(try !detects(sig, inner))
    }

    @Test func entryPointAndSectionCountConstraints() throws {
        let pe = AVFixtures.pe(sections: [(".text", Data("pe-code-marker".utf8) + Data(count: 100)), (".rdata", Data(count: 64))])
        let ok = "Win.Test.Ep-1;Engine:51-255,EntryPoint:1000-1100,NumberOfSections:2-3,Target:1;0;\(h("pe-code-marker"))"
        let wrongCount = "Win.Test.Ep-2;Engine:51-255,NumberOfSections:3-5,Target:1;0;\(h("pe-code-marker"))"
        #expect(try detects(ok, pe))
        #expect(try !detects(wrongCount, pe))
    }

    @Test func unsupportedFeaturesAreCountedNotLoaded() throws {
        let (_, summary) = try AVFixtures.compile(["t.ldb": """
            Test.Icon-1;Engine:51-255,IconGroup1:FAKE,Target:1;0;41424344454647
            Test.Macro-1;Engine:51-255,Target:0;0&1;41424344454647;${6-7}12$
            Test.Fuzzy-1;Engine:150-255,Target:0;0;fuzzy_img#af2ad01ed42993c7#0
            Test.Handler-1;Engine:51-255,HandlerType:CL_TYPE_PDF,Target:0;0;41424344454647
            Test.Good-1;Engine:51-255,Target:0;0;41424344454647
            """])
        let coverage = try #require(summary.coverage?.files["t.ldb"])
        #expect(coverage.loaded == 1)
        #expect(coverage.unsupported == 4)
        #expect(summary.logicalSignatureCount == 1)
    }

    @Test func manyAliveSignaturesUseTheDatabaseDeferredTable() throws {
        // 200 signatures share a rare trigger; each has 3 deferred subsignatures (600 > the
        // per-buffer limit), so the database's deferred table is used. Only signature 7 completes.
        var lines = [String]()
        for index in 0..<200 {
            let parts = ["shared#trigger!zq", "part-a-\(index)-x", "part-b-\(index)-y", "part-c-\(index)-z"]
            lines.append("Test.Many-\(index);Engine:51-255,Target:0;0&1&2&3;" + parts.map(h).joined(separator: ";"))
        }
        let engine = try AVFixtures.engine(["t.ldb": lines.joined(separator: "\n") + "\n"])
        let data = binary([(100, "shared#trigger!zq"), (400, "part-a-7-x"), (900, "part-b-7-y"), (1500, "part-c-7-z"), (2500, "part-a-8-x")])
        #expect(engine.names(data) == ["Test.Many-7"])
    }

    @Test func deferredSubsignaturesAreFoundAfterATrigger() throws {
        // Five subsignatures: only the rarest is in the main pass, the rest are searched once it matched.
        let parts = ["zq8!trigger#rare", "common-a", "common-b", "common-c", "common-d"]
        let sig = "Test.Deferred-1;Engine:51-255,Target:0;0&1&2&3&4;" + parts.map(h).joined(separator: ";")
        let all = binary([(100, parts[1]), (400, parts[2]), (800, parts[0]), (1500, parts[3]), (3000, parts[4])])
        #expect(try detects(sig, all))
        #expect(try !detects(sig, binary([(100, parts[1]), (400, parts[2]), (800, parts[0]), (1500, parts[3])])))
    }

    /// A deferred subsignature without a 4-byte anchor (3 case-insensitive letters) is found by
    /// the shared 2-byte-keyed pass, in any letter case.
    @Test func shortCaseInsensitiveDeferredSubsignature() throws {
        let sig = "Test.ShortDeferred-1;Engine:51-255,Target:0;0&1;\(h("zq8!trigger#rare"));\(h("pxa"))::i"
        for form in ["pxa", "PXA", "pXa"] {
            #expect(try detects(sig, binary([(100, "zq8!trigger#rare"), (6000, form)])), "\(form)")
        }
        #expect(try !detects(sig, binary([(100, "zq8!trigger#rare"), (6000, "pxb")])))
        #expect(try !detects(sig, binary([(6000, "pxa")])))
    }

    /// A signature restricted to a container is ruled out by its first hit elsewhere, and still
    /// matches inside that container however often its trigger occurs.
    @Test func containerRuleWithRepeatedTrigger() throws {
        let sig = "Test.ZipOnly-2;Engine:51-255,Container:CL_TYPE_ZIP,Target:0;0&1;\(h("torch"));\(h("zq8-second-part"))"
        var parts = [(Int, String)]()
        for offset in stride(from: 100, to: 7000, by: 64) { parts.append((offset, "torch")) }
        parts.append((7500, "zq8-second-part"))
        let member = binary(parts)
        #expect(try !detects(sig, member))
        let zip = AVFixtures.zip([AVFixtures.ZipMember(name: "model/data.pkl", data: member, deflate: false)])
        #expect(try detects(sig, zip))
    }
}
