import Foundation

/// Entry point and sections of an executable, as ClamAV's `EP`, `Sx`, `SEx` and `SL` offsets
/// and the `EntryPoint`/`NumberOfSections` target conditions see them.
struct AVExecutableInfo: Sendable {
    struct Section: Sendable, Hashable {
        /// Virtual address (RVA for PE).
        var virtualAddress: UInt64
        var virtualSize: UInt64
        /// File offset and size of the section's data.
        var rawOffset: Int
        var rawSize: Int
    }

    /// File offset of the entry point.
    var entryPoint: Int?
    var sections: [Section] = []
    /// PE only: 32-bit (PE32) image. ClamAV applies PE section hash signatures only to these.
    var isPE32 = false

    /// Parses `data` according to `kind`; nil when the headers are invalid.
    static func parse(_ data: AVByteView, kind: AVFileKind) -> AVExecutableInfo? {
        switch kind {
        case .pe: return parsePE(data)
        case .elf: return parseELF(data)
        case .machO: return parseMachO(data)
        default: return nil
        }
    }

    // MARK: PE

    /// PE/COFF: DOS header → `PE\0\0` at e_lfanew → COFF header → optional header → section table.
    /// Section file offsets are aligned down to FileAlignment (as the Windows loader does) when
    /// it's a power of two of at least 512; sizes are clipped to the file.
    static func parsePE(_ d: AVByteView) -> AVExecutableInfo? {
        guard d.matches([0x4D, 0x5A], at: 0), let lfanew = d.u32le(0x3C).map(Int.init),
              d.matches([0x50, 0x45, 0, 0], at: lfanew),
              let sectionCount = d.u16le(lfanew + 6).map(Int.init),
              let optionalSize = d.u16le(lfanew + 20).map(Int.init) else { return nil }
        let optional = lfanew + 24
        guard let magic = d.u16le(optional), magic == 0x10B || magic == 0x20B,
              let entryRVA = d.u32le(optional + 16),
              let sectionAlignment = d.u32le(optional + 32), let fileAlignment = d.u32le(optional + 36) else { return nil }
        var info = AVExecutableInfo()
        info.isPE32 = magic == 0x10B
        let validFileAlignment = fileAlignment >= 512 && fileAlignment.nonzeroBitCount == 1
        let validSectionAlignment = sectionAlignment >= 1 && sectionAlignment.nonzeroBitCount == 1
        var table = optional + optionalSize
        for _ in 0..<min(sectionCount, 96) {
            guard let virtualSize = d.u32le(table + 8), let virtualAddress = d.u32le(table + 12),
                  let rawSize = d.u32le(table + 16), let rawPointer = d.u32le(table + 20) else { break }
            var raw = Int(rawPointer)
            if validFileAlignment { raw = raw / Int(fileAlignment) * Int(fileAlignment) }
            var size = Int(rawSize)
            if raw >= d.count { size = 0 } else if size > d.count - raw { size = d.count - raw }
            var rva = UInt64(virtualAddress)
            if validSectionAlignment { rva = rva / UInt64(sectionAlignment) * UInt64(sectionAlignment) }
            info.sections.append(Section(virtualAddress: rva, virtualSize: UInt64(virtualSize == 0 ? rawSize : virtualSize),
                                         rawOffset: raw, rawSize: size))
            table += 40
        }
        info.entryPoint = peRawAddress(UInt64(entryRVA), info.sections, headerEnd: table, fileSize: d.count)
        return info
    }

    private static func peRawAddress(_ rva: UInt64, _ sections: [Section], headerEnd: Int, fileSize: Int) -> Int? {
        let firstSection = sections.map(\.virtualAddress).min() ?? UInt64.max
        if rva < firstSection {
            return rva < UInt64(fileSize) ? Int(rva) : nil
        }
        for section in sections where section.rawSize > 0 || section.virtualSize > 0 {
            let span = max(section.virtualSize, UInt64(section.rawSize))
            if rva >= section.virtualAddress, rva - section.virtualAddress < span {
                let raw = UInt64(section.rawOffset) + (rva - section.virtualAddress)
                return raw < UInt64(fileSize) ? Int(raw) : nil
            }
        }
        return nil
    }

    // MARK: ELF

