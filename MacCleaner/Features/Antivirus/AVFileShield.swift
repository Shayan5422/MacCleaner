import Darwin
import Foundation

enum AVShieldKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case file, download

    var id: String { rawValue }

    var title: String {
        switch self {
        case .file: return "File Shield"
        case .download: return "Download Shield"
        }
    }
}

/// A file the File Shield looked at, for the Shields tab.
struct AVShieldActivity: Identifiable, Sendable, Hashable {
    enum Outcome: Sendable, Hashable {
        case clean
        case threat(String)
        case skipped(String)
    }

    var id = UUID()
    var date: Date
    var path: String
    var outcome: Outcome
}

/// What the File Shield reports to the app.
enum AVShieldNotice: Sendable {
    case detection(AVThreat, AVShieldKind)
    /// macOS didn't allow reading a watched folder; it is skipped until access is granted.
    case accessDenied(folder: String)
    case activity(AVShieldActivity)
}

/// Real-time protection: watches folders with FSEvents, waits until new or changed files stop
/// changing, then scans them one at a time on a low-priority queue, throttled so it never takes
/// much CPU or disk time. New downloads are also checked against URLhaus and ThreatFox.
final class AVFileShield: @unchecked Sendable {
    struct Configuration: Sendable {
        var folders: [String]
        var downloadsFolder: String
        var checksDownloads = true
        var options = AVScanOptions()
        var exclusions = ExclusionList()
        var skippedRoots: [String] = []
        var allowedHashes: Set<String> = []
        var maxFilesPerSecond = 20
        var maxBytesPerSecond: Int64 = 40_000_000

        /// Downloads, Desktop, Documents, both Applications folders, launch agent and daemon folders and /Users/Shared.
        static func standardFolders(home: String) -> [String] {
            [home + "/Downloads", home + "/Desktop", home + "/Documents", home + "/Applications", "/Applications",
             home + "/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Users/Shared"]
        }
    }

    struct Statistics: Sendable, Equatable {
        var isRunning = false
        var filesScanned = 0
        var threatsFound = 0
        var lastScanAt: Date?
        var deniedFolders: [String] = []
        var droppedEvents = 0
        var recent: [AVShieldActivity] = []
    }

    private let source: any AVFileEventSource
    private let scanner: @Sendable () -> any AVFileScanning
    private let intel: @Sendable () -> (any ThreatIntelLookup)?
    private let tracker: AVFileSettleTracker
    private let onNotice: @Sendable (AVShieldNotice) -> Void
    private let workQueue = DispatchQueue(label: "MacCleaner.Antivirus.FileShield", qos: .utility)
    private let lock = NSLock()
    private var configuration: Configuration
    private var stats = Statistics()
    private var timer: DispatchSourceTimer?
    private var windowStart = Date.distantPast
    private var windowFiles = 0
    private var windowBytes: Int64 = 0

    init(source: any AVFileEventSource,
         scanner: @escaping @Sendable () -> any AVFileScanning,
         intel: @escaping @Sendable () -> (any ThreatIntelLookup)?,
         configuration: Configuration,
         tracker: AVFileSettleTracker = AVFileSettleTracker(),
         onNotice: @escaping @Sendable (AVShieldNotice) -> Void) {
        self.source = source
        self.scanner = scanner
        self.intel = intel
        self.configuration = configuration
        self.tracker = tracker
        self.onNotice = onNotice
    }

    var statistics: Statistics {
        lock.withLock {
            var value = stats
            value.droppedEvents = tracker.droppedCount
            return value
        }
    }

