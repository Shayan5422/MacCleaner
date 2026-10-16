import QuickLook
import SwiftUI

extension CloudProviderKind {
    var tint: Color {
        switch self {
        case .iCloudDrive: return AppSection.cloud.tint
        case .googleDrive: return ChartPalette.color(at: 1)
        case .dropbox: return ChartPalette.color(at: 0)
        case .oneDrive: return ChartPalette.color(at: 8)
        case .box: return ChartPalette.color(at: 5)
        case .other: return ChartPalette.color(at: 7)
        }
    }
}

/// Cloud Storage: what cloud folders keep on this Mac, and how to free that
/// space with Remove Download — without deleting anything from the cloud.
struct CloudStorageView: View {
    @Bindable var model: CloudStorageViewModel

    var body: some View {
        PageScroll {
            PageHeader(section: .cloud, subtitle: subtitle) {
                if model.phase == .ready {
                    Button {
                        model.scan()
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Analyze cloud folders again (⌘R)")
                }
            }
            CloudRemoveDownloadExplainer()
            content
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.phase == .ready, !model.selectedItems.isEmpty {
                CloudSelectionBar(model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.selection.isEmpty)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search downloaded files")
        .quickLookPreview($model.quickLookURL)
        .sheet(item: $model.removalRequest) { request in
            CloudRemovalSheet(model: model, request: request)
        }
        .sheet(isPresented: $model.showsRemovalReport) {
            CloudRemovalReportSheet(model: model)
        }
        .overlay {
            if model.isRemoving {
                CloudRemovingOverlay(done: model.removalDone, total: model.removalTotal)
            }
        }
        .task { model.detectIfNeeded() }
    }

    private var subtitle: String {
        if model.phase == .ready {
            return "\(ByteFormatting.string(model.totalLocalBytes)) of your cloud files are stored on this Mac."
        }
        return "See what your cloud folders store on this Mac and free space without deleting anything from the cloud."
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            if !model.hasDetected {
                ProgressView("Looking for cloud folders…")
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if model.locations.isEmpty {
                EmptyStateView(
                    title: "No Cloud Folders Found",
                    symbol: "icloud.slash",
                    message: "Mac Cleaner looks for iCloud Drive and for folders of services such as Google Drive, Dropbox, OneDrive and Box. Sign in to a cloud service on this Mac and its folder will appear here.",
                    actionTitle: "Look Again",
                    action: { model.detect() }
                )
            } else {
                ScanLaunchView(
                    section: .cloud,
                    headline: "Analyze Your Cloud Folders",
                    message: "Found " + ListFormatter.localizedString(byJoining: model.detectedProviderNames) + ".",
                    buttonTitle: "Analyze",
                    bullets: [
                        "How much of each cloud folder is downloaded to this Mac",
                        "Large downloads and files you haven't opened in a while",
                        "On request, identical copies stored locally",
                        "Only names, sizes and dates are read; nothing is downloaded or deleted",
                    ],
                    action: { model.scan() }
                )
                CloudDetectedLocationsList(locations: model.locations)
            }
        case .scanning:
            ScanProgressCard(
                title: "Analyzing cloud folders…",
                message: progressMessage,
                fraction: model.progress?.fraction,
                tint: AppSection.cloud.tint,
                onCancel: { model.cancelScan() }
            )
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                InfoCallout(style: .danger, title: "The analysis couldn't be completed", message: message)
                Button("Try Again") { model.scan() }
                    .buttonStyle(.borderedProminent)
            }
        case .ready:
            CloudResultsView(model: model)
        }
    }

    private var progressMessage: String {
        guard let progress = model.progress else { return "Starting…" }
        switch progress.phase {
        case .reading:
            return "Reading \(progress.locationTitle) · \(NumberFormatting.count(progress.filesSeen, "item"))"
        case .readingDates:
            return "Reading when files were last opened…"
        case .comparing:
            if progress.bytesToCompare > 0 {
                return "Comparing files with identical sizes · \(ByteFormatting.string(progress.bytesCompared)) of \(ByteFormatting.string(progress.bytesToCompare))"
            }
            return "Comparing files with identical sizes…"
        }
    }
}

// MARK: - Explanation

/// Explains, prominently, that Remove Download is not Delete.
struct CloudRemoveDownloadExplainer: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remove Download isn't Delete").font(.headline)
            HStack(alignment: .top, spacing: 12) {
                panel(
                    symbol: "icloud.and.arrow.down", tint: .green, title: "Remove Download",
                    lines: ["Frees space on this Mac", "Keeps the file in the cloud and on your other devices", "Downloads it again when you open it"]
                )
                panel(
                    symbol: "trash.slash", tint: .red, title: "Deleting a synced file",
                    lines: ["Removes it from the cloud", "Deletes it on every device that syncs", "Mac Cleaner never deletes files here"]
                )
            }
        }
        .card()
        .accessibilityElement(children: .combine)
    }

    private func panel(symbol: String, tint: Color, title: String, lines: [String]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct CloudDetectedLocationsList: View {
    let locations: [CloudLocation]

    var body: some View {
        Card("Cloud Folders on This Mac", symbol: "folder") {
            VStack(spacing: 0) {
                ForEach(locations) { location in
                    HStack(spacing: 10) {
                        Image(systemName: location.provider.symbolName)
                            .foregroundStyle(location.provider.tint)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(location.account.map { "\(location.title) · \($0)" } ?? location.title)
                            PathText(path: location.path)
                        }
                        Spacer()
                        if location.role == .legacyFolder {
                            Badge(text: "Synced by its own app", symbol: nil, tint: .secondary)
                        } else if location.role == .desktopAndDocuments {
                            Badge(text: "Desktop & Documents in iCloud", symbol: nil, tint: AppSection.cloud.tint)
                        }
                    }
                    .padding(.vertical, 6)
                    .contextMenu { FileContextMenu(path: location.path) }
                    Divider()
                }
            }
        }
    }
}

