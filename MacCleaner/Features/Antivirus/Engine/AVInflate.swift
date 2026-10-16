import Foundation
import zlib

/// DEFLATE decompression with zlib (`libz`, part of macOS; `import zlib` links it automatically,
/// so the Xcode project needs no extra linker flags).
///
/// Everything happens in memory and every call has an output cap, so a "zip bomb" can't make the
/// engine allocate more than the caller allows. zlib is used instead of the Compression framework
/// because it reports exactly how much input a stream consumed (needed to find what follows a
/// gzip member or a ZIP entry) and is hardened against malformed streams.
enum AVInflate {
    enum Wrapper {
        /// Raw DEFLATE (ZIP members).
        case raw
        /// zlib header + DEFLATE + Adler-32 (compressed SWF).
        case zlib
        /// One gzip member: header, DEFLATE, CRC-32 and length (zlib checks the trailer).
        case gzip

        var windowBits: Int32 {
            switch self {
            case .raw: return -15
            case .zlib: return 15
            case .gzip: return 15 + 16
            }
        }
    }

    struct Output {
        var data: Data
        /// Input bytes consumed by the stream (exact).
        var consumed: Int
        /// The stream ended cleanly (and, for gzip, its checksum matched).
        var complete: Bool
        /// Decompression stopped because the output would have exceeded the limit.
        var hitLimit: Bool
        /// The stream is damaged or truncated. `data` holds what could be decompressed.
        var damaged: Bool
    }

    /// Decompresses one stream from the start of `input`, producing at most `limit` bytes. The
    /// output buffer reserves `limit` bytes of address space up front; only what is written is
    /// committed, so sizes claimed by archive headers never need to be trusted.
    static func inflate(_ input: AVByteView, wrapper: Wrapper, limit: Int) -> Output {
        var stream = z_stream()
        guard inflateInit2_(&stream, wrapper.windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return Output(data: Data(), consumed: 0, complete: false, hitLimit: false, damaged: true)
        }
        defer { inflateEnd(&stream) }

        let cap = max(0, limit)
        // Reserve the whole allowance as address space: only the pages written get committed.
        guard let output = AVScratchBuffer(capacity: min(cap, Int.max - 1) + 1) else {
            return Output(data: Data(), consumed: 0, complete: false, hitLimit: false, damaged: true)
        }
        let capacity = output.capacity
        var produced = 0
        var complete = false, hitLimit = false, damaged = false

        let inputBase = input.base.map { UnsafeMutablePointer(mutating: $0.assumingMemoryBound(to: Bytef.self)) }
        var remainingInput = input.count
        var offset = 0
        // zlib's avail_in and avail_out are 32-bit; feed and drain in slices.
        let maxSlice = Int(UInt32.max / 2)

        loop: while true {
            if stream.avail_in == 0, remainingInput > 0, let inputBase {
                let slice = min(remainingInput, maxSlice)
                stream.next_in = inputBase + offset
                stream.avail_in = uInt(slice)
                offset += slice
                remainingInput -= slice
            }
            if produced == capacity { hitLimit = true; break }
            stream.next_out = output.base.assumingMemoryBound(to: Bytef.self) + produced
            stream.avail_out = uInt(min(capacity - produced, maxSlice))
            let outBefore = stream.avail_out
            let inBefore = stream.avail_in
            let status = zlib.inflate(&stream, Z_NO_FLUSH)
            produced += Int(outBefore - stream.avail_out)
            switch status {
            case Z_STREAM_END:
                complete = true
                break loop
            case Z_OK, Z_BUF_ERROR:
                let progressed = stream.avail_out != outBefore || stream.avail_in != inBefore
                if stream.avail_out == 0 { continue } // more room needed (or the limit was reached)
                if stream.avail_in == 0 && remainingInput > 0 { continue } // feed the next slice
                if !progressed || (stream.avail_in == 0 && remainingInput == 0) {
                    // The input ended before the stream did (truncated) or zlib is stuck.
                    damaged = true
                    break loop
                }
            default:
                damaged = true
                break loop
            }
        }

        if produced > cap {
            produced = cap
            hitLimit = true
            complete = false
        }
        let consumed = offset - Int(stream.avail_in)
        output.setCount(produced)
        let data = output.data()
        return Output(data: data, consumed: consumed, complete: complete, hitLimit: hitLimit, damaged: damaged && !hitLimit)
    }
}

extension AVInflate {
    /// Finds where a stream ends without keeping its output: inflates into a small scratch
    /// buffer. Returns nil when the stream is damaged or would produce more than `outputLimit`.
    static func measure(_ input: AVByteView, wrapper: Wrapper, outputLimit: Int) -> (consumed: Int, produced: Int)? {
        guard let inputBase = input.base else { return nil }
        var stream = z_stream()
        guard inflateInit2_(&stream, wrapper.windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        let scratchSize = 256 * 1024
        let scratch = UnsafeMutablePointer<Bytef>.allocate(capacity: scratchSize)
        defer { scratch.deallocate() }
        stream.next_in = UnsafeMutablePointer(mutating: inputBase.assumingMemoryBound(to: Bytef.self))
        stream.avail_in = uInt(min(input.count, Int(UInt32.max / 2)))
        var produced = 0
        while true {
            stream.next_out = scratch
            stream.avail_out = uInt(scratchSize)
            let inBefore = stream.avail_in
            let status = zlib.inflate(&stream, Z_NO_FLUSH)
            let made = scratchSize - Int(stream.avail_out)
            produced += made
            if produced > outputLimit { return nil }
            if status == Z_STREAM_END {
                return (Int(stream.total_in), produced)
            }
            guard status == Z_OK || status == Z_BUF_ERROR, made > 0 || stream.avail_in != inBefore else { return nil }
        }
    }
}

/// Raw DEFLATE compression (used to store signature names compactly).
enum AVDeflate {
    static func compress(_ input: [UInt8], level: Int32 = 6) -> [UInt8]? {
        var stream = z_stream()
        guard deflateInit2_(&stream, level, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { deflateEnd(&stream) }
        let bound = Int(deflateBound(&stream, uLong(input.count)))
        var output = [UInt8](repeating: 0, count: max(bound, 64))
        let status: Int32 = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                stream.next_in = UnsafeMutablePointer(mutating: source.baseAddress)
                stream.avail_in = uInt(source.count)
                stream.next_out = destination.baseAddress
                stream.avail_out = uInt(destination.count)
                return zlib.deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { return nil }
        output.removeSubrange(Int(stream.total_out)...)
        return output
    }
}

/// CRC-32 (IEEE), via zlib.
enum AVCRC32 {
    static func checksum(_ view: AVByteView) -> UInt32 {
        guard let base = view.base else { return 0 }
        var crc = zlib.crc32(0, nil, 0)
        var offset = 0
        while offset < view.count {
            let chunk = min(view.count - offset, 1 << 30)
            crc = zlib.crc32(crc, base.assumingMemoryBound(to: Bytef.self) + offset, uInt(chunk))
            offset += chunk
        }
        return UInt32(truncatingIfNeeded: crc)
    }
}