    var isRunning: Bool { lock.withLock { stats.isRunning } }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        let folders = lock.withLock { configuration.folders }
        let tracker = self.tracker
        guard source.start(paths: folders, handler: { tracker.record($0) }) else { return false }
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.processReady() }
        timer.resume()
        lock.withLock {
            self.timer = timer
            stats.isRunning = true
        }
        return true
    }

    func stop() {
        let timer = lock.withLock { () -> DispatchSourceTimer? in
            stats.isRunning = false
            defer { self.timer = nil }
            return self.timer
        }
        timer?.cancel()
        source.stop()
    }

    func reconfigure(_ configuration: Configuration) {
        let restart = lock.withLock { () -> Bool in
            let changedFolders = self.configuration.folders != configuration.folders
            self.configuration = configuration
            return changedFolders && stats.isRunning
        }
        if restart {
            stop()
            start()
        }
    }

    /// Scans files that have settled (runs on the shield's queue; tests call it directly).
    func processReady() {
        for path in tracker.poll() { handle(path) }
    }

    // MARK: - Scanning

    private func handle(_ path: String) {
        let configuration = lock.withLock { self.configuration }
        let denied = lock.withLock { stats.deniedFolders }
        guard !configuration.skippedRoots.contains(where: { PathUtilities.isSameOrDescendant(path, of: $0) }),
              !configuration.exclusions.isExcluded(path), !AVScanScope.isSystemPath(path),
              !denied.contains(where: { PathUtilities.isSameOrDescendant(path, of: $0) }) else { return }

        // A folder macOS protects (Desktop, Documents, Downloads) fails with EPERM until access is allowed.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            if errno == EPERM || errno == EACCES, let folder = configuration.folders.first(where: { PathUtilities.isSameOrDescendant(path, of: $0) }) {
                let isNew = lock.withLock { () -> Bool in
                    guard !stats.deniedFolders.contains(folder) else { return false }
                    stats.deniedFolders.append(folder)
                    return true
                }
                if isNew { onNotice(.accessDenied(folder: folder)) }
            }
            return
        }
        var info = stat()
        let statOK = fstat(fd, &info) == 0
        close(fd)
        guard statOK, (info.st_mode & S_IFMT) == S_IFREG else { return }
        let size = Int64(info.st_size)
        if size > configuration.options.maxFileSize {
            record(AVShieldActivity(date: Date(), path: path, outcome: .skipped("larger than the size limit")), scanned: false)
            return
        }
        throttle(bytes: size, configuration: configuration)

        AVThreadIO.disableCloudDownloads()
        let result = scanner().scanFile(atPath: path, options: configuration.options)
        var origin: AVDownloadOrigin?
        if configuration.checksDownloads, PathUtilities.isSameOrDescendant(path, of: configuration.downloadsFolder) {
            origin = AVDownloadOriginReader.read(path: path, intel: intel())
        }
        let flagged = origin?.isKnownMalwareSite == true
        guard result.isInfected || flagged else {
            record(AVShieldActivity(date: Date(), path: path, outcome: result.skipped == nil ? .clean : .skipped("couldn't be read")), scanned: result.skipped == nil)
            return
        }
        let sha256 = (result.sha256 ?? AVFileHasher.sha256(path: path))?.lowercased()
        if let sha256, configuration.allowedHashes.contains(sha256) {
            record(AVShieldActivity(date: Date(), path: path, outcome: .clean), scanned: true)
            return
        }
        if AVSignatureDatabases.isVerifiedDatabase(path: path) {
            // ClamAV's own signature database: it contains malware patterns by design.
            record(AVShieldActivity(date: Date(), path: path, outcome: .skipped("ClamAV signature database")), scanned: true)
            return
        }
        let snapshot = FileSnapshot(identity: FileIdentity(device: info.st_dev, inode: UInt64(info.st_ino)), type: .regular)
        let kind: AVShieldKind = result.isInfected ? .file : .download
        let threat = AVThreat(path: path, detections: result.detections, origin: flagged ? origin : nil, sha256: sha256, size: size,
                              snapshot: snapshot, detectedAt: Date(), foundBy: kind == .file ? .fileShield : .downloadShield,
                              limitsReached: result.limitsReached)
        lock.withLock { stats.threatsFound += 1 }
        record(AVShieldActivity(date: Date(), path: path, outcome: .threat(threat.name)), scanned: true)
        onNotice(.detection(threat, kind))
    }

    private func record(_ activity: AVShieldActivity, scanned: Bool) {
        lock.withLock {
            if scanned {
                stats.filesScanned += 1
                stats.lastScanAt = activity.date
            }
            stats.recent.insert(activity, at: 0)
            if stats.recent.count > 25 { stats.recent.removeLast(stats.recent.count - 25) }
        }
        onNotice(.activity(activity))
    }

    /// Keeps the shield under its file and byte budget per second.
    private func throttle(bytes: Int64, configuration: Configuration) {
        let now = Date()
        if now.timeIntervalSince(windowStart) >= 1 {
            windowStart = now
            windowFiles = 0
            windowBytes = 0
        }
        if windowFiles >= configuration.maxFilesPerSecond || windowBytes >= configuration.maxBytesPerSecond {
            let wait = max(0, 1 - Date().timeIntervalSince(windowStart))
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            windowStart = Date()
            windowFiles = 0
            windowBytes = 0
        }
        windowFiles += 1
        windowBytes += bytes
    }
}
