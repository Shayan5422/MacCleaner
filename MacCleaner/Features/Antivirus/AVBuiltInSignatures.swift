import CryptoKit
import Darwin
import Foundation

/// The EICAR standard antivirus test file: a harmless 68-byte text that every antivirus
/// reports, used by "Test Protection". It is stored masked so the app's own binary never
/// contains it verbatim (other scanners would otherwise flag Mac Cleaner itself).
enum AVEICAR {
    static let signatureName = "Eicar-Test-Signature"

    private static let mask: UInt8 = 0xA5
    private static let masked: [UInt8] = [
        0xFD, 0x90, 0xEA, 0x84, 0xF5, 0x80, 0xE5, 0xE4, 0xF5, 0xFE, 0x91, 0xF9,
        0xF5, 0xFF, 0xFD, 0x90, 0x91, 0x8D, 0xF5, 0xFB, 0x8C, 0x92, 0xE6, 0xE6,
        0x8C, 0x92, 0xD8, 0x81, 0xE0, 0xEC, 0xE6, 0xE4, 0xF7, 0x88, 0xF6, 0xF1,
        0xE4, 0xEB, 0xE1, 0xE4, 0xF7, 0xE1, 0x88, 0xE4, 0xEB, 0xF1, 0xEC, 0xF3,
        0xEC, 0xF7, 0xF0, 0xF6, 0x88, 0xF1, 0xE0, 0xF6, 0xF1, 0x88, 0xE3, 0xEC,
        0xE9, 0xE0, 0x84, 0x81, 0xED, 0x8E, 0xED, 0x8F,
    ]

    /// The 68 bytes of the test file.
    static var data: Data { Data(masked.map { $0 ^ mask }) }

    /// The official definition: the file starts with the test string and may be followed only
    /// by whitespace, up to 128 bytes in total.
    static func matches(_ bytes: Data) -> Bool {
        let pattern = data
        guard bytes.count >= pattern.count, bytes.count <= 128 else { return false }
        guard bytes.prefix(pattern.count).elementsEqual(pattern) else { return false }
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, 0x1A]
        return bytes.dropFirst(pattern.count).allSatisfy { whitespace.contains($0) }
    }
}

/// SHA-256 of files, read without following symbolic links and without downloading
/// cloud-only files.
enum AVFileHasher {
    static func sha256(path: String, maxBytes: Int64 = .max) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return sha256(descriptor: fd, maxBytes: maxBytes)
    }

    static func sha256(descriptor fd: Int32, maxBytes: Int64 = .max) -> String? {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        if info.st_flags & FileFlags.dataless != 0 { return nil }
        guard Int64(info.st_size) <= maxBytes else { return nil }
        var hasher = SHA256()
        let size = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let count = read(fd, buffer, size)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
        }
        return hex(hasher.finalize())
    }

    static func sha256(data: Data) -> String { hex(SHA256.hash(data: data)) }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Signatures built into the app. They work without downloaded definitions and only detect
/// the EICAR test file, so "Test Protection" works on a fresh install. This is not malware
/// detection, and the interface says so.
struct AVBuiltInScanner: AVFileScanning {
    init() {}

    func scanFile(atPath path: String, options: AVScanOptions) -> AVFileScanResult {
        AVThreadIO.disableCloudDownloads()
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            let code = errno
            if code == ELOOP { return AVFileScanResult(path: path, skipped: .notRegularFile) }
            return AVFileScanResult(path: path, skipped: .unreadable(String(cString: strerror(code))))
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return AVFileScanResult(path: path, skipped: .unreadable(String(cString: strerror(errno)))) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return AVFileScanResult(path: path, skipped: .notRegularFile) }
        if info.st_flags & FileFlags.dataless != 0 { return AVFileScanResult(path: path, skipped: .dataless) }
        if Int64(info.st_size) > options.maxFileSize { return AVFileScanResult(path: path, skipped: .tooLarge) }
        guard info.st_size <= 128 else { return AVFileScanResult(path: path) }

        var buffer = [UInt8](repeating: 0, count: 129)
        let count = read(fd, &buffer, buffer.count)
        guard count >= 0 else { return AVFileScanResult(path: path, skipped: .unreadable(String(cString: strerror(errno)))) }
        let bytes = Data(buffer.prefix(count))
        guard AVEICAR.matches(bytes) else { return AVFileScanResult(path: path, bytesScanned: Int64(count)) }
        let detection = AVDetection(signatureName: AVEICAR.signatureName, kind: .testFile, source: .builtIn, memberPath: nil)
        return AVFileScanResult(path: path, detections: [detection], bytesScanned: Int64(count), sha256: AVFileHasher.sha256(data: bytes))
    }
}

/// Per-thread I/O policy helpers.
enum AVThreadIO {
    /// Makes opening a cloud-only (dataless) file on this thread fail instead of downloading it.
    static func disableCloudDownloads() {
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    }
}
