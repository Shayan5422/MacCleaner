import Compression
import Darwin
import Foundation

// Small, bounded archive helpers for the definitions updater: raw DEFLATE (Compression
// framework), gzip members, the minimal tar format ClamAV uses, and single zip entries.
// Everything has size limits so a damaged or hostile download can't fill the disk.

enum AVDefsArchiveError: LocalizedError, Equatable {
    case notGzip
    case corrupt(String)
    case tooLarge
    case unsupported(String)
    case unsafeName(String)

    var errorDescription: String? {
        switch self {
        case .notGzip: return "The file isn't gzip-compressed."
        case .corrupt(let detail): return "The archive is damaged (\(detail))."
        case .tooLarge: return "The archive expands to more data than expected."
        case .unsupported(let detail): return "The archive uses an unsupported format (\(detail))."
        case .unsafeName(let name): return "The archive contains an unexpected file name (\(name))."
        }
    }
}

/// CRC-32 (IEEE 802.3), as used by gzip and zip.
struct AVDefsCRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    private(set) var value: UInt32 = 0xFFFF_FFFF

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        var crc = value
        for byte in bytes { crc = Self.table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        value = crc
    }

    var checksum: UInt32 { value ^ 0xFFFF_FFFF }
}

enum AVDefsInflater {
    /// Decodes one raw DEFLATE stream from `input`, passing output to `sink`.
    /// Returns the number of input bytes the stream used.
    static func inflate(_ input: UnsafeRawBufferPointer, maxOutput: Int64, sink: (UnsafeRawBufferPointer) throws -> Void) throws -> Int {
        guard let base = input.baseAddress, input.count > 0 else { throw AVDefsArchiveError.corrupt("empty stream") }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw AVDefsArchiveError.corrupt("decoder unavailable")
        }
        defer { compression_stream_destroy(stream) }
        let capacity = 1 << 20
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        stream.pointee.src_ptr = base.assumingMemoryBound(to: UInt8.self)
        stream.pointee.src_size = input.count
        var produced: Int64 = 0
        while true {
            stream.pointee.dst_ptr = buffer
            stream.pointee.dst_size = capacity
            let before = stream.pointee.src_size
            let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            let count = capacity - stream.pointee.dst_size
            if count > 0 {
                produced += Int64(count)
                guard produced <= maxOutput else { throw AVDefsArchiveError.tooLarge }
                try sink(UnsafeRawBufferPointer(start: buffer, count: count))
            }
            switch status {
            case COMPRESSION_STATUS_END:
                return input.count - stream.pointee.src_size
            case COMPRESSION_STATUS_OK:
                if count == 0 && stream.pointee.src_size == before { throw AVDefsArchiveError.corrupt("truncated data") }
            default:
                throw AVDefsArchiveError.corrupt("invalid compressed data")
            }
        }
    }
}

enum AVDefsGzip {
    /// Decompresses single-member gzip `data` (what ClamAV containers and patches use), checking
    /// the CRC and size in its trailer (the last 8 bytes).
    static func decompress(_ data: Data, maxOutput: Int64, sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let start = try memberStart(raw, at: 0)
            guard raw.count - start > 8 else { throw AVDefsArchiveError.corrupt("missing trailer") }
            let trailer = raw.count - 8
            var crc = AVDefsCRC32()
            var size: Int64 = 0
            _ = try AVDefsInflater.inflate(UnsafeRawBufferPointer(rebasing: raw[start..<trailer]), maxOutput: maxOutput) { chunk in
                crc.update(chunk)
                size += Int64(chunk.count)
                try sink(chunk)
            }
            guard littleEndian32(raw, trailer) == crc.checksum, littleEndian32(raw, trailer + 4) == UInt32(truncatingIfNeeded: size) else {
                throw AVDefsArchiveError.corrupt("checksum mismatch")
            }
        }
    }

    private static func memberStart(_ raw: UnsafeRawBufferPointer, at offset: Int) throws -> Int {
        guard raw.count - offset >= 18, raw[offset] == 0x1F, raw[offset + 1] == 0x8B else { throw AVDefsArchiveError.notGzip }
        guard raw[offset + 2] == 8 else { throw AVDefsArchiveError.unsupported("compression method") }
        let flags = raw[offset + 3]
        var position = offset + 10
        if flags & 0x04 != 0 {
            guard position + 2 <= raw.count else { throw AVDefsArchiveError.corrupt("header") }
            position += 2 + Int(raw[position]) | Int(raw[position + 1]) << 8
        }
        for flag in [UInt8(0x08), UInt8(0x10)] where flags & flag != 0 {
            while position < raw.count && raw[position] != 0 { position += 1 }
            position += 1
        }
        if flags & 0x02 != 0 { position += 2 }
        guard position < raw.count else { throw AVDefsArchiveError.corrupt("header") }
        return position
    }

    static func littleEndian32(_ raw: UnsafeRawBufferPointer, _ index: Int) -> UInt32 {
        UInt32(raw[index]) | UInt32(raw[index + 1]) << 8 | UInt32(raw[index + 2]) << 16 | UInt32(raw[index + 3]) << 24
    }
}

