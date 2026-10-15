import CoreServices
import Foundation

/// Results for one junk category.
struct JunkCategoryResult: Sendable, Identifiable {
    var category: JunkCategory
    var candidates: [CleanupCandidate]

    var id: String { category.id }
    var totalBytes: Int64 { candidates.reduce(0) { $0 + $1.usage.reclaimableBytes } }
}

/// Finds caches, logs, temporary files and other regenerable data in the
/// person's account. Read-only: removal happens through `CleanupEngine`.
struct SystemJunkScanner: Sendable {
    /// Where to look; injectable so tests can use a fake home folder.
    struct Locations: Sendable {
        var home: String
        var temporaryDirectory: String?
        var sharedTemporaryDirectory: String? = "/private/tmp"

        var library: String { home + "/Library" }

        static var current: Locations {
            let policy = SafetyPolicy.current
            return Locations(home: policy.home, temporaryDirectory: policy.userTemporaryDirectory)
        }
    }

    var locations: Locations
    /// Reading other apps' containers needs Full Disk Access (or triggers a privacy prompt), so it's opt-in.
    var includeAppContainers: Bool
    var ownBundleIdentifier: String?
    /// Items untouched for less than this are never offered as temporary junk.
    var temporaryMinimumAge: TimeInterval = 3 * 86_400
    /// Installers newer than this are probably still being used.
    var installerMinimumAge: TimeInterval = 2 * 86_400

    init(
        locations: Locations = .current,
        includeAppContainers: Bool = FullDiskAccessProbe.status() == .granted,
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        self.locations = locations
        self.includeAppContainers = includeAppContainers
        self.ownBundleIdentifier = ownBundleIdentifier
    }

    // MARK: - Scanning

    func scan(
        categories: Set<String>? = nil,
        preferences: ScanPreferences,
        now: Date = Date(),
        progress: @escaping @Sendable (_ fraction: Double, _ message: String) -> Void = { _, _ in }
    ) async throws -> [JunkCategoryResult] {
        let selected = JunkCategory.all.filter { categories?.contains($0.id) ?? true }
        var results: [JunkCategoryResult] = []
        for (index, category) in selected.enumerated() {
            try Task.checkCancellation()
            progress(Double(index) / Double(max(selected.count, 1)), "Looking for \(category.title.lowercased())…")
            let specs = collect(category, preferences: preferences, now: now)
                .filter { !preferences.exclusions.isExcluded($0.path) }
            let candidates = try await measure(specs, category: category, preferences: preferences, now: now) { fraction in
                progress((Double(index) + fraction) / Double(max(selected.count, 1)), "Measuring \(category.title.lowercased())…")
            }
            if !candidates.isEmpty {
                results.append(JunkCategoryResult(category: category, candidates: candidates))
            }
        }
        progress(1, "Done")
        return results
    }

    /// One item to measure before it becomes a candidate.
    struct ItemSpec: Sendable {
        var path: String
        var title: String
        var detail: String?
        var safety: CleanupSafety
        var purpose: DeletionPurpose
        var ownerBundleIdentifier: String?
        /// Age rule applied after measuring.
        var ageRule: AgeRule = .none
    }

    enum AgeRule: Sendable {
        case none
        /// Drop the item if anything inside changed more recently than this.
        case dropIfNewerThan(TimeInterval)
        /// Keep the item but mark it for review if something inside changed recently.
        case reviewIfNewerThan(TimeInterval)
        /// Keep only if both modification and last-open dates are older than this.
        case keepIfUnusedFor(TimeInterval)
    }

    // MARK: - Collecting