    /// ELF: entry point converted to a file offset through the PT_LOAD program headers; sections
    /// from the section header table.
    static func parseELF(_ d: AVByteView) -> AVExecutableInfo? {
        guard d.matches([0x7F, 0x45, 0x4C, 0x46], at: 0), let elfClass = d.u8(4), let encoding = d.u8(5),
              elfClass == 1 || elfClass == 2, encoding == 1 || encoding == 2 else { return nil }
        let is64 = elfClass == 2
        let big = encoding == 2
        func half(_ o: Int) -> Int? { d.u16(o, bigEndian: big).map(Int.init) }
        func word(_ o: Int) -> UInt64? { d.u32(o, bigEndian: big).map(UInt64.init) }
        func address(_ o: Int) -> UInt64? { is64 ? d.u64(o, bigEndian: big) : word(o) }
        guard let entry = address(24) else { return nil }
        let phoff = is64 ? d.u64(32, bigEndian: big) : word(28)
        let shoff = is64 ? d.u64(40, bigEndian: big) : word(32)
        let base = is64 ? 52 : 40
        guard let phoff = phoff.flatMap({ Int(exactly: $0) }), let shoff = shoff.flatMap({ Int(exactly: $0) }),
              let phentsize = half(base + 2), let phnum = half(base + 4),
              let shentsize = half(base + 6), let shnum = half(base + 8) else { return nil }
        var info = AVExecutableInfo()
        if phnum > 0, phentsize >= (is64 ? 56 : 32), phoff < d.count {
            for index in 0..<min(phnum, 256) {
                let header = phoff + index * phentsize
                guard d.contains(offset: header, length: phentsize), let type = word(header) else { break }
                guard type == 1 else { continue } // PT_LOAD
                let offset = is64 ? d.u64(header + 8, bigEndian: big) : word(header + 4)
                let vaddr = is64 ? d.u64(header + 16, bigEndian: big) : word(header + 8)
                let filesz = is64 ? d.u64(header + 32, bigEndian: big) : word(header + 16)
                guard let offset, let vaddr, let filesz else { continue }
                if entry >= vaddr, entry - vaddr < filesz, offset <= UInt64(Int.max) {
                    let raw = offset + (entry - vaddr)
                    if raw < UInt64(d.count) { info.entryPoint = Int(raw) }
                    break
                }
            }
        }
        if shnum > 0, shentsize >= (is64 ? 64 : 40), shoff < d.count {
            for index in 0..<min(shnum, 4096) {
                let header = shoff + index * shentsize
                guard d.contains(offset: header, length: shentsize), let type = word(header + 4) else { break }
                let addr = is64 ? d.u64(header + 16, bigEndian: big) : word(header + 12)
                let offset = is64 ? d.u64(header + 24, bigEndian: big) : word(header + 16)
                let size = is64 ? d.u64(header + 32, bigEndian: big) : word(header + 20)
                guard let addr, let offset, let size else { break }
                let raw = offset < UInt64(d.count) ? Int(offset) : d.count
                // SHT_NOBITS (.bss) occupies no file space.
                let rawSize = type == 8 ? 0 : Int(min(size, UInt64(d.count - raw)))
                info.sections.append(Section(virtualAddress: addr, virtualSize: size, rawOffset: raw, rawSize: rawSize))
            }
        }
        return info
    }

    // MARK: Mach-O

