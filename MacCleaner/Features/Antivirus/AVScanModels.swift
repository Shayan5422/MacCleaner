import Foundation

/// What kind of scan ran.
enum AVScanKind: String, Codable, Sendable, CaseIterable {
    case quick, full, custom, volume, smartScan, scheduled, downloads

    var title: String {
        switch self {
        case .quick: return "Quick Scan"
        case .full: return "Full Scan"
        case .custom: return "Custom Scan"
        case .volume: return "Drive Scan"
        case .smartScan: return "Smart Scan"
        case .scheduled: return "Scheduled Quick Scan"
        case .downloads: return "Downloads Check"
        }
    }

    var symbolName: String {
        switch self {
        case .quick, .smartScan, .scheduled: return "bolt.shield"
        case .full: return "internaldrive"
        case .custom: return "doc.viewfinder"
        case .volume: return "externaldrive"
        case .downloads: return "arrow.down.circle"
        }
    }
}

/// Who found a threat.
enum AVDetectionOrigin: String, Codable, Sendable {
    case scan, fileShield, downloadShield, test

    var title: String {
        switch self {
        case .scan: return "Scan"
        case .fileShield: return "File Shield"
        case .downloadShield: return "Download Shield"
        case .test: return "Protection test"
        }
    }
}

/// How serious a threat is, for badges and automatic actions.
enum AVThreatCategory: String, Codable, Sendable, Comparable {
    case testFile, maliciousDownload, pua, malware

    static func < (lhs: AVThreatCategory, rhs: AVThreatCategory) -> Bool { lhs.rank < rhs.rank }

    private var rank: Int {
        switch self {
        case .testFile: return 0
        case .pua: return 1
        case .maliciousDownload: return 2
        case .malware: return 3
        }
    }

    var badgeTitle: String {
        switch self {
        case .malware: return "Malware"
        case .pua: return "PUA"
        case .testFile: return "Test file"
        case .maliciousDownload: return "Malware site"
        }
    }

    var explanation: String {
        switch self {
        case .malware: return "Malicious software that can harm your Mac or steal data."
        case .pua: return "Potentially unwanted software such as adware, bundled installers or hacking tools."
        case .testFile: return "A harmless test file used to check that antivirus protection works."
        case .maliciousDownload: return "Downloaded from an address that abuse.ch lists as distributing malware. No virus signature matched the file itself."
        }
    }

    var symbolName: String {
        switch self {
        case .malware: return "ladybug.fill"
        case .pua: return "exclamationmark.triangle.fill"
        case .testFile: return "checkmark.seal.fill"
        case .maliciousDownload: return "arrow.down.circle.fill"
        }
    }

    /// Smart Scan and Dashboard severity.
    var severity: FindingSeverity {
        switch self {
        case .malware: return .threat
        case .pua, .maliciousDownload: return .suspicious
        case .testFile: return .info
        }
    }
}

/// A documented adware rule from the Security feature that matched (no signature needed).
struct AVRuleMatch: Codable, Sendable, Hashable {
    var title: String
    var family: String
    var isMalware: Bool
}

/// Where a downloaded file came from (extended attributes written by browsers).
struct AVDownloadOrigin: Codable, Sendable, Hashable {
    /// `kMDItemWhereFroms`: the download address, then usually the page it came from.
    var urls: [String] = []
    /// The app that downloaded it (`com.apple.quarantine`).
    var agent: String?
    var downloadedAt: Date?
    /// The address listed by URLhaus or ThreatFox, if any.
    var listedURL: String?
    var intelMatch: ThreatIntelMatch?

    var downloadURL: String? { urls.first }
    var isKnownMalwareSite: Bool { intelMatch != nil }
}

/// Something a scan or shield found.
struct AVThreat: Identifiable, Codable, Sendable, Hashable {
    var id: String
    var path: String
    var detections: [AVDetection] = []
    var ruleMatch: AVRuleMatch?
    var origin: AVDownloadOrigin?
    var sha256: String?
    var size: Int64 = 0
    /// Identity at detection, re-checked before anything is moved.
    var snapshot: FileSnapshot?
    var detectedAt: Date
    var foundBy: AVDetectionOrigin
    /// An archive inside the file couldn't be scanned completely.
    var limitsReached = false

