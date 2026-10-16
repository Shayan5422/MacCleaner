import Darwin
import Foundation

/// Settings for one scan, as values.
struct AVScanConfiguration: Sendable {
    var scanner: any AVFileScanning
    var options = AVScanOptions()
    /// The person's exclusions (global and antivirus).
    var exclusions = ExclusionList()
    /// Folders never scanned (the Virus Chest and the definitions).
    var skippedRoots: [String] = []
    /// SHA-256 values the person always allows.
    var allowedHashes: Set<String> = []
    var workerCount = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
    var listingConcurrency = 3
    var queueCapacity = 4_096
    var qualityOfService: QualityOfService = .userInitiated
    /// Downloads are also checked against URLhaus/ThreatFox (Download Shield).
    var downloadRoots: [String] = []
    var intel: (any ThreatIntelLookup)?
    var usedDefinitions = true
    var definitionsDescription: String?
    /// Detections in ClamAV's own, signature-verified databases aren't reported (injectable for tests).
    var isVerifiedSignatureDatabase: @Sendable (String) -> Bool = { AVSignatureDatabases.isVerifiedDatabase(path: $0) }
}

/// Runs a scan: folders are listed with `ParallelDirectoryWalker` (never following symlinks,
/// staying on one volume, never entering cloud-only folders) and files are scanned on dedicated
/// worker threads through `AVFileScanning`, with a bounded queue between them.
final class AVScanSession: @unchecked Sendable {
    private struct Job: Sendable {
        var path: String
        var size: Int64
        var identity: FileIdentity
    }

    private let configuration: AVScanConfiguration
    private let exclusions: ExclusionList
    private let queue: AVBlockingQueue<Job>
    private let lock = NSLock()
    private var cancelled = false
    private var activeWalker: ParallelDirectoryWalker<Void>?
    private var seen = Set<FileIdentity>()
    private var progress: AVScanProgress
    private var report: AVScanReport
    private var unreadable: [String: (count: Int, sample: String)] = [:]
    private var startedAt = Date()

    init(configuration: AVScanConfiguration, kind: AVScanKind) {
        self.configuration = configuration
        var exclusions = configuration.exclusions
        for root in configuration.skippedRoots { exclusions.add(root) }
        self.exclusions = exclusions
        queue = AVBlockingQueue(capacity: configuration.queueCapacity)
        progress = AVScanProgress(kind: kind)
        report = AVScanReport(kind: kind, startedAt: Date(), finishedAt: Date(), usedDefinitions: configuration.usedDefinitions,
                              definitionsDescription: configuration.definitionsDescription)
    }

    func cancel() {
        let walker = lock.withLock { () -> ParallelDirectoryWalker<Void>? in
            cancelled = true
            return activeWalker
        }
        walker?.cancel()
        queue.close()
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func snapshot() -> AVScanProgress {
        lock.withLock {
            var value = progress
            value.elapsed = Date().timeIntervalSince(startedAt)
            if value.listingComplete, value.elapsed > 5, let fraction = value.fraction, fraction > 0.03, fraction < 1 {
                value.estimatedRemaining = value.elapsed * (1 - fraction) / fraction
            }
            return value
        }
    }

    /// Scans everything in `plan`. Blocks until done or cancelled.
    func run(plan: AVScanPlan) -> AVScanReport {
        startedAt = Date()
        lock.withLock {
            report.startedAt = startedAt
            progress.phase = .scanning
        }
        let workers = DispatchGroup()
        for _ in 0..<max(1, configuration.workerCount) {
            workers.enter()
            let thread = Thread { [self] in
                AVThreadIO.disableCloudDownloads()
                while let job = queue.pop() {
                    if isCancelled { break }
                    scan(job)
                }
                workers.leave()
            }
            thread.qualityOfService = configuration.qualityOfService
            thread.stackSize = 8 << 20
            thread.start()
        }

        AVThreadIO.disableCloudDownloads()
        for path in plan.files where !isCancelled { enqueueFile(path) }
        for target in plan.targets where !isCancelled { walk(target) }
        lock.withLock { progress.listingComplete = true }
        queue.finishAdding()
        workers.wait()

        return lock.withLock {
            progress.phase = .finishing
            report.finishedAt = Date()
            report.wasCancelled = cancelled
            let signaturePaths = Set(report.threats.map(\.path))
            let rules = plan.ruleMatches.filter { !signaturePaths.contains($0.path) && !exclusions.isExcluded($0.path) }
            report.threats = (report.threats + rules).sorted { lhs, rhs in
                lhs.category != rhs.category ? lhs.category > rhs.category : lhs.path < rhs.path
            }
            report.limitations = plan.limitations + report.limitations + unreadable.keys.sorted().map { label in
                let entry = unreadable[label]!
                return AVLimitation(
                    title: "\(NumberFormatting.count(entry.count)) folder\(entry.count == 1 ? "" : "s") in \(label) couldn't be read",
                    detail: "macOS protects \(entry.count == 1 ? "it" : "them"). Grant Full Disk Access to include protected folders in scans.",
                    path: entry.sample,
                    settingsPane: SystemSettingsPane.fullDiskAccess.rawValue
                )
            }
            return report
        }
    }

    // MARK: - Listing

    private func enqueueFile(_ path: String) {
        guard !exclusions.isExcluded(path), !AVScanScope.isSystemPath(path) else { return }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return }
        if info.st_flags & FileFlags.dataless != 0 {
            lock.withLock { report.skippedCloudOnly += 1; progress.filesSkipped += 1 }
            return
        }
        if Int64(info.st_size) > configuration.options.maxFileSize {
            lock.withLock { report.skippedTooLarge += 1; progress.filesSkipped += 1 }
            return
        }
        offer(Job(path: path, size: Int64(info.st_size), identity: FileIdentity(device: info.st_dev, inode: UInt64(info.st_ino))))
    }

