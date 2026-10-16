import AppKit
import QuickLook
import SwiftUI

/// Storage Analyzer: scan a volume or folder, explore it as a treemap or
/// sunburst, find large and old files, and remove or move them safely.
struct StorageAnalyzerView: View {
    @Bindable var model: StorageAnalyzerViewModel

    var body: some View {
        PageScroll {
            PageHeader(section: .storage, subtitle: subtitle) {
                headerAccessory
            }
            content
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.phase == .ready, !model.selectedNodes.isEmpty {
                StorageSelectionBar(model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.selection.isEmpty)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search scanned items")
        .quickLookPreview($model.quickLookURL)
        .cleanupFlow(model.cleanupFlow, services: model.services)
        .sheet(item: Binding(get: { model.relocation.request }, set: { model.relocation.request = $0 })) { _ in
            StorageRelocationSheet(controller: model.relocation, services: model.services)
        }
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
            presenting: model.alert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
        .task { model.refreshSources() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            model.refreshSources()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            model.refreshSources()
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .ready:
            if let tree = model.tree {
                let age = Date().timeIntervalSince(tree.scanDate) < 60 ? "just now" : DateFormatting.relative(tree.scanDate)
                return "\(ByteFormatting.string(tree.root.size)) in \(NumberFormatting.count(tree.statistics.fileCount, "file")) · scanned \(age)"
            }
            return "Find what's using space."
        default:
            return "See what's using space, find large and old files, and remove or move them safely."
        }
    }

    @ViewBuilder
    private var headerAccessory: some View {
        if model.phase == .ready || model.phase == .idle && model.tree != nil {
            HStack(spacing: 8) {
                Menu {
                    StorageSourceMenuItems(model: model)
                } label: {
                    Label(model.source?.title ?? "Location", systemImage: model.source?.symbolName ?? "internaldrive")
                }
                .menuStyle(.button)
                .fixedSize()
                Button {
                    model.rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Scan this location again (⌘R)")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            StorageSourcePicker(model: model)
        case .scanning:
            ScanProgressCard(
                title: "Scanning \(model.scanningSource?.title ?? model.source?.title ?? "")…",
                message: progressMessage,
                fraction: model.progress?.fraction,
                tint: AppSection.storage.tint,
                onCancel: { model.cancelScan() }
            )
            if model.progress?.phase == .reading, (model.progress?.unreadableCount ?? 0) > 0 {
                FullDiskAccessBanner(reason: "Some folders can't be read without Full Disk Access, so they won't be included.")
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                InfoCallout(style: .danger, title: "The scan couldn't be completed", message: message)
                FullDiskAccessBanner()
                HStack {
                    Button("Try Again") { model.rescan() }
                        .buttonStyle(.borderedProminent)
                    Button("Choose Another Location") { model.showSources() }
                }
            }
        case .ready:
            StorageResultsView(model: model)
        }
    }

    private var progressMessage: String {
        guard let progress = model.progress else { return "Starting…" }
        switch progress.phase {
        case .reading:
            let counts = "\(NumberFormatting.count(progress.directoriesRead, "folder")) · \(NumberFormatting.count(progress.itemsSeen, "item")) · \(ByteFormatting.string(progress.bytesCounted))"
            guard !progress.currentPath.isEmpty else { return counts }
            return counts + " — " + PathUtilities.abbreviate(PathUtilities.firmlinkCanonical(progress.currentPath))
        case .summarizing:
            return "Adding up folder sizes…"
        case .readingDates:
            return "Reading when large files were last opened…"
        }
    }
}

// MARK: - Sources

struct StorageSourceMenuItems: View {
    let model: StorageAnalyzerViewModel

    var body: some View {
        ForEach(model.volumes) { volume in
            Button {
                model.scan(.volume(volume))
            } label: {
                Label("\(volume.name) — \(ByteFormatting.string(volume.effectiveAvailable)) available", systemImage: volume.symbolName)
            }
        }
        Button {
            model.scanHome()
        } label: {
            Label("Home Folder", systemImage: "house")
        }
        if !model.rememberedLocations.isEmpty {
            Divider()
            ForEach(model.rememberedLocations) { location in
                Button {
                    model.scanRemembered(location)
                } label: {
                    Label(PathUtilities.abbreviate(location.path), systemImage: "folder")
                }
            }
        }
        Divider()
        Button("Choose Folder…") { model.chooseFolderAndScan() }
        Button("All Locations…") { model.showSources() }
    }
}

/// Initial screen: pick a volume or folder.
struct StorageSourcePicker: View {
    @Bindable var model: StorageAnalyzerViewModel

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What would you like to analyze?")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Text("Scan a whole drive to see everything, or a single folder for a quick look.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(model.volumes) { volume in
                    StorageSourceCard(
                        title: volume.name,
                        subtitle: volume.isReadOnly
                            ? "Read-only · \(ByteFormatting.string(volume.totalCapacity))"
                            : "\(ByteFormatting.string(volume.effectiveAvailable)) available",
                        symbol: volume.symbolName,
                        usedFraction: volume.isReadOnly ? nil : volume.usedFraction,
                        caption: Self.caption(for: volume)
                    ) {
                        model.scan(.volume(volume))
                    }
                }
                StorageSourceCard(title: "Home Folder", subtitle: model.homePath, symbol: "house.fill", caption: "Documents, downloads, apps' data and more") {
                    model.scanHome()
                }
                ForEach(model.rememberedLocations) { location in
                    StorageSourceCard(title: (location.path as NSString).lastPathComponent, subtitle: PathUtilities.abbreviate(location.path), symbol: "folder.fill", caption: "Previously chosen") {
                        model.scanRemembered(location)
                    }
                    .contextMenu {
                        Button("Reveal in Finder", systemImage: "folder") { FinderActions.reveal(location.path) }
                        Button("Forget This Location", systemImage: "minus.circle") { model.forget(location) }
                    }
                }
                StorageSourceCard(title: "Choose Folder…", subtitle: "Any folder or connected drive", symbol: "folder.badge.plus", isDashed: true) {
                    model.chooseFolderAndScan()
                }
            }

            InfoCallout(
                style: .info,
                title: "Private and accurate",
                message: "Mac Cleaner reads only names, sizes and dates; it never opens your files. Cloud-only files aren't downloaded, and storage shared by hard links and APFS clones is counted once, like the disk does."
            )
            FullDiskAccessBanner(reason: "Without Full Disk Access, protected folders (Mail, Messages, Safari and others) can't be measured.")
        }
    }

    private static func caption(for volume: VolumeInfo) -> String {
        if !volume.isLocal { return "Network volume · scanning may be slow" }
        var parts: [String] = []
        if volume.isRootFileSystem { parts.append("Startup disk") } else if let format = volume.formatDescription { parts.append(format) }
        if !volume.isReadOnly { parts.append("\(ByteFormatting.string(volume.totalCapacity)) capacity") }
        return parts.joined(separator: " · ")
    }
}

struct StorageSourceCard: View {
    var title: String
    var subtitle: String
    var symbol: String
    var usedFraction: Double?
    var caption: String?
    var isDashed = false
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(AppSection.storage.tint)
                        .frame(width: 36, height: 36)
                        .background(AppSection.storage.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline).lineLimit(1)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(isHovering ? 1 : 0)
                }
                Spacer(minLength: 0)
                if let usedFraction {
                    ProgressView(value: min(1, max(0, usedFraction)))
                        .tint(usedFraction > 0.9 ? .orange : AppSection.storage.tint)
                        .accessibilityLabel("\(NumberFormatting.percent(usedFraction)) used")
                }
                if let caption {
                    Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 108, maxHeight: 108, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .fill(isHovering ? Color.hoverFill : Color.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(isHovering ? AppSection.storage.tint.opacity(0.5) : Color.subtleBorder,
                                  style: StrokeStyle(lineWidth: 1, dash: isDashed ? [5, 4] : []))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityHint("Starts a scan")
    }
}

// MARK: - Results

struct StorageResultsView: View {
    @Bindable var model: StorageAnalyzerViewModel