// MARK: - Results

struct CloudResultsView: View {
    @Bindable var model: CloudStorageViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            TileRow {
                StatTile(title: "In Your Cloud Folders", value: ByteFormatting.string(model.totalLogicalBytes),
                         caption: "\(NumberFormatting.count(model.totalFileCount, "file"))", symbol: "icloud", tint: AppSection.cloud.tint, fillsHeight: true)
                StatTile(title: "Stored on This Mac", value: ByteFormatting.string(model.totalLocalBytes),
                         caption: "Downloaded copies", symbol: "internaldrive", tint: AppSection.storage.tint, fillsHeight: true)
                StatTile(title: "Cloud-Only", value: ByteFormatting.string(model.totalCloudOnlyBytes),
                         caption: "\(NumberFormatting.count(model.totalCloudOnlyCount, "file"))", symbol: "icloud.and.arrow.up", tint: .secondary, fillsHeight: true)
                StatTile(title: "Could Be Freed", value: ByteFormatting.string(recoverableBytes),
                         caption: "By removing downloads", symbol: "sparkles", tint: .green, fillsHeight: true)
            }

            if model.groups.contains(where: { $0.summaries.contains { $0.unreadableFolders > 0 || $0.errorMessage != nil } }) {
                FullDiskAccessBanner(reason: "Some cloud folders couldn't be read, so their totals may be incomplete.")
            }

            if !model.suggestions.isEmpty {
                CloudSuggestionsCard(model: model)
            }

            ForEach(model.groups) { group in
                CloudProviderCard(model: model, group: group)
            }

            CloudDuplicatesCard(model: model)

            if model.hasICloud {
                CloudOptimizeStorageCard(model: model)
            }
        }
    }

    private var recoverableBytes: Int64 {
        var seen = Set<String>()
        let candidates = (model.notOpenedItems + model.largeLocalItems).filter { seen.insert($0.path).inserted }
        let duplicates = model.duplicateGroups.reduce(0) { $0 + $1.redundantLocalBytes }
        return candidates.reduce(0) { $0 + $1.localBytes } + duplicates
    }
}

