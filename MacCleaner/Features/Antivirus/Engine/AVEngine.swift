import Foundation

// PLACEHOLDER. The engine implementation replaces this file; the API below is what the
// rest of the Antivirus feature uses (see AVEngineAPI.swift).

/// Header of a ClamAV database container (`.cvd` / `.cld`).
struct ClamAVDatabaseHeader: Sendable, Codable, Hashable {
    /// "main", "daily"...
    var name: String
    var buildTime: Date
    var version: Int
    var signatureCount: Int
    var functionalityLevel: Int
    var builder: String
}

enum AVEngineError: Error, LocalizedError, Sendable, Equatable {
    case notInstalled
    case invalidDatabase(String)
    case signatureMismatch(String)
    case notImplemented

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Virus definitions aren't installed yet."
        case .invalidDatabase(let detail): return "The virus definitions are damaged: \(detail)"
        case .signatureMismatch(let name): return "\(name) isn't signed by ClamAV. It was not installed."
        case .notImplemented: return "The antivirus engine isn't available in this build."
        }
    }
}

/// Reads and verifies ClamAV database containers.
enum ClamAVDatabaseFile {
    /// Parses the 512-byte header without verifying the contents.
    static func readHeader(at url: URL) throws -> ClamAVDatabaseHeader {
        throw AVEngineError.notImplemented
    }

    /// Checks the header, the MD5 of the archive and ClamAV's digital signature.
    static func verify(at url: URL) throws -> ClamAVDatabaseHeader {
        throw AVEngineError.notImplemented
    }
}

/// Builds the engine's database from downloaded files.
enum AVDatabaseCompiler {
    /// Verifies and compiles `inputs` into `directory`, replacing its previous contents only
    /// when compilation succeeds. Blocks; run it off the main actor.
    static func compile(
        _ inputs: AVDatabaseInputs,
        into directory: URL,
        progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }
    ) throws -> AVDatabaseSummary {
        throw AVEngineError.notImplemented
    }
}

/// A loaded, ready-to-scan engine. Thread-safe.
final class AVEngine: AVFileScanning, @unchecked Sendable {
    let summary: AVDatabaseSummary

    private init(summary: AVDatabaseSummary) {
        self.summary = summary
    }

    /// Loads a database compiled by `AVDatabaseCompiler` (memory-mapped, fast).
    static func load(from directory: URL) throws -> AVEngine {
        throw AVEngineError.notInstalled
    }

    func scanFile(atPath path: String, options: AVScanOptions) -> AVFileScanResult {
        AVFileScanResult(path: path)
    }

    /// Scans bytes that aren't a file on disk (an archive member, a download in memory).
    func scan(data: Data, name: String, options: AVScanOptions) -> [AVDetection] {
        []
    }
}
