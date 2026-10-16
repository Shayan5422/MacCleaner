import Foundation

// Readers for the containers the engine looks inside: tar, ZIP (and everything built on it:
// .jar, .apk, .docx, .xpi, .crx), gzip and universal Mach-O binaries. All of them work on
// bytes already in memory, never write anything to disk, and bounds-check every length and
// offset read from the input.

/// One file inside a tar archive.
struct AVTarEntry: Sendable, Hashable {
    var name: String
    /// Offset of the file's data in the archive.
    var dataOffset: Int
    var size: Int
}

/// POSIX/GNU tar (also the old v7 layout ClamAV uses inside `.cvd` files: no `ustar` magic and
/// no end-of-archive blocks).
enum AVTarReader {
    static let blockSize = 512

    /// `true` when the first block is a tar header with a valid checksum.
    static func looksLikeTar(_ view: AVByteView) -> Bool {
        guard let header = view.slice(0, blockSize) else { return false }
        if isZeroBlock(header) { return false }
        guard checksumIsValid(header) else { return false }
        // Require a plausible name and size so random data with a lucky checksum isn't a tar.
        return header[0] != 0 && octal(header, 124, 12) != nil
    }

    struct Listing {
        var entries: [AVTarEntry]
        /// A header was damaged or a file extended past the end of the archive.
        var damaged: Bool
        /// Listing stopped at `maxEntries`.
        var hitLimit: Bool
    }

    /// Lists the regular files in `archive`. Stops at the end-of-archive marker, the end of the
    /// data, a damaged header or after `maxEntries` files.
    static func list(_ archive: AVByteView, maxEntries: Int = .max) -> Listing {
        var entries = [AVTarEntry]()
        var offset = 0
        var damaged = false
        var hitLimit = false
        var pendingLongName: String?
        var pendingPaxPath: String?
        var pendingPaxSize: Int?

        while offset < archive.count {
            guard let header = archive.slice(offset, blockSize) else { damaged = true; break }
            if isZeroBlock(header) { break }
            guard checksumIsValid(header), var size = octal(header, 124, 12) else { damaged = true; break }
            if let paxSize = pendingPaxSize { size = paxSize }
            let type = header[156]
            let dataOffset = offset + blockSize
            guard size >= 0, archive.contains(offset: dataOffset, length: 0) else { damaged = true; break }
            let available = archive.count - dataOffset
            // A size past the end means a truncated archive: keep what's there, then stop.
            let next = size > available ? archive.count : dataOffset + (size + blockSize - 1) / blockSize * blockSize

            switch type {
            case UInt8(ascii: "L"): // GNU long name for the next entry
                pendingLongName = archive.slice(dataOffset, min(size, available, 4096)).map { $0.cString(0, maxLength: $0.count) }
            case UInt8(ascii: "x"): // pax extended header for the next entry
                if let data = archive.slice(dataOffset, min(size, available, 65536)) {
                    let (path, paxSize) = parsePax(data)
                    pendingPaxPath = path
                    pendingPaxSize = paxSize
                }
                offset = next
                continue
            case 0, UInt8(ascii: "0"), UInt8(ascii: "7"):
                var name = pendingLongName ?? pendingPaxPath ?? headerName(header)
                if name.isEmpty { name = "file\(entries.count)" }
                if size > available { damaged = true }
                entries.append(AVTarEntry(name: name, dataOffset: dataOffset, size: min(size, available)))
                if entries.count >= maxEntries {
                    hitLimit = true
                    return Listing(entries: entries, damaged: damaged, hitLimit: hitLimit)
                }
            default:
                break // directories, links, devices, global pax headers, GNU sparse...
            }
            if type != UInt8(ascii: "L") { pendingLongName = nil }
            pendingPaxPath = nil
            pendingPaxSize = nil
            guard next > offset else { damaged = true; break }
            offset = next
        }
        return Listing(entries: entries, damaged: damaged, hitLimit: hitLimit)
    }

    private static func isZeroBlock(_ header: AVByteView) -> Bool {
        guard let base = header.base else { return true }
        var index = 0
        while index + 8 <= header.count {
            if base.loadUnaligned(fromByteOffset: index, as: UInt64.self) != 0 { return false }
            index += 8
        }
        return true
    }