struct CloudSuggestionsCard: View {
    let model: CloudStorageViewModel

    var body: some View {
        Card("Ways to Free Space", symbol: "lightbulb") {
            VStack(spacing: 0) {
                ForEach(model.suggestions) { suggestion in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: suggestion.symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppSection.cloud.tint)
                            .frame(width: 28, height: 28)
                            .background(AppSection.cloud.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title).font(.callout.weight(.medium))
                            Text(suggestion.detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if let bytes = suggestion.bytes {
                            SizeText(bytes: bytes, font: .callout.weight(.semibold))
                        }
                        Button(buttonTitle(for: suggestion.action)) { model.perform(suggestion) }
                    }
                    .padding(.vertical, 8)
                    Divider()
                }
            }
        }
    }

    private func buttonTitle(for action: CloudSuggestion.Action) -> String {
        switch action {
        case .selectNotOpened, .selectLarge: return "Select"
        case .compareDuplicates: return "Compare"
        case .showDuplicates: return "Show"
        case .openICloudSettings: return "Open Settings"
        }
    }
}

// MARK: - Provider card

struct CloudProviderCard: View {
    let model: CloudStorageViewModel
    let group: CloudProviderGroup
    @State private var showsLargest = true
    @State private var showsNotOpened = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            UsageBar(
                segments: [
                    UsageSegment(label: "Stored on this Mac", bytes: group.localBytes, color: group.provider.tint),
                    UsageSegment(label: "Cloud-only", bytes: group.cloudOnlyBytes, color: Color.gray.opacity(0.35)),
                ],
                total: max(group.logicalBytes, 1), height: 10
            )
            HStack(spacing: 16) {
                LegendItem(color: group.provider.tint, label: "On this Mac", value: ByteFormatting.string(group.localBytes))
                LegendItem(color: Color.gray.opacity(0.35), label: "Cloud-only", value: "\(ByteFormatting.string(group.cloudOnlyBytes)) · \(NumberFormatting.count(group.cloudOnlyCount, "file"))")
                if group.notDownloadedFolders > 0 {
                    LegendItem(color: .clear, label: "\(NumberFormatting.count(group.notDownloadedFolders, "folder")) not downloaded")
                        .help("These folders exist only in the cloud. They weren't opened, so nothing was downloaded; files inside them aren't counted.")
                }
            }

            ForEach(group.summaries.filter { $0.errorMessage != nil }) { summary in
                InfoCallout(style: .warning, title: "\(summary.location.title) couldn't be read", message: summary.errorMessage ?? "")
            }
            if !group.supportsRemoveDownload {
                InfoCallout(style: .info, message: "\(group.name) syncs this folder with its own app rather than through macOS, so Mac Cleaner can't remove downloads here. Use \(group.name)'s settings to make files online-only.")
            }

            if group.summaries.count > 1 {
                locationsBreakdown
            } else if let summary = group.summaries.first, !summary.topFolders.isEmpty {
                topFolders(summary)
            }

