import Foundation

/// File types the engine distinguishes, with the ClamAV target type their signatures use.
enum AVFileKind: UInt8, Sendable {
    case binary, pe, elf, machO, machOUniversal, ole2, html, mail, graphics, text, pdf, swf, javaClass
    case zip, gzip, posixTar, oldTar, crx, rtf

    /// ClamAV target type (0 = only "any file" signatures).
    var target: Int {
        switch self {
        case .pe: return 1
        case .ole2: return 2
        case .html: return 3
        case .mail: return 4
        case .graphics: return 5
        case .elf: return 6
        case .text: return 7
        case .machO, .machOUniversal: return 9
        case .pdf: return 10
        case .swf: return 11
        case .javaClass: return 12
        default: return 0
        }
    }

    var isExecutable: Bool { self == .pe || self == .elf || self == .machO }
}

/// Detects file types from content, following ClamAV's file type magic (`daily.ftm`): a fixed
/// magic at the start, else a text check of the first 1 KiB, then HTML and mail markers in it.
enum AVFileTyper {
    /// ClamAV looks at this much of the file to decide its type.
    static let magicWindow = 1024

    static func detect(_ data: AVByteView) -> AVFileKind {
        guard data.count >= 2 else { return data.count == 0 ? .binary : classifyText(data) }
        if let kind = magic(data) { return kind }
        let window = data.slice(0, min(data.count, magicWindow)) ?? data
        let isText = textKind(window) != nil
        // HTML and mail markers are looked for in text and in unrecognized binary data.
        if containsHTMLMarker(window) { return .html }
        if looksLikeMail(data) { return .mail }
        return isText ? .text : .binary
    }

    private static func classifyText(_ data: AVByteView) -> AVFileKind {
        textKind(data) != nil ? .text : .binary
    }

    // MARK: Magic numbers

    private static let mailPrefixes: [[UInt8]] = [
        "From ", ">From ", "Date: ", "Delivered-To: ", "Delivery-date: ", "Envelope-to: ", "For: ", "From: ",
        "Hi. This is the qmail-send", "Message-ID: ", "Message-Id: ", "Received: ", "Return-Path: ", "Return-path: ",
        "Subject: ", "To: ", "X-Apparently-To: ", "X-EVS", "X-Envelope-From: ", "X-Original-To: ", "X-Real-To: ",
        "X-Sieve: ", "X-Symantec-", "X-UIDL: ", "v:\nReceived: ", "v:\r\nReceived: ", "Received-SPF: ",
    ].map { Array($0.utf8) }

    private static func magic(_ d: AVByteView) -> AVFileKind? {
        guard let b0 = d.u8(0), let b1 = d.u8(1) else { return nil }
        switch (b0, b1) {
        case (0x4D, 0x5A): return .pe // "MZ": ClamAV types every MZ file as an executable
        case (0x1F, 0x8B): return .gzip
        default: break
        }
        if let word = d.u32be(0) {
            switch word {
            case 0x7F45_4C46: return .elf
            case 0xFEED_FACE, 0xFEED_FACF, 0xCEFA_EDFE, 0xCFFA_EDFE: return .machO
            case 0xCAFE_BABE, 0xCAFE_BABF:
                if AVFatMachOReader.slices(d) != nil { return .machOUniversal }
                if let major = d.u16be(6), d.u16be(4) == 0, major >= 45 { return .javaClass }
                return .binary
            case 0xD0CF_11E0 where d.u32be(4) == 0xA1B1_1AE1: return .ole2
            case 0x504B_0304, 0x504B_0506: return .zip
            case 0x4372_3234: return .crx // "Cr24"
            case 0x8950_4E47: return .graphics // PNG
            case 0x4949_2A00: return .graphics // TIFF little-endian
            case 0x0000_000C where d.matches([0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A], at: 4): return .graphics // JPEG 2000
            default: break
            }
        }
        if d.matches(Magic.spannedZip, at: 0) { return .zip }
        if d.matches(Magic.pdf, at: 0) { return .pdf }
        for prefix in Magic.swf where d.matches(prefix, at: 0) { return .swf }
        for prefix in Magic.graphics where d.matches(prefix, at: 0) { return .graphics }
        if d.matches(Magic.rtf, at: 0) { return .rtf }
        if d.matches(Magic.ustar, at: 257) { return .posixTar }
        if d.count >= 512, AVTarReader.looksLikeTar(d) { return .oldTar }
        for prefix in mailPrefixes where d.matches(prefix, at: 0) { return .mail }
        if d.matches(Magic.asp, at: 0) { return .html }
        return nil
    }

    /// Magic byte strings, built once (this runs for every scanned object).
    private enum Magic {
        static let spannedZip = Array("PK00PK".utf8) + [3, 4]
        static let pdf = Array("%PDF-".utf8)
        static let swf = ["FWS", "CWS", "ZWS"].map { Array($0.utf8) }
        static let graphics: [[UInt8]] = [Array("GIF".utf8), [0xFF, 0xD8, 0xFF], Array("BM".utf8), Array("MM".utf8)]
        static let rtf = Array("{\\rt".utf8)
        static let ustar = Array("ustar".utf8)
        static let asp = Array("<%@ LANGUAGE =".utf8)
    }

    // MARK: Text

    enum TextKind { case ascii, utf8, utf16LittleEndian, utf16BigEndian }