    /// The checksum is the sum of the header bytes with the checksum field read as spaces.
    /// Old writers summed signed chars, so both sums are accepted.
    private static func checksumIsValid(_ header: AVByteView) -> Bool {
        guard let stored = octal(header, 148, 8) else { return false }
        var unsigned = 0, signed = 0
        for index in 0..<blockSize {
            let byte = (148..<156).contains(index) ? 0x20 : header[index]
            unsigned += Int(byte)
            signed += Int(Int8(bitPattern: byte))
        }
        return stored == unsigned || stored == signed
    }

    /// Octal number in a fixed field (leading spaces/zeros, ended by NUL or space), or the GNU
    /// base-256 form (high bit of the first byte set).
    static func octal(_ header: AVByteView, _ offset: Int, _ length: Int) -> Int? {
        guard let field = header.slice(offset, length), field.count > 0 else { return nil }
        if field[0] & 0x80 != 0 {
            var value = 0
            for index in 1..<field.count {
                guard value < (Int.max >> 8) else { return nil }
                value = value << 8 | Int(field[index])
            }
            return value
        }
        var value = 0
        var sawDigit = false
        for index in 0..<field.count {
            let c = field[index]
            if c == 0x20 && !sawDigit { continue }
            if c == 0 || c == 0x20 { break }
            guard c >= 0x30, c <= 0x37, value < (Int.max >> 3) else { return nil }
            value = value << 3 | Int(c - 0x30)
            sawDigit = true
        }
        return value
    }

    private static func headerName(_ header: AVByteView) -> String {
        let name = header.cString(0, maxLength: 100)
        // ustar splits long paths into prefix + name.
        if header.matches(Array("ustar".utf8), at: 257) {
            let prefix = header.cString(345, maxLength: 155)
            if !prefix.isEmpty { return prefix + "/" + name }
        }
        return name
    }

    /// Reads `path` and `size` from pax records ("<length> <key>=<value>\n").
    private static func parsePax(_ data: AVByteView) -> (String?, Int?) {
        var path: String?
        var size: Int?
        let text = String(decoding: data.buffer, as: UTF8.self)
        for record in text.split(separator: "\n") {
            guard let space = record.firstIndex(of: " ") else { continue }
            let body = record[record.index(after: space)...]
            guard let equals = body.firstIndex(of: "=") else { continue }
            let key = body[..<equals]
            let value = String(body[body.index(after: equals)...])
            if key == "path" { path = value }
            if key == "size" { size = Int(value) }
        }
        return (path, size)
    }
}

/// One member of a ZIP archive.
struct AVZipEntry: Sendable, Hashable {
    var name: String
    /// 0 stored, 8 deflate; anything else isn't supported.
    var method: UInt16
    var flags: UInt16
    var compressedSize: Int
    var uncompressedSize: Int
    var localHeaderOffset: Int
    var crc32: UInt32

    var isEncrypted: Bool { flags & 0x0001 != 0 }
    var isDirectory: Bool { name.hasSuffix("/") }
}

/// ZIP reader: central directory (with ZIP64), falling back to walking local headers when the
/// central directory is missing or damaged (truncated downloads, self-extractors).
enum AVZipReader {
    static let localSignature: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
    private static let centralSignature: UInt32 = 0x0201_4B50
    private static let endSignature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    private static let zip64EndSignature: UInt32 = 0x0606_4B50

    static func looksLikeZip(_ view: AVByteView) -> Bool {
        view.matches(localSignature, at: 0) || view.matches(endSignature, at: 0)
            || view.matches([0x50, 0x4B, 0x30, 0x30, 0x50, 0x4B, 0x03, 0x04], at: 0)
    }

    struct Listing {
        var entries: [AVZipEntry]
        var damaged: Bool
        var hitLimit: Bool
    }

    /// - Parameter measureLimit: When the central directory is unusable and a member's size is
    ///   only recorded after its data, the member is inflated (into a scratch buffer, output
    ///   discarded) to find where it ends; this caps that work.
    static func list(_ archive: AVByteView, maxEntries: Int, measureLimit: Int = 256 << 20) -> Listing {
        if let listing = listCentralDirectory(archive, maxEntries: maxEntries) { return listing }
        return listLocalHeaders(archive, maxEntries: maxEntries, measureLimit: measureLimit)
    }