    func collect(_ category: JunkCategory, preferences: ScanPreferences, now: Date) -> [ItemSpec] {
        let library = locations.library
        switch category.id {
        case JunkCategory.applicationCaches.id, JunkCategory.systemCaches.id:
            let wantsApple = category.id == JunkCategory.systemCaches.id
            var specs: [ItemSpec] = []
            for name in listNames(library + "/Caches") {
                guard !JunkExclusions.isExcludedCacheFolder(name, ownBundleIdentifier: ownBundleIdentifier) else { continue }
                guard isAppleCache(name) == wantsApple else { continue }
                let (title, detail, owner) = describeBundleNamed(name)
                specs.append(ItemSpec(path: library + "/Caches/" + name, title: title, detail: detail,
                                      safety: wantsApple ? .review : .safe, purpose: .junk, ownerBundleIdentifier: owner))
            }
            if includeAppContainers {
                for container in listNames(library + "/Containers") {
                    guard isAppleCache(container) == wantsApple, container != ownBundleIdentifier,
                          !JunkExclusions.isExcludedCacheFolder(container, ownBundleIdentifier: ownBundleIdentifier) else { continue }
                    let caches = library + "/Containers/" + container + "/Data/Library/Caches"
                    let (appTitle, _, owner) = describeBundleNamed(container)
                    for child in listNames(caches) {
                        specs.append(ItemSpec(path: caches + "/" + child, title: appTitle, detail: "Sandboxed cache · \(child)",
                                              safety: wantsApple ? .review : .safe, purpose: .junk, ownerBundleIdentifier: owner))
                    }
                }
            }
            return specs

        case JunkCategory.temporaryFiles.id:
            var specs: [ItemSpec] = []
            if let temporary = locations.temporaryDirectory {
                for name in listNames(temporary) where !isOwnItem(name) {
                    specs.append(ItemSpec(path: temporary + "/" + name, title: name, detail: "Your temporary folder",
                                          safety: .safe, purpose: .junk, ageRule: .dropIfNewerThan(temporaryMinimumAge)))
                }
            }
            if let shared = locations.sharedTemporaryDirectory {
                let uid = getuid()
                for name in listNames(shared) {
                    let path = shared + "/" + name
                    var info = stat()
                    guard lstat(path, &info) == 0, info.st_uid == uid else { continue }
                    specs.append(ItemSpec(path: path, title: name, detail: "Shared temporary folder (/tmp)",
                                          safety: .safe, purpose: .junk, ageRule: .dropIfNewerThan(temporaryMinimumAge)))
                }
            }
            return specs

        case JunkCategory.logs.id:
            let recent = TimeInterval(max(1, preferences.logAgeDays)) * 86_400
            var specs: [ItemSpec] = []
            for name in listNames(library + "/Logs") where !["DiagnosticReports", "CrashReporter", "Mac Cleaner"].contains(name) {
                let (title, detail, owner) = describeBundleNamed(name)
                specs.append(ItemSpec(path: library + "/Logs/" + name, title: title, detail: detail,
                                      safety: .safe, purpose: .junk, ownerBundleIdentifier: owner, ageRule: .reviewIfNewerThan(recent)))
            }
            if includeAppContainers {
                for container in listNames(library + "/Containers") where container != ownBundleIdentifier {
                    let logs = library + "/Containers/" + container + "/Data/Library/Logs"
                    let (appTitle, _, owner) = describeBundleNamed(container)
                    for child in listNames(logs) {
                        specs.append(ItemSpec(path: logs + "/" + child, title: appTitle, detail: "Sandboxed log · \(child)",
                                              safety: .safe, purpose: .junk, ownerBundleIdentifier: owner, ageRule: .reviewIfNewerThan(recent)))
                    }
                }
            }
            return specs

        case JunkCategory.crashReports.id:
            var specs: [ItemSpec] = []
            for folder in [library + "/Logs/DiagnosticReports", library + "/Logs/DiagnosticReports/Retired"] {
                for name in listNames(folder) {
                    let path = folder + "/" + name
                    guard isRegularFile(path) else { continue }
                    let (app, date) = parseCrashReportName(name)
                    specs.append(ItemSpec(path: path, title: app, detail: date.map { "Report from \(DateFormatting.day($0))" } ?? name,
                                          safety: .safe, purpose: .junk))
                }
            }
            return specs

        case JunkCategory.xcodeBuildData.id:
            let derived = library + "/Developer/Xcode/DerivedData"
            return listNames(derived).map { name in
                let path = derived + "/" + name
                let (title, detail) = describeDerivedData(folder: path, name: name)
                return ItemSpec(path: path, title: title, detail: detail, safety: .safe, purpose: .junk)
            }

        case JunkCategory.savedState.id:
            let folder = library + "/Saved Application State"
            return listNames(folder).filter { $0.hasSuffix(".savedState") }.compactMap { name in
                let bundleID = String(name.dropLast(".savedState".count))
                guard bundleID != ownBundleIdentifier else { return nil }
                let (title, _, owner) = describeBundleNamed(bundleID)
                return ItemSpec(path: folder + "/" + name, title: title, detail: title == bundleID ? nil : bundleID,
                                safety: .review, purpose: .junk, ownerBundleIdentifier: owner)
            }

        case JunkCategory.deviceUpdates.id:
            var specs: [ItemSpec] = []
            for device in ["iPhone", "iPad", "iPod"] {
                let folder = library + "/iTunes/\(device) Software Updates"
                for name in listNames(folder) where name.lowercased().hasSuffix(".ipsw") {
                    specs.append(ItemSpec(path: folder + "/" + name, title: name, detail: "\(device) firmware", safety: .safe, purpose: .junk))
                }
            }
            return specs

        case JunkCategory.mailDownloads.id:
            let folder = library + "/Containers/com.apple.mail/Data/Library/Mail Downloads"
            guard includeAppContainers else { return [] }
            return listNames(folder).map { name in
                let path = folder + "/" + name
                let firstFile = listNames(path).first
                return ItemSpec(path: path, title: firstFile ?? name, detail: "Copy of a Mail attachment", safety: .review, purpose: .junk)
            }

        case JunkCategory.installers.id:
            let downloads = locations.home + "/Downloads"
            return listNames(downloads).filter { isInstaller($0) }.map { name in
                ItemSpec(path: downloads + "/" + name, title: name, detail: "Installer in Downloads", safety: .review,
                         purpose: .userFile, ageRule: .dropIfNewerThan(installerMinimumAge))
            }

        case JunkCategory.oldDownloads.id:
            let downloads = locations.home + "/Downloads"
            let age = TimeInterval(max(1, preferences.oldDownloadAgeDays)) * 86_400
            return listNames(downloads).filter { !isInstaller($0) && !$0.hasPrefix(".") }.map { name in
                ItemSpec(path: downloads + "/" + name, title: name, detail: nil, safety: .review,
                         purpose: .userFile, ageRule: .keepIfUnusedFor(age))
            }

        default:
            return []
        }
    }

