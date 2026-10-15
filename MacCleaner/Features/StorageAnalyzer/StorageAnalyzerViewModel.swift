import AppKit
import Foundation
import Observation
import SwiftUI

/// A place the Storage Analyzer can scan.
enum StorageScanSource: Identifiable, Hashable, Sendable {
    case volume(VolumeInfo)
    case folder(path: String)

    var id: String {
        switch self {
        case .volume(let volume): return "volume:" + volume.path
        case .folder(let path): return "folder:" + path
        }
    }

    /// The folder that is walked (`/System/Volumes/Data` for the startup disk).
    var scanPath: String {
        switch self {
        case .volume(let volume): return volume.scanRootPath
        case .folder(let path): return path
        }
    }

    var title: String {
        switch self {
        case .volume(let volume): return volume.name
        case .folder(let path):
            if path == FileManager.default.homeDirectoryForCurrentUser.path { return "Home" }
            return FileManager.default.displayName(atPath: path)
        }
    }

    var symbolName: String {
        switch self {
        case .volume(let volume): return volume.symbolName
        case .folder(let path):
            return path == FileManager.default.homeDirectoryForCurrentUser.path ? "house.fill" : "folder.fill"
        }
    }

    var volume: VolumeInfo? {
        if case .volume(let volume) = self { return volume }
        return nil
    }

    var isWholeVolume: Bool { volume != nil }
}

/// One row of the analyzer's tables.
struct StorageRow: Identifiable, Hashable {
    let node: StorageNode
    let id: ObjectIdentifier
    let name: String
    let size: Int64
    /// Share of the displayed folder (contents) or of the whole scan (file lists).
    let share: Double
    let kind: String
    let modified: Date
    let lastOpened: Date
    /// Enclosing folder, abbreviated (file lists only).
    let location: String

    init(node: StorageNode, share: Double, location: String = "") {
        self.node = node
        id = node.id
        name = node.displayName
        size = node.size
        self.share = share
        kind = node.kindDescription
        modified = node.modificationDate ?? .distantPast
        lastOpened = node.lastOpenedDate ?? .distantPast
        self.location = location
    }

