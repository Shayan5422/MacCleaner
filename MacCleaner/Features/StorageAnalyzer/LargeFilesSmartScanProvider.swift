import Foundation

/// Smart Scan area "Large & Old Files": personal files in the home folder that
/// are large, or haven't been used for a long time.
///
/// Never looks inside ~/Library, the Trash, cloud storage folders, packages
/// (apps, Photos and other libraries, virtual machines) or developer
/// dependency folders, and skips cloud-only files. Every candidate is
/// `.review` — never selected by default — and goes to the Trash as a
/// `.userFile`.
struct LargeFilesSmartScanProvider: SmartScanProvider {
    let area: SmartScanArea = .largeFiles
    let home: String
    let policy: SafetyPolicy
    /// Most candidates per group, largest first.
    var maximumCandidates = 150
    /// Old files smaller than this aren't worth listing.
    var oldFileMinimumBytes: Int64 = 25_000_000

    static let largeCategoryID = "storage.largeFiles"
    static let oldCategoryID = "storage.oldFiles"

    init(home: String = FileManager.default.homeDirectoryForCurrentUser.path, policy: SafetyPolicy = .current) {
        self.home = PathUtilities.normalize(home)
        self.policy = policy
    }

    func smartScan(context: SmartScanContext) async throws -> SmartScanContribution {
        let preferences = context.preferences
        let threshold = max(1_000_000, preferences.largeFileThresholdBytes)
        let oldMinimum = min(oldFileMinimumBytes, threshold)
        let now = Date()
        let cutoff = now.timeIntervalSince1970 - Double(max(1, preferences.oldFileAgeDays)) * 86_400

        let skipped = Set(excludedTopLevelPaths())
        let topLevel = try FileSystemScanner()
            .children(of: home, includeHidden: preferences.includeHiddenFiles)
            .filter { !skipped.contains($0.path) && !preferences.exclusions.isExcluded($0.path) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let large = FileCollector(limit: maximumCandidates)
        let old = FileCollector(limit: maximumCandidates)
        let consider: @Sendable (String, RawDirectoryEntry) -> Void = { path, entry in
            guard entry.type == .regular, !entry.isDataless else { return }
            if entry.allocatedSize >= threshold {
                large.add(FileRecord(path: path, entry: entry))
            } else if entry.allocatedSize >= oldMinimum, max(entry.modificationTime, entry.accessTime) < cutoff {
                old.add(FileRecord(path: path, entry: entry))
            }
        }

        var options = WalkOptions()
        options.includesHiddenItems = preferences.includeHiddenFiles
        options.descendsIntoPackages = false
        options.exclusions = preferences.exclusions
        options.crossesVolumes = false

        for (index, item) in topLevel.enumerated() {
            try Task.checkCancellation()
            context.reportProgress(Double(index) / Double(max(1, topLevel.count)), "Looking for large files in \(item.name)…")
            switch item.type {
            case .regular:
                guard let entry = BulkDirectoryReader.readAttributes(path: item.path) else { continue }
                consider(item.path, entry)
            case .directory:
                guard !item.isDataless, !Self.isSkippedFolder(name: item.name) else { continue }
                let walker = ParallelDirectoryWalker<Void>(options: options, handlers: WalkHandlers(
                    didRead: { directory, entries in
                        for entry in entries where entry.type == .regular {
                            consider(PathUtilities.join(directory.path, entry.name), entry)
                        }
                    },
                    descend: { entry, _ in
                        entry.isDataless || Self.isSkippedFolder(name: entry.name) ? nil : ()
                    }
                ))
                _ = try await walker.walk(rootPath: item.path, rootContext: ())
            case .symlink, .other:
                continue
            }
        }
        try Task.checkCancellation()
        context.reportProgress(0.95, "Checking when files were last opened…")

        let policy = self.policy
        let largeRecords = large.results
        let oldRecords = old.results
        let lastOpened = await BackgroundWork.run(qos: .utility) {
            var dates: [String: Date] = [:]
            for record in largeRecords + oldRecords {
                if let date = StorageSpotlight.lastUsedDate(path: record.path) { dates[record.path] = date }
            }
            return dates
        }
        try Task.checkCancellation()

        let cutoffDate = Date(timeIntervalSince1970: cutoff)
        // Desktop & Documents may be synced with iCloud Drive: deleting there deletes everywhere, so say so.
        let syncedRoots = CloudProviderDetector.detect(home: home).filter { $0.role == .desktopAndDocuments }.map(\.path)
        let largeCandidates = largeRecords
            .filter { policy.evaluate(path: $0.path, purpose: .userFile).isAllowed }
            .map { candidate(for: $0, lastOpened: lastOpened[$0.path], isLarge: true, now: now, syncedRoots: syncedRoots) }
        let oldCandidates = oldRecords
            .filter { lastOpened[$0.path].map { $0 < cutoffDate } ?? true }
            .filter { policy.evaluate(path: $0.path, purpose: .userFile).isAllowed }
            .map { candidate(for: $0, lastOpened: lastOpened[$0.path], isLarge: false, now: now, syncedRoots: syncedRoots) }

        var findings: [Finding] = []
        if let backups = await iOSBackupFinding() { findings.append(backups) }

        let largeBytes = largeCandidates.reduce(0) { $0 + $1.usage.reclaimableBytes }
        let oldBytes = oldCandidates.reduce(0) { $0 + $1.usage.reclaimableBytes }
        var parts: [String] = []
        if !largeCandidates.isEmpty { parts.append("\(largeCandidates.count) large file\(largeCandidates.count == 1 ? "" : "s") (\(ByteFormatting.string(largeBytes)))") }
        if !oldCandidates.isEmpty { parts.append("\(oldCandidates.count) old file\(oldCandidates.count == 1 ? "" : "s") (\(ByteFormatting.string(oldBytes)))") }
        context.reportProgress(1, "Done")
        return SmartScanContribution(
            area: .largeFiles,
            candidates: largeCandidates + oldCandidates,
            findings: findings,
            summary: parts.isEmpty ? "No large or old files found" : parts.joined(separator: ", ")
        )
    }

    // MARK: - Helpers

    /// Top-level folders of the home folder that are never searched.
    func excludedTopLevelPaths() -> [String] {
        var paths = [home + "/Library", home + "/.Trash"]
        paths += CloudProviderDetector.legacyFolderPaths(home: home)
        return paths.map(PathUtilities.normalize)
    }

    /// Folders whose contents are managed by apps or tools: packages (apps, libraries, virtual
    /// machines) and dependency or build folders, which Developer Tools handles.
    static func isSkippedFolder(name: String) -> Bool {
        StoragePackages.isPackage(name: name) || StorageCategory.developerFolderNames.contains(name)
    }

    private func candidate(for record: FileRecord, lastOpened: Date?, isLarge: Bool, now: Date, syncedRoots: [String]) -> CleanupCandidate {
        let category = StorageCategory.classify(fileName: record.name, logicalSize: record.logicalSize)
        var detail = category.singularTitle
        if let lastOpened {
            detail += " · last opened \(DateFormatting.relative(lastOpened, to: now))"
        } else {
            detail += " · modified \(DateFormatting.relative(record.modificationDate, to: now))"
        }
        if record.linkCount > 1 { detail += " · hard link" }
        if syncedRoots.contains(where: { PathUtilities.isSameOrDescendant(record.path, of: $0) }) {
            detail += " · in iCloud Drive (removing it removes it from all devices)"
        }
        let usage = DiskUsage(
            logicalBytes: record.logicalSize, allocatedBytes: record.allocatedSize,
            reclaimableBytes: record.exclusiveSize, cloudOnlyBytes: 0, fileCount: 1
        )
        return CleanupCandidate(
            path: record.path,
            title: record.name,
            detail: detail,
            categoryID: isLarge ? Self.largeCategoryID : Self.oldCategoryID,
            categoryTitle: isLarge ? "Large Files" : "Old Files",
            usage: usage,
            snapshot: record.snapshot,
            safety: .review,
            purpose: .userFile,
            modificationDate: record.modificationDate
        )
    }

    /// iPhone and iPad backups live in ~/Library, which Smart Scan never cleans; they're reported as a finding.
    private func iOSBackupFinding() async -> Finding? {
        let path = home + "/Library/Application Support/MobileSync/Backup"
        guard FileManager.default.fileExists(atPath: path),
              let usage = try? await FileSystemScanner().measure(path: path),
              usage.allocatedBytes >= 500_000_000 else { return nil }
        return Finding(
            area: .largeFiles,
            severity: .recommendation,
            title: "iPhone and iPad backups use \(ByteFormatting.string(usage.allocatedBytes))",
            detail: "Local device backups can be large and are kept until you delete them.",
            path: path,
            recommendation: "In Finder, select your device, click Manage Backups and delete backups you no longer need.",
            destination: .storage
        )
    }
}
