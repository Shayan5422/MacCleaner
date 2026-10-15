import Darwin
import Foundation

/// The kind of a filesystem object, as reported by the kernel (`fsobj_type_t`).
enum FileObjectType: UInt8, Sendable, Codable, Hashable {
    case regular
    case directory
    case symlink
    case other

    init(vnodeType: UInt32) {
        switch vnodeType {
        case 1: self = .regular      // VREG
        case 2: self = .directory    // VDIR
        case 5: self = .symlink      // VLNK
        default: self = .other
        }
    }

    init(mode: mode_t) {
        switch mode & S_IFMT {
        case S_IFREG: self = .regular
        case S_IFDIR: self = .directory
        case S_IFLNK: self = .symlink
        default: self = .other
        }
    }
}

/// Uniquely identifies an inode on a mounted volume (`st_dev` + `st_ino`).
struct FileIdentity: Hashable, Sendable, Codable {
    var device: Int32
    var inode: UInt64
}

/// Metadata for one directory entry, read in bulk with `getattrlistbulk(2)`.
///
/// Reading attributes in bulk is several times faster than `stat`-ing every
/// entry or using `FileManager` enumerators, which matters when walking
/// millions of files. It also exposes APFS clone information
/// (`ATTR_CMNEXT_PRIVATESIZE`) that is otherwise unavailable, so clones are
/// not counted twice when estimating reclaimable space.
struct RawDirectoryEntry: Sendable {
    var name: String
    var type: FileObjectType
    var device: Int32
    var inode: UInt64
    var linkCount: UInt32
    /// Logical length of all forks, in bytes.
    var logicalSize: Int64
    /// Bytes allocated on disk for all forks (includes blocks shared with clones).
    var allocatedSize: Int64
    /// Bytes that belong exclusively to this file (not shared with an APFS clone).
    /// `nil` when the filesystem does not report it.
    var privateSize: Int64?
    /// Identifies the APFS clone family this file's data belongs to, if any.
    var cloneID: UInt64?
    /// Number of files in this entry's clone family (1 when not cloned).
    var cloneReferenceCount: UInt32
    /// `true` when APFS reports that the file may share blocks with clones.
    var mayShareBlocks: Bool
    /// BSD file flags (`st_flags`): `UF_HIDDEN`, `UF_COMPRESSED`, `SF_DATALESS`, ...
    var flags: UInt32
    /// Seconds since 1970.
    var modificationTime: Double
    /// Seconds since 1970. May be stale on volumes mounted with `noatime`.
    var accessTime: Double
    /// Non-zero when the kernel could not read this entry's attributes.
    var error: Int32

    var identity: FileIdentity { FileIdentity(device: device, inode: inode) }

    /// The file's contents live in the cloud and are not stored locally
    /// (iCloud Drive or a File Provider placeholder). Reading it would trigger a download.
    var isDataless: Bool { flags & FileFlags.dataless != 0 }
    var isHiddenFlagSet: Bool { flags & FileFlags.hidden != 0 }
    var isCompressed: Bool { flags & FileFlags.compressed != 0 }

    /// Conservative estimate of the space that deleting this file alone would free.
    var exclusiveAllocatedSize: Int64 {
        if mayShareBlocks, let privateSize { return min(privateSize, allocatedSize) }
        return allocatedSize
    }
}

/// BSD file flags that matter to the scanner (from `<sys/stat.h>`).
enum FileFlags {
    static let hidden: UInt32 = 0x0000_8000       // UF_HIDDEN
    static let compressed: UInt32 = 0x0000_0020   // UF_COMPRESSED
    static let immutable: UInt32 = 0x0000_0002    // UF_IMMUTABLE
    static let systemImmutable: UInt32 = 0x0002_0000 // SF_IMMUTABLE
    static let restricted: UInt32 = 0x0008_0000   // SF_RESTRICTED (SIP)
    static let dataless: UInt32 = 0x4000_0000     // SF_DATALESS
}

/// Low-level bulk directory reader built on `getattrlistbulk(2)`.
enum BulkDirectoryReader {
    // Attribute bits from <sys/attr.h>. Declared locally because several of
    // them don't fit in Int32 and import with inconsistent types.
    private static let cmnName: UInt32 = 0x0000_0001
    private static let cmnDevID: UInt32 = 0x0000_0002
    private static let cmnObjType: UInt32 = 0x0000_0008
    private static let cmnModTime: UInt32 = 0x0000_0400
    private static let cmnAccTime: UInt32 = 0x0000_1000
    private static let cmnFlags: UInt32 = 0x0004_0000
    private static let cmnFileID: UInt32 = 0x0200_0000
    private static let cmnError: UInt32 = 0x2000_0000
    private static let cmnReturnedAttrs: UInt32 = 0x8000_0000

