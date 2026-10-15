import Darwin
import Foundation

/// Permanently removes files and folders using descriptor-relative system calls.
///
/// Unlike path-based recursive deletion, every step goes through an open
/// directory descriptor (`openat`/`unlinkat` with `O_NOFOLLOW`), so a folder
/// that is swapped for a symbolic link mid-way can never redirect deletion
/// elsewhere. Mount points are never crossed.
enum SafeRemover {
    struct Failure: Sendable, Hashable {
        var path: String
        var code: Int32
        var message: String { String(cString: strerror(code)) }
    }

    struct Result: Sendable {
        /// Allocated bytes of removed files that no other hard link still references.
        var bytesFreed: Int64 = 0
        var itemsRemoved: Int = 0
        var failures: [Failure] = []
        var removedRoot = false
    }

    enum RemovalError: LocalizedError {
        case missing
        case changed
        case cannotOpenParent(Int32)
        case partial(Result)

        var errorDescription: String? {
            switch self {
            case .missing: return "The item no longer exists."
            case .changed: return "The item changed after it was scanned, so it was left untouched."
            case .cannotOpenParent(let code): return "Couldn't open the enclosing folder: \(String(cString: strerror(code)))."
            case .partial(let result):
                let first = result.failures.first.map { " First problem: \(PathUtilities.abbreviate($0.path)) — \($0.message)." } ?? ""
                return "Some items couldn't be removed (\(result.failures.count)).\(first)"
            }
        }
    }

    private static let openNoFollowAny: Int32 = 0x2000_0000 // O_NOFOLLOW_ANY (macOS 11+)
    private static let maximumDepth = 1024

    /// Removes `path`. If `expected` is given, the item must still have that identity.
    @discardableResult
    static func remove(path: String, expected: FileSnapshot?) throws -> Result {
        let parentPath = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { throw RemovalError.missing }

        // O_NOFOLLOW_ANY refuses a symlink in any component of the parent path.
        let parentFD = open(parentPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | openNoFollowAny)
        guard parentFD >= 0 else {
            if errno == ENOENT { throw RemovalError.missing }
            throw RemovalError.cannotOpenParent(errno)
        }
        defer { close(parentFD) }

        var info = stat()
        guard fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { throw RemovalError.missing }
            throw RemovalError.cannotOpenParent(errno)
        }
        let current = FileSnapshot(identity: FileIdentity(device: info.st_dev, inode: UInt64(info.st_ino)), type: FileObjectType(mode: info.st_mode))
        if let expected, expected != current { throw RemovalError.changed }

        var result = Result()
        if current.type != .directory {
            if unlinkat(parentFD, name, 0) == 0 {
                result.itemsRemoved = 1
                result.removedRoot = true
                if info.st_nlink <= 1 { result.bytesFreed = Int64(info.st_blocks) * 512 }
            } else {
                result.failures.append(Failure(path: path, code: errno))
                throw RemovalError.partial(result)
            }
            return result
        }

        removeDirectory(parentFD: parentFD, name: name, path: path, expected: info, result: &result)
        if !result.failures.isEmpty { throw RemovalError.partial(result) }
        return result
    }

    private struct Frame {
        var fd: Int32
        var name: String
        var path: String
        var entries: [RawDirectoryEntry]
        var index = 0
        var hadFailure = false
    }

    private static func removeDirectory(parentFD: Int32, name: String, path: String, expected: stat, result: inout Result) {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: BulkDirectoryReader.recommendedBufferSize, alignment: 16)
        defer { buffer.deallocate() }
        let device = expected.st_dev

        func openVerified(_ dirFD: Int32, _ childName: String, inode: UInt64) -> Int32? {
            let fd = openat(dirFD, childName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            var opened = stat()
            // The folder must be the one we listed and on the same volume.
            guard fstat(fd, &opened) == 0, UInt64(opened.st_ino) == inode, opened.st_dev == device else {
                close(fd)
                errno = EBUSY
                return nil
            }
            return fd
        }

        func readEntries(_ fd: Int32) -> [RawDirectoryEntry]? {
            var entries: [RawDirectoryEntry] = []
            do {
                try BulkDirectoryReader.forEachEntry(directoryFD: fd, device: device, buffer: buffer) { entries.append($0) }
                return entries
            } catch {
                return nil
            }
        }

        guard let rootFD = openVerified(parentFD, name, inode: UInt64(expected.st_ino)) else {
            result.failures.append(Failure(path: path, code: errno))
            return
        }
        guard let rootEntries = readEntries(rootFD) else {
            result.failures.append(Failure(path: path, code: errno))
            close(rootFD)
            return
        }

        var stack = [Frame(fd: rootFD, name: name, path: path, entries: rootEntries)]
        while !stack.isEmpty {
            let top = stack.count - 1
            if stack[top].index < stack[top].entries.count {
                let child = stack[top].entries[stack[top].index]
                stack[top].index += 1
                let childPath = PathUtilities.join(stack[top].path, child.name)

                if child.type == .directory {
                    if child.device != 0 && child.device != device {
                        // Another volume is mounted here; never delete into it.
                        stack[top].hadFailure = true
                        result.failures.append(Failure(path: childPath, code: EXDEV))
                        continue
                    }
                    guard stack.count < maximumDepth else {
                        stack[top].hadFailure = true
                        result.failures.append(Failure(path: childPath, code: ELOOP))
                        continue
                    }
                    guard let fd = openVerified(stack[top].fd, child.name, inode: child.inode) else {
                        stack[top].hadFailure = true
                        result.failures.append(Failure(path: childPath, code: errno))
                        continue
                    }
                    guard let entries = readEntries(fd) else {
                        let code = errno
                        close(fd)
                        stack[top].hadFailure = true
                        result.failures.append(Failure(path: childPath, code: code))
                        continue
                    }
                    stack.append(Frame(fd: fd, name: child.name, path: childPath, entries: entries))
                } else {
                    if unlinkat(stack[top].fd, child.name, 0) == 0 {
                        result.itemsRemoved += 1
                        if child.linkCount <= 1 { result.bytesFreed += child.exclusiveAllocatedSize }
                    } else {
                        stack[top].hadFailure = true
                        result.failures.append(Failure(path: childPath, code: errno))
                    }
                }
            } else {
                let frame = stack.removeLast()
                close(frame.fd)
                let enclosingFD = stack.last?.fd ?? parentFD
                if frame.hadFailure {
                    // Keep the folder; its remaining contents couldn't be removed.
                    if let index = stack.indices.last { stack[index].hadFailure = true }
                    continue
                }
                if unlinkat(enclosingFD, frame.name, AT_REMOVEDIR) == 0 {
                    result.itemsRemoved += 1
                    if stack.isEmpty { result.removedRoot = true }
                } else {
                    result.failures.append(Failure(path: frame.path, code: errno))
                    if let index = stack.indices.last { stack[index].hadFailure = true }
                }
            }
        }
    }
}
