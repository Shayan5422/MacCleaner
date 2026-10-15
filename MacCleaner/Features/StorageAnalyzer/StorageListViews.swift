import SwiftUI

/// Tabs below the chart: folder contents, large files, old files, kinds, downloads and search results.
struct StorageListsCard: View {
    @Bindable var model: StorageAnalyzerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Picker("List", selection: $model.listTab) {
                    ForEach(model.availableTabs) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 8)
                if model.listTab == .results || model.listTab == .largest || model.listTab == .old {
                    StorageFilterBar(model: model)
                }
            }

            switch model.listTab {
            case .contents:
                StorageFolderTable(model: model, rows: model.contentsRows, sortOrder: $model.contentsSort)
                    .accessibilityLabel("Contents of \(model.currentNode?.displayName ?? "folder")")
            case .largest:
                StorageFileTable(
                    model: model, rows: model.largestRows,
                    emptyTitle: "No Large Files",
                    emptyMessage: "No file in this scan uses \(model.largeFileThresholdDescription) or more. You can change the size in Settings."
                )
                footnote("Files and packages of \(model.largeFileThresholdDescription) or more, largest first (up to 500). Change the size in Settings › Scanning." + hiddenNote)
            case .old:
                StorageFileTable(
                    model: model, rows: model.oldRows,
                    emptyTitle: "No Old Files",
                    emptyMessage: "Every file of 1 MB or more was opened or modified in the last \(model.services.settings.oldFileAgeDays) days."
                )
                footnote("Files of 1 MB or more not opened or modified for \(model.services.settings.oldFileAgeDays) days. “Last opened” is approximate: macOS updates access times lazily, so Spotlight's last-opened date is used where available." + hiddenNote)
            case .categories:
                if let tree = model.tree {
                    StorageCategoriesView(statistics: tree.statistics) { category in
                        var filter = StorageFilter()
                        filter.category = category
                        model.filter = filter
                    }
                }
            case .downloads:
                StorageDownloadsView(model: model)
            case .results:
                if model.isSearching && model.resultRows.isEmpty {
                    ProgressView("Searching…").frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    StorageFileTable(
                        model: model, rows: model.resultRows,
                        emptyTitle: "No Matches",
                        emptyMessage: "No scanned file, package or folder of 1 MB or more matches the search and filters."
                    )
                    footnote(model.resultRows.count >= 1_000 ? "Showing the 1,000 largest matches." : "\(NumberFormatting.count(model.resultRows.count)) matches, largest first. Search covers files and folders of 1 MB or more.")
                }
            }
        }
        .card()
    }

    /// Hidden items always count toward sizes; lists only show them when the setting is on.
    private var hiddenNote: String {
        model.services.settings.includeHiddenFiles ? "" : " Hidden files are measured but listed only when Include Hidden Files is on in Settings."
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Tables

/// A folder's children: Contents and Downloads.
struct StorageFolderTable: View {
    @Bindable var model: StorageAnalyzerViewModel
    let rows: [StorageRow]
    @Binding var sortOrder: [KeyPathComparator<StorageRow>]
    var shareTitle: String = "Share"

    var body: some View {
        Table(rows, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { row in
                StorageNameCell(row: row, tree: model.tree)
            }
            .width(min: 200, ideal: 300)
            TableColumn("Size", value: \.size) { row in
                SizeText(bytes: row.size).foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 85, max: 110)
            TableColumn(shareTitle, value: \.share) { row in
                StorageShareCell(share: row.share, color: row.node.category.color)
            }
            .width(min: 80, ideal: 110, max: 150)
            TableColumn("Kind", value: \.kind, comparator: .localizedStandard) { row in
                Text(row.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 120)
            TableColumn("Modified", value: \.modified) { row in
                StorageDateCell(date: row.node.kind == .smallFiles ? nil : row.node.modificationDate)
            }
            .width(min: 80, ideal: 105)
            TableColumn("Last Opened", value: \.lastOpened) { row in
                StorageDateCell(date: row.node.isLeaf && row.node.kind != .smallFiles ? row.node.lastOpenedDate : nil, isApproximate: true)
            }
            .width(min: 80, ideal: 105)
        }
        .contextMenu(forSelectionType: ObjectIdentifier.self) { ids in
            StorageNodeMenu(model: model, nodes: model.nodes(for: ids))
        } primaryAction: { ids in
            model.performPrimaryAction(ids)
        }
        .onKeyPress(.space) {
            model.quickLookSelection()
            return .handled
        }
        .frame(minHeight: 340, idealHeight: 380)
    }
}

struct StorageFileTable: View {
    @Bindable var model: StorageAnalyzerViewModel
    let rows: [StorageRow]
    let emptyTitle: String
    let emptyMessage: String

    var body: some View {
        if rows.isEmpty {
            EmptyStateView(title: emptyTitle, symbol: "checkmark.circle", message: emptyMessage)
        } else {
            Table(rows, selection: $model.selection, sortOrder: $model.fileSort) {
                TableColumn("Name", value: \.name, comparator: .localizedStandard) { row in
                    StorageNameCell(row: row, tree: model.tree)
                }
                .width(min: 160, ideal: 230)
                TableColumn("Location", value: \.location, comparator: .localizedStandard) { row in
                    Text(row.location)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.location)
                }
                .width(min: 110, ideal: 190)
                TableColumn("Size", value: \.size) { row in
                    SizeText(bytes: row.size).foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 85, max: 110)
                TableColumn("Kind", value: \.kind, comparator: .localizedStandard) { row in
                    Label {
                        Text(row.kind).lineLimit(1)
                    } icon: {
                        Image(systemName: row.node.category.symbolName).foregroundStyle(row.node.category.color)
                    }
                    .foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 125)
                TableColumn("Modified", value: \.modified) { row in
                    StorageDateCell(date: row.node.kind == .smallFiles ? nil : row.node.modificationDate)
                }
                .width(min: 80, ideal: 105)
                TableColumn("Last Opened", value: \.lastOpened) { row in
                    StorageDateCell(date: row.node.isLeaf && row.node.kind != .smallFiles ? row.node.lastOpenedDate : nil, isApproximate: true)
                }
                .width(min: 80, ideal: 105)
            }
            .contextMenu(forSelectionType: ObjectIdentifier.self) { ids in
                StorageNodeMenu(model: model, nodes: model.nodes(for: ids))
            } primaryAction: { ids in
                model.performPrimaryAction(ids)
            }
            .onKeyPress(.space) {
                model.quickLookSelection()
                return .handled
            }
            .frame(minHeight: 340, idealHeight: 380)
        }
    }
}

struct StorageNameCell: View {
    let row: StorageRow
    let tree: StorageTree?

    var body: some View {
        HStack(spacing: 8) {
            icon
            HStack(spacing: 5) {
                Text(row.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(row.node.isHidden || row.node.kind == .smallFiles ? .secondary : .primary)
                badges
            }
        }
        .help(row.location.isEmpty ? row.name : row.location + "/" + row.name)
    }

    @ViewBuilder
    private var icon: some View {
        if row.node.kind == .smallFiles {
            Image(systemName: "square.grid.2x2")
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
        } else if let tree, case let path = tree.path(of: row.node), !path.isEmpty {
            FileIcon(path: path, size: 18)
        } else {
            Image(systemName: row.node.isFolder ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
        }
    }

    @ViewBuilder
    private var badges: some View {
        if row.node.isUnreadable {
            Image(systemName: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .help("Couldn't be read; its contents aren't included.")
        }
        if row.node.isCloudOnly {
            Image(systemName: "icloud")
                .font(.caption2)
                .foregroundStyle(AppSection.cloud.tint)
                .help("Stored in the cloud, not downloaded to this Mac.")
        }
        if row.node.flags.contains(.sharedHardLink) {
            Image(systemName: "link")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("Hard link: its storage is counted once, at another name.")
        }
        if row.node.flags.contains(.sharedClone) {
            Image(systemName: "square.on.square")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("APFS clone: storage shared with another file is counted once.")
        }
    }
}

struct StorageShareCell: View {
    let share: Double
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(color.gradient)
                        .frame(width: max(2, proxy.size.width * min(1, max(0, share))))
                }
            }
            .frame(height: 6)
            Text(NumberFormatting.percent(share, digits: share > 0 && share < 0.01 ? 1 : 0))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NumberFormatting.percent(share))
    }
}

