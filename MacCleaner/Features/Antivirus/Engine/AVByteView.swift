import Darwin
import Foundation

/// A read-only, bounds-checked view of bytes that came from outside the app (a scanned file,
/// an archive member, a downloaded database).
///
/// Every accessor returns `nil` (or `false`) instead of trapping when an offset or length
/// falls outside the buffer, so malformed input can never crash the engine. The view does
/// not own its memory: callers keep the underlying storage alive while they use it.
struct AVByteView {
    let base: UnsafeRawPointer?
    let count: Int

    init(_ buffer: UnsafeRawBufferPointer) {
        base = buffer.baseAddress
        count = buffer.baseAddress == nil ? 0 : buffer.count
    }

    init(base: UnsafeRawPointer?, count: Int) {
        self.base = base
        self.count = base == nil ? 0 : max(0, count)
    }

    static var empty: AVByteView { AVByteView(base: nil, count: 0) }

    var isEmpty: Bool { count == 0 }

    var buffer: UnsafeRawBufferPointer { UnsafeRawBufferPointer(start: base, count: count) }

    /// `true` when `[offset, offset + length)` lies inside the view (overflow-safe).
    @inline(__always)
    func contains(offset: Int, length: Int) -> Bool {
        offset >= 0 && length >= 0 && offset <= count && length <= count - offset
    }

    /// A sub-view, or nil when the range is out of bounds.
    func slice(_ offset: Int, _ length: Int) -> AVByteView? {
        guard contains(offset: offset, length: length), let base else {
            return length == 0 && offset == count ? AVByteView.empty : nil
        }
        return AVByteView(base: base + offset, count: length)
    }

    /// The bytes from `offset` to the end, or nil when out of bounds.
    func suffix(from offset: Int) -> AVByteView? {
        guard offset >= 0, offset <= count else { return nil }
        return slice(offset, count - offset)
    }

    @inline(__always)
    subscript(offset: Int) -> UInt8 {
        // Callers that use the subscript have already checked the range.
        base.unsafelyUnwrapped.load(fromByteOffset: offset, as: UInt8.self)
    }

    @inline(__always)
    func u8(_ offset: Int) -> UInt8? {
        guard offset >= 0, offset < count, let base else { return nil }
        return base.load(fromByteOffset: offset, as: UInt8.self)
    }

