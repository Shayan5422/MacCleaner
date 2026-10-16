import Foundation

// The contract between the antivirus engine (everything in Features/Antivirus/Engine)
// and the rest of the Antivirus feature (updater, scan coordinator, shields, UI).
//
// The engine owns database verification, compilation and matching. It is UI-free,
// `Sendable` and synchronous: scanning blocks the calling thread, so callers run it
// on their own worker threads (never on the main actor or the Swift concurrency
// pool's cooperative threads for long stretches).
//
// The types below may gain members, but existing members keep their meaning.

/// Where a signature comes from.
enum AVSignatureSource: String, Sendable, Codable, Hashable, CaseIterable {
    /// ClamAV's official databases (main, daily).
    case clamav
    /// abuse.ch MalwareBazaar SHA-256 list.
    case malwareBazaar
    /// File hashes from abuse.ch ThreatFox.
    case threatFox
    /// Test signatures built into the app (the EICAR test file).
    case builtIn

    var title: String {
        switch self {
        case .clamav: return "ClamAV"
        case .malwareBazaar: return "MalwareBazaar"
        case .threatFox: return "ThreatFox"
        case .builtIn: return "Built-in"
        }
    }
}

/// What kind of detection a signature reports.
enum AVThreatKind: String, Sendable, Codable, Hashable {
    /// Malicious software (trojans, stealers, backdoors, ransomware...).
    case malware
    /// Potentially unwanted software (adware, bundlers, hacking tools). ClamAV's "PUA" signatures.
    case pua
    /// A harmless test file such as EICAR.
    case testFile
}

/// One signature that matched.
struct AVDetection: Sendable, Codable, Hashable {
    /// e.g. "Osx.Trojan.Amos-10012345-0", "Win.Test.EICAR_HDB-1", "MalwareBazaar.SHA256".
    var signatureName: String
    var kind: AVThreatKind
    var source: AVSignatureSource
    /// Where inside the scanned file the match was: an archive member ("payload/run.sh"),
    /// a universal-binary slice ("x86_64"), nested members joined with " › ". nil for the file itself.
    var memberPath: String?
}

/// Why a file wasn't (fully) scanned.
enum AVSkipReason: Sendable, Codable, Hashable {
    /// Larger than `AVScanOptions.maxFileSize`.
    case tooLarge
    /// A directory, symbolic link, socket, device...
    case notRegularFile
    /// Stored only in the cloud (iCloud Drive, Dropbox...). Reading it would download it, so it is never opened.
    case dataless
    /// Couldn't be opened or read (permissions, file vanished...).
    case unreadable(String)
}

/// The result of scanning one file on disk.
struct AVFileScanResult: Sendable, Hashable {
    var path: String
    var detections: [AVDetection]
    var skipped: AVSkipReason?
    /// Bytes read from disk (0 when skipped).
    var bytesScanned: Int64
    /// Hex SHA-256 of the file when it was computed (always for files that matched).
    var sha256: String?
    /// An archive inside the file hit a size, depth or file-count limit, so it wasn't scanned completely.
    var limitsReached: Bool

    init(path: String, detections: [AVDetection] = [], skipped: AVSkipReason? = nil, bytesScanned: Int64 = 0, sha256: String? = nil, limitsReached: Bool = false) {
        self.path = path
        self.detections = detections
        self.skipped = skipped
        self.bytesScanned = bytesScanned
        self.sha256 = sha256
        self.limitsReached = limitsReached
    }

    var isInfected: Bool { !detections.isEmpty }
}

/// Per-scan settings.
struct AVScanOptions: Sendable, Codable, Hashable {
    /// Files larger than this are skipped (`.tooLarge`).
    var maxFileSize: Int64 = 200_000_000
    /// Look inside archives (zip, gzip, tar...) and universal binaries.
    var scanArchives = true
    /// How deep nested archives are opened.
    var maxArchiveDepth = 4
    /// Total bytes extracted from one file's archives before scanning stops (`limitsReached`).
    var maxExtractedBytes: Int64 = 500_000_000
    /// Archive members scanned per file before scanning stops (`limitsReached`).
    var maxArchiveMembers = 10_000
    /// Report potentially unwanted applications (ClamAV PUA signatures).
    var detectPUA = true
    /// Also apply signatures for Windows (PE) and Linux (ELF) malware. They can't run on a Mac,
    /// but can be passed on to other computers.
    var detectNonMacThreats = true

    init() {}
}

/// Downloaded files the updater hands to the compiler.
struct AVDatabaseInputs: Sendable {
    /// ClamAV database containers (`main.cvd`, `daily.cvd`, or `.cld`), already verified.
    var clamavFiles: [URL] = []
    /// Text files with one hex SHA-256 per line (`#` starts a comment), e.g. MalwareBazaar exports.
    var sha256Lists: [(url: URL, source: AVSignatureSource)] = []

    init(clamavFiles: [URL] = [], sha256Lists: [(url: URL, source: AVSignatureSource)] = []) {
        self.clamavFiles = clamavFiles
        self.sha256Lists = sha256Lists
    }
}

/// What a compiled database contains, shown on the Antivirus page.
struct AVDatabaseSummary: Sendable, Codable, Hashable {
    var builtAt: Date
    /// ClamAV database versions by name: ["main": 63, "daily": 28155].
    var clamavVersions: [String: Int]
    /// Build times from the ClamAV database headers.
    var clamavBuildDates: [String: Date]
    /// Signatures the engine uses.
    var signatureCount: Int
    /// Signatures skipped because they use features this engine doesn't support.
    var unsupportedSignatureCount: Int
    var hashSignatureCount: Int
    var bodySignatureCount: Int
    var logicalSignatureCount: Int
    /// Hashes from SHA-256 lists (MalwareBazaar, ThreatFox).
    var hashListCount: Int
}

/// Scans files. `AVEngine` conforms; tests and the scan coordinator can substitute fakes.
protocol AVFileScanning: Sendable {
    /// Scans one file. Blocks the calling thread; safe to call from many threads at once.
    func scanFile(atPath path: String, options: AVScanOptions) -> AVFileScanResult
}
