import AppKit
import Combine
import QuickLook
import SwiftUI

/// The Uninstaller page: installed apps on the left, details on the right, and a
/// separate view for leftovers of apps that were already removed.
struct UninstallerView: View {
    @Bindable var model: UninstallerViewModel

    var body: some View {
        UninstallerMainContent(model: model)
            .searchable(text: $model.searchText, placement: .toolbar, prompt: model.filter == .leftovers ? "Search leftovers" : "Search apps")
            .task { model.loadIfNeeded() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
                model.refreshRunningApps()
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
                model.refreshRunningApps()
            }
            .alert(
                "Can't Uninstall",
                isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
            .cleanupFlow(model.flow, services: model.services)
    }
}

/// Header, filters, content and bottom bar. Kept separate from the root so the
/// preview sheet and the cleanup flow's sheets attach to different views.
private struct UninstallerMainContent: View {
    @Bindable var model: UninstallerViewModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(section: .uninstaller, subtitle: "Remove apps completely, including the files they keep in your Library folder.") {
                    HStack(spacing: 8) {
                        if model.filter != .leftovers {
                            Picker(selection: $model.sortKey) {
                                ForEach(UninstallerViewModel.SortKey.allCases) { key in
                                    Text(key.title).tag(key)
                                }
                            } label: {
                                Label("Sort By", systemImage: "arrow.up.arrow.down")
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .help("Sort apps")
                        }
                        Button {
                            model.chooseOtherApp()
                        } label: {
                            Label("Choose App…", systemImage: "plus.app")
                        }
                        .help("Uninstall an app stored outside the Applications folders")
                        Button {
                            if model.filter == .leftovers { model.scanOrphans() } else { model.reload() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help(model.filter == .leftovers ? "Scan for leftovers again" : "Reload the list of apps")
                        .accessibilityLabel("Refresh")
                        .disabled(model.isLoading)
                    }
                }
                UninstallerStatTiles(model: model)
                FullDiskAccessBanner(reason: "Apps' containers are protected by macOS. With Full Disk Access, Mac Cleaner can measure and remove them completely.")
                if let message = model.appManagementMessage {
                    UninstallerAppManagementCallout(message: message, services: model.services) {
                        model.appManagementMessage = nil
                    }
                }
                UninstallerFilterBar(model: model)
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.top, Metrics.pagePadding)
            .padding(.bottom, 12)

            Divider()

            Group {
                if model.filter == .leftovers {
                    UninstallerOrphansView(model: model)
                } else if model.loadCancelled && !model.hasLoaded {
                    EmptyStateView(
                        title: "Apps Not Loaded",
                        symbol: "app.dashed",
                        message: "Mac Cleaner reads the Applications folders to list the apps you can uninstall.",
                        actionTitle: "Load Apps",
                        action: { model.reload() }
                    )
                } else if !model.hasLoaded || (model.isLoading && model.listedApps.isEmpty) {
                    ScanProgressCard(
                        title: "Finding apps…",
                        message: "Reading the Applications folders",
                        fraction: nil,
                        tint: AppSection.uninstaller.tint,
                        onCancel: { model.cancelLoading() }
                    )
                    .padding(Metrics.pagePadding)
                    .frame(maxHeight: .infinity, alignment: .top)
                } else if model.listedApps.isEmpty {
                    EmptyStateView(
                        title: "No Apps Found",
                        symbol: "app.dashed",
                        message: "There are no apps in the Applications folders that can be uninstalled.",
                        actionTitle: "Reload",
                        action: { model.reload() }
                    )
                } else {
                    HStack(spacing: 0) {
                        UninstallerAppTable(model: model)
                        Divider()
                        UninstallerDetailPanel(model: model)
                            .frame(width: 340)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            UninstallerBottomBar(model: model)
        }
        .background(Color.windowBackground)
        .quickLookPreview($model.quickLookURL)
        .sheet(item: $model.preview, onDismiss: { model.previewDismissed() }) { preview in
            UninstallerPreviewSheet(model: model, preview: preview)
        }
    }
}

private struct UninstallerStatTiles: View {
    var model: UninstallerViewModel

    var body: some View {
        HStack(spacing: 12) {
            StatTile(
                title: "Installed Apps",
                value: model.hasLoaded ? NumberFormatting.count(model.listedApps.count) : "—",
                caption: sizeCaption,
                symbol: "app.badge",
                tint: AppSection.uninstaller.tint
            )
            StatTile(
                title: "Unused for 90 Days",
                value: model.hasLoaded ? NumberFormatting.count(model.unusedApps.count) : "—",
                caption: unusedCaption,
                symbol: "moon.zzz.fill",
                tint: .orange
            )
            StatTile(
                title: "Leftovers of Removed Apps",
                value: leftoverValue,
                caption: leftoverCaption,
                symbol: "shippingbox.fill",
                tint: .purple
            )
        }
    }

    private var sizeCaption: String {
        guard model.hasLoaded else { return "Reading apps…" }
        if model.isMeasuringSizes { return "Measuring… \(model.measuredCount) of \(model.listedApps.count)" }
        return "\(ByteFormatting.string(model.totalAppBytes)) on disk"
    }

    private var unusedCaption: String {
        guard model.hasLoaded else { return " " }
        if !model.hasUsageData { return "Spotlight has no usage records" }
        let bytes = model.unusedApps.reduce(0) { $0 + ($1.usage?.allocatedBytes ?? 0) }
        return bytes > 0 ? "\(ByteFormatting.string(bytes)) you might not need" : "Based on Spotlight usage records"
    }

    private var leftoverValue: String {
        switch model.orphanState {
        case .loaded(let result): return ByteFormatting.string(result.totalBytes)
        case .scanning: return "Scanning…"
        default: return "Not scanned"
        }
    }

    private var leftoverCaption: String {
        switch model.orphanState {
        case .loaded(let result):
            return result.groups.isEmpty ? "Nothing left behind" : "\(result.itemCount) item\(result.itemCount == 1 ? "" : "s") from \(result.groups.count) app\(result.groups.count == 1 ? "" : "s")"
        case .failed: return "The last scan failed"
        default: return "Files left by apps you removed"
        }
    }
}

private struct UninstallerFilterBar: View {
    @Bindable var model: UninstallerViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(UninstallerViewModel.Filter.allCases) { filter in
                    UninstallerFilterChip(
                        title: filter == .large ? "Large (1 GB+)" : filter.title,
                        symbol: filter.symbol,
                        count: count(for: filter),
                        isSelected: model.filter == filter,
                        tint: AppSection.uninstaller.tint
                    ) {
                        model.filter = filter
                        if filter == .leftovers, case .notScanned = model.orphanState { model.scanOrphans() }
                    }
                    .help(help(for: filter))
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func count(for filter: UninstallerViewModel.Filter) -> Int? {
        guard model.hasLoaded else { return nil }
        switch filter {
        case .all: return model.listedApps.count
        case .unused: return model.unusedApps.count
        case .large: return model.listedApps.filter { ($0.usage?.allocatedBytes ?? 0) >= UninstallerViewModel.largeAppBytes }.count
        case .appStore: return model.listedApps.filter { $0.info.isAppStoreApp || $0.isWrappediOSApp }.count
        case .leftovers: return model.orphanResult?.groups.count
        }
    }

    private func help(for filter: UninstallerViewModel.Filter) -> String {
        switch filter {
        case .all: return "Every app you can uninstall"
        case .unused: return "Apps Spotlight hasn't seen opened in the last 90 days"
        case .large: return "Apps that take 1 GB or more"
        case .appStore: return "Apps installed from the App Store"
        case .leftovers: return "Files left behind by apps that are no longer installed"
        }
    }
}

private struct UninstallerAppManagementCallout: View {
    var message: String
    var services: AppServices
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            InfoCallout(style: .warning, title: "macOS blocked the removal", message: message)
            VStack(spacing: 6) {
                Button("Open App Management") { services.permissions.open(.appManagement) }
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.borderless)
            }
        }
    }
}

/// Bottom bar for the current selection.
private struct UninstallerBottomBar: View {
    @Bindable var model: UninstallerViewModel