/// The minimal tar layout ClamAV uses inside `.cvd`/`.cld` containers (flat file names).
enum AVDefsTar {
    /// Streaming reader that writes regular files into a directory.
    final class Extractor {
        private let directory: URL
        private let maxFiles: Int
        private let maxTotal: Int64
        private var header = Data()
        private var current: (handle: FileHandle, remaining: Int64, padding: Int64)?
        private var skipping: Int64 = 0
        private var finished = false
        private(set) var files: [String] = []
        private var total: Int64 = 0

        init(directory: URL, maxFiles: Int = 400, maxTotal: Int64 = 2_000_000_000) {
            self.directory = directory
            self.maxFiles = maxFiles
            self.maxTotal = maxTotal
        }

        func consume(_ chunk: UnsafeRawBufferPointer) throws {
            var index = 0
            while index < chunk.count, !finished {
                if skipping > 0 {
                    let step = Int(min(skipping, Int64(chunk.count - index)))
                    skipping -= Int64(step)
                    index += step
                    continue
                }
                if var file = current {
                    if file.remaining > 0 {
                        let step = Int(min(file.remaining, Int64(chunk.count - index)))
                        try file.handle.write(contentsOf: Data(UnsafeRawBufferPointer(rebasing: chunk[index..<(index + step)])))
                        file.remaining -= Int64(step)
                        index += step
                        current = file
                    }
                    if file.remaining == 0 {
                        try file.handle.close()
                        skipping = file.padding
                        current = nil
                    }
                    continue
                }
                let step = min(512 - header.count, chunk.count - index)
                header.append(contentsOf: UnsafeRawBufferPointer(rebasing: chunk[index..<(index + step)]))
                index += step
                if header.count == 512 {
                    try handleHeader(header)
                    header.removeAll(keepingCapacity: true)
                }
            }
        }

        func finish() throws {
            if let file = current {
                try? file.handle.close()
                guard file.remaining == 0 else { throw AVDefsArchiveError.corrupt("truncated tar entry") }
            }
            guard !files.isEmpty else { throw AVDefsArchiveError.corrupt("no files") }
        }

        private func handleHeader(_ block: Data) throws {
            if block.allSatisfy({ $0 == 0 }) {
                finished = true
                return
            }
            let bytes = [UInt8](block)
            let rawName = AVDefsTar.string(bytes[0..<100])
            let size = try AVDefsTar.octal(bytes[124..<136])
            let type = bytes[156]
            let padding = (512 - size % 512) % 512
            guard type == 0 || type == UInt8(ascii: "0") else {
                skipping = size + padding // links, directories and extended headers aren't used by ClamAV
                return
            }
            let name = rawName.hasPrefix("./") ? String(rawName.dropFirst(2)) : rawName
            guard !name.isEmpty, !name.contains("/"), name != ".", name != "..", !name.hasPrefix(".") else {
                throw AVDefsArchiveError.unsafeName(rawName)
            }
            guard files.count < maxFiles else { throw AVDefsArchiveError.tooLarge }
            total += size
            guard total <= maxTotal else { throw AVDefsArchiveError.tooLarge }
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw AVDefsArchiveError.corrupt("couldn't create \(name)")
            }
            files.append(name)
            let handle = try FileHandle(forWritingTo: url)
            current = (handle, size, padding)
            if size == 0 {
                try handle.close()
                current = nil
                skipping = padding
            }
        }
    }

    /// Writes `names` (files inside `directory`) after `header` in the layout freshclam uses for `.cld` files.
    static func write(header: Data, files names: [String], from directory: URL, to destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o644]) else {
            throw AVDefsArchiveError.corrupt("couldn't create \(destination.lastPathComponent)")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.write(contentsOf: header)
        for name in names {
            let url = directory.appendingPathComponent(name)
            let size = ((try FileManager.default.attributesOfItem(atPath: url.path))[.size] as? NSNumber)?.int64Value ?? 0
            var block = [UInt8](repeating: 0, count: 512)
            let nameBytes = Array(name.utf8.prefix(99))
            block.replaceSubrange(0..<nameBytes.count, with: nameBytes)
            let sizeField = Array(String(size, radix: 8).utf8)
            block.replaceSubrange(124..<(124 + sizeField.count), with: sizeField)
            let checksum = block.reduce(0) { $0 + Int($1) } + 256 // the checksum field counts as eight spaces
            let checksumField = Array(String(format: "%06o", checksum).utf8) + [0]
            block.replaceSubrange(148..<(148 + checksumField.count), with: checksumField)
            try output.write(contentsOf: Data(block))
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            let remainder = Int(size % 512)
            if remainder != 0 { try output.write(contentsOf: Data(count: 512 - remainder)) }
        }
    }

    static func string(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    static func octal(_ bytes: ArraySlice<UInt8>) throws -> Int64 {
        if let first = bytes.first, first & 0x80 != 0 { // base-256 for large sizes
            var value: Int64 = 0
            for byte in bytes.dropFirst() { value = value << 8 | Int64(byte) }
            return value
        }
        let text = string(bytes).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return 0 }
        guard let value = Int64(text, radix: 8), value >= 0 else { throw AVDefsArchiveError.corrupt("tar size") }
        return value
    }
}