    private static func listCentralDirectory(_ archive: AVByteView, maxEntries: Int) -> Listing? {
        // The end record is 22 bytes plus a comment of up to 65535 bytes.
        guard archive.count >= 22,
              let end = archive.lastIndex(of: endSignature, lowerBound: max(0, archive.count - 22 - 65535)),
              var entryCount = archive.u16le(end + 10).map(Int.init),
              var directorySize = archive.u32le(end + 12).map(Int.init),
              var directoryOffset = archive.u32le(end + 16).map(Int.init) else { return nil }

        if entryCount == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF,
           archive.u32le(end - 20) == zip64LocatorSignature,
           let zip64End = archive.u64le(end - 20 + 8).flatMap({ Int(exactly: $0) }),
           archive.u32le(zip64End) == zip64EndSignature,
           let count64 = archive.u64le(zip64End + 32).flatMap({ Int(exactly: $0) }),
           let size64 = archive.u64le(zip64End + 40).flatMap({ Int(exactly: $0) }),
           let offset64 = archive.u64le(zip64End + 48).flatMap({ Int(exactly: $0) }) {
            entryCount = count64
            directorySize = size64
            directoryOffset = offset64
        }

        // Self-extracting archives and archives with data prepended: the stored offsets are
        // relative to the start of the ZIP part, which ends right before the directory.
        var shift = 0
        if !archive.contains(offset: directoryOffset, length: directorySize) || archive.u32le(directoryOffset) != centralSignature {
            let realStart = end - directorySize
            guard realStart >= 0, archive.u32le(realStart) == centralSignature else { return nil }
            shift = realStart - directoryOffset
            directoryOffset = realStart
        }

        var entries = [AVZipEntry]()
        var damaged = false
        var offset = directoryOffset
        let directoryEnd = directoryOffset + directorySize
        var index = 0
        while index < entryCount || (entryCount == 0xFFFF && offset < directoryEnd) {
            guard offset + 46 <= directoryEnd, archive.u32le(offset) == centralSignature,
                  let flags = archive.u16le(offset + 8), let method = archive.u16le(offset + 10),
                  let crc = archive.u32le(offset + 16),
                  let compressed32 = archive.u32le(offset + 20), let uncompressed32 = archive.u32le(offset + 24),
                  let nameLength = archive.u16le(offset + 28).map(Int.init),
                  let extraLength = archive.u16le(offset + 30).map(Int.init),
                  let commentLength = archive.u16le(offset + 32).map(Int.init),
                  let local32 = archive.u32le(offset + 42),
                  let nameView = archive.slice(offset + 46, nameLength) else { damaged = true; break }
            var compressed = Int(compressed32), uncompressed = Int(uncompressed32), local = Int(local32)
            if let extra = archive.slice(offset + 46 + nameLength, extraLength) {
                applyZip64Extra(extra, compressed: &compressed, uncompressed: &uncompressed, local: &local,
                                compressed32: compressed32, uncompressed32: uncompressed32, local32: local32)
            }
            let name = decodeName(nameView, utf8: flags & 0x0800 != 0)
            let (shifted, overflow) = local.addingReportingOverflow(shift)
            entries.append(AVZipEntry(name: name, method: method, flags: flags, compressedSize: compressed,
                                      uncompressedSize: uncompressed, localHeaderOffset: overflow ? -1 : shifted, crc32: crc))
            if entries.count >= maxEntries { return Listing(entries: entries, damaged: damaged, hitLimit: true) }
            offset += 46 + nameLength + extraLength + commentLength
            index += 1
        }
        return Listing(entries: entries, damaged: damaged, hitLimit: false)
    }

    private static func applyZip64Extra(_ extra: AVByteView, compressed: inout Int, uncompressed: inout Int, local: inout Int,
                                        compressed32: UInt32, uncompressed32: UInt32, local32: UInt32) {
        var position = 0
        while position + 4 <= extra.count {
            guard let id = extra.u16le(position), let length = extra.u16le(position + 2).map(Int.init) else { return }
            if id == 0x0001, let field = extra.slice(position + 4, length) {
                var cursor = 0
                if uncompressed32 == 0xFFFF_FFFF, let value = field.u64le(cursor).flatMap({ Int(exactly: $0) }) { uncompressed = value; cursor += 8 }
                if compressed32 == 0xFFFF_FFFF, let value = field.u64le(cursor).flatMap({ Int(exactly: $0) }) { compressed = value; cursor += 8 }
                if local32 == 0xFFFF_FFFF, let value = field.u64le(cursor).flatMap({ Int(exactly: $0) }) { local = value }
                return
            }
            position += 4 + length
        }
    }

