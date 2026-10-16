import Foundation

/// Which tool keeps the ClamAV databases up to date.
enum AVUpdaterKind: String, Codable, Sendable, Hashable {
    /// ClamAV's own updater, when it is installed (recommended by ClamAV).
    case freshclam
    /// Mac Cleaner's updater: DNS version check, signed incremental CDIFF patches, rare full downloads.
    case builtIn

    var title: String {
        switch self {
        case .freshclam: return "ClamAV freshclam (official)"
        case .builtIn: return "Built-in updater"
        }
    }
}

/// Local state of one ClamAV database.
struct AVDatabaseFileState: Codable, Sendable, Equatable {
    /// Version of the file in `clamav/`.
    var version: Int?
    var buildTime: Date?
    var signatureCount: Int?
    /// "main.cvd", "daily.cld"…
    var fileName: String?
    var fileSize: Int64?
    /// Last full `.cvd` request that the CDN answered with data (counts against the once-a-day rule).
    var lastFullDownload: Date?
    /// When the local version last changed.
    var lastUpdated: Date?
    /// Last time CDIFF patches were applied.
    var lastPatched: Date?
    var lastModifiedHeader: String?
    /// Backoff after errors for full downloads.
    var nextAllowedFullDownload: Date?
    var consecutiveFailures = 0
    var lastError: String?
    /// Patching up to this version failed; the next update uses a full download instead.
    var cdiffFailedTarget: Int?
}

/// Local state of one abuse.ch feed.
struct AVFeedFileState: Codable, Sendable, Equatable {
    var lastChecked: Date?
    /// When the downloaded content last changed.
    var lastChanged: Date?
    var etag: String?
    var lastModifiedHeader: String?
    /// Entries currently kept (after accumulation and expiry).
    var entryCount = 0
    var bytesOnDisk: Int64 = 0
    var nextAllowedAttempt: Date?
    var consecutiveFailures = 0
    var lastError: String?
}

/// The compiled database that the engine loads.
struct AVInstalledDatabase: Codable, Sendable, Equatable {
    var summary: AVDatabaseSummary
    var compiledAt: Date
    /// ClamAV versions that went into it.
    var clamavVersions: [String: Int]
    /// Hash list entries that went into it, by feed.
    var hashListCounts: [String: Int]
    /// The Mac Cleaner build that compiled it (`AVAppBuild.current`). Another build may read
    /// the compiled format differently, so the database is compiled again after an app update.
    var compiledByBuild: String? = nil
}

enum AVAppBuild {
    /// "2.0.0 (42)" for the running app.
    static let current: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }()
}

/// Everything the updater remembers, in `state.json`.
struct AVDefinitionsState: Codable, Sendable, Equatable {
    var databases: [String: AVDatabaseFileState] = [:]
    var feeds: [String: AVFeedFileState] = [:]
    var lastVersionCheck: Date?
    var lastVersionInfo: AVClamAVVersionInfo?
    /// Last update run that went online.
    var lastCheck: Date?
    /// Last run that confirmed the ClamAV databases are current.
    var lastSuccessfulCheck: Date?
    /// Last time the compiled database changed.
    var lastUpdated: Date?
    var lastError: String?
    /// The ClamAV CDN asked to wait (429 or 403) until then.
    var cdnRetryAfter: Date?
    var installed: AVInstalledDatabase?
    var lastUpdater: AVUpdaterKind?
    var freshclamVersion: String?
    /// The person started the first download (automatic updates only run after that).
    var firstInstallRequested = false

    init() {}

    subscript(database: AVClamAVDatabase) -> AVDatabaseFileState {
        get { databases[database.rawValue] ?? AVDatabaseFileState() }
        set { databases[database.rawValue] = newValue }
    }

    subscript(feed: AVFeedID) -> AVFeedFileState {
        get { feeds[feed.rawValue] ?? AVFeedFileState() }
        set { feeds[feed.rawValue] = newValue }
    }

    var hasClamAVDatabases: Bool {
        AVClamAVDatabase.allCases.allSatisfy { self[$0].version != nil }
    }
}

struct AVStateFile: Sendable {
    let url: URL

