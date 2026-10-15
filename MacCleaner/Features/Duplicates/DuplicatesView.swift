import AppKit
import QuickLook
import SwiftUI

/// Duplicate Finder: exact duplicates and similar photos.
struct DuplicatesView: View {
    @Bindable var model: DuplicatesViewModel

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.windowBackground)
            .searchable(text: $model.searchText, prompt: model.mode == .exact ? "Search names and paths" : "Search photos")
            .quickLookPreview($model.quickLookURL, in: model.quickLookItems)
            .cleanupFlow(model.cleanupFlow, services: model.services)
            .onAppear { model.refreshVolumes() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
                model.refreshVolumes()
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
                model.refreshVolumes()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .exact:
            switch model.exactPhase {
            case .idle: DuplicatesSetupPage(model: model)
            case .scanning: DuplicatesScanningPage(model: model)
            case .finished: DuplicateResultsPage(model: model)
            case .failed(let message): DuplicatesSetupPage(model: model, errorMessage: message)
            }
        case .similar:
            switch model.similarPhase {
            case .idle: DuplicatesSetupPage(model: model)
            case .scanning: DuplicatesScanningPage(model: model)
            case .finished: SimilarPhotosResultsPage(model: model)
            case .failed(let message): DuplicatesSetupPage(model: model, errorMessage: message)
            }
        }
    }
}

// MARK: - Header

/// Page title with the mode switch and, on result pages, a button to scan again.
struct DuplicatesHeader: View {
    @Bindable var model: DuplicatesViewModel
    var showsScanButton = false

