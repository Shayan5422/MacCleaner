import Darwin
import Foundation

/// Turns a filled `AVDatabaseBuilder` into the binary database file.
extension AVDatabaseBuilder {
    /// Names per compressed block. Names are only read when something is detected.
    static let namesPerBlock = 256

    /// Below this many patterns for a target, short-anchor patterns are searched one by one.
    static let minimumShortTablePatterns = 16

    /// Writes the database to `url` (the caller renames it into place). Sections are written as
    /// soon as they're built and the builder's buffers are released along the way, to keep the
    /// compiler's peak memory down.
    func write(to url: URL, summary: AVDatabaseSummary) throws {
        let file = try AVSectionFileWriter(url: url)

        // A 2-byte-keyed pass costs about as much as a prefilter pass; for a handful of
        // patterns one search each (memchr on their rarest byte) is cheaper, so those stay weak.
        var shortTableTargets = Set<Int>()
        for target in 0..<AVDatabaseFormat.targetCount {
            let patterns = Set(shortAnchors[target].map { UInt32(truncatingIfNeeded: $0) })
            if patterns.count >= Self.minimumShortTablePatterns {
                shortTableTargets.insert(target)
            } else {
                weakPatterns[target] += patterns.sorted()
            }
        }

        var metadata = AVDatabaseMetadata(formatVersion: AVDatabaseFormat.version, engineFunctionalityLevel: functionalityLevel, summary: summary)
        metadata.md5Wildcard = fileHashWildcard[0]
        metadata.sha1Wildcard = fileHashWildcard[1]
        metadata.sha256Wildcard = fileHashWildcard[2]
        metadata.md5WildcardMachO = fileHashWildcardMachO[0]
        metadata.sha1WildcardMachO = fileHashWildcardMachO[1]
        metadata.sha256WildcardMachO = fileHashWildcardMachO[2]
        metadata.sectionMD5Wildcard = sectionHashWildcard[0]
        metadata.sectionSHA1Wildcard = sectionHashWildcard[1]
        metadata.sectionSHA256Wildcard = sectionHashWildcard[2]
        metadata.pcres = pcres
        metadata.byteCompares = byteCompares
        metadata.weakTargets = (0..<AVDatabaseFormat.targetCount).filter { !weakPatterns[$0].isEmpty }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try file.add(AVDatabaseFormat.meta, Array(try encoder.encode(metadata)))

        let (nameBlocks, nameIndex) = try compressedNames()
        try file.add(AVDatabaseFormat.names, nameBlocks)
        try file.add(AVDatabaseFormat.nameOffsets, nameIndex)
        nameBytes = []
        nameEnds = []
        try file.add(AVDatabaseFormat.signatures, signatureRecords.bytes)
        signatureRecords = AVBinaryWriter()
        try file.add(AVDatabaseFormat.subsigs, subsigRecords.bytes)
        subsigRecords = AVBinaryWriter()
        try file.add(AVDatabaseFormat.patterns, patternRecords.bytes)
        patternRecords = AVBinaryWriter()
        try file.add(AVDatabaseFormat.programs, programBytes.bytes)
        programBytes = AVBinaryWriter()
        try file.add(AVDatabaseFormat.expressions, expressionBytes.bytes)
        try file.add(AVDatabaseFormat.constraints, constraintRecords.bytes)

        for target in 0..<AVDatabaseFormat.targetCount {
            if target == 0 || !triggerAnchors[target].isEmpty {
                let entries = target == 0 ? triggerAnchors[0] : triggerAnchors[0] + triggerAnchors[target]
                try file.add(AVDatabaseFormat.prefilter(target), Self.prefilterTable(entries, checks: patternChecks))
            }
            if target == 0 || !deferredAnchors[target].isEmpty {
                let entries = target == 0 ? deferredAnchors[0] : deferredAnchors[0] + deferredAnchors[target]
                try file.add(AVDatabaseFormat.deferredPrefilter(target), Self.prefilterTable(entries, checks: patternChecks))
            }
            if !anchoredPatterns[target].isEmpty {
                try file.add(AVDatabaseFormat.anchored(target), Self.list(anchoredPatterns[target]))
            }
            if !weakPatterns[target].isEmpty {
                try file.add(AVDatabaseFormat.weak(target), Self.list(weakPatterns[target]))
            }
            if !deferredListPatterns[target].isEmpty {
                try file.add(AVDatabaseFormat.deferredList(target), Self.list(deferredListPatterns[target]))
            }
            if shortTableTargets.contains(target) {
                let entries = target == 0 || !shortTableTargets.contains(0) ? shortAnchors[target] : shortAnchors[0] + shortAnchors[target]
                try file.add(AVDatabaseFormat.shortPrefilter(target), Self.prefilterTable(entries, checks: patternChecks))
            }
        }
        triggerAnchors = []
        deferredAnchors = []
        shortAnchors = []
        patternChecks = []

        let fileTags = [AVDatabaseFormat.fileMD5, AVDatabaseFormat.fileSHA1, AVDatabaseFormat.fileSHA256]
        let fileSizeTags = [AVDatabaseFormat.fileMD5Sizes, AVDatabaseFormat.fileSHA1Sizes, AVDatabaseFormat.fileSHA256Sizes]
        let sectionTags = [AVDatabaseFormat.sectionMD5, AVDatabaseFormat.sectionSHA1, AVDatabaseFormat.sectionSHA256]
        let sectionSizeTags = [AVDatabaseFormat.sectionMD5Sizes, AVDatabaseFormat.sectionSHA1Sizes, AVDatabaseFormat.sectionSHA256Sizes]
        let allowTags = [AVDatabaseFormat.allowMD5, AVDatabaseFormat.allowSHA1, AVDatabaseFormat.allowSHA256]
        for (slot, length) in Self.digestLengths.enumerated() {
            let recordSize = AVDatabaseFormat.hashRecordSize(digestLength: length)
            let files = Self.sortedRecords(fileHashes[slot].bytes, recordSize: recordSize, keyLength: length + 4)
            fileHashes[slot] = AVBinaryWriter()
            try file.add(fileTags[slot], files)
            try file.add(fileSizeTags[slot], Self.sizeSet(files, recordSize: recordSize, sizeOffset: length))
            let sectionRecords = Self.sortedRecords(sectionHashes[slot].bytes, recordSize: recordSize, keyLength: length + 4)
            sectionHashes[slot] = AVBinaryWriter()
            try file.add(sectionTags[slot], sectionRecords)
            try file.add(sectionSizeTags[slot], Self.sizeSet(sectionRecords, recordSize: recordSize, sizeOffset: length))
            let allowSize = AVDatabaseFormat.allowRecordSize(digestLength: length)
            try file.add(allowTags[slot], Self.sortedRecords(allowHashes[slot].bytes, recordSize: allowSize, keyLength: allowSize, unique: true))
        }
        let list = Self.sortedRecords(hashList.bytes, recordSize: AVDatabaseFormat.hashListRecordSize,
                                      keyLength: AVDatabaseFormat.hashListRecordSize, unique: true)
        hashList = AVBinaryWriter()
        try file.add(AVDatabaseFormat.hashList, list)
        try file.finish()
    }

