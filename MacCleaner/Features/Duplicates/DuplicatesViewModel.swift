import AppKit
import Foundation
import Observation

/// Short-lived feedback shown above the results.
struct DuplicateNotice: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var style: InfoCallout.Style = .info
}

/// State and actions of the Duplicate Finder screen: locations and options,
/// exact-duplicate and similar-photo scans, selection, and moving files to the Trash.
@MainActor
@Observable
final class DuplicatesViewModel {
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case exact, similar

        var id: String { rawValue }

        var title: String {
            switch self {
            case .exact: return "Exact Duplicates"
            case .similar: return "Similar Photos"
            }
        }

        var symbolName: String {
            switch self {
            case .exact: return "doc.on.doc"
            case .similar: return "photo.on.rectangle.angled"
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case scanning
        case finished
        case failed(String)
    }

    let services: AppServices
    let cleanupFlow = CleanupFlow()

    // MARK: Persisted settings

    var mode: Mode {
        didSet { defaults.set(mode.rawValue, forKey: Keys.mode) }
    }
    private(set) var locations: [DuplicateLocation] {
        didSet { locationStore.save(locations) }
    }
    var minimumSize: DuplicateMinimumSize {
        didSet { defaults.set(NSNumber(value: minimumSize.rawValue), forKey: Keys.minimumSize) }
    }
    var kindFilter: DuplicateKindFilter {
        didSet { defaults.set(kindFilter.rawValue, forKey: Keys.kindFilter) }
    }
    var skipDeveloperFolders: Bool {
        didSet { defaults.set(skipDeveloperFolders, forKey: Keys.skipDeveloperFolders) }
    }
    var keepRule: DuplicateKeepRule {
        didSet {
            defaults.set(keepRule.rawValue, forKey: Keys.keepRule)
            refreshReclaimable()
        }
    }
    private(set) var preferredFolder: String? {
        didSet {
            defaults.set(preferredFolder, forKey: Keys.preferredFolder)
            keepContext = DuplicateKeepContext.standard(preferredFolder: preferredFolder)
            refreshReclaimable()
        }
    }
    /// 0 (loosely similar) ... 1 (nearly identical).
    var similarity: Double {
        didSet {
            defaults.set(similarity, forKey: Keys.similarity)
            scheduleRegroup()
        }
    }

    // MARK: Transient UI state

    var searchText = ""
    var quickLookURL: URL?
    private(set) var quickLookItems: [URL] = []
    private(set) var notice: DuplicateNotice?
    private(set) var availableVolumes: [VolumeInfo] = []
    private(set) var keepContext: DuplicateKeepContext

    // MARK: Exact duplicates

    private(set) var exactPhase: Phase = .idle
    private(set) var exactProgress: DuplicateScanProgress?
    private(set) var exactResult: DuplicateScanResult?
    /// Groups sorted by reclaimable space under the current keep rule.
    private(set) var groups: [DuplicateGroup] = []
    private(set) var reclaimableByGroup: [String: Int64] = [:]
    private(set) var totalReclaimable: Int64 = 0
    var selectedGroupID: DuplicateGroup.ID?
    private(set) var marks = DuplicateMarkSet() {
        didSet { updateMarkedBytes() }
    }
    private(set) var markedBytes: Int64 = 0

    // MARK: Similar photos

    private(set) var similarPhase: Phase = .idle
    private(set) var similarProgress: SimilarScanProgress?
    private(set) var similarResult: SimilarPhotoScanResult?
    private(set) var similarGroups: [SimilarPhotoGroup] = []
    var selectedSimilarGroupID: SimilarPhotoGroup.ID?
    private(set) var similarMarks = DuplicateMarkSet() {
        didSet { updateSimilarMarkedBytes() }
    }
    private(set) var similarMarkedBytes: Int64 = 0
    /// Photos removed from the results after the scan (moved to the Trash or excluded).
    private var hiddenSimilarPaths = Set<String>()

    private let defaults: UserDefaults
    private let locationStore: DuplicateLocationStore
    private var scanTask: Task<Void, Never>?
    private var regroupTask: Task<Void, Never>?
    private var regroupGeneration = 0
    private var noticeTask: Task<Void, Never>?

    private enum Keys {
        static let mode = "duplicates.mode"
        static let minimumSize = "duplicates.minimumSize"
        static let kindFilter = "duplicates.kindFilter"
        static let skipDeveloperFolders = "duplicates.skipDeveloperFolders"
        static let keepRule = "duplicates.keepRule"
        static let preferredFolder = "duplicates.preferredFolder"
        static let similarity = "duplicates.similarity"
    }

    init(services: AppServices, defaults: UserDefaults = .standard) {
        self.services = services
        self.defaults = defaults
        let store = DuplicateLocationStore(defaults: defaults)
        self.locationStore = store
        self.locations = store.load()
        self.mode = defaults.string(forKey: Keys.mode).flatMap(Mode.init(rawValue:)) ?? .exact
        self.minimumSize = (defaults.object(forKey: Keys.minimumSize) as? NSNumber)
            .flatMap { DuplicateMinimumSize(rawValue: $0.int64Value) } ?? .kilobytes100
        self.kindFilter = defaults.string(forKey: Keys.kindFilter).flatMap(DuplicateKindFilter.init(rawValue:)) ?? .all
        self.skipDeveloperFolders = defaults.object(forKey: Keys.skipDeveloperFolders) as? Bool ?? true
        self.keepRule = defaults.string(forKey: Keys.keepRule).flatMap(DuplicateKeepRule.init(rawValue:)) ?? .oldest
        let preferred = defaults.string(forKey: Keys.preferredFolder)
        self.preferredFolder = preferred
        self.keepContext = DuplicateKeepContext.standard(preferredFolder: preferred)
        self.similarity = defaults.object(forKey: Keys.similarity) as? Double ?? SimilarPhotoThreshold.defaultSimilarity
    }

    // MARK: - Derived state

    var isScanning: Bool { exactPhase == .scanning || similarPhase == .scanning }
    var enabledRoots: [String] { locations.filter(\.isEnabled).map(\.path) }
    var canStartScan: Bool { !isScanning && !enabledRoots.isEmpty }
    var duplicateFileCount: Int { groups.reduce(0) { $0 + $1.files.count - 1 } }
    var similarityThreshold: Float { SimilarPhotoThreshold.distance(forSimilarity: similarity) }
    var similarityLabel: String { SimilarPhotoThreshold.label(forSimilarity: similarity) }
    var similarPhotoCount: Int { similarGroups.reduce(0) { $0 + $1.photos.count } }

    var preferredFolderName: String? {
        preferredFolder.map { FileManager.default.displayName(atPath: $0) }
    }

    var selectedGroup: DuplicateGroup? {
        guard let selectedGroupID else { return nil }
        return groups.first { $0.id == selectedGroupID }
    }

    var selectedSimilarGroup: SimilarPhotoGroup? {
        guard let selectedSimilarGroupID else { return nil }
        return similarGroups.first { $0.id == selectedSimilarGroupID }
    }

    private var trimmedSearch: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var filteredGroups: [DuplicateGroup] {
        let query = trimmedSearch
        guard !query.isEmpty else { return groups }
        return groups.filter { group in
            group.files.contains { $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) }
        }
    }