    var body: some View {
        if let tree = model.tree {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                if let notice = model.notice {
                    HStack(alignment: .top) {
                        InfoCallout(style: .success, message: notice)
                        Button {
                            model.notice = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss")
                    }
                }

                if let volume = model.volume {
                    StorageVolumeSummaryCard(
                        volume: volume,
                        scannedBytes: tree.root.size,
                        isWholeVolume: model.source?.isWholeVolume ?? false,
                        statistics: tree.statistics,
                        snapshots: model.snapshots,
                        snapshotMessage: model.snapshotMessage
                    )
                }

                StorageStatTiles(model: model, tree: tree)

                if tree.statistics.unreadableCount > 0 {
                    StorageUnreadableSection(statistics: tree.statistics)
                }

                if !model.insights.isEmpty {
                    StorageInsightsGrid(insights: model.insights) { model.perform($0) }
                }

                StorageChartCard(model: model)
                StorageListsCard(model: model)
            }
        }
    }
}

struct StorageStatTiles: View {
    let model: StorageAnalyzerViewModel
    let tree: StorageTree

    var body: some View {
        let stats = tree.statistics
        TileRow(minimumTileWidth: 200) {
            StatTile(
                title: "Scanned", value: ByteFormatting.string(tree.root.size),
                caption: "\(NumberFormatting.count(stats.fileCount, "file")) in \(NumberFormatting.count(stats.directoryCount, "folder"))",
                symbol: "internaldrive", tint: AppSection.storage.tint, fillsHeight: true
            )
            StatTile(
                title: "Large Files", value: NumberFormatting.count(model.largestRows.count),
                caption: "\(model.largeFileThresholdDescription) or more · \(ByteFormatting.string(model.largestRows.reduce(0) { $0 + $1.size }))",
                symbol: "doc.richtext", tint: StorageCategory.videos.color, fillsHeight: true
            )
            StatTile(
                title: "Old Files", value: NumberFormatting.count(model.oldRows.count),
                caption: "Unused for \(model.services.settings.oldFileAgeDays) days · \(ByteFormatting.string(model.oldRows.reduce(0) { $0 + $1.size }))",
                symbol: "clock", tint: StorageCategory.archives.color, fillsHeight: true
            )
            if stats.cloudOnlyFileCount > 0 {
                StatTile(
                    title: "In the Cloud Only", value: NumberFormatting.count(stats.cloudOnlyFileCount),
                    caption: "\(ByteFormatting.string(stats.cloudOnlyLogicalBytes)) not stored on this Mac",
                    symbol: "icloud", tint: AppSection.cloud.tint, fillsHeight: true
                )
            } else {
                StatTile(
                    title: "Scan Time", value: DateFormatting.duration(max(1, tree.duration)),
                    caption: "\(NumberFormatting.count(stats.packageCount, "app or package", plural: "apps and packages")) measured whole",
                    symbol: "timer", tint: .secondary, fillsHeight: true
                )
            }
        }
    }
}

struct StorageUnreadableSection: View {
    let statistics: StorageScanStatistics
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FullDiskAccessBanner(reason: statistics.unreadableCount == 1
                                         ? "1 folder couldn't be read, so its contents aren't in the totals."
                                         : "\(NumberFormatting.count(statistics.unreadableCount)) folders couldn't be read, so their contents aren't in the totals.")
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(statistics.unreadablePaths.prefix(60), id: \.self) { path in
                        PathText(path: path, font: .caption)
                            .contextMenu { FileContextMenu(path: path) }
                    }
                    if statistics.unreadableCount > statistics.unreadablePaths.prefix(60).count {
                        Text("and \(NumberFormatting.count(statistics.unreadableCount - statistics.unreadablePaths.prefix(60).count)) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Some folders are protected by macOS for every app (System Integrity Protection and other users' data). Others become readable when you grant Full Disk Access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .padding(.top, 6)
            } label: {
                Label("\(NumberFormatting.count(statistics.unreadableCount, "folder")) couldn't be read", systemImage: "lock")
                    .font(.callout)
            }
        }
    }
}

