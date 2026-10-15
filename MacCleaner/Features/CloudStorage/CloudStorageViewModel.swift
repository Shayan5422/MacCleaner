import AppKit
import Foundation
import Observation
import SwiftUI

/// Locations of one provider account, shown together.
struct CloudProviderGroup: Identifiable {
    var id: String
    var provider: CloudProviderKind
    var name: String
    var account: String?
    var summaries: [CloudLocationSummary]

    var logicalBytes: Int64 { summaries.reduce(0) { $0 + $1.logicalBytes } }
    var localBytes: Int64 { summaries.reduce(0) { $0 + $1.localBytes } }
    var cloudOnlyBytes: Int64 { summaries.reduce(0) { $0 + $1.cloudOnlyBytes } }
    var cloudOnlyCount: Int { summaries.reduce(0) { $0 + $1.cloudOnlyCount } }
    var fileCount: Int { summaries.reduce(0) { $0 + $1.fileCount } }
    var notDownloadedFolders: Int { summaries.reduce(0) { $0 + $1.notDownloadedFolders } }
    var supportsRemoveDownload: Bool { summaries.contains { $0.location.supportsRemoveDownload } }
}

/// A way to free local space, derived from the scan.
struct CloudSuggestion: Identifiable {
    enum Action {
        case selectNotOpened, selectLarge, compareDuplicates, showDuplicates, openICloudSettings
    }

    var id: String
    var title: String
    var detail: String
    var bytes: Int64?
    var symbol: String
    var action: Action
}

@MainActor
@Observable
final class CloudStorageViewModel {
    enum Phase: Equatable {
        case idle, scanning, ready
        case failed(String)
    }

    struct RemovalRequest: Identifiable {
        let id = UUID()
        var items: [CloudFileItem]
        /// Problems found before asking the provider, by item path.
        var problems: [String: String]
    }

    let services: AppServices

    private(set) var locations: [CloudLocation] = []
    private(set) var hasDetected = false
    private(set) var phase: Phase = .idle
    private(set) var progress: CloudScanProgress.Snapshot?
    private(set) var result: CloudScanResult?
    /// Items whose download was removed in this session (now cloud-only).
    private(set) var evictedPaths: Set<String> = []

    var selection: Set<String> = []
    var searchText = ""
    var quickLookURL: URL?
    var removalRequest: RemovalRequest?
    private(set) var isRemoving = false
    private(set) var removalDone = 0
    private(set) var removalTotal = 0
    private(set) var removalOutcomes: [CloudDownloadRemover.Outcome] = []
    var showsRemovalReport = false
    var highlightsDuplicates = false

    /// Identical copies, once compared (nil until the person asks for a comparison).
    private(set) var duplicates: [CloudDuplicateGroup]?
    private(set) var duplicateNote: String?
    private(set) var isComparing = false
    private(set) var compareProgress: CloudScanProgress.Snapshot?
    /// Sets of locally stored files that share a size (possible duplicates), found without reading them.
    private(set) var possibleDuplicateSets = 0
    private var compareTask: Task<Void, Never>?
    private var compareProgressSource: CloudScanProgress?

    private var scanTask: Task<Void, Never>?
    private var scanProgress: CloudScanProgress?
    /// Identifies the current scan, so a cancelled scan finishing late can't overwrite a newer one.
    private var scanGeneration = 0

    /// The home folder whose cloud folders are analyzed.
    let home: String

    init(services: AppServices, home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.services = services
        self.home = home
    }

    // MARK: - Detection and scanning

    func detectIfNeeded() {
        guard !hasDetected else { return }
        detect()
    }

    func detect() {
        let home = self.home
        Task {
            let found = await BackgroundWork.run(qos: .userInitiated) { CloudProviderDetector.detect(home: home) }
            locations = found
            hasDetected = true
        }
    }