    // MARK: Names

    /// Blocks of `namesPerBlock` names joined by LF, each raw-DEFLATE compressed. The index is
    /// `u32 nameCount, u32 namesPerBlock`, then per block `u32 offset, u32 length`.
    private func compressedNames() throws -> ([UInt8], [UInt8]) {
        var blocks = AVBinaryWriter()
        var index = AVBinaryWriter()
        index.u32(UInt32(nameCount))
        index.u32(UInt32(Self.namesPerBlock))
        var start = 0
        while start < nameCount {
            let end = min(start + Self.namesPerBlock, nameCount)
            var joined = [UInt8]()
            for position in start..<end {
                if position > start { joined.append(0x0A) }
                joined.append(contentsOf: name(at: position))
            }
            guard let compressed = AVDeflate.compress(joined) else {
                throw AVEngineError.invalidDatabase("signature names couldn't be compressed.")
            }
            index.u32(UInt32(blocks.count))
            index.u32(UInt32(compressed.count))
            blocks.append(compressed)
            start = end
        }
        return (blocks.bytes, index.bytes)
    }

    // MARK: Tables

    /// `u32 count` followed by the pattern indices.
    static func list(_ patterns: [UInt32]) -> [UInt8] {
        var writer = AVBinaryWriter(capacity: 4 + patterns.count * 4)
        writer.u32(UInt32(patterns.count))
        for pattern in patterns { writer.u32(pattern) }
        return writer.bytes
    }

