import CryptoKit
import Darwin
import Foundation

/// An item in the Virus Chest.
struct AVChestItem: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var originalPath: String
    var name: String
    var isDirectory: Bool
    /// Size of the original item.
    var size: Int64
    /// SHA-256 of the detected file.
    var sha256: String?
    var signatureName: String
    var category: AVThreatCategory
    var source: AVDetectionOrigin
    var quarantinedAt: Date
    var originalMode: UInt16
    var originalOwner: UInt32
    var originalGroup: UInt32
    /// Size and SHA-256 of the stored archive (checked before restoring).
    var payloadSize: Int64
    var payloadSHA256: String
    /// The detected file inside, when a whole app was moved.
    var detectedFile: String?
    var downloadURL: String?
}

/// What to move into the Virus Chest.
struct AVQuarantineRequest: Sendable {
    var path: String
    /// Identity recorded when the threat was found; the item must still be the same file.
    var expected: FileSnapshot?
    var signatureName: String
    var category: AVThreatCategory
    var sha256: String?
    var source: AVDetectionOrigin
    var detectedFile: String?
    var downloadURL: String?
}

enum AVChestError: LocalizedError, Equatable {
    case refused(String)
    case needsAdministrator(String)
    case changedSinceScan
    case missing
    case blockedByMacOS(String)
    case destinationExists(String)
    case originalFolderMissing
    case damaged(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .refused(let reason), .needsAdministrator(let reason), .blockedByMacOS(let reason): return reason
        case .changedSinceScan: return "The file changed after it was scanned, so it wasn't moved. Scan it again."
        case .missing: return "The item no longer exists."
        case .destinationExists(let path): return "Something already exists at \(PathUtilities.abbreviate(path))."
        case .originalFolderMissing: return "The original folder no longer exists."
        case .damaged(let detail): return "The stored copy is damaged (\(detail)), so it can't be restored."
        case .failed(let detail): return detail
        }
    }

    /// Show "Reveal in Finder" for these.
    var suggestsFinder: Bool {
        switch self {
        case .needsAdministrator, .blockedByMacOS: return true
        default: return false
        }
    }
}

