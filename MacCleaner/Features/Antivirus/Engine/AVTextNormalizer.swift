import Foundation

/// Normalization applied before matching target type 7 (ASCII text) and 3 (HTML) signatures.
///
/// ClamAV documents ASCII normalization as "all lowercase" and HTML normalization as "whitespace
/// transformed to spaces, tags/tag attributes normalized, all lowercase". This engine implements:
///
/// * **Text (target 7)**: `A–Z` lowercased; runs of whitespace (TAB, LF, VT, FF, CR, space) become
///   one space; other control characters (0x00–0x08, 0x0E–0x1F) are dropped; everything else is
///   kept. That is how ClamAV's text normalizer behaves (signatures never contain uppercase
///   letters or line breaks, and EICAR inside a PDF stream is matched as `…h+h* `).
/// * **HTML (target 3)**: the raw page, plus two normalized versions like ClamAV's
///   `nocomment.html` and `notags.html`: lowercase, comments removed, whitespace runs collapsed,
///   whitespace around `=` and before `>` inside tags removed, numeric character references
///   (`&#65;`, `&#x41;`) decoded; the second version also drops the tags.
///   Deviations from ClamAV: named entities (`&amp;`, `&nbsp;`...) are kept as written (ClamAV
///   keeps `&nbsp;` too), tag attributes aren't re-quoted, and scripts don't go through ClamAV's
///   JavaScript normalizer, so signatures written against normalized JavaScript (renamed
///   variables, decoded strings) may not match.
enum AVTextNormalizer {
    /// UTF-16 text is first narrowed to bytes (characters above U+00FF become `?`).
    static func narrowUTF16(_ data: AVByteView, bigEndian: Bool) -> AVScratchBuffer? {
        guard let out = AVScratchBuffer(capacity: data.count / 2 + 1) else { return nil }
        var index = 2
        while index + 1 < data.count {
            let unit = bigEndian ? UInt16(data[index]) << 8 | UInt16(data[index + 1]) : UInt16(data[index + 1]) << 8 | UInt16(data[index])
            out.append(unit < 0x100 ? UInt8(unit) : 0x3F)
            index += 2
        }
        return out
    }

    static func normalizeText(_ data: AVByteView) -> AVScratchBuffer? {
        guard let out = AVScratchBuffer(capacity: data.count + 1) else { return nil }
        guard let input = data.base, data.count > 0 else { return out }
        let output = out.base.assumingMemoryBound(to: UInt8.self)
        var written = 0
        var spaceWritten = false
        textMap.withUnsafeBufferPointer { map in
            let bytes = input.assumingMemoryBound(to: UInt8.self)
            for index in 0..<data.count {
                let mapped = map[Int(bytes[index])]
                if mapped == 0x20 {
                    if !spaceWritten { output[written] = 0x20; written &+= 1; spaceWritten = true }
                } else if mapped != 0 {
                    output[written] = mapped
                    written &+= 1
                    spaceWritten = false
                }
            }
        }
        out.setCount(written)
        return out
    }

    /// Per input byte: 0 = dropped (control characters), 0x20 = whitespace, else the byte to
    /// write (`A–Z` lowercased).
    private static let textMap: [UInt8] = (0...255).map { value -> UInt8 in
        let c = UInt8(value)
        switch c {
        case 0x09...0x0D, 0x20: return 0x20
        case 0x00...0x08, 0x0E...0x1F: return 0
        case 0x41...0x5A: return c | 0x20
        default: return c
        }
    }

    /// Returns (nocomment, notags) normalized versions of an HTML page.
    static func normalizeHTML(_ data: AVByteView) -> (withTags: AVScratchBuffer, textOnly: AVScratchBuffer)? {
        guard let tagged = AVScratchBuffer(capacity: data.count + 16), let text = AVScratchBuffer(capacity: data.count + 16) else { return nil }
        var taggedSpace = false, textSpace = false
        var inTag = false
        var quote: UInt8 = 0
        var index = 0
        let count = data.count

        func emit(_ c: UInt8, toText: Bool) {
            let isSpace = c == 0x20 || (c >= 0x09 && c <= 0x0D)
            if isSpace {
                if !taggedSpace { tagged.append(0x20); taggedSpace = true }
                if toText, !textSpace { text.append(0x20); textSpace = true }
                return
            }
            let lower = c >= 0x41 && c <= 0x5A ? c | 0x20 : c
            if inTag, quote == 0, (lower == 0x3D || lower == 0x3E), taggedSpace, tagged.last == 0x20 {
                tagged.removeLast() // "a = b" → "a=b", "<br >" → "<br>"
            }
            tagged.append(lower)
            taggedSpace = false
            if toText {
                text.append(lower)
                textSpace = false
            }
        }

        while index < count {
            let c = data[index]
            if !inTag {
                if c == 0x3C, data.matches([0x3C, 0x21, 0x2D, 0x2D], at: index) { // <!-- comment -->
                    var end = index + 4
                    while end < count, !data.matches([0x2D, 0x2D, 0x3E], at: end) { end += 1 }
                    index = min(count, end + 3)
                    continue
                }
                if c == 0x3C, let next = data.u8(index + 1), isTagStart(next) {
                    inTag = true
                    emit(c, toText: false)
                    index += 1
                    // "< a" isn't a tag in browsers, so only skip whitespace after "<" for "</".
                    continue
                }
                if c == 0x26, let (decoded, length) = numericReference(data, index) { // &#NN; &#xHH;
                    emit(decoded, toText: true)
                    index += length
                    continue
                }
                emit(c, toText: true)
                index += 1
            } else {
                if quote != 0 {
                    if c == quote { quote = 0 }
                    emit(c, toText: false)
                } else if c == 0x22 || c == 0x27 {
                    quote = c
                    emit(c, toText: false)
                } else if c == 0x3E {
                    emit(c, toText: false)
                    inTag = false
                    if !textSpace, !text.isEmpty { text.append(0x20); textSpace = true }
                } else if c == 0x26, let (decoded, length) = numericReference(data, index) {
                    emit(decoded, toText: false)
                    index += length
                    continue
                } else {
                    let isSpace = c == 0x20 || (c >= 0x09 && c <= 0x0D)
                    // Drop whitespace right after "=" inside a tag.
                    if isSpace, tagged.last == 0x3D { index += 1; continue }
                    emit(c, toText: false)
                }
                index += 1
            }
        }
        return (tagged, text)
    }

    private static func isTagStart(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2F || c == 0x21 || c == 0x3F
    }

    /// `&#65;` or `&#x41;` → the byte (values above 255 are left undecoded).
    private static func numericReference(_ data: AVByteView, _ index: Int) -> (UInt8, Int)? {
        guard data.u8(index + 1) == 0x23 else { return nil }
        var cursor = index + 2
        var hex = false
        if let x = data.u8(cursor), x == 0x78 || x == 0x58 { hex = true; cursor += 1 }
        var value = 0
        let start = cursor
        while cursor < data.count, cursor - start < 8 {
            let c = data[cursor]
            if hex, let digit = AVHex.nibble(c) {
                value = value * 16 + Int(digit)
            } else if !hex, c >= 0x30, c <= 0x39 {
                value = value * 10 + Int(c - 0x30)
            } else {
                break
            }
            cursor += 1
        }
        guard cursor > start, value < 256 else { return nil }
        if data.u8(cursor) == 0x3B { cursor += 1 }
        return (UInt8(value), cursor - index)
    }
}