struct StorageDateCell: View {
    let date: Date?
    var isApproximate = false

    var body: some View {
        if let date {
            Text((isApproximate ? "≈ " : "") + DateFormatting.day(date))
                .foregroundStyle(.secondary)
                .help(DateFormatting.relative(date) + (isApproximate ? " (approximate)" : ""))
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Context menu

/// Actions for one or more items, used by the charts and the tables.
struct StorageNodeMenu: View {
    let model: StorageAnalyzerViewModel
    let nodes: [StorageNode]

    var body: some View {
        let actionable = nodes.filter(\.isActionable)
        if nodes.count == 1, let node = nodes.first {
            if node.kind == .directory, !node.children.isEmpty {
                Button("Open", systemImage: "arrow.down.forward.circle") {
                    withAnimation(.snappy(duration: 0.25)) { model.open(node) }
                }
            }
            if node.kind == .smallFiles, let parent = node.parent {
                Button("Open Enclosing Folder", systemImage: "folder") {
                    withAnimation(.snappy(duration: 0.25)) { model.open(parent) }
                }
            }
            if model.canQuickLook(node) {
                Button("Quick Look", systemImage: "eye") { model.quickLook(node) }
            }
            Button("Reveal in Finder", systemImage: "folder") { model.reveal(node) }
            Button("Copy Path", systemImage: "doc.on.doc") { model.copyPath(node) }
        } else if !nodes.isEmpty {
            Button("Reveal in Finder", systemImage: "folder") {
                FinderActions.reveal(nodes.map { model.path(of: $0) }.filter { !$0.isEmpty })
            }
        }
        if !actionable.isEmpty {
            Divider()
            // For a single item, say up front when the safety policy doesn't allow removing or moving it.
            let problem = actionable.count == 1 ? actionable.first.flatMap { model.trashProblem(for: $0) } : nil
            Button("Move to…", systemImage: "folder.badge.arrow.forward") { model.relocate(actionable) }
                .disabled(problem != nil)
            Button("Move to Trash", systemImage: "trash", role: .destructive) { model.trash(actionable) }
                .disabled(problem != nil)
            if let problem {
                Text(problem)
            }
            if actionable.count == 1, let node = actionable.first {
                Divider()
                Button("Exclude from Scans", systemImage: "eye.slash") { model.exclude(node) }
            }
        }
    }
}

// MARK: - Filters

struct StorageFilterBar: View {
    @Bindable var model: StorageAnalyzerViewModel

    var body: some View {
        HStack(spacing: 8) {
            Picker("Kind", selection: $model.filter.category) {
                Text("All Kinds").tag(StorageCategory?.none)
                Divider()
                ForEach(StorageCategory.allCases) { category in
                    Label(category.title, systemImage: category.symbolName).tag(StorageCategory?.some(category))
                }
            }
            .fixedSize()
            Picker("Size", selection: $model.filter.minimumSize) {
                ForEach(StorageFilter.sizeOptions, id: \.self) { size in
                    Text(size == 0 ? "Any Size" : "≥ \(ByteFormatting.string(size))").tag(size)
                }
            }
            .fixedSize()
            Picker("Age", selection: $model.filter.olderThanDays) {
                Text("Any Age").tag(Int?.none)
                ForEach(StorageFilter.ageOptions, id: \.self) { days in
                    Text(days >= 365 ? "Unused \(days / 365)+ year\(days >= 730 ? "s" : "")" : "Unused \(days)+ days").tag(Int?.some(days))
                }
            }
            .fixedSize()
            if model.isFiltering {
                Button("Clear") { model.clearSearchAndFilters() }
                    .buttonStyle(.borderless)
            }
        }
        .labelsHidden()
        .controlSize(.small)
    }
}

// MARK: - Kinds

struct StorageCategoriesView: View {
    let statistics: StorageScanStatistics
    let onShow: (StorageCategory) -> Void

    private var categories: [StorageCategory] {
        StorageCategory.allCases
            .filter { statistics.count(for: $0) > 0 }
            .sorted { statistics.bytes(for: $0) > statistics.bytes(for: $1) }
    }

    var body: some View {
        let total = max(statistics.countedBytes, 1)
        VStack(alignment: .leading, spacing: 12) {
            UsageBar(
                segments: categories.map { UsageSegment(label: $0.title, bytes: statistics.bytes(for: $0), color: $0.color) },
                total: total, height: 14
            )
            VStack(spacing: 0) {
                ForEach(categories) { category in
                    let bytes = statistics.bytes(for: category)
                    HStack(spacing: 12) {
                        Image(systemName: category.symbolName)
                            .foregroundStyle(category.color)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(category.title).font(.callout.weight(.medium))
                            Text("\(NumberFormatting.count(statistics.count(for: category))) files")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StorageShareCell(share: Double(bytes) / Double(total), color: category.color)
                            .frame(width: 150)
                        SizeText(bytes: bytes, font: .callout.weight(.semibold))
                            .frame(minWidth: 80, alignment: .trailing)
                        Button("Show") { onShow(category) }
                            .buttonStyle(.borderless)
                            .help("List \(category.title.lowercased()) of 1 MB or more")
                    }
                    .padding(.vertical, 7)
                    Divider()
                }
            }
            Text("Every scanned file is counted here, including files under 1 MB. Storage shared by hard links and APFS clones is counted once. Kinds are based on file name extensions and location (for example, everything inside an iPhone backup counts as a backup).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Downloads

struct StorageDownloadsView: View {
    @Bindable var model: StorageAnalyzerViewModel

    var body: some View {
        if let summary = model.downloadsSummary {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                    StatTile(title: "Downloads", value: ByteFormatting.string(summary.total), caption: nil, symbol: "arrow.down.circle", tint: AppSection.storage.tint)
                    StatTile(title: "Installers & Disk Images", value: ByteFormatting.string(summary.installers),
                             caption: "\(summary.installerCount) item\(summary.installerCount == 1 ? "" : "s"); usually not needed after installing",
                             symbol: StorageCategory.diskImages.symbolName, tint: StorageCategory.diskImages.color)
                    StatTile(title: "Archives", value: ByteFormatting.string(summary.archives),
                             caption: "\(summary.archiveCount) item\(summary.archiveCount == 1 ? "" : "s")",
                             symbol: StorageCategory.archives.symbolName, tint: StorageCategory.archives.color)
                    StatTile(title: "Unused for \(summary.oldAgeDays) Days", value: ByteFormatting.string(summary.old),
                             caption: "\(summary.oldCount) item\(summary.oldCount == 1 ? "" : "s")",
                             symbol: "clock", tint: .secondary)
                }
                if model.downloadsRows.isEmpty {
                    EmptyStateView(title: "Downloads Is Empty", symbol: "checkmark.circle", message: "There's nothing in your Downloads folder.")
                } else {
                    StorageFolderTable(model: model, rows: model.downloadsRows, sortOrder: $model.fileSort)
                }
            }
        } else {
            EmptyStateView(
                title: "Downloads Isn't in This Scan",
                symbol: "arrow.down.circle",
                message: "Scan your startup disk, your home folder or the Downloads folder to see what's there.",
                actionTitle: "Scan Downloads",
                action: { model.scanFolder(model.homePath + "/Downloads") }
            )
        }
    }
}