    /// ClamAV's text check: ASCII when every byte is printable or one of BEL, BS, TAB, LF, FF, CR,
    /// ESC; UTF-8 when it's valid UTF-8 of such characters; UTF-16 with a byte order mark.
    static func textKind(_ data: AVByteView) -> TextKind? {
        if data.matches([0xFF, 0xFE], at: 0) { return .utf16LittleEndian }
        if data.matches([0xFE, 0xFF], at: 0) { return .utf16BigEndian }
        var index = 0
        var sawMultibyte = false
        let count = data.count
        while index < count {
            let c = data[index]
            if c < 0x80 {
                guard isTextByte(c) else { return nil }
                index += 1
                continue
            }
            // UTF-8 sequence; a sequence cut off by the end of the window still counts as text.
            let length: Int
            switch c {
            case 0xC2...0xDF: length = 2
            case 0xE0...0xEF: length = 3
            case 0xF0...0xF4: length = 4
            default: return nil
            }
            for k in 1..<length {
                guard index + k < count else { return sawMultibyte || index > 0 ? .utf8 : nil }
                guard data[index + k] & 0xC0 == 0x80 else { return nil }
            }
            sawMultibyte = true
            index += length
        }
        return sawMultibyte ? .utf8 : .ascii
    }

    @inline(__always)
    static func isTextByte(_ c: UInt8) -> Bool {
        (c >= 0x20 && c < 0x7F) || (c >= 0x07 && c <= 0x0D) || c == 0x1B
    }

    // MARK: HTML and mail markers

    /// Each marker in lowercase, uppercase and capitalized form.
    private static let htmlTagForms = caseForms(["html>", "head>"])
    private static let htmlOpenTagForms = caseForms(["script", "iframe", "img", "object", "table"])

    private static func caseForms(_ words: [String]) -> [[UInt8]] {
        words.flatMap { word in
            [Array(word.utf8), Array(word.uppercased().utf8), Array((word.prefix(1).uppercased() + word.dropFirst()).utf8)]
        }
    }

    /// `>`, whitespace or `/` after an opening tag name.
    @inline(__always)
    private static func isTagDelimiter(_ c: UInt8) -> Bool {
        c == 0x3E || c == 0x20 || c == 0x2F || (c >= 0x09 && c <= 0x0D)
    }

    /// ClamAV's HTML markers (`daily.ftm`): `<html>`, `<head>`, `<script`, `<iframe`, `<img`,
    /// `<object`, `<table` (followed by `>`, whitespace or `/`) and `<a ` … `href`, each written in
    /// lowercase, uppercase or capitalized.
    static func containsHTMLMarker(_ window: AVByteView) -> Bool {
        guard let base = window.base else { return false }
        var position = 0
        while position < window.count, let found = memchr(base + position, 0x3C, window.count - position) {
            let index = UnsafeRawPointer(found) - base
            position = index + 1
            for form in htmlTagForms where window.matches(form, at: index + 1) { return true }
            for form in htmlOpenTagForms where window.matches(form, at: index + 1) {
                if let next = window.u8(index + 1 + form.count), isTagDelimiter(next) { return true }
            }
            if let a = window.u8(index + 1), a == 0x61 || a == 0x41, window.u8(index + 2) == 0x20 {
                if hasHref(window, from: index + 3) { return true }
            }
        }
        return false
    }

    /// `(h|H)(r|R)(EF|ef)` anywhere after `<a `.
    private static func hasHref(_ window: AVByteView, from start: Int) -> Bool {
        var index = start
        while index + 4 <= window.count {
            let h = window[index], r = window[index + 1]
            if (h == 0x68 || h == 0x48) && (r == 0x72 || r == 0x52) {
                let e = window[index + 2], f = window[index + 3]
                if (e == 0x45 && f == 0x46) || (e == 0x65 && f == 0x66) { return true }
            }
            index += 1
        }
        return false
    }

    /// The multi-line mail markers of `daily.ftm` (a `From:`/`Received:`/`MIME-Version:` header line
    /// followed by `Content-Type:` or `MIME-Version:` within the first 2 KiB).
    private static func looksLikeMail(_ data: AVByteView) -> Bool {
        guard let window = data.slice(0, min(data.count, 3072)), let base = window.base,
              memchr(base, 0x3A, window.count) != nil else { return false } // every marker has a colon
        // Every marker starts with a line feed: one pass over the line starts records where each
        // form of each marker first occurs.
        let markers = mailStarters + mailFollowers
        var exact = [Int?](repeating: nil, count: markers.count)
        var lower = [Int?](repeating: nil, count: markers.count)
        var position = 0
        while position < window.count, let found = memchr(base + position, 0x0A, window.count - position) {
            let index = UnsafeRawPointer(found) - base
            position = index + 1
            for (k, marker) in markers.enumerated() {
                if exact[k] == nil, window.matches(marker.exact, at: index) { exact[k] = index }
                if lower[k] == nil, window.matches(marker.lower, at: index) { lower[k] = index }
            }
        }
        func first(_ k: Int) -> Int? { exact[k] ?? lower[k] }
        guard let start = (0..<mailStarters.count).compactMap(first).min(), start <= 1024 else { return false }
        return (mailStarters.count..<markers.count).compactMap(first).contains { $0 > start }
    }

    private static let mailStarters = ["\nFrom: ", "\nMIME-Version: ", "\nReceived: ", "\nMessage-Id: "].map(markerForms)
    private static let mailFollowers = ["\nContent-Type: ", "\nMIME-Version: "].map(markerForms)

    private static func markerForms(_ text: String) -> (exact: [UInt8], lower: [UInt8]) {
        (Array(text.utf8), Array(text.lowercased().utf8))
    }
}
