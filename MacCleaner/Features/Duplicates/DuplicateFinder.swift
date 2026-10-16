import Foundation

/// Finds files with identical contents.
///
/// Pipeline: scan the locations → collapse hard links (several names of one inode
/// are one file, never duplicates) → group by size → SHA-256 of the first and last
/// 64 KiB → SHA-256 of the whole file. Only files whose full digests match are
/// reported. Every stage is cancellable and reports progress.
struct DuplicateFinder: Sendable {
    var policy: SafetyPolicy

    init(policy: SafetyPolicy = .current) {
        self.policy = policy
    }

    func findDuplicates(
        options: DuplicateScanOptions,
        progress: @escaping @Sendable (DuplicateScanProgress) -> Void = { _ in }
    ) async throws -> DuplicateScanResult {
        let cancellation = DuplicateCancellation()
        return try await withTaskCancellationHandler {
            try await scan(options: options, cancellation: cancellation, progress: progress)
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func scan(
        options: DuplicateScanOptions,
        cancellation: DuplicateCancellation,
        progress: @escaping @Sendable (DuplicateScanProgress) -> Void
    ) async throws -> DuplicateScanResult {
        let started = Date()
        var result = DuplicateScanResult(startedAt: started)

        // 1. Scanning
        progress(DuplicateScanProgress(stage: .scanning, fraction: nil, message: "Looking for files…"))
        let walkProgress = WalkProgress()
        let poller = DuplicateWalkPoller.start(walkProgress) { snapshot in
            progress(DuplicateScanProgress(stage: .scanning, fraction: nil, message: DuplicateFinder.scanningMessage(snapshot)))
        }
        let kinds = options.kinds
        let collection: DuplicateCollection
        do {
            collection = try await DuplicateFileCollector.collect(options: options, progress: walkProgress) { _, entry in
                kinds == .all || kinds.includes(DuplicateFileKind.classify(extension: (entry.name as NSString).pathExtension))
            }
            poller.cancel()
        } catch {
            poller.cancel()
            throw error
        }
        result.roots = collection.roots
        result.unavailableRoots = collection.unavailableRoots
        result.cloudOnlySkipped = collection.cloudOnlySkipped
        result.unreadableFolders = collection.unreadableFolders
        result.filesExamined = collection.files.count

        // 2. Grouping by size. Hard links are one file with several names.
        try Task.checkCancellation()
        progress(DuplicateScanProgress(
            stage: .groupingBySize, fraction: nil,
            message: "Grouping \(NumberFormatting.count(collection.files.count, "file")) by size…"
        ))
        let inodes = DuplicateInode.collapse(collection.files)
        result.hardLinkSets = inodes.compactMap(\.hardLinkSet).sorted { $0.allocatedSize > $1.allocatedSize }

        var bySize: [Int64: [Int]] = [:]
        for (index, inode) in inodes.enumerated() {
            bySize[inode.primary.entry.logicalSize, default: []].append(index)
        }
        let candidates = bySize.values.filter { $0.count >= 2 }.flatMap { $0 }
        result.filesCompared = candidates.count
        guard !candidates.isEmpty else {
            result.duration = Date().timeIntervalSince(started)
            return result
        }

        var samplePaths: [Int32: String] = [:]
        for index in candidates where samplePaths[inodes[index].primary.entry.device] == nil {
            samplePaths[inodes[index].primary.entry.device] = inodes[index].primary.path
        }
        // Partial hashes are small random reads that SSDs serve best with a deeper queue;
        // full hashes are long sequential reads where a few streams saturate the disk.
        let partialLimits = DuplicateIOLimits.forVolumes(samplePaths: samplePaths, internalLimit: 8, externalLimit: 2)
        let fullLimits = DuplicateIOLimits.forVolumes(samplePaths: samplePaths, internalLimit: 4, externalLimit: 2)
        let throttle = DuplicateProgressThrottle()

        // 3. Partial hash: first and last 64 KiB.
        try Task.checkCancellation()
        let partialTargets = candidates.map { inodes[$0].hashTarget }
        let partialTotal = partialTargets.count
        let partialDone = DuplicateLockedBox(0)
        progress(DuplicateScanProgress(
            stage: .partialHash, fraction: 0,
            message: "Comparing \(NumberFormatting.count(partialTotal)) files that share a size…"
        ))
        let partialResults = try await DuplicateWorkQueue.run(partialTargets, limits: partialLimits, device: { $0.identity.device }) { target in
            defer {
                let done = partialDone.withLock { count -> Int in
                    count += 1
                    return count
                }
                if throttle.shouldReport(force: done == partialTotal) {
                    progress(DuplicateScanProgress(
                        stage: .partialHash, fraction: Double(done) / Double(partialTotal),
                        message: "Partial hash: \(NumberFormatting.count(done)) of \(NumberFormatting.count(partialTotal, "file"))"
                    ))
                }
            }
            return try DuplicateHasher.partialDigest(of: target, cancellation: cancellation)
        }

        var bytesRead: Int64 = 0
        var partialBuckets: [DuplicateContentKey: [(inode: Int, partial: DuplicatePartialDigest)]] = [:]
        for (position, outcome) in partialResults.enumerated() {
            switch outcome {
            case .success(let partial):
                bytesRead += min(partial.dataSize, Int64(2 * DuplicateHasher.edgeLength))
                partialBuckets[DuplicateContentKey(size: partial.dataSize, digest: partial.digest), default: []]
                    .append((candidates[position], partial))
            case .failure(let error):
                Self.tally(error, into: &result)
            }
        }

        // 4. Full hash of every file whose partial digest matched another file's.
        try Task.checkCancellation()
        var fullBuckets: [DuplicateContentKey: [Int]] = [:]
        var fullTargets: [(inode: Int, target: DuplicateHashTarget, size: Int64)] = []
        for bucket in partialBuckets.values where bucket.count >= 2 {
            for member in bucket {
                if member.partial.coversWholeFile {
                    // Small files were hashed completely in the previous stage.
                    let key = DuplicateContentKey(size: member.partial.dataSize, digest: member.partial.digest)
                    fullBuckets[key, default: []].append(member.inode)
                } else {
                    fullTargets.append((member.inode, inodes[member.inode].hashTarget, member.partial.dataSize))
                }
            }
        }
        let fullTotalBytes = max(1, fullTargets.reduce(Int64(0)) { $0 + $1.size })
        let fullDoneBytes = DuplicateLockedBox<Int64>(0)
        progress(DuplicateScanProgress(
            stage: .fullHash, fraction: fullTargets.isEmpty ? 1 : 0,
            message: "Verifying \(NumberFormatting.count(fullTargets.count, "file")) (\(ByteFormatting.string(fullTotalBytes)))…"
        ))
        let fullResults = try await DuplicateWorkQueue.run(fullTargets, limits: fullLimits, device: { $0.target.identity.device }) { item in
            try DuplicateHasher.fullDigest(of: item.target, cancellation: cancellation) { count in
                let done = fullDoneBytes.withLock { total -> Int64 in
                    total += Int64(count)
                    return total
                }
                if throttle.shouldReport() {
                    progress(DuplicateScanProgress(
                        stage: .fullHash, fraction: min(1, Double(done) / Double(fullTotalBytes)),
                        message: "Full hash: \(ByteFormatting.string(done)) of \(ByteFormatting.string(fullTotalBytes))"
                    ))
                }
            }
        }
        for (position, outcome) in fullResults.enumerated() {
            switch outcome {
            case .success(let full):
                bytesRead += full.dataSize
                fullBuckets[DuplicateContentKey(size: full.dataSize, digest: full.digest), default: []].append(fullTargets[position].inode)
            case .failure(let error):
                Self.tally(error, into: &result)
            }
        }

        // 5. Results: describe each copy (dates, protection) off the main thread.
        try Task.checkCancellation()
        progress(DuplicateScanProgress(stage: .results, fraction: nil, message: "Preparing results…"))
        let matched = fullBuckets.filter { $0.value.count >= 2 }
        let policy = self.policy
        let groups: [DuplicateGroup] = await BackgroundWork.run {
            Self.describeGroups(matched, inodes: inodes, policy: policy)
        }
        result.groups = groups
        result.bytesRead = bytesRead
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    /// Builds the groups with each copy's dates and protection status (file system
    /// calls, so this runs off the main thread), largest potential savings first.
    private static func describeGroups(
        _ matched: [DuplicateContentKey: [Int]],
        inodes: [DuplicateInode],
        policy: SafetyPolicy
    ) -> [DuplicateGroup] {
        var described: [(group: DuplicateGroup, potential: Int64)] = []
        described.reserveCapacity(matched.count)
        for (key, members) in matched {
            var files: [DuplicateFile] = []
            files.reserveCapacity(members.count)
            for index in members {
                let inode = inodes[index]
                let path = inode.primary.path
                files.append(DuplicateFile(
                    path: path,
                    entry: inode.primary.entry,
                    creationDate: DuplicateFileDates.creationDate(path: path),
                    hardLinkPaths: inode.aliases,
                    protectionReason: policy.evaluate(path: path, purpose: .userFile).reason,
                    managedLibraryName: DuplicateManagedLibrary.name(for: path, home: policy.home)
                ))
            }
            files.sort { $0.path < $1.path }
            let group = DuplicateGroup(digest: key.digest.hex, contentSize: key.size, files: files)
            described.append((group, Int64(files.count - 1) * group.allocatedSizePerCopy))
        }
        described.sort { lhs, rhs in
            lhs.potential != rhs.potential ? lhs.potential > rhs.potential : lhs.group.digest < rhs.group.digest
        }
        return described.map(\.group)
    }

    private static func tally(_ error: any Error, into result: inout DuplicateScanResult) {
        switch error as? DuplicateHashFailure {
        case .changed?: result.changedFiles += 1
        case .cloudOnly?: result.cloudOnlySkipped += 1
        case .empty?: break
        case .unreadable?, nil: result.unreadableFiles += 1
        }
    }

    static func scanningMessage(_ snapshot: WalkProgress.Snapshot) -> String {
        let count = "\(NumberFormatting.count(snapshot.entriesSeen, "item")) checked"
        guard !snapshot.currentPath.isEmpty else { return count }
        return count + " · " + PathUtilities.abbreviate(snapshot.currentPath)
    }
}

/// Size plus digest: the identity of a file's contents.
private struct DuplicateContentKey: Hashable, Sendable {
    var size: Int64
    var digest: DuplicateDigest
}

/// One file (inode) with every name found for it.
struct DuplicateInode: Sendable {
    var primary: DuplicateScannedFile
    /// Other names (hard links) of the same file found during the scan.
    var aliases: [String]

    var hashTarget: DuplicateHashTarget {
        DuplicateHashTarget(path: primary.path, identity: primary.entry.identity, modificationTime: primary.entry.modificationTime)
    }

    var hardLinkSet: DuplicateHardLinkSet? {
        guard !aliases.isEmpty else { return nil }
        return DuplicateHardLinkSet(
            identity: primary.entry.identity,
            paths: [primary.path] + aliases,
            logicalSize: primary.entry.logicalSize,
            allocatedSize: primary.entry.allocatedSize,
            linkCount: primary.entry.linkCount
        )
    }

    /// Merges names of the same inode. The shortest path becomes the primary name.
    static func collapse(_ files: [DuplicateScannedFile]) -> [DuplicateInode] {
        var inodes: [DuplicateInode] = []
        inodes.reserveCapacity(files.count)
        var linked: [FileIdentity: [DuplicateScannedFile]] = [:]
        for file in files {
            if file.entry.linkCount > 1 {
                linked[file.entry.identity, default: []].append(file)
            } else {
                inodes.append(DuplicateInode(primary: file, aliases: []))
            }
        }
        for names in linked.values {
            let sorted = names.sorted { lhs, rhs in
                lhs.path.utf8.count != rhs.path.utf8.count ? lhs.path.utf8.count < rhs.path.utf8.count : lhs.path < rhs.path
            }
            guard let primary = sorted.first else { continue }
            inodes.append(DuplicateInode(primary: primary, aliases: sorted.dropFirst().map(\.path)))
        }
        return inodes
    }
}

/// Per-volume limits on parallel reads.
struct DuplicateIOLimits: Sendable {
    private let limiters: [Int32: AsyncLimiter]
    private let fallback: AsyncLimiter
    /// Upper bound on work items in flight across all volumes.
    let totalWidth: Int

    init(limits: [Int32: Int], fallbackLimit: Int = 2) {
        var limiters: [Int32: AsyncLimiter] = [:]
        for (device, limit) in limits { limiters[device] = AsyncLimiter(limit: limit) }
        self.limiters = limiters
        self.fallback = AsyncLimiter(limit: fallbackLimit)
        self.totalWidth = max(1, min(12, limits.values.reduce(0, +)))
    }

    /// The same limit for every volume (used for CPU-bound work such as image analysis).
    init(uniformLimit: Int) {
        self.limiters = [:]
        self.fallback = AsyncLimiter(limit: uniformLimit)
        self.totalWidth = max(1, uniformLimit)
    }

    /// `internalLimit` parallel reads on internal disks; `externalLimit` on external, network
    /// or unknown volumes, where more parallel reads only cause seeking or saturate the link.
    static func forVolumes(samplePaths: [Int32: String], internalLimit: Int = 4, externalLimit: Int = 2) -> DuplicateIOLimits {
        var limits: [Int32: Int] = [:]
        for (device, path) in samplePaths {
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey])
            let isInternal = values?.volumeIsInternal ?? false
            let isLocal = values?.volumeIsLocal ?? false
            limits[device] = isInternal && isLocal ? internalLimit : externalLimit
        }
        return DuplicateIOLimits(limits: limits, fallbackLimit: externalLimit)
    }

    func limiter(for device: Int32) -> AsyncLimiter {
        limiters[device] ?? fallback
    }
}

/// Runs blocking work items on GCD threads (never on the Swift concurrency pool)
/// with bounded concurrency.
enum DuplicateWorkQueue {
    /// Results are returned in input order. A `CancellationError` from any item
    /// cancels the whole run.
    static func run<Item: Sendable, Output: Sendable>(
        _ items: [Item],
        limits: DuplicateIOLimits,
        device: @escaping @Sendable (Item) -> Int32,
        work: @escaping @Sendable (Item) throws -> Output
    ) async throws -> [Result<Output, any Error>] {
        guard !items.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: (Int, Result<Output, any Error>).self) { group in
            var results = [Result<Output, any Error>?](repeating: nil, count: items.count)
            var nextIndex = 0
            func addNext() {
                guard nextIndex < items.count else { return }
                let index = nextIndex
                let item = items[index]
                nextIndex += 1
                let limiter = limits.limiter(for: device(item))
                group.addTask {
                    let outcome = await limiter.run {
                        await BackgroundWork.run { Result<Output, any Error> { try work(item) } }
                    }
                    return (index, outcome)
                }
            }
            for _ in 0..<limits.totalWidth { addNext() }
            while let (index, outcome) = try await group.next() {
                if case .failure(let error) = outcome, error is CancellationError {
                    group.cancelAll()
                    throw error
                }
                try Task.checkCancellation()
                results[index] = outcome
                addNext()
            }
            return results.map { $0 ?? .failure(CancellationError()) }
        }
    }
}
