import Foundation

/// The ClamAV database files in `clamav/`: reading versions, unpacking `.cvd`/`.cld`
/// containers, checking unpacked files against their signed `.info` index, and packing a
/// patched database into a `.cld` the way freshclam does.
enum AVClamAVLocalDatabase {
    enum Failure: LocalizedError, Equatable {
        case missing(String)
        case mismatch(String)

        var errorDescription: String? {
            switch self {
            case .missing(let detail): return "The database is incomplete (\(detail))."
            case .mismatch(let detail): return "The database doesn't match its index (\(detail))."
            }
        }
    }

    struct LocalFile: Sendable, Hashable {
        var url: URL
        var header: AVClamAVHeaderLine
    }

    /// The newest local container of `database` (`.cld` or `.cvd`).
    static func current(_ database: AVClamAVDatabase, in directory: URL) -> LocalFile? {
        [database.cldName, database.cvdName]
            .map { directory.appendingPathComponent($0) }
            .compactMap { url in AVClamAVHeaderLine.read(at: url).map { LocalFile(url: url, header: $0) } }
            .max { $0.header.version < $1.header.version }
    }

    /// Unpacks a container into `directory` and returns the file names.
    static func unpack(_ container: URL, to directory: URL) throws -> [String] {
        let data = try Data(contentsOf: container, options: [.alwaysMapped])
        guard data.count > 512 else { throw Failure.missing("empty container") }
        let body = data.dropFirst(512)
        let extractor = AVDefsTar.Extractor(directory: directory)
        if body.first == 0x1F, body.dropFirst().first == 0x8B {
            try AVDefsGzip.decompress(Data(body), maxOutput: 2_000_000_000) { try extractor.consume($0) }
        } else {
            try Data(body).withUnsafeBytes { try extractor.consume($0) }
        }
        try extractor.finish()
        return extractor.files
    }

    /// Checks every unpacked file against `<database>.info` (size and SHA-256) and returns the
    /// header line. The `.info` file is part of the signed container, and every patch applied to
    /// it is signed too, so a match proves the patched files are exactly what ClamAV published.
    @discardableResult
    static func verifyUnpacked(_ database: AVClamAVDatabase, in directory: URL, expectedVersion: Int? = nil) throws -> AVClamAVHeaderLine {
        let infoName = database.rawValue + ".info"
        guard let info = try? Data(contentsOf: directory.appendingPathComponent(infoName)) else { throw Failure.missing(infoName) }
        let lines = String(decoding: info, as: UTF8.self).split(separator: "\n").map(String.init)
        guard let first = lines.first, let header = AVClamAVHeaderLine.parse(first) else { throw Failure.mismatch("header") }
        if let expectedVersion, header.version != expectedVersion {
            throw Failure.mismatch("version \(header.version), expected \(expectedVersion)")
        }
        var listed: [String: (size: Int64, sha256: String)] = [:]
        var signed = false
        for line in lines.dropFirst() {
            if line.hasPrefix("DSIG:") { signed = true; break }
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 3, let size = Int64(fields[1]), fields[2].count == 64 else { throw Failure.mismatch("index line") }
            listed[String(fields[0])] = (size, fields[2].lowercased())
        }
        guard signed, !listed.isEmpty else { throw Failure.mismatch("unsigned index") }
        let present = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        for name in present where name != "COPYING" && name != infoName {
            guard listed[name] != nil else { throw Failure.mismatch("unexpected file \(name)") }
        }
        for (name, expected) in listed {
            let url = directory.appendingPathComponent(name)
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
            guard let size else { throw Failure.missing(name) }
            guard size == expected.size, AVFileHasher.sha256(path: url.path) == expected.sha256 else { throw Failure.mismatch(name) }
        }
        return header
    }

    /// Packs an unpacked database into a `.cld`: the `.info` header line padded to 512 bytes,
    /// then an uncompressed tar with COPYING, the `.info` file, `daily.cfg` and the rest.
    static func pack(_ database: AVClamAVDatabase, from directory: URL, to destination: URL) throws {
        let infoName = database.rawValue + ".info"
        guard let info = try? Data(contentsOf: directory.appendingPathComponent(infoName)),
              let newline = info.firstIndex(of: 0x0A) else { throw Failure.missing(infoName) }
        var header = Data(info[info.startIndex..<newline].prefix(511))
        header.append(contentsOf: [UInt8](repeating: 0x20, count: 512 - header.count))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }
        let leading = ["COPYING", infoName, "daily.cfg"].filter { names.contains($0) }
        let ordered = leading + names.filter { !leading.contains($0) }.sorted()
        try AVDefsTar.write(header: header, files: ordered, from: directory, to: destination)
    }
}