    /// Walks `PK\x03\x04` records from the start. Entries that use a data descriptor with an
    /// unknown size are measured by inflating them (deflate) or skipped (stored).
    private static func listLocalHeaders(_ archive: AVByteView, maxEntries: Int, measureLimit: Int) -> Listing {
        var entries = [AVZipEntry]()
        var damaged = false
        guard var offset = archive.firstIndex(of: localSignature, limit: min(archive.count, 1 << 20)) else {
            return Listing(entries: [], damaged: true, hitLimit: false)
        }
        while archive.matches(localSignature, at: offset) {
            guard let flags = archive.u16le(offset + 6), let method = archive.u16le(offset + 8),
                  let crc = archive.u32le(offset + 14),
                  let compressed32 = archive.u32le(offset + 18), let uncompressed32 = archive.u32le(offset + 22),
                  let nameLength = archive.u16le(offset + 26).map(Int.init),
                  let extraLength = archive.u16le(offset + 28).map(Int.init),
                  let nameView = archive.slice(offset + 30, nameLength) else { damaged = true; break }
            var compressed = Int(compressed32), uncompressed = Int(uncompressed32), local = offset
            if let extra = archive.slice(offset + 30 + nameLength, extraLength) {
                applyZip64Extra(extra, compressed: &compressed, uncompressed: &uncompressed, local: &local,
                                compressed32: compressed32, uncompressed32: uncompressed32, local32: 0)
            }
            let dataOffset = offset + 30 + nameLength + extraLength
            guard archive.contains(offset: dataOffset, length: 0) else { damaged = true; break }
            if flags & 0x0008 != 0 && compressed == 0 {
                // Size only in the trailing data descriptor.
                guard method == 8, let data = archive.suffix(from: dataOffset),
                      let measured = AVInflate.measure(data, wrapper: .raw, outputLimit: measureLimit) else { damaged = true; break }
                compressed = measured.consumed
                uncompressed = measured.produced
            }
            let name = decodeName(nameView, utf8: flags & 0x0800 != 0)
            entries.append(AVZipEntry(name: name, method: method, flags: flags, compressedSize: compressed,
                                      uncompressedSize: uncompressed, localHeaderOffset: offset, crc32: crc))
            if entries.count >= maxEntries { return Listing(entries: entries, damaged: damaged, hitLimit: true) }
            guard compressed >= 0, compressed <= archive.count - dataOffset else { damaged = true; break }
            var next = dataOffset + compressed
            guard next > offset else { damaged = true; break }
            if flags & 0x0008 != 0 {
                // Optional signature + crc + sizes (32- or 64-bit).
                if archive.u32le(next) == 0x0807_4B50 { next += 4 }
                next += 12
                if !archive.matches(localSignature, at: next), archive.matches(localSignature, at: next + 8) { next += 8 }
            }
            offset = next
        }
        return Listing(entries: entries, damaged: damaged || entries.isEmpty, hitLimit: false)
    }

    private static func decodeName(_ view: AVByteView, utf8: Bool) -> String {
        // Names that aren't valid UTF-8 (old DOS code pages) are shown with replacement characters.
        String(decoding: view.buffer, as: UTF8.self)
    }

    /// Where an entry's compressed data starts, from its local header.
    static func dataRange(of entry: AVZipEntry, in archive: AVByteView) -> (offset: Int, length: Int)? {
        let offset = entry.localHeaderOffset
        guard archive.matches(localSignature, at: offset),
              let nameLength = archive.u16le(offset + 26).map(Int.init),
              let extraLength = archive.u16le(offset + 28).map(Int.init) else { return nil }
        let dataOffset = offset + 30 + nameLength + extraLength
        guard archive.contains(offset: dataOffset, length: 0) else { return nil }
        let length = min(entry.compressedSize, archive.count - dataOffset)
        return (dataOffset, max(0, length))
    }
}

/// gzip (RFC 1952) member headers.
enum AVGzipReader {
    static func looksLikeGzip(_ view: AVByteView) -> Bool {
        view.u8(0) == 0x1F && view.u8(1) == 0x8B && view.u8(2) == 8
    }