    /// Builds a prefilter table (see `AVPrefilterTable`) from (anchor << 32 | pattern) entries.
    /// Layout: u32 bitmap log2, u32 table log2, u32 candidate count, u32 anchor count; bitmap;
    /// slots (u32 anchor, u32 first candidate); candidates (u32: a count, then that many pattern
    /// indices, per anchor); then one u64 `AVQuickCheck` per candidate entry (0 for counts).
    static func prefilterTable(_ entries: [UInt64], checks: [UInt64]) -> [UInt8] {
        let sorted = entries.sorted()
        var anchors = [UInt32]()
        var candidates = [UInt32]()
        var candidateChecks = [UInt64]()
        var starts = [UInt32]()
        var index = 0
        while index < sorted.count {
            let anchor = UInt32(truncatingIfNeeded: sorted[index] >> 32)
            var end = index
            var patterns = [UInt32]()
            while end < sorted.count, UInt32(truncatingIfNeeded: sorted[end] >> 32) == anchor {
                let pattern = UInt32(truncatingIfNeeded: sorted[end])
                if patterns.last != pattern { patterns.append(pattern) }
                end += 1
            }
            anchors.append(anchor)
            starts.append(UInt32(candidates.count))
            candidates.append(UInt32(patterns.count))
            candidateChecks.append(AVQuickCheck.none)
            candidates.append(contentsOf: patterns)
            for pattern in patterns { candidateChecks.append(Int(pattern) < checks.count ? checks[Int(pattern)] : AVQuickCheck.none) }
            index = end
        }
        // Bitmap: ~64 bits per anchor keeps false positives near 1.5%.
        var bitmapLog2: UInt32 = 12
        while bitmapLog2 < 27, (1 << Int(bitmapLog2)) < anchors.count * 64 { bitmapLog2 += 1 }
        var tableLog2: UInt32 = 4
        while (1 << Int(tableLog2)) < anchors.count * 2 { tableLog2 += 1 }

        var bitmap = [UInt64](repeating: 0, count: (1 << Int(bitmapLog2)) / 64)
        let bitmapShift = 32 - bitmapLog2
        let slotCount = 1 << Int(tableLog2)
        var slots = [UInt64](repeating: UInt64(AVDatabaseFormat.emptySlot) << 32, count: slotCount)
        let tableShift = 32 - tableLog2
        for (position, anchor) in anchors.enumerated() {
            let h = Int((anchor &* AVDatabaseFormat.bitmapMultiplier) >> bitmapShift)
            bitmap[h >> 6] |= 1 << UInt64(h & 63)
            var slot = Int((anchor &* AVDatabaseFormat.tableMultiplier) >> tableShift)
            while UInt32(truncatingIfNeeded: slots[slot] >> 32) != AVDatabaseFormat.emptySlot {
                slot = (slot + 1) & (slotCount - 1)
            }
            // Stored little-endian as (u32 key, u32 start).
            slots[slot] = UInt64(starts[position]) << 32 | UInt64(anchor)
        }
        var writer = AVBinaryWriter(capacity: 16 + bitmap.count * 8 + slotCount * 8 + candidates.count * 12)
        writer.u32(bitmapLog2)
        writer.u32(tableLog2)
        writer.u32(UInt32(candidates.count))
        writer.u32(UInt32(anchors.count))
        for word in bitmap { writer.u64(word) }
        for slot in slots { writer.u64(slot) }
        for value in candidates { writer.u32(value) }
        for check in candidateChecks { writer.u64(check) }
        return writer.bytes
    }

