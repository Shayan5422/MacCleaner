import SwiftUI

/// Results of a similar-photo scan. Groups are suggestions; nothing is ever selected automatically.
struct SimilarPhotosResultsPage: View {
    @Bindable var model: DuplicatesViewModel
    @State private var listWidth: CGFloat = 300

    private let tint = AppSection.duplicates.tint

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                DuplicatesHeader(model: model, showsScanButton: true)
                summary
                HStack(spacing: 12) {
                    Text("Similarity").foregroundStyle(.secondary)
                    DuplicateSimilaritySlider(model: model)
                    Spacer(minLength: 8)
                    SimilarScanNotes(model: model)
                }
                // Line-limited on purpose: unbounded text outside a scroll view would raise
                // the window's minimum height when it is measured at a narrow width.
                Label {
                    Text("Similar photos aren't identical copies, so nothing is selected for you. Compare each group and mark the photos you don't need; at least one photo in every group is always kept.")
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("Similar photos aren't identical copies, so nothing is selected for you. Compare each group and mark the photos you don't need; at least one photo in every group is always kept.")
                } icon: {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(AppSection.duplicates.tint)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], Metrics.pagePadding)
            .padding(.bottom, 14)

            Divider()

            if model.similarGroups.isEmpty {
                EmptyStateView(
                    title: "No Similar Photos",
                    symbol: "photo.on.rectangle.angled",
                    message: emptyMessage,
                    actionTitle: "Scan Again",
                    action: { model.startScan() }
                )
                .disabled(!model.canStartScan)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DuplicateSplitView(listWidth: $listWidth) {
                    SimilarGroupList(model: model)
                } detail: {
                    SimilarGroupDetail(model: model)
                }
                .duplicateNotices(model)
            }

            SelectionActionBar(selectedCount: model.similarMarks.count, selectedBytes: model.similarMarkedBytes, noun: "photo") {
                Button("Deselect All") { model.deselectAllSimilar() }
                    .disabled(model.similarMarks.isEmpty)
                Button {
                    model.moveMarkedSimilarToTrash()
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.similarMarks.isEmpty || model.cleanupFlow.isCleaning)
                .help("Move the photos you marked to the Trash (⌘⌫)")
            }
        }
    }

    private var summary: some View {
        TileRow {
            StatTile(
                title: "Groups",
                value: NumberFormatting.count(model.similarGroups.count),
                caption: "Photos that look alike",
                symbol: "square.stack.3d.down.right",
                tint: tint,
                fillsHeight: true
            )
            StatTile(
                title: "Photos in groups",
                value: NumberFormatting.count(model.similarPhotoCount),
                caption: "\(NumberFormatting.count(model.similarResult?.imagesAnalyzed ?? 0)) photos analyzed",
                symbol: "photo.on.rectangle",
                tint: .blue,
                fillsHeight: true
            )
            StatTile(
                title: "Marked for Trash",
                value: NumberFormatting.count(model.similarMarks.count),
                caption: model.similarMarks.isEmpty ? "Choose photos in each group" : "Frees about \(ByteFormatting.string(model.similarMarkedBytes))",
                symbol: "trash",
                tint: .orange,
                fillsHeight: true
            )
        }
    }

    private var emptyMessage: String {
        guard let result = model.similarResult else { return "No photos look alike." }
        if result.imagesFound < 2 {
            return "Fewer than two photos were found in the chosen locations."
        }
        return "\(NumberFormatting.count(result.imagesAnalyzed)) photos were compared and none look alike at this similarity. Try moving the slider toward Looser."
    }
}

/// Facts about the similar-photo scan, with details on click.
struct SimilarScanNotes: View {
    var model: DuplicatesViewModel