    private func offer(_ job: Job) {
        let isNew = lock.withLock { () -> Bool in
            guard seen.insert(job.identity).inserted else { return false }
            progress.filesFound += 1
            progress.bytesFound += job.size
            return true
        }
        if isNew { _ = queue.push(job) }
    }

    /// True when the file was modified, or created on this volume (a download, an extracted archive member), after `cutoff`.
    static func arrived(after cutoff: Double, modified: Double, path: String) -> Bool {
        if modified >= cutoff { return true }
        var info = stat()
        guard lstat(path, &info) == 0 else { return true }
        let birth = Double(info.st_birthtimespec.tv_sec)
        let change = Double(info.st_ctimespec.tv_sec)
        return birth >= cutoff || change >= cutoff
    }

    private func walk(_ target: AVScanTarget) {
        guard !exclusions.isExcluded(target.path), !AVScanScope.isSystemPath(target.path) else { return }
        var info = stat()
        if lstat(target.path, &info) != 0 {
            if errno == EPERM || errno == EACCES { recordDenied(target) }
            return
        }
        var options = WalkOptions()
        options.includesHiddenItems = true
        options.descendsIntoPackages = true
        options.exclusions = exclusions
        options.maxDepth = target.maxDepth
        options.maxConcurrency = configuration.listingConcurrency
        let maxSize = configuration.options.maxFileSize
        let filter = target.filter
        let skippedNames = target.skippedFolderNames
        let arrivedAfter = target.arrivedWithinDays.map { Date().timeIntervalSince1970 - Double($0) * 86_400 }
        let walker = ParallelDirectoryWalker<Void>(options: options, handlers: WalkHandlers(
            didRead: { [self] directory, entries in
                let parent = (directory.path as NSString).lastPathComponent
                for entry in entries where entry.type == .regular {
                    let path = PathUtilities.join(directory.path, entry.name)
                    switch filter {
                    case .all: break
                    case .code: if !AVCodeFilter.includes(name: entry.name, parent: parent, path: path) { continue }
                    case .carriers: if !AVCodeFilter.includesCarrier(name: entry.name, parent: parent, path: path) { continue }
                    }
                    if let arrivedAfter, !Self.arrived(after: arrivedAfter, modified: entry.modificationTime, path: path) { continue }
                    if entry.isDataless {
                        lock.withLock { report.skippedCloudOnly += 1; progress.filesSkipped += 1 }
                        continue
                    }
                    if entry.logicalSize > maxSize {
                        lock.withLock { report.skippedTooLarge += 1; progress.filesSkipped += 1 }
                        continue
                    }
                    offer(Job(path: path, size: entry.logicalSize, identity: entry.identity))
                    if isCancelled { return }
                }
            },
            descend: { entry, parent in
                if skippedNames.contains(entry.name) { return nil }
                let path = PathUtilities.join(parent.path, entry.name)
                return AVScanScope.isSystemPath(path) ? nil : ()
            },
            didFail: { [self] directory, code in
                guard code == EPERM || code == EACCES else { return }
                if directory.depth == 0 {
                    recordDenied(target)
                    return
                }
                lock.withLock {
                    let current = unreadable[target.label]
                    unreadable[target.label] = ((current?.count ?? 0) + 1, current?.sample ?? directory.path)
                }
            }
        ))
        lock.withLock { activeWalker = walker }
        do {
            _ = try walker.run(rootPath: target.path, rootContext: ())
        } catch WalkError.cannotOpen(_, let code) where code == EPERM || code == EACCES {
            recordDenied(target)
        } catch {
            // Not a folder or vanished: nothing to scan.
        }
        lock.withLock { activeWalker = nil }
    }

    private func recordDenied(_ target: AVScanTarget) {
        let limitation = target.isPrivacyProtected
            ? AVLimitation(title: "Mac Cleaner wasn't allowed to read \(target.label)",
                           detail: "Allow access in System Settings › Privacy & Security › Files & Folders (or grant Full Disk Access), then scan again.",
                           path: target.path, settingsPane: SystemSettingsPane.filesAndFolders.rawValue)
            : AVLimitation(title: "\(target.label.prefix(1).uppercased() + target.label.dropFirst()) couldn't be read",
                           detail: "macOS protects this location. Grant Full Disk Access to include it.",
                           path: target.path, settingsPane: SystemSettingsPane.fullDiskAccess.rawValue)
        lock.withLock { report.limitations.append(limitation) }
    }

