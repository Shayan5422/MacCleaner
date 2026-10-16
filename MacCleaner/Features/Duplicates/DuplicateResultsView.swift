import SwiftUI

/// Results of an exact-duplicate scan: groups on the left, the selected group's copies on the right.
struct DuplicateResultsPage: View {
    @Bindable var model: DuplicatesViewModel
    @State private var isShowingHardLinks = false
    @State private var listWidth: CGFloat = 300

    private let tint = AppSection.duplicates.tint

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                DuplicatesHeader(model: model, showsScanButton: true)
                summary
                if !model.groups.isEmpty { controls }
                DuplicateScanNotes(model: model, isShowingHardLinks: $isShowingHardLinks)
            }
            .padding([.horizontal, .top], Metrics.pagePadding)
            .padding(.bottom, 14)

            Divider()

            if model.groups.isEmpty {
                emptyState
            } else {
                DuplicateSplitView(listWidth: $listWidth) {
                    DuplicateGroupList(model: model)
                } detail: {
                    DuplicateGroupDetail(model: model)
                }
                .duplicateNotices(model)
            }

            SelectionActionBar(selectedCount: model.marks.count, selectedBytes: model.markedBytes, noun: "file") {
                Button("Deselect All") { model.deselectAll() }
                    .disabled(model.marks.isEmpty)
                Button {
                    model.moveMarkedToTrash()
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.marks.isEmpty || model.cleanupFlow.isCleaning)
                .help("Move the selected copies to the Trash (⌘⌫). One copy of every file is always kept.")
            }
        }
        .sheet(isPresented: $isShowingHardLinks) {
            DuplicateHardLinksSheet(sets: model.exactResult?.hardLinkSets ?? [])
        }
    }

    private var summary: some View {
        TileRow {
            StatTile(
                title: "Duplicate groups",
                value: NumberFormatting.count(model.groups.count),
                caption: "Files with identical copies",
                symbol: "square.on.square",
                tint: tint,
                fillsHeight: true
            )
            StatTile(
                title: "Extra copies",
                value: NumberFormatting.count(model.duplicateFileCount),
                caption: "One copy is always kept",
                symbol: "doc.on.doc",
                tint: .blue,
                fillsHeight: true
            )
            StatTile(
                title: "Reclaimable",
                value: ByteFormatting.string(model.totalReclaimable),
                caption: "Keeping \(model.keepRule.keptCopyPhrase)",
                symbol: "internaldrive",
                tint: .green,
                fillsHeight: true
            )
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker(selection: $model.keepRule) {
                ForEach(DuplicateKeepRule.allCases) { rule in
                    Text(rule.title).tag(rule)
                }
            } label: {
                Text("Keep")
            }
            .fixedSize()
            .help(model.keepRule.explanation)

            if model.keepRule == .preferredFolder {
                Button {
                    model.choosePreferredFolder()
                } label: {
                    Label(model.preferredFolderName ?? "Choose Folder…", systemImage: "folder")
                }
                .help(model.preferredFolder.map { "Copies inside \(PathUtilities.abbreviate($0)) are kept" } ?? "Choose the folder whose copies you want to keep")
            }

            Button {
                model.selectDuplicatesUsingRule()
            } label: {
                Label(model.searchText.isEmpty ? "Select Duplicates" : "Select Duplicates in Shown Groups", systemImage: "checklist")
            }
            .help("\(model.keepRule.explanation) Every other copy is selected. Protected copies and copies inside app libraries are never selected automatically.")

            Spacer()

            Text("Sorted by reclaimable space")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack {
            EmptyStateView(
                title: "No Duplicates Found",
                symbol: "checkmark.seal",
                message: emptyMessage,
                actionTitle: "Scan Again",
                action: { model.startScan() }
            )
            .disabled(!model.canStartScan)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyMessage: String {
        guard let result = model.exactResult else { return "No identical files were found." }
        let files = NumberFormatting.count(result.filesExamined)
        let locations = result.roots.count
        return "\(files) file\(result.filesExamined == 1 ? "" : "s") in \(locations) location\(locations == 1 ? "" : "s") were compared and none are identical."
    }
}

// MARK: - Scan notes

/// One-line facts about the scan, each with details on click.
struct DuplicateScanNotes: View {
    var model: DuplicatesViewModel
    @Binding var isShowingHardLinks: Bool

    var body: some View {
        if let result = model.exactResult {
            HStack(spacing: 8) {
                Text("\(NumberFormatting.count(result.filesExamined, "file")) checked in \(DateFormatting.duration(max(1, result.duration)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !result.hardLinkSets.isEmpty {
                    DuplicateNoteChip(symbol: "link", text: "\(NumberFormatting.count(result.hardLinkSets.count)) hard-linked", tint: .blue) {
                        Text("Hard links aren't duplicates").font(.headline)
                        Text("\(NumberFormatting.count(result.hardLinkSets.count)) file\(result.hardLinkSets.count == 1 ? " has" : "s have") several names that point to the same data on disk. They use the space only once, so they aren't counted as duplicates and removing one name frees nothing.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Show Hard-Linked Files…") { isShowingHardLinks = true }
                    }
                }
                if result.cloudOnlySkipped > 0 {
                    DuplicateNoteChip(symbol: "icloud", text: "\(NumberFormatting.count(result.cloudOnlySkipped)) in the cloud only", tint: .teal) {
                        Text("Cloud-only files weren't compared").font(.headline)
                        Text("These files are stored in iCloud Drive or another cloud provider and aren't downloaded on this Mac. Comparing them would download them, so Mac Cleaner skips them.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                let unreadable = result.unreadableFiles + result.unreadableFolders
                if unreadable > 0 {
                    DuplicateNoteChip(symbol: "lock", text: "\(NumberFormatting.count(unreadable)) unreadable", tint: .orange) {
                        Text("Some items couldn't be read").font(.headline)
                        Text("\(NumberFormatting.count(result.unreadableFolders)) folder\(result.unreadableFolders == 1 ? "" : "s") and \(NumberFormatting.count(result.unreadableFiles)) file\(result.unreadableFiles == 1 ? "" : "s") couldn't be read, usually because macOS protects them. Allow Full Disk Access to include them.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Full Disk Access Settings") { model.services.permissions.open(.fullDiskAccess) }
                    }
                }
                if result.changedFiles > 0 {
                    DuplicateNoteChip(symbol: "pencil", text: "\(NumberFormatting.count(result.changedFiles)) changed during scan", tint: .gray) {
                        Text("Files changed while being compared").font(.headline)
                        Text("These files were modified, moved or replaced during the scan, so they were left out to be safe. Scan again to include them.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !result.unavailableRoots.isEmpty {
                    DuplicateNoteChip(symbol: "exclamationmark.triangle", text: "\(result.unavailableRoots.count) location\(result.unavailableRoots.count == 1 ? "" : "s") unavailable", tint: .orange) {
                        Text("Locations not scanned").font(.headline)
                        ForEach(result.unavailableRoots) { root in
                            VStack(alignment: .leading, spacing: 2) {
                                PathText(path: root.path, font: .callout)
                                Text(root.reason).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Group list

struct DuplicateGroupList: View {
    @Bindable var model: DuplicatesViewModel

    var body: some View {
        let groups = model.filteredGroups
        List(selection: $model.selectedGroupID) {
            ForEach(groups) { group in
                DuplicateGroupRow(group: group, reclaimable: model.reclaimable(for: group), markedCount: model.markedCount(in: group))
                    .tag(group.id)
                    .contextMenu {
                        Button("Apply “\(model.keepRule.shortTitle)” to This Group", systemImage: "checklist") { model.applyRule(to: group) }
                        Button("Keep All Copies", systemImage: "checkmark.circle") { model.unmarkAll(in: group) }
                        Divider()
                        Button("Reveal All in Finder", systemImage: "folder") { FinderActions.reveal(group.files.map(\.path)) }
                        Button("Quick Look", systemImage: "eye") {
                            model.preview(group.files[0].path, among: group.files.map(\.path))
                        }
                    }
            }
        }
        .listStyle(.inset)
        .onKeyPress(.space) {
            guard let group = model.selectedGroup, let first = group.files.first else { return .ignored }
            model.preview(first.path, among: group.files.map(\.path))
            return .handled
        }
        .overlay {
            if groups.isEmpty && !model.searchText.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
        .accessibilityLabel("Duplicate groups")
    }
}

struct DuplicateGroupRow: View {
    var group: DuplicateGroup
    var reclaimable: Int64
    var markedCount: Int

    var body: some View {
        HStack(spacing: 10) {
            DuplicateThumbnail(path: group.files[0].path, side: 36)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // As much of "3 copies · 4.2 MB each · APFS clones" as fits on one line.
                ViewThatFits(in: .horizontal) {
                    Text(subtitle)
                    Text("\(group.files.count) copies · \(ByteFormatting.string(group.contentSize)) each")
                    Text("\(group.files.count) copies")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(subtitle)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                SizeText(bytes: reclaimable, font: .callout.weight(.medium))
                if markedCount > 0 {
                    Text("\(markedCount) to Trash")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.displayName), \(subtitle), \(ByteFormatting.string(reclaimable)) reclaimable\(markedCount > 0 ? ", \(markedCount) marked for the Trash" : "")")
    }

    /// "3 copies · 4.2 MB each", noting copies that share storage.
    private var subtitle: String {
        var text = "\(group.files.count) copies · \(ByteFormatting.string(group.contentSize)) each"
        if group.containsClones { text += " · APFS clones" } else if group.containsHardLinks { text += " · hard links" }
        return text
    }
}

// MARK: - Group detail

struct DuplicateGroupDetail: View {
    @Bindable var model: DuplicatesViewModel
    @FocusState private var focusedFileID: String?

    var body: some View {
        if let group = model.selectedGroup {
            let paths = group.files.map(\.path)
            let suggestedID = model.suggestedKeeperID(in: group)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(group, paths: paths)
                    notes(group)
                    VStack(spacing: 10) {
                        ForEach(group.files) { file in
                            DuplicateFileCard(
                                file: file,
                                isMarked: model.isMarked(file),
                                isSuggestedKeeper: file.id == suggestedID,
                                keepRuleTitle: model.keepRule.shortTitle,
                                canMark: model.canMark(file, in: group),
                                isFocused: focusedFileID == file.id,
                                onSetMarked: { model.setMarked($0, file: file, in: group) },
                                onQuickLook: { model.preview(file.path, among: paths) },
                                onKeepOnly: { model.keepOnly(file, in: group) },
                                onExclude: { model.exclude(path: file.path) }
                            )
                            .focusable()
                            .focusEffectDisabled()
                            .focused($focusedFileID, equals: file.id)
                            .onTapGesture { focusedFileID = file.id }
                            .onKeyPress(.space) {
                                model.preview(file.path, among: paths)
                                return .handled
                            }
                        }
                    }
                    Text("Tip: select a copy and press Space to preview it with Quick Look.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(Metrics.pagePadding)
            }
            .id(group.id)
        } else {
            EmptyStateView(
                title: "Select a Group",
                symbol: "square.on.square",
                message: "Choose a group on the left to compare its copies and pick the one to keep."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ group: DuplicateGroup, paths: [String]) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Button {
                model.preview(paths[0], among: paths)
            } label: {
                DuplicateThumbnail(path: paths[0], side: 88)
                    .frame(width: 88, height: 88)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Quick Look")
            .accessibilityLabel("Quick Look \(group.displayName)")

            VStack(alignment: .leading, spacing: 8) {
                Text(group.displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                DuplicateFlowLayout {
                    Badge(text: group.kind.title, symbol: group.kind.symbolName, tint: .gray)
                    Badge(text: "\(group.files.count) identical copies", symbol: "equal.circle.fill", tint: AppSection.duplicates.tint)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Size of each copy").foregroundStyle(.secondary)
                        SizeText(bytes: group.contentSize, font: .callout)
                    }
                    GridRow {
                        Text("Reclaimable").foregroundStyle(.secondary)
                        Text("\(ByteFormatting.string(model.reclaimable(for: group))), keeping \(model.keepRule.keptCopyPhrase)")
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    GridRow {
                        Text("SHA-256").foregroundStyle(.secondary)
                        Text(String(group.digest.prefix(16)) + "…")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .help(group.digest)
                    }
                }
                .font(.callout)
                HStack(spacing: 8) {
                    Button("Apply “\(model.keepRule.shortTitle)”") { model.applyRule(to: group) }
                        .help(model.keepRule.explanation)
                    Button("Keep All Copies") { model.unmarkAll(in: group) }
                        .disabled(model.markedCount(in: group) == 0)
                }
                .controlSize(.small)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func notes(_ group: DuplicateGroup) -> some View {
        if group.containsClones {
            InfoCallout(style: .info, message: "Some copies are APFS clones that share storage with each other. Removing a clone frees little space; the space is freed only when every clone of the file is gone.")
        }
        if group.containsHardLinks {
            InfoCallout(style: .info, message: "Some copies have other names (hard links). Removing one name frees no space while another name still points to the data.")
        }
        if let library = group.files.compactMap(\.managedLibraryName).first {
            InfoCallout(style: .warning, message: "A copy is inside your \(library) library. It's never selected automatically, because removing it leaves a missing item in \(library). Remove duplicates there from within \(library) if you can.")
        }
        if group.files.contains(where: \.isProtected) {
            InfoCallout(style: .info, message: "Copies marked Protected can't be moved to the Trash by Mac Cleaner. The reason is shown under each one.")
        }
    }
}

/// One copy of a file in the detail pane.
struct DuplicateFileCard: View {
    var file: DuplicateFile
    var isMarked: Bool
    var isSuggestedKeeper: Bool
    var keepRuleTitle: String
    var canMark: Bool
    var isFocused: Bool
    var onSetMarked: @MainActor @Sendable (Bool) -> Void
    var onQuickLook: () -> Void
    var onKeepOnly: () -> Void
    var onExclude: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button(action: onQuickLook) {
                DuplicateThumbnail(path: file.path, side: 64)
                    .frame(width: 64, height: 64)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Quick Look (Space)")
            .accessibilityLabel("Quick Look \(file.name)")

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.name)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(file.name)
                        PathText(path: file.folderPath)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    controls
                }
                DuplicateFileBadges(file: file, isMarked: isMarked, isSuggestedKeeper: isSuggestedKeeper, keepRuleTitle: keepRuleTitle)
                DuplicateFileMetadata(file: file)
                if let reason = file.protectionReason {
                    Label(reason, systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !file.hardLinkPaths.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Also named:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(file.hardLinkPaths, id: \.self) { alias in
                            PathText(path: alias, font: .caption)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Metrics.tileRadius + 2, style: .continuous)
                .fill(isMarked ? Color.red.opacity(0.06) : Color.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.tileRadius + 2, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isFocused ? 2 : 1)
        )
        .contentShape(Rectangle())
        .contextMenu {
            FileContextMenu(path: file.path, onQuickLook: onQuickLook, onExclude: onExclude)
            Divider()
            Button("Keep Only This Copy", systemImage: "star") { onKeepOnly() }
            if isMarked {
                Button("Keep This Copy", systemImage: "checkmark.circle") { onSetMarked(false) }
            } else {
                Button("Move This Copy to Trash", systemImage: "trash") { onSetMarked(true) }
                    .disabled(!canMark)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(file.name) in \(PathUtilities.abbreviate(file.folderPath))")
        .accessibilityValue(isMarked ? "Will be moved to the Trash" : (file.isProtected ? "Protected" : "Kept"))
    }

    /// "Move to Trash" plus Quick Look and Reveal in Finder, kept compact so the name column gets the width.
    private var controls: some View {
        HStack(spacing: 6) {
            Toggle("Move to Trash", isOn: Binding(get: { isMarked }, set: onSetMarked))
                .toggleStyle(.checkbox)
                .fixedSize()
                .disabled(!canMark && !isMarked)
                .help(toggleHelp)
                .accessibilityLabel("Move \(file.name) to the Trash")
            Button(action: onQuickLook) { Image(systemName: "eye") }
                .help("Quick Look (Space)")
                .accessibilityLabel("Quick Look")
            Button { FinderActions.reveal(file.path) } label: { Image(systemName: "folder") }
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal in Finder")
        }
        .buttonStyle(.borderless)
    }

    private var borderColor: Color {
        if isFocused { return Color.accentColor }
        return isMarked ? Color.red.opacity(0.35) : Color.subtleBorder
    }

    private var toggleHelp: String {
        if let reason = file.protectionReason { return reason }
        if !canMark && !isMarked { return "At least one copy of every file is always kept." }
        return isMarked ? "This copy will be moved to the Trash." : "Mark this copy to move it to the Trash."
    }
}

// MARK: - Hard links

struct DuplicateHardLinksSheet: View {
    var sets: [DuplicateHardLinkSet]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "link")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(AppSection.duplicates.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Hard-Linked Files").font(.title3.weight(.semibold))
                    Text("Each entry is one file with several names. The names share the same data, so they use the space once and aren't duplicates. Removing one name frees no space.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            List(sets) { set in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        FileIcon(path: set.paths.first ?? "", size: 18)
                        Text(set.name).font(.headline).lineLimit(1)
                        Spacer()
                        SizeText(bytes: set.allocatedSize, font: .callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(set.paths, id: \.self) { path in
                        PathText(path: path)
                            .contextMenu { FileContextMenu(path: path) }
                    }
                    if Int(set.linkCount) > set.paths.count {
                        let outside = Int(set.linkCount) - set.paths.count
                        Text("\(outside) more name\(outside == 1 ? "" : "s") outside the scanned locations")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 260)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620, height: 480)
    }
}