            let largest = items(\.largestLocal)
            let notOpened = items(\.notOpened)
            if !largest.isEmpty {
                DisclosureGroup(isExpanded: $showsLargest) {
                    CloudItemList(model: model, items: largest)
                } label: {
                    Text("Largest files on this Mac").font(.callout.weight(.medium))
                }
            }
            if !notOpened.isEmpty {
                DisclosureGroup(isExpanded: $showsNotOpened) {
                    CloudItemList(model: model, items: notOpened)
                    Text("“Last opened” is approximate: macOS updates access times lazily; Spotlight's last-opened date is used where available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } label: {
                    HStack {
                        Text("Not opened in \(model.result?.notOpenedDays ?? 0) days").font(.callout.weight(.medium))
                        Text("\(notOpened.count) · \(ByteFormatting.string(notOpened.reduce(0) { $0 + $1.localBytes }))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .card()
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: group.provider.symbolName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(group.provider.tint.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(.headline)
                Text(group.account ?? (group.summaries.count == 1 ? PathUtilities.abbreviate(group.summaries[0].location.path) : "\(group.summaries.count) folders"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                SizeText(bytes: group.localBytes, font: .system(.title3, design: .rounded).weight(.semibold))
                Text("of \(ByteFormatting.string(group.logicalBytes)) on this Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var locationsBreakdown: some View {
        VStack(spacing: 0) {
            ForEach(group.summaries) { summary in
                HStack(spacing: 10) {
                    Image(systemName: icon(for: summary.location))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(summary.location.title)
                        PathText(path: summary.location.path)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        SizeText(bytes: summary.localBytes, font: .callout)
                        Text("of \(ByteFormatting.string(summary.logicalBytes))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                .contextMenu { FileContextMenu(path: summary.location.path) }
                Divider()
            }
        }
    }

    private func topFolders(_ summary: CloudLocationSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Top folders").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(summary.topFolders.prefix(5)) { folder in
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 18)
                    Text(folder.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(ByteFormatting.string(folder.localBytes)) on Mac")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    SizeText(bytes: folder.logicalBytes, font: .callout)
                        .frame(minWidth: 70, alignment: .trailing)
                }
                .contextMenu { FileContextMenu(path: folder.path) }
            }
        }
    }

    private func icon(for location: CloudLocation) -> String {
        switch location.role {
        case .drive: return location.provider.symbolName
        case .desktopAndDocuments: return location.title == "Desktop" ? "menubar.dock.rectangle" : "doc"
        case .appData: return "square.stack.3d.up"
        case .legacyFolder: return "folder"
        }
    }

    private func items(_ keyPath: KeyPath<CloudLocationSummary, [CloudFileItem]>) -> [CloudFileItem] {
        var seen = Set<String>()
        return group.summaries.flatMap { $0[keyPath: keyPath] }
            .filter { seen.insert($0.path).inserted && model.matchesSearch($0) }
            .sorted { $0.localBytes > $1.localBytes }
    }
}

// MARK: - Item rows

struct CloudItemList: View {
    let model: CloudStorageViewModel
    let items: [CloudFileItem]
    @State private var showsAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(showsAll ? items : Array(items.prefix(8))) { item in
                CloudItemRow(model: model, item: item)
            }
            if items.count > 8 {
                Button(showsAll ? "Show Fewer" : "Show All \(items.count)") {
                    withAnimation(.easeInOut(duration: 0.2)) { showsAll.toggle() }
                }
                .buttonStyle(.borderless)
                .padding(.leading, 10)
                .padding(.top, 4)
            }
        }
        .padding(.top, 6)
    }
}

struct CloudItemRow: View {
    let model: CloudStorageViewModel
    let item: CloudFileItem
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { model.selection.contains(item.path) }, set: { _ in model.toggle(item) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Select \(item.name)")
            FileIcon(path: item.path, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    if let opened = item.lastOpenedDate {
                        Text("Last opened ≈ \(DateFormatting.relative(opened))")
                    } else {
                        Text("Modified \(DateFormatting.relative(item.modificationDate))")
                    }
                    Text("·")
                    Text(PathUtilities.abbreviate((item.path as NSString).deletingLastPathComponent))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if isHovering {
                Button {
                    model.quickLook(item)
                } label: {
                    Image(systemName: "eye")
                }
                .buttonStyle(.borderless)
                .disabled(!model.canQuickLook(item))
                .help("Quick Look")
                Button("Remove Download") { model.requestRemoveDownload([item]) }
                    .buttonStyle(.borderless)
            }
            SizeText(bytes: item.localBytes, font: .callout)
                .foregroundStyle(.secondary)
                .frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isHovering ? Color.hoverFill : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { model.toggle(item) }
        .contextMenu {
            Button("Remove Download", systemImage: "icloud.and.arrow.up") { model.requestRemoveDownload([item]) }
            if model.canQuickLook(item) {
                Button("Quick Look", systemImage: "eye") { model.quickLook(item) }
            }
            Button("Reveal in Finder", systemImage: "folder") { model.reveal(item) }
            Button("Copy Path", systemImage: "doc.on.doc") { FinderActions.copyPath(item.path) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Remove Download") { model.requestRemoveDownload([item]) }
    }
}

// MARK: - Duplicates

struct CloudDuplicatesCard: View {
    @Bindable var model: CloudStorageViewModel
    @State private var showsAll = false

    var body: some View {
        Card("Identical Copies Stored Locally", symbol: "square.on.square") {
            if let note = model.duplicateNote {
                InfoCallout(style: .warning, message: note)
            }
            if model.isComparing {
                comparing
            } else if model.duplicates == nil {
                notCompared
            } else {
                results
            }
        }
    }

    @ViewBuilder
    private var notCompared: some View {
        if model.possibleDuplicateSets == 0 {
            Text("No two downloaded files of 1 MB or more have the same size, so there are no identical copies.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Text("\(NumberFormatting.count(model.possibleDuplicateSets)) set\(model.possibleDuplicateSets == 1 ? "" : "s") of downloaded files share a size and may be identical. Comparing reads their contents (SHA-256) — only files already on this Mac, nothing is downloaded. macOS records reading a file as an access, so compared files will show as recently opened.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Find Identical Copies") { model.compareDuplicates() }
        }
    }

    private var comparing: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fraction = model.compareProgress?.fraction {
                ProgressView(value: fraction).tint(AppSection.cloud.tint)
            } else {
                ProgressView().progressViewStyle(.linear).tint(AppSection.cloud.tint)
            }
            HStack {
                Text(compareMessage)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop", role: .cancel) { model.cancelComparison() }
            }
        }
    }

    private var compareMessage: String {
        guard let progress = model.compareProgress, progress.bytesToCompare > 0 else { return "Comparing files with identical sizes…" }
        return "Compared \(ByteFormatting.string(progress.bytesCompared)) of \(ByteFormatting.string(progress.bytesToCompare))"
    }

    @ViewBuilder
    private var results: some View {
        let groups = model.duplicateGroups.filter { group in group.items.contains(where: model.matchesSearch) }
        if groups.isEmpty {
            HStack {
                Text("No identical downloaded files of 1 MB or more were found in your cloud folders.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Compare Again") { model.compareDuplicates() }
                    .buttonStyle(.borderless)
            }
        } else {
            Text("These files have identical contents (compared with SHA-256). Removing the download of extra copies frees local space and keeps every copy in the cloud. To delete a copy everywhere, use Finder or the Duplicate Finder. Dependency and build folders such as node_modules aren't compared.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let visible = showsAll || model.highlightsDuplicates ? Array(groups.prefix(200)) : Array(groups.prefix(4))
            VStack(spacing: 10) {
                ForEach(visible) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(group.items.first?.name ?? "").font(.callout.weight(.semibold)).lineLimit(1)
                            Text("\(group.items.count) copies · \(ByteFormatting.string(group.size)) each")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(ByteFormatting.string(group.redundantLocalBytes)) extra")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                        .padding(.horizontal, 10)
                        ForEach(group.items) { item in
                            CloudItemRow(model: model, item: item)
                        }
                    }
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            if groups.count > 4 {
                Button(showsAll || model.highlightsDuplicates ? "Show Fewer" : "Show All \(groups.count) Sets") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if showsAll || model.highlightsDuplicates {
                            showsAll = false
                            model.highlightsDuplicates = false
                        } else {
                            showsAll = true
                        }
                    }
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

// MARK: - Optimize Mac Storage

struct CloudOptimizeStorageCard: View {
    let model: CloudStorageViewModel

    var body: some View {
        Card("Optimize Mac Storage for iCloud Drive", symbol: "icloud") {
            Text("With Optimize Mac Storage turned on, macOS keeps recently used iCloud Drive files on your Mac and removes downloads of older ones automatically when space runs low. They stay in iCloud and download again when you open them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Image(systemName: "gearshape").foregroundStyle(.secondary)
                Text("System Settings › your name (Apple Account) › iCloud › Drive › Optimize Mac Storage")
                    .font(.callout)
                    .textSelection(.enabled)
            }
            Button("Open iCloud Settings") { model.openICloudSettings() }
        }
    }
}

// MARK: - Selection and removal

struct CloudSelectionBar: View {
    let model: CloudStorageViewModel

    var body: some View {
        SelectionActionBar(selectedCount: model.selectedItems.count, selectedBytes: model.selectedLocalBytes, noun: "download") {
            Button("Deselect All") { model.selection.removeAll() }
            Button {
                FinderActions.reveal(model.selectedItems.map(\.path))
            } label: {
                Label("Reveal", systemImage: "folder")
            }
            Button {
                model.requestRemoveDownloadForSelection()
            } label: {
                Label("Remove Downloads", systemImage: "icloud.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .tint(AppSection.cloud.tint)
            .keyboardShortcut(.delete, modifiers: .command)
        }
    }
}

struct CloudRemovalSheet: View {
    let model: CloudStorageViewModel
    let request: CloudStorageViewModel.RemovalRequest
    @Environment(\.dismiss) private var dismiss

    private var removable: [CloudFileItem] { request.items.filter { request.problems[$0.path] == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "icloud.and.arrow.up")
                    .font(.system(size: 26))
                    .foregroundStyle(AppSection.cloud.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remove Downloads?").font(.title3.weight(.semibold))
                    Text("\(removable.count) item\(removable.count == 1 ? "" : "s") · frees about \(ByteFormatting.string(removable.reduce(0) { $0 + $1.localBytes })) on this Mac")
                        .foregroundStyle(.secondary)
                }
            }
            InfoCallout(style: .info, title: "Nothing is deleted",
                        message: "The items stay in the cloud and on your other devices, and download again automatically when you open them. You need an internet connection to open them later.")

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(request.items) { item in
                        HStack(spacing: 8) {
                            FileIcon(path: item.path, size: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).lineLimit(1).truncationMode(.middle)
                                if let problem = request.problems[item.path] {
                                    Text(problem).font(.caption).foregroundStyle(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer()
                            SizeText(bytes: item.localBytes, font: .callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 220)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.removalRequest = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Remove Downloads") {
                    model.confirmRemoval()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(AppSection.cloud.tint)
                .disabled(removable.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

struct CloudRemovalReportSheet: View {
    let model: CloudStorageViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let outcomes = model.removalOutcomes
        let succeeded = outcomes.filter(\.succeeded)
        let freed = outcomes.filter { $0.result == .removed || $0.result == .requested }.reduce(0) { $0 + $1.item.localBytes }
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: succeeded.count == outcomes.count ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(succeeded.count == outcomes.count ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Downloads Removed").font(.title3.weight(.semibold))
                    Text("\(succeeded.count) of \(outcomes.count) item\(outcomes.count == 1 ? "" : "s") are now stored only in the cloud, freeing about \(ByteFormatting.string(freed)) on this Mac.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if outcomes.contains(where: { $0.result == .requested }) {
                InfoCallout(style: .info, message: "macOS accepted some requests and will finish removing those downloads shortly.")
            }
            let failed = outcomes.filter { !$0.succeeded }
            if !failed.isEmpty {
                List {
                    Section("Not removed") {
                        ForEach(failed) { outcome in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(outcome.item.name).lineLimit(1)
                                if case .failed(let reason) = outcome.result {
                                    Text(reason).font(.caption).foregroundStyle(.secondary)
                                }
                                if outcome.canUseFinder {
                                    HStack(spacing: 6) {
                                        Text("In Finder, Control-click the item and choose Remove Download.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Button("Show in Finder") { model.reveal(outcome.item) }
                                            .buttonStyle(.borderless)
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(height: 200)
            }
            HStack {
                Spacer()
                Button("Done") {
                    model.showsRemovalReport = false
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}

struct CloudRemovingOverlay: View {
    let done: Int
    let total: Int

    var body: some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(width: 260)
                Text("Removing downloads… \(done) of \(total)").font(.headline)
                Text("Files stay in the cloud.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(radius: 20)
        }
        .transition(.opacity)
    }
}