/// Reads one entry of a zip file (the full MalwareBazaar export ships as a one-file zip).
enum AVDefsZip {
    struct Entry: Sendable, Hashable {
        var name: String
        var method: UInt16
        var crc32: UInt32
        var compressedSize: Int64
        var uncompressedSize: Int64
        var localHeaderOffset: Int64
    }

    static func entries(in data: Data) throws -> [Entry] {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Entry] in
            guard raw.count >= 22 else { throw AVDefsArchiveError.corrupt("too small") }
            var eocd = -1
            var index = raw.count - 22
            let lowest = max(0, raw.count - 22 - 65_535)
            while index >= lowest {
                if AVDefsGzip.littleEndian32(raw, index) == 0x0605_4B50 { eocd = index; break }
                index -= 1
            }
            guard eocd >= 0 else { throw AVDefsArchiveError.corrupt("no directory") }
            let count = Int(le16(raw, eocd + 10))
            let directoryOffset = Int(AVDefsGzip.littleEndian32(raw, eocd + 16))
            guard count != 0xFFFF, directoryOffset != 0xFFFF_FFFF else { throw AVDefsArchiveError.unsupported("zip64") }
            var entries: [Entry] = []
            var position = directoryOffset
            for _ in 0..<count {
                guard position + 46 <= raw.count, AVDefsGzip.littleEndian32(raw, position) == 0x0201_4B50 else {
                    throw AVDefsArchiveError.corrupt("directory entry")
                }
                let nameLength = Int(le16(raw, position + 28))
                let extraLength = Int(le16(raw, position + 30))
                let commentLength = Int(le16(raw, position + 32))
                guard position + 46 + nameLength <= raw.count else { throw AVDefsArchiveError.corrupt("directory entry") }
                let name = String(decoding: UnsafeRawBufferPointer(rebasing: raw[(position + 46)..<(position + 46 + nameLength)]), as: UTF8.self)
                let compressed = Int64(AVDefsGzip.littleEndian32(raw, position + 20))
                let uncompressed = Int64(AVDefsGzip.littleEndian32(raw, position + 24))
                let offset = Int64(AVDefsGzip.littleEndian32(raw, position + 42))
                if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF || offset == 0xFFFF_FFFF { throw AVDefsArchiveError.unsupported("zip64") }
                entries.append(Entry(name: name, method: le16(raw, position + 10), crc32: AVDefsGzip.littleEndian32(raw, position + 16),
                                     compressedSize: compressed, uncompressedSize: uncompressed, localHeaderOffset: offset))
                position += 46 + nameLength + extraLength + commentLength
            }
            return entries
        }
    }

    /// Writes `entry` to `destination`, checking its size and CRC.
    static func extract(_ entry: Entry, from data: Data, to destination: URL, maxOutput: Int64) throws {
        guard entry.uncompressedSize <= maxOutput else { throw AVDefsArchiveError.tooLarge }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw AVDefsArchiveError.corrupt("couldn't create output")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let header = Int(entry.localHeaderOffset)
            guard header + 30 <= raw.count, AVDefsGzip.littleEndian32(raw, header) == 0x0403_4B50 else { throw AVDefsArchiveError.corrupt("local header") }
            let start = header + 30 + Int(le16(raw, header + 26)) + Int(le16(raw, header + 28))
            let end = start + Int(entry.compressedSize)
            guard end <= raw.count else { throw AVDefsArchiveError.corrupt("entry data") }
            var crc = AVDefsCRC32()
            var written: Int64 = 0
            let sink: (UnsafeRawBufferPointer) throws -> Void = { chunk in
                crc.update(chunk)
                written += Int64(chunk.count)
                try output.write(contentsOf: Data(chunk))
            }
            switch entry.method {
            case 0: try sink(UnsafeRawBufferPointer(rebasing: raw[start..<end]))
            case 8: _ = try AVDefsInflater.inflate(UnsafeRawBufferPointer(rebasing: raw[start..<end]), maxOutput: maxOutput, sink: sink)
            default: throw AVDefsArchiveError.unsupported("compression method \(entry.method)")
            }
            guard written == entry.uncompressedSize, crc.checksum == entry.crc32 else { throw AVDefsArchiveError.corrupt("checksum mismatch") }
        }
    }

    private static func le16(_ raw: UnsafeRawBufferPointer, _ index: Int) -> UInt16 {
        UInt16(raw[index]) | UInt16(raw[index + 1]) << 8
    }
}