    /// Mach-O (thin): sections of every LC_SEGMENT/LC_SEGMENT_64 in load order; the entry point
    /// from LC_MAIN (a file offset) or the program counter of LC_UNIXTHREAD.
    static func parseMachO(_ d: AVByteView) -> AVExecutableInfo? {
        guard let magic = d.u32le(0) else { return nil }
        let is64: Bool, big: Bool
        switch magic {
        case 0xFEED_FACE: is64 = false; big = false
        case 0xFEED_FACF: is64 = true; big = false
        case 0xCEFA_EDFE: is64 = false; big = true
        case 0xCFFA_EDFE: is64 = true; big = true
        default: return nil
        }
        func u32(_ o: Int) -> UInt32? { d.u32(o, bigEndian: big) }
        func u64(_ o: Int) -> UInt64? { d.u64(o, bigEndian: big) }
        guard let cpuType = u32(4), let commandCount = u32(16).map(Int.init), let commandsSize = u32(20).map(Int.init) else { return nil }
        var info = AVExecutableInfo()
        var segments = [(vmaddr: UInt64, fileoff: UInt64, filesize: UInt64)]()
        var threadPC: UInt64?
        var mainOffset: UInt64?
        var cursor = is64 ? 32 : 28
        let end = cursor + commandsSize
        for _ in 0..<min(commandCount, 4096) {
            guard cursor + 8 <= end, let command = u32(cursor), let size = u32(cursor + 4).map(Int.init), size >= 8,
                  d.contains(offset: cursor, length: size) else { break }
            switch command {
            case 0x1, 0x19: // LC_SEGMENT, LC_SEGMENT_64
                let segment64 = command == 0x19
                let vmaddr = segment64 ? u64(cursor + 24) : u32(cursor + 24).map(UInt64.init)
                let fileoff = segment64 ? u64(cursor + 40) : u32(cursor + 32).map(UInt64.init)
                let filesize = segment64 ? u64(cursor + 48) : u32(cursor + 36).map(UInt64.init)
                let sectionCount = (segment64 ? u32(cursor + 64) : u32(cursor + 48)).map(Int.init) ?? 0
                if let vmaddr, let fileoff, let filesize { segments.append((vmaddr, fileoff, filesize)) }
                var section = cursor + (segment64 ? 72 : 56)
                let sectionSize = segment64 ? 80 : 68
                for _ in 0..<min(sectionCount, 1024) {
                    guard section + sectionSize <= cursor + size else { break }
                    let addr = segment64 ? u64(section + 32) : u32(section + 32).map(UInt64.init)
                    let length = segment64 ? u64(section + 40) : u32(section + 36).map(UInt64.init)
                    let offset = segment64 ? u32(section + 48) : u32(section + 40)
                    let flags = segment64 ? u32(section + 64) : u32(section + 56)
                    guard let addr, let length, let offset, let flags else { break }
                    let zeroFill = flags & 0xFF == 1 || flags & 0xFF == 0x0C || flags & 0xFF == 0x12 // S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL
                    let raw = min(Int(offset), d.count)
                    let rawSize = zeroFill || offset == 0 ? 0 : Int(min(length, UInt64(d.count - raw)))
                    info.sections.append(Section(virtualAddress: addr, virtualSize: length, rawOffset: raw, rawSize: rawSize))
                    section += sectionSize
                }
            case 0x8000_0028: // LC_MAIN: entryoff is a file offset
                mainOffset = u64(cursor + 8)
            case 0x5, 0x4: // LC_UNIXTHREAD, LC_THREAD
                threadPC = threadProgramCounter(d, cursor + 8, cursor + size, cpuType: cpuType, big: big)
            default:
                break
            }
            cursor += size
        }
        if let mainOffset, mainOffset < UInt64(d.count) {
            info.entryPoint = Int(mainOffset)
        } else if let threadPC {
            for segment in segments where threadPC >= segment.vmaddr && threadPC - segment.vmaddr < segment.filesize {
                let raw = segment.fileoff + (threadPC - segment.vmaddr)
                if raw < UInt64(d.count) { info.entryPoint = Int(raw) }
                break
            }
        }
        return info
    }

    /// Program counter in an LC_UNIXTHREAD thread state (flavor, count, registers...).
    private static func threadProgramCounter(_ d: AVByteView, _ start: Int, _ end: Int, cpuType: UInt32, big: Bool) -> UInt64? {
        guard let flavor = d.u32(start, bigEndian: big) else { return nil }
        let registers = start + 8
        func reg64(_ index: Int) -> UInt64? { registers + index * 8 + 8 <= end ? d.u64(registers + index * 8, bigEndian: big) : nil }
        func reg32(_ index: Int) -> UInt64? { registers + index * 4 + 4 <= end ? d.u32(registers + index * 4, bigEndian: big).map(UInt64.init) : nil }
        switch (cpuType, flavor) {
        case (0x0100_0007, 4): return reg64(16)   // x86_THREAD_STATE64: rip
        case (7, 1): return reg32(10)             // i386_THREAD_STATE: eip
        case (0x0100_000C, 6): return reg64(32)   // ARM_THREAD_STATE64: pc
        case (12, 1): return reg32(15)            // ARM_THREAD_STATE: pc
        case (18, 1): return reg32(0)             // PPC_THREAD_STATE: srr0
        case (0x0100_0012, 5): return reg64(0)    // PPC_THREAD_STATE64: srr0
        default: return nil
        }
    }
}