    // MARK: - Scanning

    private func scan(_ job: Job) {
        lock.withLock { progress.currentPath = job.path }
        let result = configuration.scanner.scanFile(atPath: job.path, options: configuration.options)
        var origin: AVDownloadOrigin?
        if !configuration.downloadRoots.isEmpty, configuration.downloadRoots.contains(where: { PathUtilities.isSameOrDescendant(job.path, of: $0) }) {
            origin = AVDownloadOriginReader.read(path: job.path, intel: configuration.intel)
        }
        let threat: AVThreat?
        var allowed = false
        var signatureDatabase = false
        if (result.isInfected || origin?.isKnownMalwareSite == true) && configuration.isVerifiedSignatureDatabase(job.path) {
            signatureDatabase = true
            threat = nil
        } else if result.isInfected || origin?.isKnownMalwareSite == true {
            let sha256 = (result.sha256 ?? (origin?.isKnownMalwareSite == true ? AVFileHasher.sha256(path: job.path) : nil))?.lowercased()
            if let sha256, configuration.allowedHashes.contains(sha256) {
                allowed = true
                threat = nil
            } else {
                threat = AVThreat(path: job.path, detections: result.detections, origin: origin?.isKnownMalwareSite == true ? origin : nil,
                                  sha256: sha256, size: job.size, snapshot: FileSnapshot(identity: job.identity, type: .regular),
                                  detectedAt: Date(), foundBy: .scan, limitsReached: result.limitsReached)
            }
        } else {
            threat = nil
        }
        lock.withLock {
            switch result.skipped {
            case .tooLarge?: report.skippedTooLarge += 1; progress.filesSkipped += 1
            case .dataless?: report.skippedCloudOnly += 1; progress.filesSkipped += 1
            case .unreadable?: report.skippedUnreadable += 1; progress.filesSkipped += 1
            case .notRegularFile?: progress.filesSkipped += 1
            case nil:
                report.filesScanned += 1
                report.bytesScanned += result.bytesScanned
                progress.filesScanned += 1
            }
            if result.encryptedMembers > 0 { report.encryptedArchives += 1 }
            if result.unsupportedMembers > 0 || result.limitsReached { report.partiallyScannedArchives += 1 }
            progress.bytesScanned += job.size
            if allowed { report.allowedCount += 1 }
            if signatureDatabase { report.ignoredSignatureDatabases += 1 }
            if let threat {
                report.threats.append(threat)
                progress.threatsFound += 1
            }
        }
    }
}

/// A bounded FIFO between listing and scanning threads.
final class AVBlockingQueue<Element: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var items: [Element] = []
    private var head = 0
    private let capacity: Int
    private var closed = false
    private var finished = false

    init(capacity: Int) { self.capacity = max(1, capacity) }

    /// Waits while the queue is full. Returns false when the queue was closed.
    @discardableResult
    func push(_ element: Element) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while items.count - head >= capacity && !closed { condition.wait() }
        guard !closed else { return false }
        items.append(element)
        condition.broadcast()
        return true
    }

    /// Waits for the next element; nil when closed or finished and empty.
    func pop() -> Element? {
        condition.lock()
        defer { condition.unlock() }
        while items.count == head && !closed && !finished { condition.wait() }
        guard !closed, head < items.count else { return nil }
        let element = items[head]
        head += 1
        if head > 1_024 && head * 2 > items.count {
            items.removeFirst(head)
            head = 0
        }
        condition.broadcast()
        return element
    }

    /// No more elements will be added; consumers drain what's left.
    func finishAdding() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    /// Stops everything now; queued elements are dropped.
    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }
}

/// Async front end for scans.
enum AVScanCoordinator {
    static func run(plan: AVScanPlan, configuration: AVScanConfiguration,
                    progress: @escaping @Sendable (AVScanProgress) -> Void = { _ in }) async -> AVScanReport {
        var configuration = configuration
        // Quick checks look for threats that can run on this Mac. Windows and Linux programs (for
        // example a Wine prefix's thousands of DLLs) are left to Full, custom and drive scans.
        if plan.kind.focusesOnMacThreats { configuration.options.detectNonMacThreats = false }
        let session = AVScanSession(configuration: configuration, kind: plan.kind)
        let poller = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                progress(session.snapshot())
            }
        }
        defer { poller.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<AVScanReport, Never>) in
                let thread = Thread { continuation.resume(returning: session.run(plan: plan)) }
                thread.qualityOfService = configuration.qualityOfService
                thread.stackSize = 1 << 20
                thread.start()
            }
        } onCancel: {
            session.cancel()
        }
    }
}