    var filteredSimilarGroups: [SimilarPhotoGroup] {
        let query = trimmedSearch
        guard !query.isEmpty else { return similarGroups }
        return similarGroups.filter { group in
            group.photos.contains { $0.file.name.localizedCaseInsensitiveContains(query) || $0.file.path.localizedCaseInsensitiveContains(query) }
        }
    }

    /// Folders chosen elsewhere in the app that aren't in the list yet.
    var previouslyChosenFolders: [AuthorizedLocation] {
        services.permissions.authorizedLocations.filter { chosen in
            !locations.contains { $0.path == PathUtilities.normalize(chosen.path) }
        }
    }

    // MARK: - Locations

    func setLocation(_ location: DuplicateLocation, enabled: Bool) {
        guard let index = locations.firstIndex(where: { $0.id == location.id }) else { return }
        locations[index].isEnabled = enabled
    }

    func addLocation(path: String) {
        let normalized = PathUtilities.normalize(path)
        guard !normalized.isEmpty else { return }
        if let index = locations.firstIndex(where: { $0.path == normalized }) {
            locations[index].isEnabled = true
        } else {
            locations.append(DuplicateLocation(path: normalized, isDefault: false, isEnabled: true))
        }
    }

    func removeLocation(_ location: DuplicateLocation) {
        guard !location.isDefault else { return }
        locations.removeAll { $0.id == location.id }
    }