    static func == (lhs: StorageRow, rhs: StorageRow) -> Bool {
        lhs.id == rhs.id && lhs.size == rhs.size && lhs.name == rhs.name && lhs.location == rhs.location
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Search filters for scanned items.
struct StorageFilter: Equatable {
    var category: StorageCategory?
    var minimumSize: Int64 = 0
    var olderThanDays: Int?

    var isActive: Bool { category != nil || minimumSize > 0 || olderThanDays != nil }

    static let sizeOptions: [Int64] = [0, 10_000_000, 100_000_000, 500_000_000, 1_000_000_000, 5_000_000_000]
    static let ageOptions: [Int] = [30, 90, 180, 365, 730]
}

/// A notable finding in the scan, with a way to look at it.
struct StorageInsight: Identifiable {
    enum Action {
        case showCategory(StorageCategory)
        case open(StorageNode)
        case downloads
        case trash
    }

    var id: String
    var title: String
    var detail: String
    var bytes: Int64
    var symbol: String
    var tint: Color
    var action: Action
}

@MainActor
@Observable
final class StorageAnalyzerViewModel {
    enum Phase: Equatable {
        case idle, scanning, ready
        case failed(String)
    }

    enum ListTab: String, CaseIterable, Identifiable {
        case contents, largest, old, categories, downloads, results

        var id: String { rawValue }

        var title: String {
            switch self {
            case .contents: return "Contents"
            case .largest: return "Large Files"
            case .old: return "Old Files"
            case .categories: return "Kinds"
            case .downloads: return "Downloads"
            case .results: return "Results"
            }
        }
    }

    struct Alert: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    let services: AppServices
    let cleanupFlow = CleanupFlow()
    let relocation = StorageRelocationController()

    // MARK: Sources and scan state

    private(set) var volumes: [VolumeInfo] = []
    /// The location of the results shown.
    private(set) var source: StorageScanSource?
    /// The location being scanned right now.
    private(set) var scanningSource: StorageScanSource?
    private(set) var phase: Phase = .idle
    private(set) var progress: StorageScanProgress?
    private(set) var tree: StorageTree?
    private(set) var currentNode: StorageNode?
    /// Bumped whenever the tree changes or navigation happens, so charts re-layout.
    private(set) var version = 0
    private(set) var volume: VolumeInfo?
    private(set) var snapshots: [StorageLocalSnapshot] = []
    private(set) var snapshotMessage: String?
    private(set) var insights: [StorageInsight] = []

    // MARK: Presentation

    var chartStyle: StorageChartStyle = .treemap
    var colorMode: StorageColorMode = .kind
    var listTab: ListTab = .contents
    var contentsSort: [KeyPathComparator<StorageRow>] = [KeyPathComparator(\StorageRow.size, order: .reverse)] {
        didSet { refreshContents() }
    }
    var fileSort: [KeyPathComparator<StorageRow>] = [KeyPathComparator(\StorageRow.size, order: .reverse)] {
        didSet {
            largestRows.sort(using: fileSort)
            oldRows.sort(using: fileSort)
            downloadsRows.sort(using: fileSort)
            resultRows.sort(using: fileSort)
        }
    }
    var selection: Set<ObjectIdentifier> = []
    var quickLookURL: URL?
    var alert: Alert?
    /// Short confirmation after an action ("Excluded …").
    var notice: String?

    // MARK: Search

    var searchText = "" {
        didSet { searchTextChanged(from: oldValue) }
    }
    var filter = StorageFilter() {
        didSet {
            if filter.isActive, listTab != .results { switchToResults() }
            scheduleSearch()
        }
    }
    private(set) var resultRows: [StorageRow] = []
    private(set) var isSearching = false

    // MARK: Lists

    private(set) var contentsRows: [StorageRow] = []
    private(set) var largestRows: [StorageRow] = []
    private(set) var oldRows: [StorageRow] = []
    private(set) var downloadsNode: StorageNode?
    private(set) var downloadsRows: [StorageRow] = []

    private var scanTask: Task<Void, Never>?
    /// Identifies the current scan, so a cancelled scan finishing late can't overwrite a newer one.
    private var scanGeneration = 0
    private var searchTask: Task<Void, Never>?
    private var tabBeforeResults: ListTab = .contents
    private var lookup: [ObjectIdentifier: StorageNode] = [:]
    private var accessedLocation: URL?
    /// Cloud-synced folders in the home folder, detected once per scan.
    private var cloudSyncedRoots: [String]?

    let homePath = FileManager.default.homeDirectoryForCurrentUser.path

    init(services: AppServices) {
        self.services = services
    }

    // MARK: - Sources

    var rememberedLocations: [AuthorizedLocation] { services.permissions.authorizedLocations }

    func refreshSources() {
        Task {
            let found = await BackgroundWork.run(qos: .userInitiated) { VolumeService.mountedVolumes() }
            volumes = found
        }
    }

    func scanStartupDisk() {
        if let startup = volumes.first(where: \.isRootFileSystem) ?? VolumeService.startupVolume() {
            scan(.volume(startup))
        }
    }

    func scanHome() {
        scan(.folder(path: homePath))
    }

    func scanFolder(_ path: String) {
        let normalized = PathUtilities.normalize(path)
        if let volume = VolumeService.volume(containing: normalized), volume.path == normalized {
            scan(.volume(volume))
        } else {
            scan(.folder(path: normalized))
        }
    }

    func scanRemembered(_ location: AuthorizedLocation) {
        guard let url = services.permissions.resolve(location) else {
            alert = Alert(title: "Folder Not Available", message: "“\(PathUtilities.abbreviate(location.path))” can't be found. If it's on an external drive, connect the drive and try again.")
            return
        }
        stopAccessingLocation()
        accessedLocation = url
        scanFolder(url.path)
    }

    func chooseFolderAndScan() {
        guard let url = services.permissions.chooseFolder(message: "Choose a folder or drive to analyze.", prompt: "Analyze") else { return }
        scanFolder(url.path)
    }

    func forget(_ location: AuthorizedLocation) {
        services.permissions.forget(location)
    }

    // MARK: - Scanning

    func scan(_ source: StorageScanSource) {
        scanTask?.cancel()
        searchTask?.cancel()
        let settings = services.settings
        var request = StorageScanRequest(rootPath: source.scanPath, displayName: source.title, exclusions: settings.exclusions)
        request.expectedBytes = source.isWholeVolume ? source.volume?.usedCapacity : nil
        let builder = StorageTreeBuilder(request: request)

        scanGeneration += 1
        let generation = scanGeneration
        scanningSource = source
        phase = .scanning
        progress = builder.progress
        notice = nil
        let logger = services.logger

        scanTask = Task { [weak self] in
            let poller = Task { [weak self] in
                while !Task.isCancelled {
                    if let self, self.scanGeneration == generation { self.progress = builder.progress }
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            defer { poller.cancel() }
            do {
                let tree = try await builder.build()
                guard let self, self.scanGeneration == generation else { return }
                self.didFinish(tree, source: source)
            } catch is CancellationError {
                guard let self, self.scanGeneration == generation else { return }
                self.didCancelScan()
            } catch {
                guard let self, self.scanGeneration == generation else { return }
                logger.warning("Storage scan failed: \((error as NSError).domain) \((error as NSError).code)", category: .storage)
                self.phase = .failed(error.localizedDescription)
                self.progress = nil
                self.scanningSource = nil
                self.stopAccessingLocation()
            }
        }
    }

    func rescan() {
        guard let source = scanningSource ?? source else { return }
        if let volume = source.volume, let fresh = VolumeService.info(for: volume.url) {
            scan(.volume(fresh))
        } else {
            scan(source)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    /// Returns to the location picker.
    func showSources() {
        scanGeneration += 1
        scanTask?.cancel()
        scanningSource = nil
        progress = nil
        phase = .idle
        stopAccessingLocation()
        refreshSources()
    }

    private func didCancelScan() {
        progress = nil
        scanningSource = nil
        phase = tree == nil ? .idle : .ready
        stopAccessingLocation()
    }

    private func didFinish(_ tree: StorageTree, source: StorageScanSource) {
        self.source = source
        scanningSource = nil
        cloudSyncedRoots = nil
        self.tree = tree
        currentNode = tree.root
        selection = []
        lookup = [:]
        progress = nil
        phase = .ready
        version += 1
        volume = source.volume ?? VolumeService.volume(containing: source.scanPath)
        snapshots = []
        snapshotMessage = nil
        if let volume, source.isWholeVolume { loadSnapshots(for: volume) }
        refreshAll()
        stopAccessingLocation()

        let stats = tree.statistics
        services.logger.info(
            "Storage scan finished: \(stats.directoryCount) folders, \(stats.fileCount) files, \(ByteFormatting.string(stats.countedBytes)) in \(String(format: "%.1f", tree.duration))s; \(stats.unreadableCount) unreadable folders; \(ByteFormatting.string(stats.duplicateBytesAvoided)) of hard links and clones counted once",
            category: .storage
        )
    }

    private func loadSnapshots(for volume: VolumeInfo) {
        Task { [weak self] in
            do {
                let list = try await StorageSnapshotReader.localSnapshots(volumePath: volume.path)
                self?.snapshots = list
                self?.snapshotMessage = list.isEmpty ? "There are no local snapshots on this volume." : nil
            } catch {
                self?.snapshotMessage = "Snapshots couldn't be listed: \(error.localizedDescription)"
            }
        }
    }

    private func stopAccessingLocation() {
        if let accessedLocation { services.permissions.stopAccessing(accessedLocation) }
        accessedLocation = nil
    }

    // MARK: - Navigation

    var breadcrumb: [StorageNode] {
        guard let currentNode else { return [] }
        return currentNode.ancestors + [currentNode]
    }

    var canGoUp: Bool { currentNode?.parent != nil }

    func open(_ node: StorageNode) {
        guard node.kind == .directory, tree?.isAttached(node) == true else { return }
        currentNode = node
        selection = []
        version += 1
        refreshContents()
        if listTab == .results, !isFiltering { listTab = .contents }
    }

    func goUp() {
        if let parent = currentNode?.parent { open(parent) }
    }

    /// Selects one item (from a chart click).
    func select(_ node: StorageNode) {
        lookup[node.id] = node
        selection = [node.id]
    }

    // MARK: - Selection

    var selectedNodes: [StorageNode] {
        selection.compactMap { lookup[$0] }.filter { $0.isActionable }
    }

    /// Selected bytes, without counting items inside other selected folders twice.
    var selectedBytes: Int64 {
        let nodes = selectedNodes
        return nodes.filter { node in !nodes.contains { $0 !== node && node.isDescendant(of: $0) } }
            .reduce(0) { $0 + $1.size }
    }

    func nodes(for ids: Set<ObjectIdentifier>) -> [StorageNode] {
        ids.compactMap { lookup[$0] }
    }

    /// Double-click or Return in a list: open folders, Quick Look files.
    func performPrimaryAction(_ ids: Set<ObjectIdentifier>) {
        let nodes = nodes(for: ids)
        guard nodes.count == 1, let node = nodes.first else { return }
        switch node.kind {
        case .directory:
            open(node)
            listTab = .contents
        case .smallFiles:
            if let parent = node.parent { open(parent) }
        case .file, .package:
            quickLook(node)
        }
    }

    // MARK: - Actions

    func path(of node: StorageNode) -> String {
        tree?.path(of: node) ?? ""
    }

    func reveal(_ node: StorageNode) {
        let path = self.path(of: node)
        guard !path.isEmpty else { return }
        FinderActions.reveal(path)
    }

    func copyPath(_ node: StorageNode) {
        let path = self.path(of: node)
        guard !path.isEmpty else { return }
        FinderActions.copyPath(path)
    }

    func canQuickLook(_ node: StorageNode) -> Bool {
        node.isActionable && !node.isCloudOnly && node.kind != .smallFiles
    }

    func quickLook(_ node: StorageNode) {
        guard canQuickLook(node) else { return }
        let path = self.path(of: node)
        guard !path.isEmpty else { return }
        quickLookURL = URL(fileURLWithPath: path)
    }

    func quickLookSelection() {
        if quickLookURL != nil {
            quickLookURL = nil
        } else if let node = selectedNodes.first(where: canQuickLook) {
            quickLook(node)
        }
    }

    /// Why an item can't be moved to the Trash, or nil when it can.
    func trashProblem(for node: StorageNode) -> String? {
        guard let tree, node.isActionable, node !== tree.root else { return "This item can't be removed." }
        return services.policy.evaluate(path: tree.path(of: node), purpose: .userFile).reason
    }

    func trashSelection() {
        trash(selectedNodes)
    }

    /// Asks for confirmation, then moves the items to the Trash through the cleanup engine.
    func trash(_ nodes: [StorageNode]) {
        guard let tree else { return }
        var items: [CleanupItem] = []
        var denied: [(name: String, reason: String)] = []
        for node in nodes where node.isActionable && node !== tree.root && tree.isAttached(node) {
            let path = tree.path(of: node)
            switch services.policy.evaluate(path: path, purpose: .userFile) {
            case .allowed:
                items.append(CleanupItem(
                    path: path, purpose: .userFile, snapshot: tree.snapshot(of: node),
                    estimatedBytes: node.reclaimableSize,
                    category: node.kind == .directory ? "Folders" : node.category.title
                ))
            case .denied(let reason):
                denied.append((node.displayName, reason))
            }
        }
        guard !items.isEmpty else {
            if let first = denied.first {
                alert = Alert(title: "“\(first.name)” Can't Be Moved to the Trash", message: first.reason)
            }
            return
        }
        var warning = "Items stay in the Trash and keep using space until you empty it."
        let synced = items.filter { isInCloudSyncedFolder($0.path) }.count
        if synced > 0 {
            warning += " \(synced) item\(synced == 1 ? " is" : "s are") in a folder synced with the cloud, so moving \(synced == 1 ? "it" : "them") to the Trash also removes \(synced == 1 ? "it" : "them") from the cloud and your other devices."
        }
        if let first = denied.first {
            warning += " \(denied.count) selected item\(denied.count == 1 ? "" : "s") will be left alone: \(first.reason)"
        }
        cleanupFlow.requestCleanup(
            title: "Move to Trash", items: items, services: services, regenerableData: false, warning: warning
        ) { [weak self] report in
            self?.applyCleanup(report)
        }
    }

    func relocateSelection() {
        relocate(selectedNodes)
    }

    /// Opens the "Move to…" sheet for the items.
    func relocate(_ nodes: [StorageNode]) {
        guard let tree else { return }
        let items = nodes
            .filter { $0.isActionable && $0 !== tree.root && tree.isAttached($0) }
            .map { StorageRelocator.Item(path: tree.path(of: $0), name: $0.name, snapshot: tree.snapshot(of: $0), estimatedBytes: $0.size) }
        guard !items.isEmpty else { return }
        let synced = items.filter { isInCloudSyncedFolder($0.path) }.count
        let note = synced > 0
            ? "\(synced) item\(synced == 1 ? " is" : "s are") in a folder synced with the cloud. Moving \(synced == 1 ? "it" : "them") elsewhere removes \(synced == 1 ? "it" : "them") from the cloud and your other devices."
            : nil
        relocation.begin(items: items, note: note) { [weak self] outcomes in
            self?.applyRelocation(outcomes)
        }
    }

    /// Desktop & Documents in iCloud Drive and folders of other sync apps: removing or moving an
    /// item there also removes it from the cloud. (iCloud Drive and File Provider folders
    /// themselves are refused by `SafetyPolicy`.)
    private func isInCloudSyncedFolder(_ path: String) -> Bool {
        if cloudSyncedRoots == nil {
            cloudSyncedRoots = CloudProviderDetector.detect(home: homePath)
                .filter { $0.role == .desktopAndDocuments || $0.role == .legacyFolder }
                .map(\.path)
        }
        return cloudSyncedRoots?.contains { PathUtilities.isSameOrDescendant(path, of: $0) } ?? false
    }

    /// Adds the item to the exclusion list and removes it from the current results.
    func exclude(_ node: StorageNode) {
        guard let tree, node.isActionable, node !== tree.root else { return }
        let path = tree.path(of: node)
        guard !path.isEmpty else { return }
        let position = currentPositionPath()
        services.settings.addExclusion(path)
        tree.remove(node)
        notice = "“\(node.displayName)” won't be scanned or cleaned from now on. You can change this in Settings › Exclusions."
        treeDidChange(restoring: position)
    }

    // MARK: - Applying changes without a rescan

    private func applyCleanup(_ report: CleanupReport) {
        guard let tree, !report.removed.isEmpty else { return }
        let position = currentPositionPath()
        for removed in report.removed {
            guard let node = tree.node(atPath: removed.path) else { continue }
            if let trashed = removed.trashedPath,
               let trashFolder = tree.node(atPath: (trashed as NSString).deletingLastPathComponent),
               trashFolder.kind == .directory {
                // Trashed items still use space until the Trash is emptied.
                tree.move(node, into: trashFolder, newName: (trashed as NSString).lastPathComponent)
            } else {
                tree.remove(node)
            }
        }
        services.logger.info("Storage Analyzer moved \(report.removed.count) items (\(ByteFormatting.string(report.bytesRemoved))) to the Trash", category: .storage)
        treeDidChange(restoring: position)
    }

    private func applyRelocation(_ outcomes: [StorageRelocator.Outcome]) {
        guard let tree else { return }
        let position = currentPositionPath()
        for outcome in outcomes {
            guard let node = tree.node(atPath: outcome.item.path) else { continue }
            switch outcome.result {
            case .moved(let target):
                if let destination = tree.node(atPath: (target as NSString).deletingLastPathComponent), destination.kind == .directory {
                    tree.move(node, into: destination, newName: (target as NSString).lastPathComponent)
                } else {
                    tree.remove(node)
                }
            case .copied(_, let trashed):
                if let trashed, let trashFolder = tree.node(atPath: (trashed as NSString).deletingLastPathComponent), trashFolder.kind == .directory {
                    tree.move(node, into: trashFolder, newName: (trashed as NSString).lastPathComponent)
                } else {
                    tree.remove(node)
                }
            case .copiedOriginalKept, .failed:
                continue
            }
        }
        treeDidChange(restoring: position)
    }

    private func currentPositionPath() -> String? {
        guard let tree, let currentNode else { return nil }
        return tree.rawPath(of: currentNode)
    }

    private func treeDidChange(restoring position: String?) {
        guard let tree else { return }
        if let currentNode, !tree.isAttached(currentNode) {
            // The displayed folder was removed or moved: show the closest folder that still exists.
            var path = position ?? tree.rootPath
            var replacement: StorageNode?
            while replacement == nil, PathUtilities.isSameOrDescendant(path, of: tree.rootPath) {
                replacement = tree.node(atPath: path)
                if path == tree.rootPath { break }
                path = (path as NSString).deletingLastPathComponent
            }
            self.currentNode = replacement ?? tree.root
        }
        selection = selection.filter { id in lookup[id].map { tree.isAttached($0) } ?? false }
        version += 1
        refreshAll()
    }

    // MARK: - Lists

    private var largeFileThreshold: Int64 { Int64(max(1, services.settings.largeFileThresholdMB)) * 1_000_000 }

    var largeFileThresholdDescription: String { ByteFormatting.string(largeFileThreshold) }

    private func refreshAll() {
        refreshContents()
        refreshFileLists()
        refreshDownloads()
        computeInsights()
        if isFiltering { scheduleSearch() } else { resultRows = [] }
        rebuildLookup()
    }

    private func refreshContents() {
        guard let node = currentNode else {
            contentsRows = []
            return
        }
        let total = Double(max(node.size, 1))
        contentsRows = node.children
            .map { StorageRow(node: $0, share: Double($0.size) / total) }
            .sorted(using: contentsSort)
        rebuildLookup()
    }

    private func refreshFileLists() {
        guard let tree else {
            largestRows = []
            oldRows = []
            return
        }
        let threshold = largeFileThreshold
        let includeHidden = services.settings.includeHiddenFiles
        let cutoff = StorageNode.time(Date().timeIntervalSince1970 - Double(services.settings.oldFileAgeDays) * 86_400)
        let checkAttachment = tree.version > 0
        var large: [StorageNode] = []
        var old: [StorageNode] = []
        for node in tree.searchIndex where node.kind == .file || node.kind == .package {
            guard visible(node, in: tree, includeHidden: includeHidden, checkAttachment: checkAttachment) else { continue }
            if node.size >= threshold { large.append(node) }
            if node.lastUsedTime > 0, node.lastUsedTime < cutoff { old.append(node) }
        }
        let total = Double(max(tree.root.size, 1))
        large.sort { $0.size > $1.size }
        old.sort { $0.size > $1.size }
        largestRows = large.prefix(500).map { StorageRow(node: $0, share: Double($0.size) / total, location: location(of: $0, in: tree)) }
            .sorted(using: fileSort)
        oldRows = old.prefix(500).map { StorageRow(node: $0, share: Double($0.size) / total, location: location(of: $0, in: tree)) }
            .sorted(using: fileSort)
        rebuildLookup()
    }

    private func refreshDownloads() {
        guard let tree, let node = tree.node(atPath: homePath + "/Downloads"), node.kind == .directory else {
            downloadsNode = nil
            downloadsRows = []
            return
        }
        downloadsNode = node
        let total = Double(max(node.size, 1))
        downloadsRows = node.children.map { StorageRow(node: $0, share: Double($0.size) / total) }.sorted(using: fileSort)
        rebuildLookup()
    }

    struct DownloadsSummary {
        var total: Int64 = 0
        var installers: Int64 = 0
        var installerCount = 0
        var archives: Int64 = 0
        var archiveCount = 0
        var old: Int64 = 0
        var oldCount = 0
        var oldAgeDays = 90
    }

    var downloadsSummary: DownloadsSummary? {
        guard let node = downloadsNode else { return nil }
        let days = services.settings.oldDownloadAgeDays
        let cutoff = StorageNode.time(Date().timeIntervalSince1970 - Double(days) * 86_400)
        var summary = DownloadsSummary(total: node.size, oldAgeDays: days)
        for child in node.children where child.kind != .smallFiles {
            if child.category == .diskImages, child.kind != .directory {
                summary.installers += child.size
                summary.installerCount += 1
            }
            if child.category == .archives, child.kind != .directory {
                summary.archives += child.size
                summary.archiveCount += 1
            }
            if child.kind != .directory, child.lastUsedTime > 0, child.lastUsedTime < cutoff {
                summary.old += child.size
                summary.oldCount += 1
            }
        }
        return summary
    }

    private func location(of node: StorageNode, in tree: StorageTree) -> String {
        PathUtilities.abbreviate((tree.path(of: node) as NSString).deletingLastPathComponent)
    }

    /// Hidden-file and attachment checks. Before any change to the tree, scan-time flags answer
    /// in constant time; afterwards one walk up the tree checks both.
    private func visible(_ node: StorageNode, in tree: StorageTree, includeHidden: Bool, checkAttachment: Bool) -> Bool {
        if !checkAttachment { return includeHidden || !node.isInHiddenLocation }
        var current: StorageNode? = node
        while let item = current {
            if item === tree.root { return true }
            if item.flags.contains(.detached) { return false }
            if !includeHidden && item.isHidden { return false }
            current = item.parent
        }
        return !checkAttachment
    }

    private func rebuildLookup() {
        var map: [ObjectIdentifier: StorageNode] = [:]
        for rows in [contentsRows, largestRows, oldRows, downloadsRows, resultRows] {
            for row in rows { map[row.id] = row.node }
        }
        // Keep chart selections that aren't in any list.
        for id in selection where map[id] == nil {
            if let node = lookup[id] { map[id] = node }
        }
        lookup = map
    }

    // MARK: - Insights

    private func computeInsights() {
        guard let tree else {
            insights = []
            return
        }
        let stats = tree.statistics
        var found: [StorageInsight] = []
        let minimum: Int64 = 100_000_000
        for category in [StorageCategory.videos, .diskImages, .archives, .audio, .backups] {
            let bytes = stats.bytes(for: category)
            guard bytes >= minimum else { continue }
            let count = stats.count(for: category)
            found.append(StorageInsight(
                id: "category-\(category.rawValue)",
                title: category.title,
                detail: "\(NumberFormatting.count(count)) file\(count == 1 ? "" : "s"). \(category.advice)",
                bytes: bytes, symbol: category.symbolName, tint: category.color, action: .showCategory(category)
            ))
        }
        if let backups = tree.node(atPath: homePath + "/Library/Application Support/MobileSync/Backup"), backups.size > 0 {
            found.append(StorageInsight(
                id: "ios-backups",
                title: "iPhone & iPad Backups",
                detail: "\(backups.children.filter { $0.kind == .directory }.count) device backup(s). Manage them in Finder: select your device, then Manage Backups.",
                bytes: backups.size, symbol: "iphone", tint: StorageCategory.backups.color, action: .open(backups)
            ))
        }
        if let downloads = downloadsSummary, downloads.total >= minimum {
            var detail = "Your Downloads folder."
            if downloads.oldCount > 0 {
                detail = "\(downloads.oldCount) item\(downloads.oldCount == 1 ? "" : "s") not used in \(downloads.oldAgeDays) days (\(ByteFormatting.string(downloads.old)))."
            }
            if downloads.installerCount > 0 {
                detail += " \(downloads.installerCount) installer\(downloads.installerCount == 1 ? "" : "s") or disk image\(downloads.installerCount == 1 ? "" : "s")."
            }
            found.append(StorageInsight(id: "downloads", title: "Downloads", detail: detail, bytes: downloads.total,
                                        symbol: "arrow.down.circle", tint: AppSection.storage.tint, action: .downloads))
        }
        if let trash = tree.node(atPath: homePath + "/.Trash"), trash.size > 0 {
            found.append(StorageInsight(
                id: "trash", title: "Trash",
                detail: "Items in the Trash still use space. Empty the Trash in Finder to free it.",
                bytes: trash.size, symbol: "trash", tint: .secondary, action: .trash
            ))
        }
        insights = Array(found.sorted { $0.bytes > $1.bytes }.prefix(6))
    }

    func perform(_ insight: StorageInsight) {
        switch insight.action {
        case .showCategory(let category):
            var newFilter = StorageFilter()
            newFilter.category = category
            filter = newFilter
        case .open(let node):
            open(node)
            listTab = .contents
        case .downloads:
            listTab = .downloads
        case .trash:
            FinderActions.openTrash()
        }
    }

    // MARK: - Search and filters

    var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty || filter.isActive
    }

    var availableTabs: [ListTab] {
        ListTab.allCases.filter { $0 != .results || isFiltering }
    }

    func clearSearchAndFilters() {
        filter = StorageFilter()
        searchText = ""
        if listTab == .results { listTab = tabBeforeResults }
    }

    private func switchToResults() {
        if listTab != .results { tabBeforeResults = listTab }
        listTab = .results
    }

    private func searchTextChanged(from oldValue: String) {
        let wasEmpty = oldValue.trimmingCharacters(in: .whitespaces).isEmpty
        let isEmpty = searchText.trimmingCharacters(in: .whitespaces).isEmpty
        if wasEmpty && !isEmpty { switchToResults() }
        if !wasEmpty && isEmpty && !filter.isActive && listTab == .results { listTab = tabBeforeResults }
        scheduleSearch()
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        guard let tree, isFiltering else {
            resultRows = []
            isSearching = false
            rebuildLookup()
            return
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let index = tree.searchIndex
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
            // Names never change, so they can be matched off the main thread.
            let matched: [StorageNode] = await BackgroundWork.run(qos: .userInitiated) {
                guard !query.isEmpty else { return index }
                return index.filter { $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
            if Task.isCancelled { return }
            self?.applySearch(matched)
        }
    }

    private func applySearch(_ matched: [StorageNode]) {
        guard let tree else { return }
        let includeHidden = services.settings.includeHiddenFiles
        let checkAttachment = tree.version > 0
        let ageCutoff = filter.olderThanDays.map { StorageNode.time(Date().timeIntervalSince1970 - Double($0) * 86_400) }
        var results: [StorageNode] = []
        for node in matched {
            let isFileLike = node.kind == .file || node.kind == .package
            if (filter.category != nil || ageCutoff != nil) && !isFileLike { continue }
            if let category = filter.category, node.category != category { continue }
            if node.size < filter.minimumSize { continue }
            if let ageCutoff, !(node.lastUsedTime > 0 && node.lastUsedTime < ageCutoff) { continue }
            guard visible(node, in: tree, includeHidden: includeHidden, checkAttachment: checkAttachment) else { continue }
            results.append(node)
        }
        results.sort { $0.size > $1.size }
        let total = Double(max(tree.root.size, 1))
        resultRows = results.prefix(1_000).map { StorageRow(node: $0, share: Double($0.size) / total, location: location(of: $0, in: tree)) }
            .sorted(using: fileSort)
        isSearching = false
        rebuildLookup()
    }

}