    func load() -> AVDefinitionsState {
        AVJSONFile.load(AVDefinitionsState.self, from: url) ?? AVDefinitionsState()
    }

    func save(_ state: AVDefinitionsState) throws {
        try AVJSONFile.save(state, to: url)
    }
}

/// ClamAV's rules for its CDN and polite intervals for abuse.ch.
///
/// * Versions are checked (DNS TXT) at most every 4 hours.
/// * A database behind by a few versions is patched with signed CDIFF files (about 1 KB each).
/// * A full `.cvd` download happens only when patching isn't possible, and never more than once
///   per 24 hours per file, because ClamAV blocks addresses that download more often.
/// * 429 and `Retry-After` are honored; 403 and server errors back off.
enum AVUpdatePolicy {
    static let checkInterval: TimeInterval = 4 * 3600
    static let fullDownloadInterval: TimeInterval = 24 * 3600
    /// More missing versions than this are replaced with a full download.
    static let maximumPatches = 60
    /// Manual "Update Now" never re-fetches an abuse.ch feed more often than this.
    static let manualFeedFloor: TimeInterval = 15 * 60

    enum Action: Equatable, Sendable {
        case upToDate
        /// Apply `daily-<from>.cdiff` … `daily-<to>.cdiff`.
        case applyPatches(from: Int, to: Int)
        case downloadFull
        case wait(until: Date, reason: String)
    }

    static func isVersionCheckDue(lastCheck: Date?, now: Date, manual: Bool) -> Bool {
        if manual { return true }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= checkInterval || now < lastCheck
    }

    static func plan(_ database: AVClamAVDatabase, state: AVDatabaseFileState, remoteVersion: Int?, cdnRetryAfter: Date?, now: Date) -> Action {
        if let retry = cdnRetryAfter, retry > now {
            let needed = state.version == nil || (remoteVersion.map { $0 > (state.version ?? 0) } ?? false)
            return needed ? .wait(until: retry, reason: "ClamAV's servers asked Mac Cleaner to wait before downloading again.") : .upToDate
        }
        guard let local = state.version else { return fullDownloadDecision(state, now: now) }
        guard let remote = remoteVersion, remote > local else { return .upToDate }
        if remote - local <= maximumPatches, state.cdiffFailedTarget != remote {
            return .applyPatches(from: local + 1, to: remote)
        }
        return fullDownloadDecision(state, now: now)
    }

    private static func fullDownloadDecision(_ state: AVDatabaseFileState, now: Date) -> Action {
        if let last = state.lastFullDownload, now.timeIntervalSince(last) < fullDownloadInterval, now >= last {
            return .wait(until: last.addingTimeInterval(fullDownloadInterval),
                         reason: "ClamAV allows each database to be downloaded once a day.")
        }
        if let next = state.nextAllowedFullDownload, next > now {
            return .wait(until: next, reason: "Waiting after an earlier download problem.")
        }
        return .downloadFull
    }

    /// When to try again after a failed request. `status` is nil for network errors.
    static func retryDate(status: Int?, retryAfter: TimeInterval?, failures: Int, now: Date) -> Date {
        let attempt = Double(max(1, min(failures, 8)) - 1)
        let delay: TimeInterval
        switch status {
        case 429?:
            delay = min(max(retryAfter ?? 3600, 900), 48 * 3600)
        case 403?:
            delay = max(retryAfter ?? 0, 24 * 3600)
        case let code? where code >= 500:
            delay = max(retryAfter ?? 0, min(12 * 3600, 900 * pow(2, attempt)))
        case .some:
            delay = max(retryAfter ?? 0, min(24 * 3600, 3600 * pow(2, attempt)))
        case nil:
            delay = min(6 * 3600, 1800 * pow(2, attempt))
        }
        return now.addingTimeInterval(delay)
    }

    static func isFeedDue(_ feed: AVFeedID, state: AVFeedFileState, now: Date, manual: Bool) -> Bool {
        if let next = state.nextAllowedAttempt, next > now { return false }
        guard let last = state.lastChecked, now >= last else { return true }
        return now.timeIntervalSince(last) >= (manual ? manualFeedFloor : feed.checkInterval)
    }
}