    init(path: String, detections: [AVDetection] = [], ruleMatch: AVRuleMatch? = nil, origin: AVDownloadOrigin? = nil, sha256: String? = nil,
         size: Int64 = 0, snapshot: FileSnapshot? = nil, detectedAt: Date = Date(), foundBy: AVDetectionOrigin = .scan, limitsReached: Bool = false) {
        self.path = path
        self.detections = detections
        self.ruleMatch = ruleMatch
        self.origin = origin
        self.sha256 = sha256
        self.size = size
        self.snapshot = snapshot
        self.detectedAt = detectedAt
        self.foundBy = foundBy
        self.limitsReached = limitsReached
        let key = detections.first?.signatureName ?? ruleMatch?.title ?? origin?.listedURL ?? "threat"
        id = SecurityHash.fnv1a(path + "|" + key)
    }

    var fileName: String { (path as NSString).lastPathComponent }

    var category: AVThreatCategory {
        if detections.contains(where: { $0.kind == .malware }) { return .malware }
        if let ruleMatch, ruleMatch.isMalware { return .malware }
        if detections.contains(where: { $0.kind == .pua }) || ruleMatch != nil { return .pua }
        if detections.contains(where: { $0.kind == .testFile }) { return .testFile }
        return .maliciousDownload
    }

    /// The signature or rule name shown in lists.
    var name: String {
        if let detection = detections.first(where: { $0.kind == .malware }) ?? detections.first { return detection.signatureName }
        if let ruleMatch { return ruleMatch.title }
        return "Downloaded from a known malware site"
    }

    var memberPath: String? { detections.compactMap(\.memberPath).first }

    /// Where the matching signature comes from.
    var sourceTitle: String {
        if let detection = detections.first {
            switch detection.source {
            case .clamav: return "ClamAV signatures"
            case .malwareBazaar: return "MalwareBazaar (abuse.ch)"
            case .threatFox: return "ThreatFox (abuse.ch)"
            case .builtIn: return "Built-in test signature"
            }
        }
        if ruleMatch != nil { return "Mac Cleaner adware rules" }
        return origin?.intelMatch?.source ?? "abuse.ch"
    }

    /// The outermost app bundle containing the file, when it is inside one.
    var enclosingApp: String? {
        guard let app = LaunchdProgramAnalyzer.outermostAppBundle(in: path), app != path else { return nil }
        return app
    }

    var isAppBundle: Bool { path.lowercased().hasSuffix(".app") }
}

/// Something a scan couldn't check, explained the way the rest of the app does.
struct AVLimitation: Codable, Sendable, Hashable, Identifiable {
    var title: String
    var detail: String
    var path: String?
    /// `SystemSettingsPane` raw value for an "Open Settings" button.
    var settingsPane: String?

    var id: String { title + "|" + (path ?? "") }
    var pane: SystemSettingsPane? { settingsPane.flatMap(SystemSettingsPane.init(rawValue:)) }
}

/// Live progress of a scan.
struct AVScanProgress: Sendable, Equatable {
    enum Phase: String, Sendable { case preparing, scanning, finishing }

    var kind: AVScanKind
    var phase: Phase = .preparing
    var filesScanned = 0
    var bytesScanned: Int64 = 0
    var filesSkipped = 0
    /// Files found so far (queued or scanned).
    var filesFound = 0
    var bytesFound: Int64 = 0
    /// Every folder was listed, so totals are final.
    var listingComplete = false
    var currentPath = ""
    var threatsFound = 0
    var elapsed: TimeInterval = 0
    /// Only when the totals are known and enough was scanned to estimate honestly.
    var estimatedRemaining: TimeInterval?

    var fraction: Double? {
        guard listingComplete, filesFound > 0 else { return nil }
        let work = Double(filesFound) * 65_536 + Double(bytesFound)
        let done = Double(filesScanned + filesSkipped) * 65_536 + Double(bytesScanned)
        return min(1, done / max(work, 1))
    }
}