    // MARK: - Measuring

    private func measure(
        _ specs: [ItemSpec],
        category: JunkCategory,
        preferences: ScanPreferences,
        now: Date,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [CleanupCandidate] {
        guard !specs.isEmpty else { return [] }
        var options = WalkOptions()
        options.exclusions = preferences.exclusions

        // Items that share a parent folder are measured in one parallel walk of that folder.
        let byParent = Dictionary(grouping: specs) { ($0.path as NSString).deletingLastPathComponent }
        var candidates: [CleanupCandidate] = []
        var singles: [ItemSpec] = []
        var finishedGroups = 0
        for (parent, group) in byParent {
            guard group.count >= 4 else {
                singles.append(contentsOf: group)
                continue
            }
            try Task.checkCancellation()
            let names = Set(group.map { ($0.path as NSString).lastPathComponent })
            options.maxConcurrency = WalkOptions.defaultConcurrency
            let measurements = (try? await FileSystemScanner().measureChildren(of: parent, options: options) { names.contains($0) }) ?? [:]
            for spec in group {
                guard let measured = measurements[spec.path] else { continue }
                let detailed = Measured(usage: measured.usage, newestModification: measured.newestModification,
                                        lastOpened: max(measured.lastAccess, measured.newestModification))
                if let candidate = Self.makeCandidate(spec, measured: detailed, category: category, now: now) {
                    candidates.append(candidate)
                }
            }
            finishedGroups += group.count
            progress(Double(finishedGroups) / Double(specs.count))
        }

        options.maxConcurrency = 3
        let walkOptions = options
        let counter = ProgressCounter(total: specs.count, alreadyDone: finishedGroups)
        try await withThrowingTaskGroup(of: CleanupCandidate?.self) { group in
            var iterator = singles.makeIterator()
            func addNext() {
                guard let spec = iterator.next() else { return }
                group.addTask {
                    defer { progress(counter.increment()) }
                    guard let measured = try? await Self.measureDetailed(spec.path, options: walkOptions) else { return nil }
                    return Self.makeCandidate(spec, measured: measured, category: category, now: now)
                }
            }
            for _ in 0..<6 { addNext() }
            while let result = try await group.next() {
                if let result { candidates.append(result) }
                try Task.checkCancellation()
                addNext()
            }
        }
        return candidates.sorted { $0.usage.reclaimableBytes > $1.usage.reclaimableBytes }
    }

    struct Measured: Sendable {
        var usage: DiskUsage
        var newestModification: Date
        var lastOpened: Date
    }

    /// Measures size together with the most recent modification inside (for age rules).
    static func measureDetailed(_ path: String, options: WalkOptions) async throws -> Measured {
        guard let root = BulkDirectoryReader.readAttributes(path: path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let rootModified = Date(timeIntervalSince1970: root.modificationTime)
        let rootOpened = Date(timeIntervalSince1970: root.accessTime)
        let accumulator = UsageAccumulator()
        guard root.type == .directory else {
            accumulator.add(root)
            return Measured(usage: accumulator.current, newestModification: rootModified, lastOpened: max(rootOpened, rootModified))
        }
        let newest = NewestDate(initial: rootModified)
        let walker = ParallelDirectoryWalker<Void>(options: options, handlers: WalkHandlers(
            didRead: { _, entries in
                let files = entries.filter { $0.type != .directory }
                accumulator.add(files)
                if let latest = entries.map(\.modificationTime).max() {
                    newest.update(Date(timeIntervalSince1970: latest))
                }
            },
            descend: { _, _ in
                accumulator.addDirectory()
                return ()
            },
            didFail: { _, _ in accumulator.addUnreadableDirectory() }
        ))
        _ = try await walker.walk(rootPath: path, rootContext: ())
        try Task.checkCancellation()
        return Measured(usage: accumulator.current, newestModification: newest.value, lastOpened: max(rootOpened, newest.value))
    }

    static func makeCandidate(_ spec: ItemSpec, measured: Measured, category: JunkCategory, now: Date) -> CleanupCandidate? {
        // Empty folders and tiny files aren't worth showing.
        guard measured.usage.allocatedBytes >= 4_096 || measured.usage.fileCount > 25 else { return nil }
        var safety = spec.safety
        var detail = spec.detail
        let age = now.timeIntervalSince(measured.newestModification)
        switch spec.ageRule {
        case .none:
            break
        case .dropIfNewerThan(let minimum):
            if age < minimum { return nil }
        case .reviewIfNewerThan(let minimum):
            if age < minimum {
                safety = max(safety, .review)
                detail = [detail, "Updated \(DateFormatting.relative(measured.newestModification, to: now))"].compactMap { $0 }.joined(separator: " · ")
            }
        case .keepIfUnusedFor(let minimum):
            let lastUse = max(measured.newestModification, measured.lastOpened)
            if now.timeIntervalSince(lastUse) < minimum { return nil }
            detail = "Last used \(DateFormatting.relative(lastUse, to: now))"
        }
        let fileCountText = measured.usage.fileCount > 1 ? "\(NumberFormatting.count(measured.usage.fileCount)) files" : nil
        let combinedDetail = [detail, fileCountText].compactMap { $0 }.joined(separator: " · ")
        return CleanupCandidate(
            path: spec.path,
            title: spec.title,
            detail: combinedDetail.isEmpty ? nil : combinedDetail,
            categoryID: category.id,
            categoryTitle: category.title,
            usage: measured.usage,
            safety: safety,
            purpose: spec.purpose,
            modificationDate: measured.newestModification,
            ownerBundleIdentifier: spec.ownerBundleIdentifier
        )
    }

    // MARK: - Helpers

    private func listNames(_ directory: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0 != ".DS_Store" && $0 != ".localized" }
            .sorted()
    }

    private func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && FileObjectType(mode: info.st_mode) == .regular
    }