struct StorageInsightsGrid: View {
    let insights: [StorageInsight]
    let onSelect: (StorageInsight) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Worth a Look").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ForEach(insights) { insight in
                    StorageInsightTile(insight: insight) { onSelect(insight) }
                }
            }
        }
    }
}

struct StorageInsightTile: View {
    let insight: StorageInsight
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: insight.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(insight.tint)
                    .frame(width: 32, height: 32)
                    .background(insight.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(insight.title).font(.callout.weight(.semibold))
                        Spacer()
                        SizeText(bytes: insight.bytes, font: .callout.weight(.semibold))
                    }
                    Text(insight.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(isHovering ? Color.hoverFill : Color.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(Color.subtleBorder))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(insight.title), \(ByteFormatting.string(insight.bytes))")
        .accessibilityHint(insight.detail)
    }
}

// MARK: - Chart card

struct StorageChartCard: View {
    @Bindable var model: StorageAnalyzerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { model.goUp() }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!model.canGoUp)
                .help("Enclosing folder (⌘↑)")
                .accessibilityLabel("Enclosing folder")

                StorageBreadcrumbBar(nodes: model.breadcrumb) { node in
                    withAnimation(.snappy(duration: 0.25)) { model.open(node) }
                }
                Spacer(minLength: 8)
                Picker("Chart", selection: $model.chartStyle) {
                    ForEach(StorageChartStyle.allCases) { style in
                        Label(style.title, systemImage: style.symbolName).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Picker("Colors", selection: $model.colorMode) {
                    ForEach(StorageColorMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            if let node = model.currentNode {
                chart(for: node)
                    .frame(height: 460)
                    .id(node.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
                legend(for: node)
            }
        }
        .card()
    }

    @ViewBuilder
    private func chart(for node: StorageNode) -> some View {
        let actions = StorageChartActions(
            open: { target in withAnimation(.snappy(duration: 0.25)) { model.open(target) } },
            select: { target in model.select(target) },
            goUp: { withAnimation(.snappy(duration: 0.25)) { model.goUp() } }
        )
        if node.size == 0 || node.children.allSatisfy({ $0.size == 0 }) {
            EmptyStateView(
                title: node.isUnreadable ? "Folder Couldn't Be Read" : "Nothing to Show",
                symbol: node.isUnreadable ? "lock" : "tray",
                message: node.isUnreadable
                    ? "Mac Cleaner doesn't have permission to read this folder. Full Disk Access may help."
                    : "This folder doesn't use any space on disk."
            )
        } else {
            switch model.chartStyle {
            case .treemap:
                StorageTreemapView(node: node, version: model.version, colorMode: model.colorMode, selection: model.selection, actions: actions) { target in
                    StorageNodeMenu(model: model, nodes: [target])
                }
            case .sunburst:
                StorageSunburstView(node: node, version: model.version, colorMode: model.colorMode, selection: model.selection, canGoUp: model.canGoUp, actions: actions) { target in
                    StorageNodeMenu(model: model, nodes: [target])
                }
            }
        }
    }

    @ViewBuilder
    private func legend(for node: StorageNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.colorMode {
            case .kind:
                let present = Set(node.children.map(\.category))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(StorageCategory.allCases.filter { present.contains($0) || node.children.count > 12 }) { category in
                        LegendItem(color: category.color, label: category.title)
                    }
                }
            case .folder:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(Array(node.children.filter { $0.size > 0 }.prefix(10).enumerated()), id: \.element.id) { index, child in
                        LegendItem(color: ChartPalette.color(at: index), label: child.displayName, value: ByteFormatting.string(child.size))
                    }
                }
            }
            Text("Click a folder to zoom in, a file to select it. Right-click for actions. Space shows Quick Look.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct StorageBreadcrumbBar: View {
    let nodes: [StorageNode]
    let onSelect: (StorageNode) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right")
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        let isLast = index == nodes.count - 1
                        Button {
                            onSelect(node)
                        } label: {
                            Text(node.displayName)
                                .font(isLast ? .callout.weight(.semibold) : .callout)
                                .foregroundStyle(isLast ? Color.primary : Color.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(isLast ? AppSection.storage.tint.opacity(0.12) : Color.clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isLast)
                        .id(node.id)
                    }
                }
            }
            .onChange(of: nodes.last?.id) {
                if let last = nodes.last { proxy.scrollTo(last.id, anchor: .trailing) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path")
    }
}

// MARK: - Selection bar

struct StorageSelectionBar: View {
    let model: StorageAnalyzerViewModel

    var body: some View {
        let nodes = model.selectedNodes
        SelectionActionBar(selectedCount: nodes.count, selectedBytes: model.selectedBytes) {
            Button {
                model.quickLookSelection()
            } label: {
                Label("Quick Look", systemImage: "eye")
            }
            .disabled(!nodes.contains(where: model.canQuickLook))
            Button {
                FinderActions.reveal(nodes.map { model.path(of: $0) })
            } label: {
                Label("Reveal", systemImage: "folder")
            }
            Button {
                model.relocateSelection()
            } label: {
                Label("Move to…", systemImage: "folder.badge.arrow.forward")
            }
            Button(role: .destructive) {
                model.trashSelection()
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(.delete, modifiers: .command)
        }
    }
}