    var body: some View {
        if model.filter == .leftovers {
            if model.orphanResult.map({ !$0.groups.isEmpty }) == true {
                SelectionActionBar(
                    selectedCount: model.orphanSelection.selected(in: model.orphanCandidates).count,
                    selectedBytes: model.selectedOrphanBytes,
                    noun: "item"
                ) {
                    Button("Deselect All") { model.orphanSelection.clear() }
                        .disabled(model.orphanSelection.selectedIDs.isEmpty)
                    Button("Move to Trash…", role: .destructive) { model.removeSelectedOrphans() }
                        .buttonStyle(.borderedProminent)
                        .tint(AppSection.uninstaller.tint)
                        .disabled(model.orphanSelection.selectedIDs.isEmpty || model.flow.isCleaning)
                }
            }
        } else if !model.selection.isEmpty {
            SelectionActionBar(selectedCount: model.selection.count, selectedBytes: model.selectedBytes, noun: "app") {
                Button("Deselect") { model.selection.removeAll() }
                if let app = model.singleSelection {
                    Button("Reset…") { model.beginReset(app) }
                        .disabled(app.protection == .macCleanerItself)
                        .help("Keep the app and remove its caches and settings")
                }
                Button(model.selectedRemovableApps.count > 1 ? "Uninstall \(model.selectedRemovableApps.count) Apps…" : "Uninstall…", role: .destructive) {
                    model.beginUninstall(model.selectedApps)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppSection.uninstaller.tint)
                .disabled(model.selectedRemovableApps.isEmpty || model.flow.isCleaning)
            }
        }
    }
}

// MARK: - App table

struct UninstallerAppTable: View {
    @Bindable var model: UninstallerViewModel