    private static let fileLinkCount: UInt32 = 0x0000_0001
    private static let fileTotalSize: UInt32 = 0x0000_0002
    private static let fileAllocSize: UInt32 = 0x0000_0004

    private static let extPrivateSize: UInt32 = 0x0000_0008
    private static let extCloneID: UInt32 = 0x0000_0100
    private static let extFlags: UInt32 = 0x0000_0200
    private static let extCloneRefCount: UInt32 = 0x0000_1000

    private static let optAttrCmnExtended: UInt64 = 0x0000_0020 // FSOPT_ATTR_CMN_EXTENDED
    private static let extFlagMayShareBlocks: UInt64 = 0x0000_0001 // EF_MAY_SHARE_BLOCKS

    /// Recommended size of the scratch buffer passed to `forEachEntry`.
    static let recommendedBufferSize = 128 * 1024

    /// Some filesystems reject the extended (`ATTR_CMNEXT_*`) attributes.
    /// After the first `EINVAL` we stop requesting them for that device.
    private static let extendedUnsupportedDevices = DeviceSet()

    /// Calls `body` for every entry of the open directory `fd`.
    ///
    /// - Parameters:
    ///   - fd: A descriptor opened with `O_RDONLY | O_DIRECTORY`.
    ///   - device: The directory's device, used to remember filesystems without extended attributes.
    ///   - buffer: Scratch memory of at least `recommendedBufferSize` bytes, reused between calls.
    static func forEachEntry(
        directoryFD fd: Int32,
        device: Int32,
        buffer: UnsafeMutableRawBufferPointer,
        _ body: (RawDirectoryEntry) throws -> Void
    ) throws {
        var useExtended = !extendedUnsupportedDevices.contains(device)

        while true {
            var request = attrlist()
            request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            request.commonattr = cmnReturnedAttrs | cmnName | cmnError | cmnDevID | cmnObjType
                | cmnModTime | cmnAccTime | cmnFlags | cmnFileID
            request.fileattr = fileLinkCount | fileTotalSize | fileAllocSize
            request.forkattr = useExtended ? (extPrivateSize | extCloneID | extFlags | extCloneRefCount) : 0
            let options: UInt64 = useExtended ? optAttrCmnExtended : 0

            let count = getattrlistbulk(fd, &request, buffer.baseAddress, buffer.count, options)
            if count == 0 { return }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                if code == EINVAL && useExtended {
                    // The filesystem doesn't understand ATTR_CMNEXT_*; retry without them.
                    extendedUnsupportedDevices.insert(device)
                    useExtended = false
                    // getattrlistbulk keeps its position in the directory, but nothing
                    // has been consumed by a failed call, so retrying is safe.
                    continue
                }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }

            guard let base = buffer.baseAddress else { return }
            var entryStart = UnsafeRawPointer(base)
            for _ in 0..<Int(count) {
                let length = Int(entryStart.loadUnaligned(as: UInt32.self))
                guard length > 0 else { break }
                if let entry = parseEntry(at: entryStart, length: length) {
                    try body(entry)
                }
                entryStart += length
            }
        }
    }

    /// Reads the same attributes for a single path without following a final symlink.
    /// Returns nil if the item doesn't exist or can't be read.
    static func readAttributes(path: String) -> RawDirectoryEntry? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = cmnReturnedAttrs | cmnName | cmnDevID | cmnObjType
            | cmnModTime | cmnAccTime | cmnFlags | cmnFileID
        request.fileattr = fileLinkCount | fileTotalSize | fileAllocSize
        request.forkattr = extPrivateSize | extCloneID | extFlags | extCloneRefCount
        let noFollow: UInt64 = 0x0000_0001 // FSOPT_NOFOLLOW
        let size = 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }

        var result = getattrlist(path, &request, buffer, size, UInt32(noFollow | optAttrCmnExtended))
        if result != 0 && errno == EINVAL {
            request.forkattr = 0
            result = getattrlist(path, &request, buffer, size, UInt32(noFollow))
        }
        guard result == 0 else { return nil }
        let length = Int(buffer.loadUnaligned(as: UInt32.self))
        guard var entry = parseEntry(at: UnsafeRawPointer(buffer), length: length, requireName: false) else { return nil }
        if entry.name.isEmpty { entry.name = (path as NSString).lastPathComponent }
        return entry
    }

    private static func parseEntry(at start: UnsafeRawPointer, length: Int, requireName: Bool = true) -> RawDirectoryEntry? {
        var field = start + MemoryLayout<UInt32>.size
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += MemoryLayout<attribute_set_t>.size

        var entry = RawDirectoryEntry(
            name: "", type: .other, device: 0, inode: 0, linkCount: 1,
            logicalSize: 0, allocatedSize: 0, privateSize: nil, cloneID: nil,
            cloneReferenceCount: 1, mayShareBlocks: false, flags: 0, modificationTime: 0, accessTime: 0, error: 0
        )

        let common = returned.commonattr
        // ATTR_CMN_ERROR is always packed immediately after the returned-attributes set.
        if common & cmnError != 0 {
            entry.error = Int32(bitPattern: field.loadUnaligned(as: UInt32.self))
            field += MemoryLayout<UInt32>.size
        }
        if common & cmnName != 0 {
            let reference = field.loadUnaligned(as: attrreference_t.self)
            let nameStart = field + Int(reference.attr_dataoffset)
            let nameLength = Int(reference.attr_length) // includes the trailing NUL
            if nameLength > 1, nameStart + nameLength <= start + length {
                let bytes = UnsafeRawBufferPointer(start: nameStart, count: nameLength - 1)
                entry.name = String(decoding: bytes, as: UTF8.self)
            }
            field += MemoryLayout<attrreference_t>.size
        }
        if common & cmnDevID != 0 {
            entry.device = field.loadUnaligned(as: Int32.self)
            field += MemoryLayout<Int32>.size
        }
        if common & cmnObjType != 0 {
            entry.type = FileObjectType(vnodeType: field.loadUnaligned(as: UInt32.self))
            field += MemoryLayout<UInt32>.size
        }
        if common & cmnModTime != 0 {
            entry.modificationTime = seconds(field.loadUnaligned(as: timespec.self))
            field += MemoryLayout<timespec>.size
        }
        if common & cmnAccTime != 0 {
            entry.accessTime = seconds(field.loadUnaligned(as: timespec.self))
            field += MemoryLayout<timespec>.size
        }
        if common & cmnFlags != 0 {
            entry.flags = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
        }
        if common & cmnFileID != 0 {
            entry.inode = field.loadUnaligned(as: UInt64.self)
            field += MemoryLayout<UInt64>.size
        }

        let file = returned.fileattr
        if file & fileLinkCount != 0 {
            entry.linkCount = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
        }
        if file & fileTotalSize != 0 {
            entry.logicalSize = field.loadUnaligned(as: Int64.self)
            field += MemoryLayout<Int64>.size
        }
        if file & fileAllocSize != 0 {
            entry.allocatedSize = field.loadUnaligned(as: Int64.self)
            field += MemoryLayout<Int64>.size
        }

        let extended = returned.forkattr
        if extended & extPrivateSize != 0 {
            entry.privateSize = field.loadUnaligned(as: Int64.self)
            field += MemoryLayout<Int64>.size
        }
        if extended & extCloneID != 0 {
            let cloneID = field.loadUnaligned(as: UInt64.self)
            entry.cloneID = cloneID == 0 ? nil : cloneID
            field += MemoryLayout<UInt64>.size
        }
        if extended & extFlags != 0 {
            let flags = field.loadUnaligned(as: UInt64.self)
            entry.mayShareBlocks = flags & extFlagMayShareBlocks != 0
            field += MemoryLayout<UInt64>.size
        }
        if extended & extCloneRefCount != 0 {
            entry.cloneReferenceCount = max(1, field.loadUnaligned(as: UInt32.self))
            field += MemoryLayout<UInt32>.size
        }

        if requireName {
            guard !entry.name.isEmpty, entry.name != ".", entry.name != ".." else { return nil }
        }
        return entry
    }

    private static func seconds(_ time: timespec) -> Double {
        Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }
}

/// A tiny lock-protected set of device numbers.
private final class DeviceSet: @unchecked Sendable {
    private var devices = Set<Int32>()
    private let lock = NSLock()

    func contains(_ device: Int32) -> Bool {
        lock.withLock { devices.contains(device) }
    }

    func insert(_ device: Int32) {
        _ = lock.withLock { devices.insert(device) }
    }
}