    var detectedProviderNames: [String] {
        var names: [String] = []
        for location in locations where location.role != .appData && location.role != .desktopAndDocuments {
            let name = location.account.map { "\(location.providerName) (\($0))" } ?? location.providerName
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    func scan() {
        scanProgress?.cancel()
        scanTask?.cancel()
        cancelComparison()
        duplicates = nil
        duplicateNote = nil
        possibleDuplicateSets = 0
        scanGeneration += 1
        let generation = scanGeneration
        let settings = services.settings
        let progress = CloudScanProgress()
        scanProgress = progress
        self.progress = progress.snapshot
        phase = .scanning
        selection = []
        evictedPaths = []
        let logger = services.logger
        var scanner = CloudStorageScanner()
        scanner.notOpenedDays = max(1, settings.oldFileAgeDays)
        scanner.includeHiddenItemsInLists = settings.includeHiddenFiles
        scanner.exclusions = settings.exclusions
        let configuredScanner = scanner
        let started = Date()

        let home = self.home
        scanTask = Task { [weak self] in
            let found = await BackgroundWork.run(qos: .userInitiated) { CloudProviderDetector.detect(home: home) }
            guard let current = self, current.scanGeneration == generation else { return }
            current.locations = found
            current.hasDetected = true
            let poller = Task { [weak self] in
                while !Task.isCancelled {
                    if let self, self.scanGeneration == generation { self.progress = progress.snapshot }
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            defer { poller.cancel() }
            do {
                let result = try await withTaskCancellationHandler {
                    try await configuredScanner.scan(locations: found, progress: progress)
                } onCancel: {
                    progress.cancel()
                }
                guard self?.scanGeneration == generation else { return }
                self?.result = result
                self?.possibleDuplicateSets = CloudDuplicateFinder.sameSizeGroups(in: result.duplicateCandidates, minimumBytes: 1_000_000).count
                self?.phase = .ready
                self?.progress = nil
                logger.info(
                    "Cloud scan finished: \(result.summaries.count) locations, \(ByteFormatting.string(result.totalLocalBytes)) stored locally of \(ByteFormatting.string(result.totalLogicalBytes)), \(result.totalCloudOnlyCount) cloud-only files in \(String(format: "%.1f", Date().timeIntervalSince(started)))s",
                    category: .cloud
                )
            } catch is CancellationError {
                guard self?.scanGeneration == generation else { return }
                self?.progress = nil
                self?.phase = self?.result == nil ? .idle : .ready
            } catch {
                guard self?.scanGeneration == generation else { return }
                self?.progress = nil
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelScan() {
        scanProgress?.cancel()
        scanTask?.cancel()
    }

    // MARK: - Identical copies (on request)

    /// Compares locally stored files of the same size by reading them (SHA-256). Runs only when
    /// asked: reading a file updates its access time, and comparing can read many gigabytes.
    func compareDuplicates() {
        guard let result, !isComparing else { return }
        let candidates = result.duplicateCandidates.filter { !evictedPaths.contains($0.path) }
        let progress = CloudScanProgress()
        progress.update { $0.phase = .comparing }
        compareProgressSource = progress
        compareProgress = progress.snapshot
        isComparing = true
        duplicateNote = nil
        let generation = scanGeneration
        let logger = services.logger
        let started = Date()
        compareTask = Task { [weak self] in
            let poller = Task { [weak self] in
                while !Task.isCancelled {
                    self?.compareProgress = progress.snapshot
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            defer { poller.cancel() }
            do {
                let groups = try await withTaskCancellationHandler {
                    try await CloudDuplicateFinder().findDuplicates(in: candidates, progress: progress)
                } onCancel: {
                    progress.cancel()
                }
                guard let self, self.scanGeneration == generation else { return }
                self.duplicates = groups
                self.isComparing = false
                self.compareProgress = nil
                logger.info("Compared \(ByteFormatting.string(progress.snapshot.bytesCompared)) of cloud files: \(groups.count) sets of identical copies, \(ByteFormatting.string(groups.reduce(0) { $0 + $1.redundantLocalBytes })) redundant, in \(String(format: "%.1f", Date().timeIntervalSince(started)))s", category: .cloud)
            } catch is CancellationError {
                guard let self, self.scanGeneration == generation else { return }
                self.isComparing = false
                self.compareProgress = nil
            } catch {
                guard let self, self.scanGeneration == generation else { return }
                self.isComparing = false
                self.compareProgress = nil
                self.duplicateNote = "Files couldn't be compared: \(error.localizedDescription)"
            }
        }
    }

    func cancelComparison() {
        compareProgressSource?.cancel()
        compareTask?.cancel()
    }

    // MARK: - Derived data

    var groups: [CloudProviderGroup] {
        guard let result else { return [] }
        var order: [String] = []
        var byID: [String: CloudProviderGroup] = [:]
        for summary in result.summaries {
            let location = summary.location
            let key = location.groupID
            if byID[key] == nil {
                order.append(key)
                byID[key] = CloudProviderGroup(id: key, provider: location.provider, name: location.providerName, account: location.account, summaries: [])
            }
            byID[key]?.summaries.append(adjusted(summary))
        }
        return order.compactMap { byID[$0] }
    }

    /// A summary with this session's removed downloads applied.
    private func adjusted(_ summary: CloudLocationSummary) -> CloudLocationSummary {
        guard !evictedPaths.isEmpty else { return summary }
        var copy = summary
        let evicted = (summary.largestLocal + summary.notOpened).filter { evictedPaths.contains($0.path) }
        var seen = Set<String>()
        for item in evicted where seen.insert(item.path).inserted {
            copy.localBytes = max(0, copy.localBytes - item.localBytes)
            copy.cloudOnlyBytes += item.logicalSize
            copy.cloudOnlyCount += 1
        }
        copy.largestLocal.removeAll { evictedPaths.contains($0.path) }
        copy.notOpened.removeAll { evictedPaths.contains($0.path) }
        return copy
    }

    var totalLogicalBytes: Int64 { groups.reduce(0) { $0 + $1.logicalBytes } }
    var totalLocalBytes: Int64 { groups.reduce(0) { $0 + $1.localBytes } }
    var totalCloudOnlyBytes: Int64 { groups.reduce(0) { $0 + $1.cloudOnlyBytes } }
    var totalCloudOnlyCount: Int { groups.reduce(0) { $0 + $1.cloudOnlyCount } }
    var totalFileCount: Int { groups.reduce(0) { $0 + $1.fileCount } }

    var duplicateGroups: [CloudDuplicateGroup] {
        guard let duplicates else { return [] }
        return duplicates.compactMap { group in
            var copy = group
            copy.items = group.items.filter { !evictedPaths.contains($0.path) }
            return copy.items.count > 1 ? copy : nil
        }
    }

    var notOpenedItems: [CloudFileItem] {
        groups.flatMap { $0.summaries.filter(\.location.supportsRemoveDownload).flatMap(\.notOpened) }
    }

    var largeLocalItems: [CloudFileItem] {
        let threshold = Int64(max(1, services.settings.largeFileThresholdMB)) * 1_000_000
        return groups.flatMap { $0.summaries.filter(\.location.supportsRemoveDownload).flatMap(\.largestLocal) }
            .filter { $0.localBytes >= threshold }
    }

    var hasICloud: Bool { locations.contains { $0.provider == .iCloudDrive } }

    var suggestions: [CloudSuggestion] {
        var list: [CloudSuggestion] = []
        let notOpened = unique(notOpenedItems)
        if !notOpened.isEmpty {
            let bytes = notOpened.reduce(0) { $0 + $1.localBytes }
            list.append(CloudSuggestion(
                id: "not-opened",
                title: "Remove downloads you haven't used in \(result?.notOpenedDays ?? services.settings.oldFileAgeDays) days",
                detail: "\(NumberFormatting.count(notOpened.count)) file\(notOpened.count == 1 ? "" : "s") stay in the cloud and download again when you open them.",
                bytes: bytes, symbol: "clock.arrow.circlepath", action: .selectNotOpened
            ))
        }
        let large = unique(largeLocalItems)
        if !large.isEmpty {
            list.append(CloudSuggestion(
                id: "large",
                title: "Large files downloaded to this Mac",
                detail: "\(NumberFormatting.count(large.count)) file\(large.count == 1 ? "" : "s") of \(ByteFormatting.string(Int64(services.settings.largeFileThresholdMB) * 1_000_000)) or more.",
                bytes: large.reduce(0) { $0 + $1.localBytes }, symbol: "doc.richtext", action: .selectLarge
            ))
        }
        let groups = duplicateGroups
        let redundant = groups.reduce(0) { $0 + $1.redundantLocalBytes }
        if redundant > 0 {
            list.append(CloudSuggestion(
                id: "duplicates",
                title: "Identical copies stored locally",
                detail: "\(NumberFormatting.count(groups.count)) set\(groups.count == 1 ? "" : "s") of identical files. Removing the downloads of extra copies frees space.",
                bytes: redundant, symbol: "square.on.square", action: .showDuplicates
            ))
        } else if duplicates == nil, possibleDuplicateSets > 0, !isComparing {
            list.append(CloudSuggestion(
                id: "compare",
                title: "Check for identical copies",
                detail: "\(NumberFormatting.count(possibleDuplicateSets)) set\(possibleDuplicateSets == 1 ? "" : "s") of downloaded files share a size. Comparing their contents finds exact copies.",
                bytes: nil, symbol: "square.on.square", action: .compareDuplicates
            ))
        }
        if hasICloud {
            list.append(CloudSuggestion(
                id: "optimize",
                title: "Let macOS manage iCloud Drive space",
                detail: "With Optimize Mac Storage on, macOS removes downloads of files you don't use when space runs low.",
                bytes: nil, symbol: "gearshape", action: .openICloudSettings
            ))
        }
        return list
    }

    private func unique(_ items: [CloudFileItem]) -> [CloudFileItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.path).inserted }
    }

    // MARK: - Search and selection

    func matchesSearch(_ item: CloudFileItem) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return item.name.localizedCaseInsensitiveContains(query) || item.path.localizedCaseInsensitiveContains(query)
    }

    private var itemsByPath: [String: CloudFileItem] {
        var map: [String: CloudFileItem] = [:]
        for group in groups {
            for summary in group.summaries {
                for item in summary.largestLocal + summary.notOpened { map[item.path] = item }
            }
        }
        for group in duplicateGroups {
            for item in group.items { map[item.path] = item }
        }
        return map
    }

    var selectedItems: [CloudFileItem] {
        let map = itemsByPath
        return selection.compactMap { map[$0] }.filter { !evictedPaths.contains($0.path) }
    }

    var selectedLocalBytes: Int64 { selectedItems.reduce(0) { $0 + $1.localBytes } }

    func toggle(_ item: CloudFileItem) {
        if selection.contains(item.path) { selection.remove(item.path) } else { selection.insert(item.path) }
    }

    func perform(_ suggestion: CloudSuggestion) {
        switch suggestion.action {
        case .selectNotOpened:
            selection.formUnion(notOpenedItems.map(\.path))
        case .selectLarge:
            selection.formUnion(largeLocalItems.map(\.path))
        case .compareDuplicates:
            compareDuplicates()
        case .showDuplicates:
            highlightsDuplicates = true
        case .openICloudSettings:
            openICloudSettings()
        }
    }

    // MARK: - Item actions

    func canQuickLook(_ item: CloudFileItem) -> Bool {
        // Previewing a cloud-only file would download it.
        item.isStoredLocally && !evictedPaths.contains(item.path)
    }

    func quickLook(_ item: CloudFileItem) {
        guard canQuickLook(item) else { return }
        quickLookURL = item.url
    }

    func reveal(_ item: CloudFileItem) {
        FinderActions.reveal(item.path)
    }

    func openICloudSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings:icloud",
            "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings",
            "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: - Remove Download

    func requestRemoveDownload(_ items: [CloudFileItem]) {
        let eligible = items.filter { $0.isStoredLocally && !evictedPaths.contains($0.path) }
        guard !eligible.isEmpty else { return }
        let locations = self.locations
        var problems: [String: String] = [:]
        for item in eligible {
            if let problem = CloudDownloadRemover.preflightProblem(for: item, locations: locations) {
                problems[item.path] = problem
            }
        }
        removalRequest = RemovalRequest(items: eligible, problems: problems)
    }

    func requestRemoveDownloadForSelection() {
        requestRemoveDownload(selectedItems)
    }

    func confirmRemoval() {
        guard let request = removalRequest else { return }
        removalRequest = nil
        let items = request.items.filter { request.problems[$0.path] == nil }
        let skipped = request.items.compactMap { item in
            request.problems[item.path].map { CloudDownloadRemover.Outcome(item: item, result: .failed($0), canUseFinder: false) }
        }
        guard !items.isEmpty else {
            removalOutcomes = skipped
            showsRemovalReport = true
            return
        }
        isRemoving = true
        removalDone = 0
        removalTotal = items.count
        let locations = self.locations
        let logger = services.logger
        let started = Date()
        Task {
            var outcomes: [CloudDownloadRemover.Outcome] = []
            for item in items {
                let outcome = await BackgroundWork.run(qos: .userInitiated) {
                    CloudDownloadRemover.removeDownload(of: item, locations: locations)
                }
                outcomes.append(outcome)
                removalDone += 1
                if outcome.succeeded {
                    evictedPaths.insert(item.path)
                    selection.remove(item.path)
                }
            }
            // Let the confirmation sheet finish closing before the report sheet opens.
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 0.5 { try? await Task.sleep(for: .milliseconds(Int((0.5 - elapsed) * 1_000))) }
            isRemoving = false
            removalOutcomes = outcomes + skipped
            showsRemovalReport = true
            let freed = outcomes.filter { $0.result == .removed || $0.result == .requested }.reduce(0) { $0 + $1.item.localBytes }
            logger.info("Removed downloads of \(outcomes.filter(\.succeeded).count) cloud items (\(ByteFormatting.string(freed)) freed locally, files kept in the cloud); \(outcomes.filter { !$0.succeeded }.count + skipped.count) not removed", category: .cloud)
        }
    }
}