    var body: some View {
        let rows = model.visibleApps
        Table(rows, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \UninstallerApp.sortName) { app in
                HStack(spacing: 8) {
                    FileIcon(path: app.path, size: 22)
                    Text(app.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    UninstallerAppBadges(app: app, isRunning: model.isRunning(app))
                }
                .help(app.path)
            }
            .width(min: 200, ideal: 280)

            TableColumn("Version", value: \UninstallerApp.sortVersion) { app in
                Text(app.info.displayVersion)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 60, ideal: 90)

            TableColumn("Size", value: \UninstallerApp.sortSize) { app in
                if let usage = app.usage {
                    SizeText(bytes: usage.allocatedBytes)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Measuring")
                }
            }
            .width(min: 70, ideal: 90)

            TableColumn("Last Used", value: \UninstallerApp.sortLastUsed) { app in
                if let date = app.lastUsed {
                    Text(DateFormatting.relative(date))
                        .foregroundStyle(.secondary)
                        .help(DateFormatting.short(date))
                } else {
                    Text("No record")
                        .foregroundStyle(.tertiary)
                        .help("Spotlight has no record of this app being opened.")
                }
            }
            .width(min: 90, ideal: 120)

            TableColumn("Developer", value: \UninstallerApp.sortDeveloper) { app in
                Text(app.developer ?? (app.isEnriched ? "Unknown" : "…"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(app.signature?.trustSummary ?? "")
            }
            .width(min: 100, ideal: 170)
        }
        .contextMenu(forSelectionType: UninstallerApp.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            let targets = model.apps.filter { ids.contains($0.id) }
            if targets.contains(where: \.canUninstall) { model.beginUninstall(targets) }
        }
        .overlay {
            if rows.isEmpty && model.hasLoaded {
                if model.searchText.isEmpty {
                    ContentUnavailableView("No Apps", systemImage: "app.dashed", description: Text(emptyMessage))
                } else {
                    ContentUnavailableView.search(text: model.searchText)
                }
            }
        }
    }

    private var emptyMessage: String {
        switch model.filter {
        case .unused: return model.hasUsageData ? "Every app was opened in the last 90 days." : "Spotlight has no usage records, so unused apps can't be identified."
        case .large: return model.isMeasuringSizes ? "Still measuring app sizes…" : "No app takes 1 GB or more."
        case .appStore: return "No apps from the App Store are installed."
        default: return "No apps match."
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<UninstallerApp.ID>) -> some View {
        let targets = model.apps.filter { ids.contains($0.id) }
        if !targets.isEmpty {
            Button(targets.count > 1 ? "Uninstall \(targets.count) Apps…" : "Uninstall…", systemImage: "trash") {
                model.beginUninstall(targets)
            }
            .disabled(!targets.contains(where: \.canUninstall))
            if targets.count == 1, let app = targets.first {
                Button("Reset…", systemImage: "arrow.counterclockwise") { model.beginReset(app) }
                    .disabled(app.protection == .macCleanerItself)
                Divider()
                Button("Reveal in Finder", systemImage: "folder") { FinderActions.reveal(app.path) }
                Button("Quick Look", systemImage: "eye") { model.quickLookURL = app.info.url }
                Button("Copy Path", systemImage: "doc.on.doc") { FinderActions.copyPath(app.path) }
            } else {
                Divider()
                Button("Reveal in Finder", systemImage: "folder") { FinderActions.reveal(targets.map(\.path)) }
            }
        }
    }
}