/// The quarantine vault: items are archived with `ditto` (keeping permissions and extended
/// attributes), stored masked with a per-item key under `quarantine/` (mode 0700) so nothing can
/// run them and other scanners don't keep reporting them, and can be restored or deleted.
actor AVVirusChest {
    let paths: AVPaths
    let policy: AVQuarantinePolicy
    let logger: ActivityLogger

    init(paths: AVPaths, policy: AVQuarantinePolicy = .live(), logger: ActivityLogger = .shared) {
        self.paths = paths
        self.policy = policy
        self.logger = logger
    }

    // MARK: - Listing

    func items() -> [AVChestItem] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.quarantine.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }
            .compactMap { AVJSONFile.load(AVChestItem.self, from: paths.quarantine.appendingPathComponent($0)) }
            .filter { Self.isWellFormed($0) && FileManager.default.fileExists(atPath: payloadURL($0.id).path) }
            .sorted { $0.quarantinedAt > $1.quarantinedAt }
    }

    /// Records the chest wrote itself: a UUID id, a plain file name and an absolute original path.
    /// Anything else (a tampered record naming "../" paths) is ignored, so restoring or deleting
    /// can't act outside the chest or the chosen folder.
    static func isWellFormed(_ item: AVChestItem) -> Bool {
        guard UUID(uuidString: item.id) != nil else { return false }
        func isPlainName(_ name: String) -> Bool {
            !name.isEmpty && !name.contains("/") && name != "." && name != ".." && !name.hasPrefix("..")
        }
        guard isPlainName(item.name), item.originalPath.hasPrefix("/"), !item.originalPath.contains("/../"),
              !item.originalPath.hasSuffix("/..") else { return false }
        return (item.originalPath as NSString).lastPathComponent == item.name
    }

    private func payloadURL(_ id: String) -> URL { paths.quarantine.appendingPathComponent(id + ".mcchest") }
    private func metadataURL(_ id: String) -> URL { paths.quarantine.appendingPathComponent(id + ".json") }

    // MARK: - Quarantine

    func quarantine(_ request: AVQuarantineRequest) async throws -> AVChestItem {
        let path = PathUtilities.normalize(request.path)
        switch policy.evaluate(path) {
        case .allowed: break
        case .refused(let reason): throw AVChestError.refused(reason)
        case .needsAdministrator(let reason): throw AVChestError.needsAdministrator(reason)
        }
        guard let current = FileSnapshot.capture(path: path) else { throw AVChestError.missing }
        if let expected = request.expected, expected != current { throw AVChestError.changedSinceScan }
        var info = stat()
        guard lstat(path, &info) == 0 else { throw AVChestError.missing }
        let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR

        try paths.prepare()
        let work = try paths.makeWorkDirectory("chest")
        defer { try? FileManager.default.removeItem(at: work) }
        let name = (path as NSString).lastPathComponent
        let staged = work.appendingPathComponent(name)
        let size = isDirectory ? AVPaths.diskUsage(of: URL(fileURLWithPath: path)) : Int64(info.st_size)

        // Same volume: an atomic move takes the item out of place at once.
        var movedAway = false
        if rename(path, staged.path) == 0 {
            movedAway = true
            guard FileSnapshot.capture(path: staged.path)?.identity == current.identity else {
                _ = renamex_np(staged.path, path, UInt32(RENAME_EXCL))
                throw AVChestError.changedSinceScan
            }
        } else {
            let code = errno
            switch code {
            case EXDEV: break // another volume: archive in place, then remove the original
            case EPERM:
                throw AVChestError.blockedByMacOS("macOS didn't allow Mac Cleaner to move “\(name)”. If it's an app, allow Mac Cleaner under System Settings › Privacy & Security › App Management, or move it to the Trash in Finder.")
            case EACCES:
                throw AVChestError.needsAdministrator("Mac Cleaner doesn't have permission to move “\(name)”. Reveal it in Finder and move it to the Trash there; Finder asks for your password.")
            default:
                throw AVChestError.failed("“\(name)” couldn't be moved: \(String(cString: strerror(code))).")
            }
        }
        let source = movedAway ? staged.path : path

        do {
            let archive = work.appendingPathComponent("payload.zip")
            // Folders and bundles keep their top folder (--keepParent); a single file is stored by name.
            let arguments = isDirectory ? ["-c", "-k", "--keepParent", source, archive.path] : ["-c", "-k", source, archive.path]
            let ditto = try await ProcessRunner.run("/usr/bin/ditto", arguments: arguments, timeout: 30 * 60)
            guard ditto.succeeded else { throw AVChestError.failed("Archiving “\(name)” failed: \(ditto.combinedOutput)") }
            let id = UUID().uuidString
            let payload = payloadURL(id)
            let (payloadSize, payloadHash) = try AVChestPayload.write(archive: archive, to: payload)
            let item = AVChestItem(
                id: id, originalPath: path, name: name, isDirectory: isDirectory, size: size, sha256: request.sha256,
                signatureName: request.signatureName, category: request.category, source: request.source, quarantinedAt: Date(),
                originalMode: UInt16(info.st_mode & 0o7777), originalOwner: info.st_uid, originalGroup: info.st_gid,
                payloadSize: payloadSize, payloadSHA256: payloadHash, detectedFile: request.detectedFile, downloadURL: request.downloadURL
            )
            do {
                try AVJSONFile.save(item, to: metadataURL(id))
                chmod(metadataURL(id).path, 0o600)
            } catch {
                try? FileManager.default.removeItem(at: payload)
                throw AVChestError.failed("Couldn't record “\(name)” in the Virus Chest: \(error.localizedDescription)")
            }

            if movedAway {
                _ = try? SafeRemover.remove(path: staged.path, expected: nil)
            } else {
                do {
                    try SafeRemover.remove(path: path, expected: current)
                } catch {
                    try? FileManager.default.removeItem(at: payload)
                    try? FileManager.default.removeItem(at: metadataURL(id))
                    throw AVChestError.failed("“\(name)” was archived but couldn't be removed from its location: \(error.localizedDescription)")
                }
            }
            logger.info("Antivirus: moved an item to the Virus Chest (\(request.category.badgeTitle), \(isDirectory ? "folder" : "file"), \(ByteFormatting.string(size)))", category: AVLog.category)
            return item
        } catch {
            if movedAway, renamex_np(staged.path, path, UInt32(RENAME_EXCL)) != 0 {
                // Something new appeared at the original location; keep the item recoverable in the chest folder.
                let rescue = paths.quarantine.appendingPathComponent("unfinished-\(UUID().uuidString)-\(name)")
                _ = rename(staged.path, rescue.path)
                logger.error("Antivirus: quarantine of an item failed and it couldn't be put back; it was kept at \(rescue.lastPathComponent)", category: AVLog.category)
            }
            throw error
        }
    }

    // MARK: - Restore and delete

    /// Restores `item` to `destinationFolder` (or its original folder) and returns the new path.
    func restore(_ item: AVChestItem, toFolder destinationFolder: String? = nil) async throws -> String {
        let folder = destinationFolder.map(PathUtilities.normalize) ?? (item.originalPath as NSString).deletingLastPathComponent
        var folderInfo = stat()
        guard stat(folder, &folderInfo) == 0, (folderInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw destinationFolder == nil ? AVChestError.originalFolderMissing : AVChestError.failed("The chosen folder doesn't exist.")
        }
        let destination = PathUtilities.join(folder, item.name)
        var existing = stat()
        if lstat(destination, &existing) == 0 { throw AVChestError.destinationExists(destination) }

        let work = try paths.makeWorkDirectory("restore")
        defer { try? FileManager.default.removeItem(at: work) }
        let archive = work.appendingPathComponent("payload.zip")
        try AVChestPayload.read(payloadURL(item.id), expectedSHA256: item.payloadSHA256, to: archive)
        let extracted = work.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
        let ditto = try await ProcessRunner.run("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, extracted.path], timeout: 30 * 60)
        guard ditto.succeeded else { throw AVChestError.damaged("the archive couldn't be expanded") }
        let restored = extracted.appendingPathComponent(item.name)
        guard FileManager.default.fileExists(atPath: restored.path) else { throw AVChestError.damaged("the archive is empty") }

        if renamex_np(restored.path, destination, UInt32(RENAME_EXCL)) != 0 {
            let code = errno
            if code == EEXIST { throw AVChestError.destinationExists(destination) }
            guard code == EXDEV else { throw AVChestError.failed("Couldn't restore “\(item.name)”: \(String(cString: strerror(code))).") }
            let copy = try await ProcessRunner.run("/usr/bin/ditto", arguments: [restored.path, destination], timeout: 30 * 60)
            guard copy.succeeded else { throw AVChestError.failed("Couldn't copy “\(item.name)” to the chosen folder.") }
        }
        chmod(destination, mode_t(item.originalMode))
        if item.originalOwner == getuid() { chown(destination, item.originalOwner, item.originalGroup) }
        try? FileManager.default.removeItem(at: payloadURL(item.id))
        try? FileManager.default.removeItem(at: metadataURL(item.id))
        logger.info("Antivirus: restored an item from the Virus Chest", category: AVLog.category)
        return destination
    }

    /// Deletes the stored copy for good.
    func delete(_ item: AVChestItem) throws {
        let payload = payloadURL(item.id)
        if FileManager.default.fileExists(atPath: payload.path) {
            do { try FileManager.default.removeItem(at: payload) } catch {
                throw AVChestError.failed("Couldn't delete “\(item.name)”: \(error.localizedDescription)")
            }
        }
        try? FileManager.default.removeItem(at: metadataURL(item.id))
        logger.info("Antivirus: deleted an item from the Virus Chest", category: AVLog.category)
    }
}