    /// Sorts fixed-size records by their first `keyLength` bytes (byte order, as `memcmp`).
    static func sortedRecords(_ bytes: [UInt8], recordSize: Int, keyLength: Int, unique: Bool = false) -> [UInt8] {
        let count = bytes.count / recordSize
        guard count > 1 else { return bytes }
        var order = [Int32](0..<Int32(count))
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            order.sort { a, b in memcmp(base + Int(a) * recordSize, base + Int(b) * recordSize, keyLength) < 0 }
        }
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var previous: Int?
            for index in order {
                let offset = Int(index) * recordSize
                if unique, let previous, memcmp(base + previous, base + offset, recordSize) == 0 { continue }
                out.append(contentsOf: UnsafeRawBufferPointer(start: base + offset, count: recordSize))
                previous = offset
            }
        }
        return out
    }

    /// Sorted unique sizes (u32) of hash records, wildcard excluded.
    static func sizeSet(_ records: [UInt8], recordSize: Int, sizeOffset: Int) -> [UInt8] {
        var sizes = Set<UInt32>()
        records.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + recordSize <= raw.count {
                let size = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offset + sizeOffset, as: UInt32.self))
                if size != AVDatabaseFormat.wildcardSize { sizes.insert(size) }
                offset += recordSize
            }
        }
        var writer = AVBinaryWriter(capacity: sizes.count * 4)
        for size in sizes.sorted() { writer.u32(size) }
        return writer.bytes
    }

}

/// Writes sections sequentially (16-byte aligned) after space reserved for the header and
/// directory, then fills those in.
final class AVSectionFileWriter {
    static let maxSections = 192
    private let fd: Int32
    private var directory = AVBinaryWriter()
    private var sectionCount = 0
    private var offset: Int

    init(url: URL) throws {
        fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw AVEngineError.invalidDatabase("the database can't be written (\(String(cString: strerror(errno)))).")
        }
        offset = (AVDatabaseFormat.headerSize + Self.maxSections * AVDatabaseFormat.directoryEntrySize + 15) / 16 * 16
    }

    deinit { close(fd) }

    func add(_ tag: String, _ bytes: [UInt8]) throws {
        let tagBytes = Array(tag.utf8)
        guard tagBytes.count == 4, sectionCount < Self.maxSections else {
            throw AVEngineError.invalidDatabase("internal error: bad section \(tag)")
        }
        directory.append(tagBytes)
        directory.u32(0)
        directory.u64(UInt64(offset))
        directory.u64(UInt64(bytes.count))
        sectionCount += 1
        try write(bytes, at: offset)
        offset = (offset + bytes.count + 15) / 16 * 16
    }

    func finish() throws {
        var header = AVBinaryWriter()
        header.append(AVDatabaseFormat.magic)
        header.u32(AVDatabaseFormat.version)
        header.u32(UInt32(sectionCount))
        header.u64(UInt64(offset))
        header.zeros(AVDatabaseFormat.headerSize - header.count)
        try write(header.bytes, at: 0)
        try write(directory.bytes, at: AVDatabaseFormat.headerSize)
        guard ftruncate(fd, off_t(offset)) == 0, fsync(fd) == 0 else {
            throw AVEngineError.invalidDatabase("the database can't be saved (\(String(cString: strerror(errno)))).")
        }
    }

    private func write(_ bytes: [UInt8], at position: Int) throws {
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let result = pwrite(fd, base + written, raw.count - written, off_t(position + written))
                if result < 0 {
                    if errno == EINTR { continue }
                    throw AVEngineError.invalidDatabase("the database can't be written (\(String(cString: strerror(errno)))).")
                }
                written += result
            }
        }
    }
}