    func resetLocations() {
        locations = DuplicateLocation.defaults()
    }

    /// Asks for a folder or drive and adds it to the list.
    func chooseFolder() {
        guard let url = services.permissions.chooseFolder(
            message: "Choose a folder or drive to search for duplicates.",
            prompt: "Add"
        ) else { return }
        addLocation(path: url.path)
    }

    func refreshVolumes() {
        Task { [weak self] in
            let volumes = await BackgroundWork.run(qos: .utility) { VolumeService.mountedVolumes() }
            self?.availableVolumes = volumes.filter { !$0.isRootFileSystem }
        }
    }

    // MARK: - Scanning

    func startScan() {
        switch mode {
        case .exact: startExactScan()
        case .similar: startSimilarScan()
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    private func makeOptions() -> DuplicateScanOptions {
        let preferences = services.settings.scanPreferences
        return DuplicateScanOptions(
            roots: enabledRoots,
            minimumSize: minimumSize.rawValue,
            kinds: kindFilter,
            includeHiddenFiles: preferences.includeHiddenFiles,
            exclusions: preferences.exclusions,
            skipDeveloperFolders: skipDeveloperFolders
        )
    }

    private func startExactScan() {
        guard canStartScan else { return }
        let options = makeOptions()
        let finder = DuplicateFinder(policy: services.policy)
        exactPhase = .scanning
        exactProgress = DuplicateScanProgress(stage: .scanning, fraction: nil, message: "Starting…")
        services.logger.info(
            "Duplicate scan started: \(options.roots.count) locations, minimum \(ByteFormatting.string(options.minimumSize)), kinds \(options.kinds.rawValue)",
            category: .duplicates
        )
        let (stream, continuation) = AsyncStream.makeStream(of: DuplicateScanProgress.self, bufferingPolicy: .bufferingNewest(1))
        scanTask = Task { [weak self] in
            let progressTask = Task { [weak self] in
                for await progress in stream {
                    // A late event from an earlier stage (the walk poller) must not move progress backwards.
                    if let current = self?.exactProgress, progress.stage < current.stage { continue }
                    self?.exactProgress = progress
                }
            }
            do {
                let result = try await finder.findDuplicates(options: options) { continuation.yield($0) }
                continuation.finish()
                progressTask.cancel()
                self?.finishExactScan(result)
            } catch {
                continuation.finish()
                progressTask.cancel()
                self?.exactScanStopped(error)
            }
        }
    }

    private func finishExactScan(_ result: DuplicateScanResult) {
        exactResult = result
        groups = result.groups
        marks = DuplicateMarkSet()
        refreshReclaimable()
        selectedGroupID = groups.first?.id
        exactPhase = .finished
        if result.unreadableFolders > 0 { services.permissions.refresh() }
        services.logger.info(
            "Duplicate scan finished: \(result.groups.count) groups, \(result.duplicateFileCount) duplicate files, \(ByteFormatting.string(totalReclaimable)) reclaimable, \(result.filesExamined) files examined, \(result.filesCompared) compared, \(ByteFormatting.string(result.bytesRead)) read, \(result.cloudOnlySkipped) cloud-only skipped, \(result.unreadableFiles) unreadable, \(String(format: "%.1f", result.duration))s",
            category: .duplicates
        )
    }

    private func exactScanStopped(_ error: any Error) {
        if error is CancellationError {
            exactPhase = exactResult == nil ? .idle : .finished
            services.logger.info("Duplicate scan cancelled", category: .duplicates)
        } else {
            exactPhase = .failed(error.localizedDescription)
            services.logger.error("Duplicate scan failed (\(String(describing: type(of: error))))", category: .duplicates)
        }
    }

    private func startSimilarScan() {
        guard canStartScan else { return }
        let options = makeOptions()
        let finder = SimilarPhotoFinder(policy: services.policy)
        similarPhase = .scanning
        similarProgress = SimilarScanProgress(stage: .scanning, fraction: nil, message: "Starting…")
        services.logger.info("Similar photo scan started: \(options.roots.count) locations", category: .duplicates)
        let (stream, continuation) = AsyncStream.makeStream(of: SimilarScanProgress.self, bufferingPolicy: .bufferingNewest(1))
        scanTask = Task { [weak self] in
            let progressTask = Task { [weak self] in
                for await progress in stream {
                    if let current = self?.similarProgress, progress.stage < current.stage { continue }
                    self?.similarProgress = progress
                }
            }
            do {
                let result = try await finder.findSimilarPhotos(options: options) { continuation.yield($0) }
                continuation.finish()
                progressTask.cancel()
                await self?.finishSimilarScan(result)
            } catch {
                continuation.finish()
                progressTask.cancel()
                self?.similarScanStopped(error)
            }
        }
    }

    private func finishSimilarScan(_ result: SimilarPhotoScanResult) async {
        similarResult = result
        hiddenSimilarPaths = []
        similarMarks = DuplicateMarkSet()
        selectedSimilarGroupID = nil
        await regroupSimilarPhotos()
        similarPhase = .finished
        if result.unreadableFolders > 0 { services.permissions.refresh() }
        services.logger.info(
            "Similar photo scan finished: \(similarGroups.count) groups, \(similarPhotoCount) photos in groups, \(result.imagesAnalyzed) of \(result.imagesFound) images analyzed, \(result.cloudOnlySkipped) cloud-only skipped, \(String(format: "%.1f", result.duration))s",
            category: .duplicates
        )
    }

    private func similarScanStopped(_ error: any Error) {
        if error is CancellationError {
            similarPhase = similarResult == nil ? .idle : .finished
            services.logger.info("Similar photo scan cancelled", category: .duplicates)
        } else {
            similarPhase = .failed(error.localizedDescription)
            services.logger.error("Similar photo scan failed (\(String(describing: type(of: error))))", category: .duplicates)
        }
    }

    // MARK: - Exact duplicates: selection

    func isMarked(_ file: DuplicateFile) -> Bool { marks.contains(file.id) }

    func markedCount(in group: DuplicateGroup) -> Int { marks.markedCount(in: group.files) }

    func reclaimable(for group: DuplicateGroup) -> Int64 { reclaimableByGroup[group.id] ?? 0 }

    /// The copy the current rule suggests keeping.
    func suggestedKeeperID(in group: DuplicateGroup) -> String? {
        group.keeper(rule: keepRule, context: keepContext)?.id
    }

    /// `false` for protected copies and for the last copy still kept in its group.
    func canMark(_ file: DuplicateFile, in group: DuplicateGroup) -> Bool {
        guard !file.isProtected else { return false }
        if marks.contains(file.id) { return true }
        return group.files.contains { $0.id != file.id && !marks.contains($0.id) }
    }

    func setMarked(_ shouldMark: Bool, file: DuplicateFile, in group: DuplicateGroup) {
        switch marks.setMarked(shouldMark, member: file, in: group.files) {
        case .refusedLastCopy:
            show("At least one copy of every file is always kept.")
        case .refusedProtected:
            show(file.protectionReason ?? "This copy is protected and can't be removed.", style: .warning)
        case .marked, .unmarked, .unchanged:
            break
        }
    }

    func keepOnly(_ file: DuplicateFile, in group: DuplicateGroup) {
        marks.keepOnly(file, in: group.files)
    }

    func applyRule(to group: DuplicateGroup) {
        marks.replaceMarks(in: group.files, with: group.ruleMarkedIDs(rule: keepRule, context: keepContext))
    }

    func unmarkAll(in group: DuplicateGroup) {
        marks.unmarkAll(in: group.files)
    }

    /// Applies the keep rule to every group shown (all groups unless a search is active).
    func selectDuplicatesUsingRule() {
        if keepRule == .preferredFolder && preferredFolder == nil {
            choosePreferredFolder()
            guard preferredFolder != nil else { return }
        }
        let targets = trimmedSearch.isEmpty ? groups : filteredGroups
        var updated = marks
        var leftForReview = 0
        for group in targets {
            let chosen = group.ruleMarkedIDs(rule: keepRule, context: keepContext)
            updated.replaceMarks(in: group.files, with: chosen)
            let keeperID = group.keeper(rule: keepRule, context: keepContext)?.id
            leftForReview += group.files.filter { $0.id != keeperID && !chosen.contains($0.id) }.count
        }
        marks = updated
        var message = marks.isEmpty
            ? "Nothing to select: every remaining copy is protected or inside an app library."
            : "Selected \(NumberFormatting.count(marks.count)) duplicate\(marks.count == 1 ? "" : "s") (\(ByteFormatting.string(markedBytes))), keeping \(keepRule.keptCopyPhrase) of each file."
        if leftForReview > 0 {
            message += " \(NumberFormatting.count(leftForReview)) protected or app-library cop\(leftForReview == 1 ? "y was" : "ies were") left unselected."
        }
        show(message, style: .success)
    }

    func deselectAll() {
        marks = DuplicateMarkSet()
    }

    func choosePreferredFolder() {
        guard let url = services.permissions.chooseFolder(
            message: "Choose the folder whose copies you want to keep.",
            prompt: "Keep Copies Here"
        ) else { return }
        preferredFolder = url.path
        if keepRule != .preferredFolder { keepRule = .preferredFolder }
    }

    private func refreshReclaimable() {
        var map: [String: Int64] = [:]
        for group in groups {
            map[group.id] = group.reclaimableBytes(rule: keepRule, context: keepContext)
        }
        reclaimableByGroup = map
        totalReclaimable = map.values.reduce(0, +)
        groups.sort { lhs, rhs in
            let left = map[lhs.id] ?? 0
            let right = map[rhs.id] ?? 0
            if left != right { return left > right }
            if lhs.contentSize != rhs.contentSize { return lhs.contentSize > rhs.contentSize }
            return lhs.id < rhs.id
        }
    }

    private func updateMarkedBytes() {
        var files: [DuplicateFile] = []
        for group in groups {
            for file in group.files where marks.contains(file.id) { files.append(file) }
        }
        markedBytes = DuplicateSpaceEstimator.reclaimableBytes(files)
    }

    // MARK: - Exact duplicates: removal

    /// Verifies the marked copies and asks for confirmation before moving them to the Trash.
    func moveMarkedToTrash() {
        guard !marks.isEmpty, !cleanupFlow.isCleaning else { return }
        let memberLists = groups.filter { marks.markedCount(in: $0.files) > 0 }.map(\.files)
        let marked = marks.ids
        let category = DuplicatesSmartScanProvider.categoryTitle
        Task { [weak self] in
            let plan = await BackgroundWork.run {
                DuplicateRemovalPlanner.plan(groups: memberLists, marked: marked, category: category)
            }
            self?.requestCleanup(plan, title: "Move Duplicates to Trash", extraWarning: nil) { report in
                self?.didFinishExactCleanup(report)
            }
        }
    }

    private func didFinishExactCleanup(_ report: CleanupReport) {
        services.logger.info(
            "Duplicates moved to the Trash: \(report.removed.count) files (\(ByteFormatting.string(report.bytesRemoved))), \(report.skipped.count) skipped, \(report.failed.count) failed",
            category: .duplicates
        )
        let removed = Set(report.removed.map(\.path))
        guard !removed.isEmpty else { return }
        removeFromExactResults { removed.contains($0.path) }
    }

    private func removeFromExactResults(where shouldRemove: (DuplicateFile) -> Bool) {
        groups = groups.compactMap { group in
            var copy = group
            copy.files.removeAll(where: shouldRemove)
            return copy.files.count >= 2 ? copy : nil
        }
        var updated = marks
        updated.prune(keeping: Set(groups.flatMap { $0.files.map(\.id) }))
        marks = updated
        refreshReclaimable()
        if selectedGroup == nil { selectedGroupID = groups.first?.id }
    }

    // MARK: - Similar photos: selection

    func isMarked(_ photo: SimilarPhoto) -> Bool { similarMarks.contains(photo.id) }

    func markedCount(in group: SimilarPhotoGroup) -> Int { similarMarks.markedCount(in: group.photos) }

    func canMark(_ photo: SimilarPhoto, in group: SimilarPhotoGroup) -> Bool {
        guard photo.protectionReason == nil else { return false }
        if similarMarks.contains(photo.id) { return true }
        return group.photos.contains { $0.id != photo.id && !similarMarks.contains($0.id) }
    }

    func setMarked(_ shouldMark: Bool, photo: SimilarPhoto, in group: SimilarPhotoGroup) {
        switch similarMarks.setMarked(shouldMark, member: photo, in: group.photos) {
        case .refusedLastCopy:
            show("At least one photo in every group is always kept.")
        case .refusedProtected:
            show(photo.protectionReason ?? "This photo is protected and can't be removed.", style: .warning)
        case .marked, .unmarked, .unchanged:
            break
        }
    }

    /// Marks every other photo of the group, after the person picked the one to keep.
    func keepOnly(_ photo: SimilarPhoto, in group: SimilarPhotoGroup) {
        similarMarks.keepOnly(photo, in: group.photos)
    }

    func unmarkAll(in group: SimilarPhotoGroup) {
        similarMarks.unmarkAll(in: group.photos)
    }

    func deselectAllSimilar() {
        similarMarks = DuplicateMarkSet()
    }

    private func updateSimilarMarkedBytes() {
        var files: [DuplicateFile] = []
        for group in similarGroups {
            for photo in group.photos where similarMarks.contains(photo.id) { files.append(photo.file) }
        }
        similarMarkedBytes = DuplicateSpaceEstimator.reclaimableBytes(files)
    }

    private func scheduleRegroup() {
        guard similarResult != nil else { return }
        regroupTask?.cancel()
        regroupTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.regroupSimilarPhotos()
        }
    }

    private func regroupSimilarPhotos() async {
        guard let result = similarResult else { return }
        regroupGeneration += 1
        let generation = regroupGeneration
        let threshold = similarityThreshold
        let hidden = hiddenSimilarPaths
        let regrouped = await BackgroundWork.run {
            DuplicatesViewModel.similarGroups(from: result, threshold: threshold, hidden: hidden)
        }
        guard generation == regroupGeneration else { return }
        applySimilarGroups(regrouped)
    }

    nonisolated private static func similarGroups(
        from result: SimilarPhotoScanResult,
        threshold: Float,
        hidden: Set<String>
    ) -> [SimilarPhotoGroup] {
        let groups = result.groups(threshold: threshold)
        guard !hidden.isEmpty else { return groups }
        return groups.compactMap { group in
            var copy = group
            copy.photos.removeAll { hidden.contains($0.id) }
            return copy.photos.count >= 2 ? copy : nil
        }
    }

    private func applySimilarGroups(_ regrouped: [SimilarPhotoGroup]) {
        let previousCount = similarMarks.count
        similarGroups = regrouped
        var updated = similarMarks
        updated.prune(keeping: Set(regrouped.flatMap { $0.photos.map(\.id) }))
        let repaired = updated.repair(groups: regrouped.map(\.photos))
        similarMarks = updated
        if repaired > 0 || updated.count < previousCount {
            show("Some photos were unmarked because the groups changed. Every group keeps at least one photo.")
        }
        if selectedSimilarGroup == nil { selectedSimilarGroupID = regrouped.first?.id }
    }

    // MARK: - Similar photos: removal

    func moveMarkedSimilarToTrash() {
        guard !similarMarks.isEmpty, !cleanupFlow.isCleaning else { return }
        let memberLists = similarGroups
            .filter { similarMarks.markedCount(in: $0.photos) > 0 }
            .map { $0.photos.map(\.file) }
        let marked = similarMarks.ids
        Task { [weak self] in
            let plan = await BackgroundWork.run {
                DuplicateRemovalPlanner.plan(groups: memberLists, marked: marked, category: "Similar photos")
            }
            self?.requestCleanup(
                plan,
                title: "Move Similar Photos to Trash",
                extraWarning: "These photos look alike but aren't identical copies. Make sure you've compared them before continuing."
            ) { report in
                self?.didFinishSimilarCleanup(report)
            }
        }
    }

    private func didFinishSimilarCleanup(_ report: CleanupReport) {
        services.logger.info(
            "Similar photos moved to the Trash: \(report.removed.count) files (\(ByteFormatting.string(report.bytesRemoved))), \(report.skipped.count) skipped, \(report.failed.count) failed",
            category: .duplicates
        )
        let removed = Set(report.removed.map(\.path))
        guard !removed.isEmpty else { return }
        hideSimilarPhotos { removed.contains($0) }
    }

    private func hideSimilarPhotos(where shouldHide: (String) -> Bool) {
        for group in similarGroups {
            for photo in group.photos where shouldHide(photo.id) { hiddenSimilarPaths.insert(photo.id) }
        }
        let hidden = hiddenSimilarPaths
        applySimilarGroups(similarGroups.compactMap { group in
            var copy = group
            copy.photos.removeAll { hidden.contains($0.id) }
            return copy.photos.count >= 2 ? copy : nil
        })
    }

    // MARK: - Shared actions

    private func requestCleanup(
        _ plan: DuplicateRemovalPlan,
        title: String,
        extraWarning: String?,
        onComplete: @escaping @MainActor (CleanupReport) -> Void
    ) {
        guard !plan.items.isEmpty else {
            show(plan.exclusionSummary ?? "Nothing can be moved to the Trash.", style: .warning)
            return
        }
        let warning = [extraWarning, plan.exclusionSummary].compactMap { $0 }.joined(separator: " ")
        cleanupFlow.requestCleanup(
            title: title,
            items: plan.items,
            services: services,
            regenerableData: false,
            warning: warning.isEmpty ? nil : warning,
            onComplete: onComplete
        )
    }

    /// Never scans `path` again (adds it to the exclusions in Settings) and drops it from the results.
    func exclude(path: String) {
        services.settings.addExclusion(path)
        removeFromExactResults { PathUtilities.isSameOrDescendant($0.path, of: path) }
        hideSimilarPhotos { PathUtilities.isSameOrDescendant($0, of: path) }
        services.logger.info("Duplicates: added an exclusion from the results", category: .duplicates)
        show("“\((path as NSString).lastPathComponent)” won't be scanned again. You can change this in Settings › Exclusions.")
    }

    func preview(_ path: String, among paths: [String]) {
        quickLookItems = paths.map { URL(fileURLWithPath: $0) }
        quickLookURL = URL(fileURLWithPath: path)
    }

    func show(_ message: String, style: InfoCallout.Style = .info) {
        notice = DuplicateNotice(message: message, style: style)
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func dismissNotice() {
        noticeTask?.cancel()
        notice = nil
    }
}