/// The result of one scan.
struct AVScanReport: Sendable, Codable, Identifiable {
    var id = UUID()
    var kind: AVScanKind
    var startedAt: Date
    var finishedAt: Date
    var filesScanned = 0
    var bytesScanned: Int64 = 0
    var skippedTooLarge = 0
    var skippedCloudOnly = 0
    var skippedUnreadable = 0
    /// Matches the person marked "always allow".
    var allowedCount = 0
    /// Archives with password-protected members (their contents couldn't be checked).
    var encryptedArchives = 0
    /// Archives that were only partly checked (unsupported compression, size or nesting limits).
    var partiallyScannedArchives = 0
    /// Matches in ClamAV's own signature databases (verified by ClamAV's signature), which
    /// contain malware patterns by design and aren't reported.
    var ignoredSignatureDatabases = 0
    var threats: [AVThreat] = []
    var limitations: [AVLimitation] = []
    var wasCancelled = false
    /// false when only the built-in test signatures were available.
    var usedDefinitions: Bool
    var definitionsDescription: String?

    var skippedCount: Int { skippedTooLarge + skippedCloudOnly + skippedUnreadable }
    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

    var summary: AVScanSummary {
        AVScanSummary(id: id, kind: kind, startedAt: startedAt, finishedAt: finishedAt, filesScanned: filesScanned, bytesScanned: bytesScanned,
                      threatsFound: threats.count, malwareFound: threats.filter { $0.category == .malware }.count,
                      skippedCount: skippedCount, wasCancelled: wasCancelled, usedDefinitions: usedDefinitions,
                      definitionsDescription: definitionsDescription)
    }
}

/// A stored scan summary (History tab, last scan tile).
struct AVScanSummary: Codable, Sendable, Identifiable, Hashable {
    var id: UUID
    var kind: AVScanKind
    var startedAt: Date
    var finishedAt: Date
    var filesScanned: Int
    var bytesScanned: Int64
    var threatsFound: Int
    var malwareFound: Int
    var skippedCount: Int
    var wasCancelled: Bool
    var usedDefinitions: Bool
    var definitionsDescription: String?
    /// Threats moved to the Virus Chest afterwards (updated by the page).
    var quarantinedCount = 0

    var duration: TimeInterval { max(0, finishedAt.timeIntervalSince(startedAt)) }

    /// "No threats found · 12,345 files in 1m 12s".
    var resultLine: String {
        let files = "\(NumberFormatting.count(filesScanned)) file\(filesScanned == 1 ? "" : "s")"
        let threats: String
        switch threatsFound {
        case 0: threats = wasCancelled ? "Stopped, no threats found so far" : "No threats found"
        case 1: threats = "1 threat found"
        default: threats = "\(threatsFound) threats found"
        }
        return "\(threats) · \(files) in \(AVFormat.duration(duration))"
    }
}

enum AVFormat {
    /// "45s", "3m 12s", "1h 5m".
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "—" }
        if seconds < 1 { return "under a second" }
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        return DateFormatting.duration(seconds)
    }

    /// "just now", "5 minutes ago".
    static func relative(_ date: Date, now: Date = Date()) -> String {
        abs(now.timeIntervalSince(date)) < 60 ? "just now" : DateFormatting.relative(date, to: now)
    }

    /// "2 h", "3 days" — compact age for tiles and the menu bar.
    static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<120: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3600)) h ago"
        default:
            let days = Int(seconds / 86_400)
            return days == 1 ? "1 day ago" : "\(days) days ago"
        }
    }
}

/// Recent scan summaries (`history.json`, newest first, last 50).
struct AVScanHistoryStore: Sendable {
    let url: URL
    static let limit = 50

    func load() -> [AVScanSummary] { AVJSONFile.load([AVScanSummary].self, from: url) ?? [] }

    func append(_ summary: AVScanSummary) {
        var history = load().filter { $0.id != summary.id }
        history.insert(summary, at: 0)
        if history.count > Self.limit { history.removeLast(history.count - Self.limit) }
        try? AVJSONFile.save(history, to: url)
    }

    func update(_ summary: AVScanSummary) {
        var history = load()
        guard let index = history.firstIndex(where: { $0.id == summary.id }) else { return }
        history[index] = summary
        try? AVJSONFile.save(history, to: url)
    }

    func clear() { try? AVJSONFile.save([AVScanSummary](), to: url) }
}

/// Unresolved threats from the most recent scan, so results found by Smart Scan or the
/// background agent are shown when the Antivirus page opens.
struct AVOpenThreats: Codable, Sendable {
    var kind: AVScanKind
    var date: Date
    var threats: [AVThreat]

    static func load(from url: URL) -> AVOpenThreats? { AVJSONFile.load(AVOpenThreats.self, from: url) }

    func save(to url: URL) { try? AVJSONFile.save(self, to: url) }
}