/// The masked payload format: `MCCHEST1`, key length (UInt32 LE), key, payload length
/// (UInt64 LE), payload SHA-256 (32 bytes), then the archive XOR-ed with the key.
enum AVChestPayload {
    static let magic = Data("MCCHEST1".utf8)
    static let keyLength = 64

    /// Writes the masked copy and checks it by reading it back. Returns its size and hash.
    static func write(archive: URL, to destination: URL) throws -> (Int64, String) {
        var key = [UInt8](repeating: 0, count: keyLength)
        guard SecRandomCopyBytes(kSecRandomDefault, keyLength, &key) == errSecSuccess else { throw AVChestError.failed("Couldn't create a key.") }
        let plainHash = try sha256(of: archive)
        let size = ((try FileManager.default.attributesOfItem(atPath: archive.path))[.size] as? NSNumber)?.int64Value ?? 0
        var header = magic
        withUnsafeBytes(of: UInt32(keyLength).littleEndian) { header.append(contentsOf: $0) }
        header.append(contentsOf: key)
        withUnsafeBytes(of: UInt64(size).littleEndian) { header.append(contentsOf: $0) }
        header.append(contentsOf: plainHash)

        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw AVChestError.failed("Couldn't write to the Virus Chest.")
        }
        do {
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            try output.write(contentsOf: header)
            let input = try FileHandle(forReadingFrom: archive)
            defer { try? input.close() }
            var offset = 0
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try output.write(contentsOf: mask(chunk, key: key, offset: offset))
                offset += chunk.count
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw AVChestError.failed("Couldn't write to the Virus Chest: \(error.localizedDescription)")
        }
        // Read it back before anything is removed.
        let check = destination.deletingLastPathComponent().appendingPathComponent(".verify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: check) }
        try read(destination, expectedSHA256: AVFileHasher.hex(plainHash), to: check)
        return (size, AVFileHasher.hex(plainHash))
    }