    private func isOwnItem(_ name: String) -> Bool {
        guard let ownBundleIdentifier else { return false }
        return name.hasPrefix(ownBundleIdentifier)
    }

    private func isInstaller(_ name: String) -> Bool {
        JunkExclusions.installerExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private static let appleCacheNames: Set<String> = [
        "GeoServices", "Metadata", "PassKit", "SiriTTS", "familycircled", "storeassetd", "storeaccountd",
        "AMSDataMigratorTool", "SpeechModels", "TemporaryItems", "com.crashlytics.data",
    ]

    private func isAppleCache(_ name: String) -> Bool {
        name.hasPrefix("com.apple.") || name.hasPrefix("group.com.apple.") || Self.appleCacheNames.contains(name)
    }

    /// Turns a bundle-identifier-like folder name into a readable title.
    private func describeBundleNamed(_ name: String) -> (title: String, detail: String?, owner: String?) {
        guard name.split(separator: ".").count >= 3 else { return (name, nil, nil) }
        if let appName = BundleNameResolver.shared.applicationName(for: name) {
            return (appName, name, name)
        }
        return (name, nil, nil)
    }

    private func describeDerivedData(folder: String, name: String) -> (String, String?) {
        if name == "ModuleCache.noindex" { return ("Module cache", "Shared by all projects") }
        let plist = folder + "/info.plist"
        if let data = FileManager.default.contents(atPath: plist),
           let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let workspace = info["WorkspacePath"] as? String {
            let project = ((workspace as NSString).lastPathComponent as NSString).deletingPathExtension
            let exists = FileManager.default.fileExists(atPath: workspace)
            return (project, exists ? PathUtilities.abbreviate(workspace) : "Project no longer exists")
        }
        let base = name.split(separator: "-").dropLast().joined(separator: "-")
        return (base.isEmpty ? name : base, nil)
    }

    /// "Safari-2026-10-01-101530.ips" → ("Safari", date).
    func parseCrashReportName(_ name: String) -> (String, Date?) {
        let base = (name as NSString).deletingPathExtension
        let parts = base.split(separator: "-", omittingEmptySubsequences: false)
        if let yearIndex = parts.firstIndex(where: { $0.count == 4 && Int($0) != nil && $0.hasPrefix("20") }), yearIndex > 0,
           parts.count >= yearIndex + 3 {
            let app = parts[..<yearIndex].joined(separator: "-")
            var components = DateComponents()
            components.year = Int(parts[yearIndex])
            components.month = Int(parts[yearIndex + 1])
            components.day = Int(parts[yearIndex + 2])
            return (app, Calendar.current.date(from: components))
        }
        return (base, nil)
    }
}

/// Resolves bundle identifiers to installed app names (thread-safe, cached).
final class BundleNameResolver: @unchecked Sendable {
    static let shared = BundleNameResolver()
    private let lock = NSLock()
    private var cache: [String: String?] = [:]