    /// The original file name stored in the header (FNAME), if any.
    static func originalName(_ view: AVByteView) -> String? {
        guard looksLikeGzip(view), let flags = view.u8(3) else { return nil }
        var offset = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard let length = view.u16le(offset) else { return nil }
            offset += 2 + Int(length)
        }
        guard flags & 0x08 != 0, view.contains(offset: offset, length: 0) else { return nil }
        let name = view.cString(offset, maxLength: 1024)
        return name.isEmpty ? nil : name
    }

    /// Decompresses every member (gzip files may be concatenated), up to `limit` bytes in total.
    static func decompress(_ view: AVByteView, limit: Int) -> AVInflate.Output {
        var combined = Data()
        var consumed = 0
        var result = AVInflate.Output(data: Data(), consumed: 0, complete: false, hitLimit: false, damaged: false)
        var members = 0
        while consumed < view.count, members < 64 {
            guard let rest = view.suffix(from: consumed), looksLikeGzip(rest) else { break }
            let output = AVInflate.inflate(rest, wrapper: .gzip, limit: limit - combined.count)
            if members == 0 { combined = output.data } else { combined.append(output.data) }
            consumed += output.consumed
            members += 1
            result = AVInflate.Output(data: Data(), consumed: consumed, complete: output.complete,
                                      hitLimit: output.hitLimit, damaged: output.damaged)
            if !output.complete || output.consumed == 0 { break }
        }
        result.data = combined
        return result
    }
}

/// Chrome/Edge extensions: `Cr24` header (version 2 or 3) followed by a ZIP archive.
enum AVCRXReader {
    static func looksLikeCRX(_ view: AVByteView) -> Bool {
        view.matches(Array("Cr24".utf8), at: 0)
    }

    /// Offset of the embedded ZIP archive.
    static func zipOffset(_ view: AVByteView) -> Int? {
        guard looksLikeCRX(view), let version = view.u32le(4) else { return nil }
        let offset: Int
        switch version {
        case 2:
            guard let keyLength = view.u32le(8), let signatureLength = view.u32le(12) else { return nil }
            offset = 16 + Int(keyLength) + Int(signatureLength)
        case 3:
            guard let headerLength = view.u32le(8) else { return nil }
            offset = 12 + Int(headerLength)
        default:
            return nil
        }
        guard view.contains(offset: offset, length: 4), view.matches(AVZipReader.localSignature, at: offset) else { return nil }
        return offset
    }
}

/// One architecture slice of a universal ("fat") Mach-O binary.
struct AVFatSlice: Sendable, Hashable {
    var architecture: String
    var offset: Int
    var size: Int
}

/// Universal binaries: `0xCAFEBABE` (32-bit table) or `0xCAFEBABF` (64-bit table), big-endian.
/// Java class files share the `CAFEBABE` magic; they're told apart by the second word, which is
/// a small architecture count for universal binaries and the class file version for Java.
enum AVFatMachOReader {
    static func slices(_ view: AVByteView) -> [AVFatSlice]? {
        guard let magic = view.u32be(0), magic == 0xCAFE_BABE || magic == 0xCAFE_BABF,
              let count = view.u32be(4), count > 0, count < 0x20 else { return nil }
        let is64 = magic == 0xCAFE_BABF
        let entrySize = is64 ? 32 : 20
        var slices = [AVFatSlice]()
        for index in 0..<Int(count) {
            let entry = 8 + index * entrySize
            guard let cpuType = view.u32be(entry), let cpuSubtype = view.u32be(entry + 4) else { return nil }
            let offset: Int, size: Int
            if is64 {
                guard let o = view.u64be(entry + 8).flatMap({ Int(exactly: $0) }),
                      let s = view.u64be(entry + 16).flatMap({ Int(exactly: $0) }) else { return nil }
                offset = o; size = s
            } else {
                guard let o = view.u32be(entry + 8), let s = view.u32be(entry + 12) else { return nil }
                offset = Int(o); size = Int(s)
            }
            // A slice must lie after the table and inside the file.
            guard offset >= 8 + Int(count) * entrySize, view.contains(offset: offset, length: size), size > 0 else { continue }
            slices.append(AVFatSlice(architecture: architectureName(cpuType: cpuType, subtype: cpuSubtype), offset: offset, size: size))
        }
        return slices.isEmpty ? nil : slices
    }

    static func architectureName(cpuType: UInt32, subtype: UInt32) -> String {
        switch cpuType {
        case 0x0100_0007: return (subtype & 0xFF) == 8 ? "x86_64h" : "x86_64"
        case 7: return "i386"
        case 0x0100_000C: return (subtype & 0xFF) == 2 ? "arm64e" : "arm64"
        case 0x0200_000C: return "arm64_32"
        case 12: return "arm"
        case 18: return "ppc"
        case 0x0100_0012: return "ppc64"
        default: return String(format: "cpu-%x", cpuType)
        }
    }
}