    var body: some View {
        if let result = model.similarResult {
            HStack(spacing: 8) {
                if result.cloudOnlySkipped > 0 {
                    DuplicateNoteChip(symbol: "icloud", text: "\(NumberFormatting.count(result.cloudOnlySkipped)) in the cloud only", tint: .teal) {
                        Text("Cloud-only photos weren't analyzed").font(.headline)
                        Text("These photos are stored in iCloud Drive or another cloud provider and aren't downloaded on this Mac. Analyzing them would download them, so they were skipped.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                let unreadable = result.unreadableImages + result.unreadableFolders
                if unreadable > 0 {
                    DuplicateNoteChip(symbol: "exclamationmark.triangle", text: "\(NumberFormatting.count(unreadable)) unreadable", tint: .orange) {
                        Text("Some items couldn't be read").font(.headline)
                        Text("\(NumberFormatting.count(result.unreadableImages)) image\(result.unreadableImages == 1 ? "" : "s") couldn't be decoded and \(NumberFormatting.count(result.unreadableFolders)) folder\(result.unreadableFolders == 1 ? "" : "s") couldn't be opened. Protected folders need Full Disk Access.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Full Disk Access Settings") { model.services.permissions.open(.fullDiskAccess) }
                    }
                }
                if !result.unavailableRoots.isEmpty {
                    DuplicateNoteChip(symbol: "folder.badge.questionmark", text: "\(result.unavailableRoots.count) location\(result.unavailableRoots.count == 1 ? "" : "s") unavailable", tint: .orange) {
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
            }
        }
    }
}

// MARK: - Group list

struct SimilarGroupList: View {
    @Bindable var model: DuplicatesViewModel

    var body: some View {
        let groups = model.filteredSimilarGroups
        List(selection: $model.selectedSimilarGroupID) {
            ForEach(groups) { group in
                SimilarGroupRow(group: group, markedCount: model.markedCount(in: group))
                    .tag(group.id)
                    .contextMenu {
                        Button("Keep All Photos", systemImage: "checkmark.circle") { model.unmarkAll(in: group) }
                        Divider()
                        Button("Reveal All in Finder", systemImage: "folder") { FinderActions.reveal(group.photos.map(\.file.path)) }
                        Button("Quick Look", systemImage: "eye") {
                            model.preview(group.photos[0].file.path, among: group.photos.map(\.file.path))
                        }
                    }
            }
        }
        .listStyle(.inset)
        .onKeyPress(.space) {
            guard let group = model.selectedSimilarGroup, let first = group.photos.first else { return .ignored }
            model.preview(first.file.path, among: group.photos.map(\.file.path))
            return .handled
        }
        .overlay {
            if groups.isEmpty && !model.searchText.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
        .accessibilityLabel("Groups of similar photos")
    }
}

struct SimilarGroupRow: View {
    var group: SimilarPhotoGroup
    var markedCount: Int

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .leading) {
                ForEach(Array(group.photos.prefix(3).enumerated()).reversed(), id: \.element.id) { index, photo in
                    DuplicateThumbnail(path: photo.file.path, side: 36)
                        .frame(width: 34, height: 34)
                        .background(Color.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.subtleBorder))
                        .offset(x: CGFloat(index) * 11)
                }
            }
            .frame(width: 34 + 22, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(group.photos.count) similar photos")
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                SizeText(bytes: group.totalBytes, font: .callout)
                if markedCount > 0 {
                    Text("\(markedCount) to Trash")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.photos.count) similar photos, \(subtitle), \(ByteFormatting.string(group.totalBytes))\(markedCount > 0 ? ", \(markedCount) marked for the Trash" : "")")
    }

    private var subtitle: String {
        if let date = group.photos.compactMap(\.captureDate).min() {
            return "\(group.displayName) · \(DateFormatting.day(date))"
        }
        return group.displayName
    }
}

// MARK: - Group detail

struct SimilarGroupDetail: View {
    @Bindable var model: DuplicatesViewModel
    @FocusState private var focusedPhotoID: String?

    var body: some View {
        if let group = model.selectedSimilarGroup {
            let paths = group.photos.map(\.file.path)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(group.photos.count) Similar Photos")
                                .font(.title3.weight(.semibold))
                            Text("\(similarityDescription(group)) · \(ByteFormatting.string(group.totalBytes)) in total")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Keep All") { model.unmarkAll(in: group) }
                            .controlSize(.small)
                            .disabled(model.markedCount(in: group) == 0)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                        ForEach(group.photos) { photo in
                            SimilarPhotoCard(
                                photo: photo,
                                isMarked: model.isMarked(photo),
                                canMark: model.canMark(photo, in: group),
                                isHighestResolution: photo.id == group.highestResolutionID,
                                isFocused: focusedPhotoID == photo.id,
                                onSetMarked: { model.setMarked($0, photo: photo, in: group) },
                                onQuickLook: { model.preview(photo.file.path, among: paths) },
                                onKeepOnly: { model.keepOnly(photo, in: group) },
                                onExclude: { model.exclude(path: photo.file.path) }
                            )
                            .focusable()
                            .focusEffectDisabled()
                            .focused($focusedPhotoID, equals: photo.id)
                            .onTapGesture { focusedPhotoID = photo.id }
                            .onKeyPress(.space) {
                                model.preview(photo.file.path, among: paths)
                                return .handled
                            }
                        }
                    }
                    Text("Tip: select a photo and press Space to compare it full size with Quick Look; use the arrow keys there to step through the group.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(Metrics.pagePadding)
            }
            .id(group.id)
        } else {
            EmptyStateView(
                title: "Select a Group",
                symbol: "photo.on.rectangle.angled",
                message: "Choose a group on the left to compare its photos side by side."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func similarityDescription(_ group: SimilarPhotoGroup) -> String {
        if group.looksIdentical { return "Look identical" }
        return SimilarPhotoThreshold.label(forDistance: group.maximumDistance)
    }
}

/// One photo in a group, with its metadata and a manual "Move to Trash" choice.
struct SimilarPhotoCard: View {
    var photo: SimilarPhoto
    var isMarked: Bool
    var canMark: Bool
    var isHighestResolution: Bool
    var isFocused: Bool
    var onSetMarked: @MainActor @Sendable (Bool) -> Void
    var onQuickLook: () -> Void
    var onKeepOnly: () -> Void
    var onExclude: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onQuickLook) {
                DuplicateThumbnail(path: photo.file.path, side: 320)
                    .frame(maxWidth: .infinity)
                    .frame(height: 190)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if isMarked {
                            Image(systemName: "trash.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .red)
                                .font(.title2)
                                .padding(6)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help("Quick Look (Space)")
            .accessibilityLabel("Quick Look \(photo.file.name)")

            VStack(alignment: .leading, spacing: 2) {
                Text(photo.file.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(photo.file.name)
                PathText(path: photo.file.folderPath, font: .caption2)
            }

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                GridRow {
                    Text("Dimensions").foregroundStyle(.tertiary)
                    Text(photo.dimensionsText).foregroundStyle(.secondary)
                }
                if let taken = photo.captureDate {
                    GridRow {
                        Text("Taken").foregroundStyle(.tertiary)
                        Text(DateFormatting.short(taken)).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Modified").foregroundStyle(.tertiary)
                    Text(DateFormatting.short(photo.file.modificationDate)).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Size").foregroundStyle(.tertiary)
                    Text(ByteFormatting.string(photo.file.logicalSize)).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .monospacedDigit()

            // Always reserves a row so cards in a grid row line up.
            DuplicateFlowLayout {
                if isMarked {
                    Badge(text: "Moving to Trash", symbol: "trash.fill", tint: .red)
                } else if photo.file.isProtected {
                    Badge(text: "Protected", symbol: "lock.fill", tint: .orange)
                        .help(photo.file.protectionReason ?? "")
                } else {
                    Badge(text: "Keeping", symbol: "checkmark.circle.fill", tint: .green)
                }
                if isHighestResolution {
                    Badge(text: "Highest resolution", symbol: "arrow.up.left.and.arrow.down.right", tint: AppSection.duplicates.tint)
                }
                if let library = photo.file.managedLibraryName {
                    Badge(text: "In \(library) library", symbol: "building.columns", tint: .purple)
                }
            }

            Divider()

            HStack(spacing: 6) {
                Toggle("Move to Trash", isOn: Binding(get: { isMarked }, set: onSetMarked))
                    .toggleStyle(.checkbox)
                    .disabled(!canMark && !isMarked)
                    .help(toggleHelp)
                    .accessibilityLabel("Move \(photo.file.name) to the Trash")
                Spacer()
                Button(action: onQuickLook) { Image(systemName: "eye") }
                    .help("Quick Look (Space)")
                    .accessibilityLabel("Quick Look")
                Button { FinderActions.reveal(photo.file.path) } label: { Image(systemName: "folder") }
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal in Finder")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Metrics.tileRadius + 2, style: .continuous)
                .fill(isMarked ? Color.red.opacity(0.06) : Color.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.tileRadius + 2, style: .continuous)
                .strokeBorder(isFocused ? Color.accentColor : (isMarked ? Color.red.opacity(0.35) : Color.subtleBorder), lineWidth: isFocused ? 2 : 1)
        )
        .contentShape(Rectangle())
        .contextMenu {
            FileContextMenu(path: photo.file.path, onQuickLook: onQuickLook, onExclude: onExclude)
            Divider()
            Button("Keep Only This Photo", systemImage: "star") { onKeepOnly() }
            if isMarked {
                Button("Keep This Photo", systemImage: "checkmark.circle") { onSetMarked(false) }
            } else {
                Button("Move This Photo to Trash", systemImage: "trash") { onSetMarked(true) }
                    .disabled(!canMark)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(photo.file.name), \(photo.dimensionsText)")
        .accessibilityValue(isMarked ? "Will be moved to the Trash" : "Kept")
    }

    private var toggleHelp: String {
        if let reason = photo.file.protectionReason { return reason }
        if !canMark && !isMarked { return "At least one photo in every group is always kept." }
        return isMarked ? "This photo will be moved to the Trash." : "Mark this photo to move it to the Trash."
    }
}
