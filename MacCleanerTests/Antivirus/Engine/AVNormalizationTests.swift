import Foundation
import Testing
@testable import MacCleaner

/// File typing and the normalization behind target types 7 (text) and 3 (HTML).
struct AVNormalizationTests {
    private func text(_ buffer: AVScratchBuffer?) -> String {
        buffer.map { String(decoding: $0.view.buffer, as: UTF8.self) } ?? "<nil>"
    }

    @Test func textNormalization() {
        let input = Data("Hello\t\tWORLD\r\n  x\0y".utf8)
        let normalized = input.withUnsafeBytes { AVTextNormalizer.normalizeText(AVByteView($0)) }
        #expect(text(normalized) == "hello world xy")
    }

    @Test func htmlNormalization() {
        let page = Data("<HTML><!-- hidden --><BODY  BGCOLOR = \"#FFF\" >Hello&#33;  <b>World</b></BODY></HTML>".utf8)
        let result = page.withUnsafeBytes { AVTextNormalizer.normalizeHTML(AVByteView($0)) }
        #expect(text(result?.withTags) == "<html><body bgcolor=\"#fff\">hello! <b>world</b></body></html>")
        #expect(text(result?.textOnly) == "hello! world ")
    }

    @Test func fileTypes() {
        func kind(_ bytes: [UInt8]) -> AVFileKind { Data(bytes).withUnsafeBytes { AVFileTyper.detect(AVByteView($0)) } }
        func kind(_ text: String) -> AVFileKind { kind(Array(text.utf8)) }
        #expect(kind("#!/bin/sh\necho hello\n") == .text)
        #expect(kind("<!DOCTYPE html>\n<html>\n<body>hi</body></html>") == .html)
        #expect(kind("var a = 1; // see <a href=\"x\">docs</a>") == .html) // ClamAV's "<a ...href" marker
        #expect(kind("From someone@example.com Mon Jan 1\nSubject: hi\n") == .mail)
        #expect(kind("%PDF-1.7\n") == .pdf)
        #expect(kind([0x4D, 0x5A, 0x90, 0]) == .pe)
        #expect(kind([0x7F, 0x45, 0x4C, 0x46, 2, 1]) == .elf)
        #expect(kind([0xCF, 0xFA, 0xED, 0xFE, 0, 0]) == .machO)
        #expect(kind([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 0x34]) == .javaClass)
        #expect(kind([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]) == .graphics)
        #expect(kind([0x1F, 0x8B, 8, 0]) == .gzip)
        #expect(kind([0x50, 0x4B, 3, 4]) == .zip)
        #expect(kind([0, 1, 2, 3, 0xFF, 0xFE, 0x80]) == .binary)
        #expect(kind("caf\u{E9} cr\u{E8}me") == .text) // UTF-8
    }

    @Test func textSignaturesMatchNormalizedText() throws {
        let engine = try AVFixtures.engine(["t.ndb": """
            Txt.Test.Norm-1:7:*:\(AVFixtures.hex("eval(base64_decode('"))
            Txt.Test.Space-1:7:*:\(AVFixtures.hex("curl -s http"))
            Txt.Test.Raw-1:0:*:\(AVFixtures.hex("CURL"))
            """])
        let script = Data("#!/bin/sh\nEVAL(Base64_Decode('aGVsbG8=')) \nCURL \t -s   HTTP://example\n".utf8)
        #expect(Set(engine.names(script)) == ["Txt.Test.Norm-1", "Txt.Test.Space-1", "Txt.Test.Raw-1"])
        // Target 7 signatures don't apply to binary files.
        let binary = Data([0, 1, 2, 0xFF]) + Data("EVAL(Base64_Decode('".utf8) + AVFixtures.filler(64)
        #expect(engine.names(binary).isEmpty)
        // UTF-16 text is narrowed before normalization.
        var utf16 = Data([0xFF, 0xFE])
        for unit in "x = eval(base64_decode('abc'))".utf16 { utf16 += withUnsafeBytes(of: unit.littleEndian) { Data($0) } }
        #expect(engine.names(utf16).contains("Txt.Test.Norm-1"))
    }

    @Test func htmlSignaturesMatchNormalizedPages() throws {
        let tagged = AVFixtures.hex("<body bgcolor=\"#fff\">hello!")
        let textOnly = AVFixtures.hex("hello! world")
        let raw = AVFixtures.hex("BGCOLOR = ")
        let engine = try AVFixtures.engine(["t.ndb": "Html.Test.Tagged-1:3:*:\(tagged)\nHtml.Test.TextOnly-1:3:*:\(textOnly)\nHtml.Test.Raw-1:3:*:\(raw)\n"])
        let page = Data("<HTML><!-- hidden --><BODY  BGCOLOR = \"#FFF\" >Hello&#33;  <b>World</b></BODY></HTML>".utf8)
        #expect(Set(engine.names(page)) == ["Html.Test.Tagged-1", "Html.Test.TextOnly-1", "Html.Test.Raw-1"])
        // Target 3 signatures don't apply to plain text.
        #expect(engine.names(Data("hello! world, no markup here".utf8)).isEmpty)
    }
}