    var body: some View {
        PageHeader(section: .duplicates, subtitle: subtitle) {
            HStack(spacing: 10) {
                Picker("Mode", selection: $model.mode) {
                    ForEach(DuplicatesViewModel.Mode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbolName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(model.isScanning)
                .help(model.isScanning ? "Available when the current scan finishes" : "Switch between exact duplicates and similar photos")
                .accessibilityLabel("Find")

                if showsScanButton {
                    Button {
                        model.startScan()
                    } label: {
                        Label("Scan Again", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .fixedSize()
                    .disabled(!model.canStartScan)
                    .help("Scan the same locations again (⌘R)")
                }
            }
        }
    }

    private var subtitle: String {
        switch model.mode {
        case .exact: return "Find byte-for-byte identical files and choose which copy to keep."
        case .similar: return "Find photos that look alike, compare them side by side and keep the best ones."
        }
    }
}

// MARK: - Setup

struct DuplicatesSetupPage: View {
    @Bindable var model: DuplicatesViewModel
    var errorMessage: String?

    var body: some View {
        PageScroll {
            DuplicatesHeader(model: model)
            FullDiskAccessBanner(reason: "Some folders are protected by macOS. Files in them can't be compared until you allow access.")
            if let errorMessage {
                InfoCallout(style: .danger, title: "The scan couldn't finish", message: errorMessage)
            }
            launchView
                .disabled(!model.canStartScan)
            if model.enabledRoots.isEmpty {
                InfoCallout(style: .warning, message: "Turn on at least one location below to start a scan.")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                DuplicateLocationsCard(model: model)
                DuplicateOptionsCard(model: model)
            }
            InfoCallout(
                style: .info,
                title: "About your Photos library",
                message: "Photos manages the contents of its library, so Mac Cleaner treats it as a single item and never looks inside. To merge duplicates there, open Photos and choose Duplicates in the sidebar under Utilities."
            )
        }
    }

    @ViewBuilder
    private var launchView: some View {
        switch model.mode {
        case .exact:
            ScanLaunchView(
                section: .duplicates,
                headline: "Find duplicate files",
                message: "Mac Cleaner compares files in the locations below and shows identical copies side by side. Nothing is removed until you choose what to keep and confirm.",
                buttonTitle: "Find Duplicates",
                bullets: [
                    "Compares size, then SHA-256 of each file's first and last 64 KB, then of the whole file",
                    "Recognizes hard links and APFS clones, so space estimates are honest",
                    "One copy of every file is always kept; removed copies go to the Trash",
                ]
            ) { model.startScan() }
        case .similar:
            ScanLaunchView(
                section: .duplicates,
                headline: "Find similar photos",
                message: "Apple's Vision framework compares how your photos look, right on this Mac. Resized, recompressed and lightly edited versions are grouped together.",
                buttonTitle: "Find Similar Photos",
                bullets: [
                    "Photos are analyzed on this Mac and never uploaded",
                    "Groups show photos side by side with dimensions, dates and sizes",
                    "Nothing is ever selected automatically — you decide what goes",
                ]
            ) { model.startScan() }
        }
    }
}

/// The folders and drives to search.
struct DuplicateLocationsCard: View {
    @Bindable var model: DuplicatesViewModel

    var body: some View {
        Card("Locations", symbol: "folder", accessory: { addMenu }) {
            VStack(spacing: 0) {
                ForEach(Array(model.locations.enumerated()), id: \.element.id) { index, location in
                    if index > 0 { Divider() }
                    DuplicateLocationRow(
                        location: location,
                        isEnabled: Binding(
                            get: { location.isEnabled },
                            set: { model.setLocation(location, enabled: $0) }
                        ),
                        onRemove: location.isDefault ? nil : { model.removeLocation(location) }
                    )
                }
            }
            Text("Apps, bundles and libraries such as Photos are treated as single items and never searched inside. Hidden files and excluded folders follow your settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var addMenu: some View {
        Menu {
            Button("Choose Folder or Drive…", systemImage: "folder.badge.plus") { model.chooseFolder() }
            let volumes = model.availableVolumes.filter { volume in !model.locations.contains { $0.path == volume.path } }
            if !volumes.isEmpty {
                Section("Drives") {
                    ForEach(volumes) { volume in
                        Button(volume.name, systemImage: volume.symbolName) { model.addLocation(path: volume.path) }
                    }
                }
            }
            let previous = model.previouslyChosenFolders
            if !previous.isEmpty {
                Section("Previously Chosen") {
                    ForEach(previous) { location in
                        Button(PathUtilities.abbreviate(location.path), systemImage: "clock.arrow.circlepath") {
                            model.addLocation(path: location.path)
                        }
                    }
                }
            }
            Divider()
            Button("Restore Default Locations", systemImage: "arrow.uturn.backward") { model.resetLocations() }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.isScanning)
        .accessibilityLabel("Add location")
    }
}

struct DuplicateLocationRow: View {
    var location: DuplicateLocation
    @Binding var isEnabled: Bool
    var onRemove: (() -> Void)?

    var body: some View {
        let exists = location.exists
        HStack(spacing: 10) {
            Toggle(isOn: $isEnabled) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Search \(location.displayName)")
            Image(systemName: location.symbolName)
                .foregroundStyle(location.isExternal ? Color.orange : AppSection.duplicates.tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(location.displayName)
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                PathText(path: location.path, font: .caption2)
            }
            Spacer(minLength: 8)
            if !exists {
                Badge(text: location.isExternal ? "Not connected" : "Not found", symbol: "exclamationmark.triangle.fill", tint: .orange)
            } else if location.isExternal {
                Badge(text: "External", symbol: "externaldrive", tint: .gray)
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove from the list")
                .accessibilityLabel("Remove \(location.displayName)")
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            if exists { Button("Reveal in Finder", systemImage: "folder") { FinderActions.reveal(location.path) } }
            Button("Copy Path", systemImage: "doc.on.doc") { FinderActions.copyPath(location.path) }
            if let onRemove {
                Divider()
                Button("Remove from List", systemImage: "minus.circle", action: onRemove)
            }
        }
    }
}

/// Scan options for the current mode.
struct DuplicateOptionsCard: View {
    @Bindable var model: DuplicatesViewModel

    var body: some View {
        Card("Options", symbol: "slider.horizontal.3") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                if model.mode == .exact {
                    GridRow {
                        Text("Compare").foregroundStyle(.secondary)
                        Picker("Compare", selection: $model.kindFilter) {
                            ForEach(DuplicateKindFilter.allCases) { filter in
                                Label(filter.title, systemImage: filter.symbolName).tag(filter)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                GridRow {
                    Text("Minimum size").foregroundStyle(.secondary)
                    Picker("Minimum size", selection: $model.minimumSize) {
                        ForEach(DuplicateMinimumSize.allCases) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if model.mode == .similar {
                    GridRow {
                        Text("Similarity").foregroundStyle(.secondary)
                        DuplicateSimilaritySlider(model: model)
                    }
                }
            }
            Toggle(isOn: $model.skipDeveloperFolders) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skip developer and dependency folders")
                    Text("node_modules, .git, build products and similar folders belong to projects and break when files inside are removed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            Text(settingsSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(model.isScanning)
    }

    private var settingsSummary: String {
        let settings = model.services.settings
        let exclusions = settings.exclusions.paths.count
        var text = settings.includeHiddenFiles ? "Hidden files are included" : "Hidden files are skipped"
        if exclusions > 0 {
            text += " and \(exclusions) excluded location\(exclusions == 1 ? " is" : "s are") left out"
        }
        return text + " (change this in Settings). Files stored only in iCloud are never downloaded to be compared."
    }
}

/// Similarity threshold slider with a descriptive label.
struct DuplicateSimilaritySlider: View {
    @Bindable var model: DuplicatesViewModel

    var body: some View {
        HStack(spacing: 8) {
            Text("Looser").font(.caption).foregroundStyle(.secondary)
            Slider(value: $model.similarity, in: 0...1)
                .frame(minWidth: 140, maxWidth: 240)
                .accessibilityLabel("Similarity")
                .accessibilityValue(model.similarityLabel)
            Text("Stricter").font(.caption).foregroundStyle(.secondary)
            Badge(text: model.similarityLabel, symbol: nil, tint: AppSection.duplicates.tint)
        }
    }
}

// MARK: - Scanning

struct DuplicatesScanningPage: View {
    @Bindable var model: DuplicatesViewModel

    var body: some View {
        PageScroll {
            DuplicatesHeader(model: model)
            switch model.mode {
            case .exact:
                let progress = model.exactProgress ?? DuplicateScanProgress(stage: .scanning, fraction: nil, message: "Starting…")
                ScanProgressCard(
                    title: progress.stage.activeTitle,
                    message: progress.message,
                    fraction: progress.fraction,
                    tint: AppSection.duplicates.tint,
                    onCancel: { model.cancelScan() }
                )
                DuplicateStageTracker(titles: DuplicateScanStage.allCases.map(\.title), currentIndex: progress.stage.rawValue)
                InfoCallout(style: .info, title: progress.stage.title, message: progress.stage.detail)
            case .similar:
                let progress = model.similarProgress ?? SimilarScanProgress(stage: .scanning, fraction: nil, message: "Starting…")
                ScanProgressCard(
                    title: progress.stage.activeTitle,
                    message: progress.message,
                    fraction: progress.fraction,
                    tint: AppSection.duplicates.tint,
                    onCancel: { model.cancelScan() }
                )
                DuplicateStageTracker(titles: SimilarScanStage.allCases.map(\.title), currentIndex: progress.stage.rawValue)
                InfoCallout(style: .info, message: "Photos are analyzed with Apple's Vision framework on this Mac. Files stored only in iCloud are skipped rather than downloaded.")
            }
        }
    }
}
