import Darwin
import Foundation
@testable import MacCleaner

/// A temporary folder for one antivirus engine test, removed when released.
final class AVTestDirectory: @unchecked Sendable {
    let url: URL

    init(_ name: String = "AVEngineTests") {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    @discardableResult
    func write(_ name: String, _ data: Data) throws -> URL {
        let target = file(name)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
        return target
    }
}

/// Builders for test fixtures: databases, archives and executables, all in memory.
enum AVFixtures {
    // MARK: Databases

    /// A ClamAV header line padded to 512 bytes.
    static func header(name: String = "test", version: Int = 1, signatures: Int = 1, md5: String = "X", dsig: String = "X") -> Data {
        var text = "ClamAV-VDB:16 Oct 2026 06-24 +0000:\(version):\(signatures):90:\(md5):\(dsig):tester:1792131857"
        text += String(repeating: " ", count: max(0, 512 - text.utf8.count))
        return Data(text.utf8)
    }

    /// A `.cld`-style container: header + plain tar.
    static func cld(name: String = "test", files: [(String, Data)]) -> Data {
        header(name: name) + tar(files)
    }

    /// Compiles signature files (name → text) into a loaded engine.
    static func engine(_ files: [String: String], hashLists: [(String, AVSignatureSource)] = [], keep directory: AVTestDirectory = AVTestDirectory()) throws -> AVEngine {
        let container = directory.file("test.cld")
        let sorted = files.sorted { $0.key < $1.key }.map { ($0.key, Data($0.value.utf8)) }
        try cld(files: sorted).write(to: container)
        var lists = [(url: URL, source: AVSignatureSource)]()
        for (index, list) in hashLists.enumerated() {
            lists.append((try directory.write("list\(index).txt", Data(list.0.utf8)), list.1))
        }
        let databaseDirectory = directory.file("db")
        _ = try AVDatabaseCompiler.compile(AVDatabaseInputs(clamavFiles: [container], sha256Lists: lists), into: databaseDirectory)
        return try AVEngine.load(from: databaseDirectory)
    }

    /// Compiles and returns the summary too.
    static func compile(_ files: [String: String]) throws -> (AVEngine, AVDatabaseSummary) {
        let directory = AVTestDirectory()
        let container = directory.file("test.cld")
        try cld(files: files.sorted { $0.key < $1.key }.map { ($0.key, Data($0.value.utf8)) }).write(to: container)
        let databaseDirectory = directory.file("db")
        let summary = try AVDatabaseCompiler.compile(AVDatabaseInputs(clamavFiles: [container]), into: databaseDirectory)
        return (try AVEngine.load(from: databaseDirectory), summary)
    }

    // MARK: Archives

    /// A POSIX (ustar) tar archive.
    static func tar(_ files: [(String, Data)], ustar: Bool = true) -> Data {
        var out = Data()
        for (name, contents) in files {
            var header = [UInt8](repeating: 0, count: 512)
            let nameBytes = Array(name.utf8.prefix(99))
            header.replaceSubrange(0..<nameBytes.count, with: nameBytes)
            func octal(_ value: Int, _ offset: Int, _ width: Int) {
                let digits = Array(String(value, radix: 8).utf8)
                let padded = [UInt8](repeating: 0x30, count: width - 1 - digits.count) + digits
                header.replaceSubrange(offset..<(offset + width - 1), with: padded)
            }
            octal(0o644, 100, 8)
            octal(0, 108, 8)
            octal(0, 116, 8)
            octal(contents.count, 124, 12)
            octal(1_700_000_000, 136, 12)
            header[156] = UInt8(ascii: "0")
            if ustar {
                header.replaceSubrange(257..<263, with: Array("ustar\0".utf8))
                header.replaceSubrange(263..<265, with: Array("00".utf8))
            }
            header.replaceSubrange(148..<156, with: [UInt8](repeating: 0x20, count: 8))
            let sum = header.reduce(0) { $0 + Int($1) }
            let digits = Array(String(sum, radix: 8).utf8)
            let field = [UInt8](repeating: 0x30, count: 6 - digits.count) + digits + [0, 0x20]
            header.replaceSubrange(148..<156, with: field)
            out.append(contentsOf: header)
            out.append(contents)
            let padding = (512 - contents.count % 512) % 512
            out.append(Data(count: padding))
        }
        out.append(Data(count: 1024))
        return out
    }

    struct ZipMember {
        var name: String
        var data: Data
        var deflate = true
        var encrypted = false
        var method: UInt16?
    }