    /// Unmasks a payload into `destination`, checking its hash.
    static func read(_ payload: URL, expectedSHA256: String, to destination: URL) throws {
        guard let input = try? FileHandle(forReadingFrom: payload) else { throw AVChestError.damaged("missing") }
        defer { try? input.close() }
        guard let prefix = try input.read(upToCount: magic.count + 4), prefix.count == magic.count + 4, prefix.prefix(magic.count) == magic else {
            throw AVChestError.damaged("unknown format")
        }
        let length = Int(prefix.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard length > 0, length <= 4_096, let key = try input.read(upToCount: length), key.count == length,
              let sizeData = try input.read(upToCount: 8), sizeData.count == 8, let storedHash = try input.read(upToCount: 32), storedHash.count == 32 else {
            throw AVChestError.damaged("header")
        }
        let size = sizeData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        guard AVFileHasher.hex(storedHash) == expectedSHA256.lowercased() else { throw AVChestError.damaged("record mismatch") }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw AVChestError.failed("Couldn't create a temporary file.")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var hasher = SHA256()
        var offset = 0
        let keyBytes = [UInt8](key)
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            let plain = mask(chunk, key: keyBytes, offset: offset)
            hasher.update(data: plain)
            try output.write(contentsOf: plain)
            offset += chunk.count
        }
        guard UInt64(offset) == size, AVFileHasher.hex(hasher.finalize()) == expectedSHA256.lowercased() else {
            throw AVChestError.damaged("checksum mismatch")
        }
    }

    private static func mask(_ data: Data, key: [UInt8], offset: Int) -> Data {
        var bytes = [UInt8](data)
        let count = key.count
        for index in bytes.indices { bytes[index] ^= key[(offset + index) % count] }
        return Data(bytes)
    }

    private static func sha256(of url: URL) throws -> [UInt8] {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return Array(hasher.finalize())
    }
}

/// Activity log category for antivirus events.
enum AVLog {
    static let category: LogCategory = .antivirus
}