    func applicationName(for bundleIdentifier: String) -> String? {
        if let cached = lock.withLock({ cache[bundleIdentifier] }) { return cached }
        var name: String?
        if let urls = LSCopyApplicationURLsForBundleIdentifier(bundleIdentifier as CFString, nil)?.takeRetainedValue() as? [URL],
           let first = urls.first {
            name = first.deletingPathExtension().lastPathComponent
        }
        lock.withLock { cache[bundleIdentifier] = name }
        return name
    }
}

private final class NewestDate: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(initial: Date) { date = initial }

    func update(_ candidate: Date) {
        lock.withLock { if candidate > date { date = candidate } }
    }

    var value: Date { lock.withLock { date } }
}

private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var done = 0
    private let total: Int

    init(total: Int, alreadyDone: Int = 0) {
        self.total = max(total, 1)
        self.done = alreadyDone
    }

    func increment() -> Double {
        lock.withLock {
            done += 1
            return Double(done) / Double(total)
        }
    }
}

/// System Junk's contribution to Smart Scan.
struct SystemJunkSmartScanProvider: SmartScanProvider {
    var area: SmartScanArea { .junk }
    var scanner: SystemJunkScanner = SystemJunkScanner()

    func smartScan(context: SmartScanContext) async throws -> SmartScanContribution {
        let results = try await scanner.scan(preferences: context.preferences, progress: context.reportProgress)
        let candidates = results.flatMap(\.candidates)
        let safeBytes = candidates.filter { $0.safety == .safe }.reduce(Int64(0)) { $0 + $1.usage.reclaimableBytes }
        return SmartScanContribution(
            area: .junk,
            candidates: candidates,
            summary: candidates.isEmpty ? "No junk found" : "\(ByteFormatting.string(safeBytes)) of caches, logs and temporary files"
        )
    }
}