    /// A ZIP archive with a central directory.
    static func zip(_ members: [ZipMember], prefix: Data = Data()) -> Data {
        var out = prefix
        var central = Data()
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).littleEndian) { Data($0) } }
        for member in members {
            let bytes = [UInt8](member.data)
            let compressed: Data
            let method: UInt16
            if member.deflate {
                compressed = Data(AVDeflate.compress(bytes) ?? [])
                method = member.method ?? 8
            } else {
                compressed = member.data
                method = member.method ?? 0
            }
            let crc = member.data.withUnsafeBytes { AVCRC32.checksum(AVByteView($0)) }
            let flags: UInt16 = member.encrypted ? 1 : 0
            let localOffset = out.count - prefix.count
            let name = Data(member.name.utf8)
            var local = Data([0x50, 0x4B, 0x03, 0x04])
            local += le16(20) + le16(Int(flags)) + le16(Int(method)) + le16(0) + le16(0)
            local += le32(Int(crc)) + le32(compressed.count) + le32(member.data.count) + le16(name.count) + le16(0)
            out += local + name + compressed
            var entry = Data([0x50, 0x4B, 0x01, 0x02])
            entry += le16(20) + le16(20) + le16(Int(flags)) + le16(Int(method)) + le16(0) + le16(0)
            entry += le32(Int(crc)) + le32(compressed.count) + le32(member.data.count)
            entry += le16(name.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(localOffset)
            central += entry + name
        }
        let directoryOffset = out.count - prefix.count
        out += central
        var end = Data([0x50, 0x4B, 0x05, 0x06])
        end += le16(0) + le16(0) + le16(members.count) + le16(members.count) + le32(central.count) + le32(directoryOffset) + le16(0)
        out += end
        return out
    }

    /// A single-member gzip file.
    static func gzip(_ data: Data, name: String? = nil) -> Data {
        var out = Data([0x1F, 0x8B, 8, name == nil ? 0 : 0x08, 0, 0, 0, 0, 0, 3])
        if let name { out += Data(name.utf8) + Data([0]) }
        out += Data(AVDeflate.compress([UInt8](data)) ?? [])
        let crc = data.withUnsafeBytes { AVCRC32.checksum(AVByteView($0)) }
        out += withUnsafeBytes(of: crc.littleEndian) { Data($0) }
        out += withUnsafeBytes(of: UInt32(truncatingIfNeeded: data.count).littleEndian) { Data($0) }
        return out
    }

    // MARK: Executables

    /// A minimal 64-bit Mach-O (arm64) with one __TEXT segment holding a __text section that
    /// contains `code`, and LC_MAIN pointing at the start of that section.
    static func machO(code: Data, cpuType: UInt32 = 0x0100_000C, padTo: Int = 0x400) -> Data {
        var out = Data()
        func u32(_ v: UInt32) { out += withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u64(_ v: UInt64) { out += withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func name16(_ s: String) { var bytes = Array(s.utf8); bytes += [UInt8](repeating: 0, count: 16 - bytes.count); out += Data(bytes) }
        let codeOffset = padTo
        let segmentCommandSize = 72 + 80
        let mainCommandSize = 24
        u32(0xFEED_FACF); u32(cpuType); u32(0); u32(2) // MH_EXECUTE
        u32(2); u32(UInt32(segmentCommandSize + mainCommandSize)); u32(0); u32(0)
        // LC_SEGMENT_64 __TEXT
        u32(0x19); u32(UInt32(segmentCommandSize)); name16("__TEXT")
        u64(0x1_0000_0000); u64(UInt64(codeOffset + code.count)); u64(0); u64(UInt64(codeOffset + code.count))
        u32(5); u32(5); u32(1); u32(0)
        // section __text
        name16("__text"); name16("__TEXT")
        u64(0x1_0000_0000 + UInt64(codeOffset)); u64(UInt64(code.count)); u32(UInt32(codeOffset)); u32(2); u32(0); u32(0)
        u32(0x8000_0400); u32(0); u32(0); u32(0)
        // LC_MAIN
        u32(0x8000_0028); u32(UInt32(mainCommandSize)); u64(UInt64(codeOffset)); u64(0)
        out += Data(count: codeOffset - out.count)
        out += code
        return out
    }

    /// A universal binary holding the given slices (arm64 then x86_64 CPU types).
    static func universal(_ slices: [Data]) -> Data {
        var out = Data()
        func u32be(_ v: UInt32) { out += withUnsafeBytes(of: v.bigEndian) { Data($0) } }
        u32be(0xCAFE_BABE)
        u32be(UInt32(slices.count))
        var offset = 0x1000
        let cpuTypes: [UInt32] = [0x0100_000C, 0x0100_0007, 7, 12]
        var placements = [(Int, Data)]()
        for (index, slice) in slices.enumerated() {
            u32be(cpuTypes[index % cpuTypes.count]); u32be(0); u32be(UInt32(offset)); u32be(UInt32(slice.count)); u32be(12)
            placements.append((offset, slice))
            offset += (slice.count + 0xFFF) / 0x1000 * 0x1000
        }
        for (position, slice) in placements {
            out += Data(count: position - out.count)
            out += slice
        }
        return out
    }

    /// A minimal PE32 with `sections` (name, data) and the entry point at the start of the first section.
    static func pe(sections: [(String, Data)], entryOffsetInFirstSection: Int = 0, pe32Plus: Bool = false) -> Data {
        var out = Data(count: 0x40)
        out[0] = 0x4D; out[1] = 0x5A
        out[0x3C] = 0x40
        func u16(_ v: Int) { out += withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        func u32(_ v: Int) { out += withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).littleEndian) { Data($0) } }
        out += Data([0x50, 0x45, 0, 0])
        let optionalSize = pe32Plus ? 240 : 224
        u16(pe32Plus ? 0x8664 : 0x14C); u16(sections.count); u32(0); u32(0); u32(0); u16(optionalSize); u16(0x102)
        let optionalStart = out.count
        u16(pe32Plus ? 0x20B : 0x10B)
        out += Data(count: 14) // linker version, code sizes
        u32(0x1000 + entryOffsetInFirstSection) // AddressOfEntryPoint
        out += Data(count: optionalStart + 32 - out.count)
        u32(0x1000) // SectionAlignment
        u32(0x200)  // FileAlignment
        out += Data(count: optionalStart + optionalSize - out.count)
        var raw = 0x400
        var placements = [(Int, Data)]()
        for (index, section) in sections.enumerated() {
            var name = Array(section.0.utf8.prefix(8))
            name += [UInt8](repeating: 0, count: 8 - name.count)
            out += Data(name)
            let rawSize = (section.1.count + 0x1FF) / 0x200 * 0x200
            u32(section.1.count); u32(0x1000 * (index + 1)); u32(rawSize); u32(raw)
            out += Data(count: 16)
            placements.append((raw, section.1 + Data(count: rawSize - section.1.count)))
            raw += rawSize
        }
        for (position, data) in placements {
            if out.count < position { out += Data(count: position - out.count) }
            out += data
        }
        return out
    }

    /// Hex text of bytes (for writing signatures).
    static func hex(_ text: String) -> String { AVHex.string(Array(text.utf8)) }
    static func hex(_ data: Data) -> String { AVHex.string(Array(data)) }

    /// Random-looking but deterministic filler bytes.
    static func filler(_ count: Int, seed: UInt64 = 1) -> Data {
        var state = seed &* 0x9E37_79B9_7F4A_7C15
        var out = Data(count: count)
        for index in 0..<count {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            out[index] = UInt8(truncatingIfNeeded: state)
        }
        return out
    }
}