    func u16le(_ offset: Int) -> UInt16? {
        guard contains(offset: offset, length: 2), let base else { return nil }
        return UInt16(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    func u32le(_ offset: Int) -> UInt32? {
        guard contains(offset: offset, length: 4), let base else { return nil }
        return UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    func u64le(_ offset: Int) -> UInt64? {
        guard contains(offset: offset, length: 8), let base else { return nil }
        return UInt64(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }

    func u16be(_ offset: Int) -> UInt16? {
        guard contains(offset: offset, length: 2), let base else { return nil }
        return UInt16(bigEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    func u32be(_ offset: Int) -> UInt32? {
        guard contains(offset: offset, length: 4), let base else { return nil }
        return UInt32(bigEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    func u64be(_ offset: Int) -> UInt64? {
        guard contains(offset: offset, length: 8), let base else { return nil }
        return UInt64(bigEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }

    func u32(_ offset: Int, bigEndian: Bool) -> UInt32? {
        bigEndian ? u32be(offset) : u32le(offset)
    }

    func u64(_ offset: Int, bigEndian: Bool) -> UInt64? {
        bigEndian ? u64be(offset) : u64le(offset)
    }

    func u16(_ offset: Int, bigEndian: Bool) -> UInt16? {
        bigEndian ? u16be(offset) : u16le(offset)
    }

    /// `true` when the bytes at `offset` equal `bytes`.
    func matches(_ bytes: [UInt8], at offset: Int) -> Bool {
        guard contains(offset: offset, length: bytes.count), let base else { return bytes.isEmpty }
        return bytes.withUnsafeBytes { other in
            guard let otherBase = other.baseAddress else { return true }
            return memcmp(base + offset, otherBase, bytes.count) == 0
        }
    }

    /// Copies a range into an array (empty when out of bounds).
    func bytes(_ offset: Int, _ length: Int) -> [UInt8] {
        guard let view = slice(offset, length), let base = view.base else { return [] }
        return Array(UnsafeRawBufferPointer(start: base, count: view.count))
    }

    /// The bytes as Latin-1 text, stopping at the first NUL (for fixed-size header fields).
    func cString(_ offset: Int, maxLength: Int) -> String {
        guard let view = slice(offset, min(maxLength, max(0, count - offset))) else { return "" }
        var end = 0
        while end < view.count, view[end] != 0 { end += 1 }
        return String(decoding: UnsafeRawBufferPointer(start: view.base, count: end), as: UTF8.self)
    }

    /// Position of the first occurrence of `needle` at or after `from`, searching up to `limit`.
    func firstIndex(of needle: [UInt8], from: Int = 0, limit: Int? = nil) -> Int? {
        let end = min(limit ?? count, count)
        guard !needle.isEmpty, from >= 0, end - from >= needle.count, let base else { return nil }
        return needle.withUnsafeBytes { n -> Int? in
            guard let nBase = n.baseAddress else { return nil }
            guard let found = memmem(base + from, end - from, nBase, needle.count) else { return nil }
            return UnsafeRawPointer(found) - base
        }
    }

    /// Position of the last occurrence of `needle` that starts at or after `lowerBound`.
    func lastIndex(of needle: [UInt8], lowerBound: Int = 0) -> Int? {
        guard !needle.isEmpty, count >= needle.count else { return nil }
        var index = count - needle.count
        let first = needle[0]
        while index >= max(0, lowerBound) {
            if self[index] == first, matches(needle, at: index) { return index }
            index -= 1
        }
        return nil
    }
}

/// Hex encoding and decoding helpers.
enum AVHex {
    private static let digits: [UInt8] = Array("0123456789abcdef".utf8)

    static func string(_ bytes: some Sequence<UInt8>) -> String {
        var out = [UInt8]()
        out.reserveCapacity(64)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Value of one ASCII hex digit, or nil.
    @inline(__always)
    static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x61...0x66: return c - 0x61 + 10
        case 0x41...0x46: return c - 0x41 + 10
        default: return nil
        }
    }

    /// Decodes an even-length hex string (either case). Returns nil on any invalid character.
    static func decode<C: Collection>(_ text: C) -> [UInt8]? where C.Element == UInt8 {
        guard text.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(text.count / 2)
        var iterator = text.makeIterator()
        while let high = iterator.next() {
            guard let low = iterator.next(), let h = nibble(high), let l = nibble(low) else { return nil }
            out.append(h << 4 | l)
        }
        return out
    }

    static func decode(_ text: String) -> [UInt8]? {
        decode(Array(text.utf8))
    }
}

/// Substring search tuned for the needles signatures produce. libc's memmem is fast for long
/// needles but scans byte by byte for 2–4-byte ones; for those, memchr (vectorized) looks for
/// the needle's rarest byte and the rest is compared around each hit.
enum AVFind {
    /// The first occurrence of `needle` (length > 0) starting in `[from, end - needle.count]`.
    static func first(_ needle: UnsafeRawPointer, _ length: Int, in base: UnsafeRawPointer, from: Int, end: Int) -> Int? {
        guard length > 0, end - from >= length else { return nil }
        if length >= 5 {
            guard let found = memmem(base + from, end - from, needle, length) else { return nil }
            return UnsafeRawPointer(found) - base
        }
        // Pick the rarest byte of the needle.
        var pivot = 0
        var pivotScore = -1
        for k in 0..<length {
            let score = Int(AVByteRarity.score[Int(needle.load(fromByteOffset: k, as: UInt8.self))])
            if score > pivotScore { pivotScore = score; pivot = k }
        }
        let pivotByte = Int32(needle.load(fromByteOffset: pivot, as: UInt8.self))
        var position = from + pivot
        let lastPivot = end - length + pivot
        while position <= lastPivot {
            guard let hit = memchr(base + position, pivotByte, lastPivot - position + 1) else { return nil }
            let at = UnsafeRawPointer(hit) - base
            let start = at - pivot
            if memcmp(base + start, needle, length) == 0 { return start }
            position = at + 1
        }
        return nil
    }
}

/// A growable byte buffer for large, short-lived data (file contents, decompressed members,
/// normalized text). Large buffers are anonymous mappings that reserve `capacity` bytes of
/// address space (pages are only committed when written) and are unmapped when released, so big
/// scans don't leave freed memory cached in malloc's large-allocation pool; small ones (most
/// files) come from malloc, which is cheaper than a mapping per buffer.
final class AVScratchBuffer {
    let base: UnsafeMutableRawPointer
    let capacity: Int
    private(set) var count = 0
    private let mapped: Bool

    /// Buffers up to this size come from malloc.
    static let heapLimit = 256 * 1024

    init?(capacity: Int) {
        let size = max(capacity, 1)
        if size <= Self.heapLimit {
            guard let address = malloc(size) else { return nil }
            base = address
            mapped = false
        } else {
            guard let address = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), address != MAP_FAILED else { return nil }
            base = address
            mapped = true
        }
        self.capacity = size
    }

    deinit {
        if mapped { munmap(base, capacity) } else { free(base) }
    }

    var view: AVByteView { AVByteView(base: UnsafeRawPointer(base), count: count) }

    @inline(__always)
    func append(_ byte: UInt8) {
        guard count < capacity else { return }
        base.storeBytes(of: byte, toByteOffset: count, as: UInt8.self)
        count += 1
    }

    var isEmpty: Bool { count == 0 }

    /// The last byte written, if any.
    var last: UInt8? { count > 0 ? base.load(fromByteOffset: count - 1, as: UInt8.self) : nil }

    func removeLast() { if count > 0 { count -= 1 } }

    /// Sets the number of valid bytes after writing directly through `base`.
    func setCount(_ newCount: Int) { count = min(max(0, newCount), capacity) }

    /// Wraps the buffer in `Data` without copying; the mapping lives as long as the Data.
    func data() -> Data {
        guard count > 0 else { return Data() }
        return Data(bytesNoCopy: base, count: count, deallocator: .custom { [self] _, _ in _ = self })
    }
}