/// Convenience for tests: detection names of a scan.
extension AVEngine {
    func names(_ data: Data, name: String = "sample", options: AVScanOptions = AVScanOptions()) -> [String] {
        scan(data: data, name: name, options: options).map(\.signatureName)
    }
}

/// The real ClamAV databases downloaded for development, if present.
enum AVRealDatabase {
    static let directory: URL? = {
        let candidates = [
            ProcessInfo.processInfo.environment["MACCLEANER_AVDB_DIR"],
            "/private/tmp/claude-501/-Users-shayanhashemi-Downloads-Mac-cleaner/d5bdd58a-7de9-4905-b694-4f4dc0b3c27b/scratchpad/avdb",
        ].compactMap { $0 }
        return candidates.map { URL(fileURLWithPath: $0) }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("clamav/main.cvd").path)
                && FileManager.default.fileExists(atPath: $0.appendingPathComponent("clamav/daily.cvd").path)
        }
    }()

    static var isAvailable: Bool { directory != nil }

    static var mainCVD: URL? { directory?.appendingPathComponent("clamav/main.cvd") }
    static var dailyCVD: URL? { directory?.appendingPathComponent("clamav/daily.cvd") }
    /// The small (~280 KB) bytecode database: quick to compile, and signed like the others.
    static var bytecodeCVD: URL? {
        directory.map { $0.appendingPathComponent("clamav/bytecode.cvd") }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }
    static var extractedMain: URL? { directory?.appendingPathComponent("x-main") }
    static var extractedDaily: URL? { directory?.appendingPathComponent("x-daily") }

    struct Compiled: Sendable {
        var engine: AVEngine?
        var summary: AVDatabaseSummary?
        var error: String?
        var seconds: Double = 0
    }

    /// The real databases compiled once per test run (shared by all real-database tests).
    static let compiled: Compiled = {
        guard let mainCVD, let dailyCVD else { return Compiled(error: "databases not present") }
        let directory = AVTestDirectory("AVRealDatabase")
        let start = Date()
        do {
            let summary = try AVDatabaseCompiler.compile(AVDatabaseInputs(clamavFiles: [mainCVD, dailyCVD]), into: directory.url)
            // The mapping stays valid after the directory is removed.
            let engine = try AVEngine.load(from: directory.url)
            return Compiled(engine: engine, summary: summary, seconds: Date().timeIntervalSince(start))
        } catch {
            return Compiled(error: error.localizedDescription)
        }
    }()
}
