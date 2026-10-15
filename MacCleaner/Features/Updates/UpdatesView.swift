import SwiftUI

/// The Updates page: installed apps with versions, sizes and update status.
struct UpdatesView: View {
    @Bindable var model: UpdatesViewModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(section: .updates, subtitle: subtitle) {
                    HStack(spacing: 8) {
                        if model.appStoreUpdateCount > 0 {
                            Button("Open App Store Updates") { model.openAppStoreUpdates() }
                        }
                        if model.isChecking {
                            Button("Stop", role: .cancel) { model.cancelCheck() }
                        } else {
                            Button {
                                model.checkForUpdates()
                            } label: {
                                Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AppSection.updates.tint)
                            .disabled(!model.hasLoaded)
                            .keyboardShortcut("r", modifiers: .command)
                        }
                    }
                }
                UpdatesStatTiles(model: model)
                UpdatesNetworkNotice(model: model)
                if model.isChecking {
                    ScanProgressCard(
                        title: "Checking for updates…",
                        message: model.checkMessage,
                        fraction: model.checkFraction,
                        tint: AppSection.updates.tint,
                        onCancel: { model.cancelCheck() }
                    )
                }
                UpdatesFilterBar(model: model)
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.top, Metrics.pagePadding)
            .padding(.bottom, 12)

            Divider()

            Group {
                if model.isLoading && model.rows.isEmpty {
                    ScanProgressCard(title: "Reading installed apps…", message: "Reading app versions from the Applications folders", fraction: nil, tint: AppSection.updates.tint)
                        .padding(Metrics.pagePadding)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else if model.hasLoaded && model.rows.isEmpty {
                    EmptyStateView(title: "No Apps Found", symbol: "app.dashed", message: "No apps were found in the Applications folders.", actionTitle: "Reload", action: { model.reload() })
                } else {
                    HStack(spacing: 0) {
                        UpdatesTable(model: model)
                        Divider()
                        UpdatesDetailPanel(model: model)
                            .frame(width: 340)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.windowBackground)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search apps")
        .task { model.loadIfNeeded() }
        .sheet(item: $model.homebrewRun) { run in
            UpdatesHomebrewRunSheet(run: run)
        }
        .alert(
            "Update with Homebrew?",
            isPresented: Binding(get: { model.homebrewConfirmationPath != nil }, set: { if !$0 { model.homebrewConfirmationPath = nil } })
        ) {
            Button("Cancel", role: .cancel) { model.homebrewConfirmationPath = nil }
            Button("Run Update") { model.confirmHomebrewUpgrade() }
        } message: {
            Text(confirmationMessage)
        }
    }

    private var subtitle: String {
        if let date = model.lastCheckDate {
            return "Versions of your apps and available updates. Last checked \(DateFormatting.relative(date))."
        }
        return "Versions of your apps and available updates from the App Store, developers' update feeds and Homebrew."
    }

    private var confirmationMessage: String {
        guard let path = model.homebrewConfirmationPath,
              let row = model.rows.first(where: { $0.id == path }),
              let cask = model.homebrewCask(for: row) else { return "" }
        return "Mac Cleaner will run “\(cask.upgradeCommand)”. Homebrew downloads the new version of \(row.name) and replaces the installed app; the app may be quit. This can take a few minutes. If it needs an administrator password, run the command in Terminal instead."
    }
}

private struct UpdatesStatTiles: View {
    var model: UpdatesViewModel

    var body: some View {
        HStack(spacing: 12) {
            StatTile(
                title: "Updates Available",
                value: model.lastCheckDate == nil && !model.isChecking ? "—" : NumberFormatting.count(model.availableUpdateCount),
                caption: model.lastCheckDate == nil ? "Not checked yet" : "From supported sources",
                symbol: "arrow.down.circle.fill",
                tint: AppSection.updates.tint
            )
            StatTile(
                title: "Up to Date",
                value: model.lastCheckDate == nil ? "—" : NumberFormatting.count(model.upToDateCount),
                caption: "\(NumberFormatting.count(model.rows.count)) apps installed",
                symbol: "checkmark.circle.fill",
                tint: .green
            )
            StatTile(
                title: "No Information",
                value: model.lastCheckDate == nil ? "—" : NumberFormatting.count(model.unknownCount),
                caption: "Apps that update themselves or another way",
                symbol: "questionmark.circle.fill",
                tint: .gray
            )
            StatTile(
                title: "Removed-App Data",
                value: model.leftoverSummary.map { ByteFormatting.string($0.totalBytes) } ?? "—",
                caption: leftoverCaption,
                symbol: "shippingbox.fill",
                tint: .purple
            )
            .help("Data left behind by apps that are no longer installed. Review it in the Uninstaller under “Leftovers of Removed Apps”.")
        }
        if let navigate = model.navigate, let summary = model.leftoverSummary, !summary.groups.isEmpty {
            HStack {
                Spacer()
                Button {
                    navigate(.uninstaller)
                } label: {
                    Label("Review leftovers of removed apps in Uninstaller", systemImage: "arrow.right.circle")
                }
                .buttonStyle(.link)
            }
        }
    }

    private var leftoverCaption: String {
        guard let summary = model.leftoverSummary else { return "Looking for leftovers…" }
        if summary.groups.isEmpty { return "No leftovers of removed apps" }
        return "Left by \(summary.groups.count) removed app\(summary.groups.count == 1 ? "" : "s")"
    }
}

private struct UpdatesNetworkNotice: View {
    @Bindable var model: UpdatesViewModel

    var body: some View {
        if !model.services.settings.checkUpdatesOnline {
            HStack(alignment: .top, spacing: 10) {
                InfoCallout(
                    style: .warning,
                    title: "Online update checks are off",
                    message: "Mac Cleaner can still check Homebrew's local catalog. Turn on online checks to also ask the App Store and the update feeds published by app developers."
                )
                Button("Allow Online Checks") { model.allowOnlineChecks() }
            }
        } else if let notice = model.checkNotice {
            InfoCallout(style: .info, message: notice)
        } else if model.lastCheckDate == nil {
            InfoCallout(
                style: .info,
                message: "Checking for updates contacts the App Store and the update feeds that app developers publish (always over HTTPS), and reads Homebrew's local catalog. Nothing about your apps is sent anywhere else, and all other features work offline."
            )
        }
        if let error = model.homebrewError {
            InfoCallout(style: .warning, title: "Homebrew couldn't be checked", message: error + " Run “brew doctor” in Terminal to find the problem.")
        }
    }
}

private struct UpdatesFilterBar: View {
    @Bindable var model: UpdatesViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(UpdatesViewModel.Filter.allCases) { filter in
                    if filter != .homebrew || model.brewPath != nil {
                        UninstallerFilterChip(
                            title: filter.title,
                            symbol: filter.symbol,
                            count: model.hasLoaded ? model.count(for: filter) : nil,
                            isSelected: model.filter == filter,
                            tint: AppSection.updates.tint
                        ) {
                            model.filter = filter
                        }
                    }
                }
            }
            .padding(.vertical, 1)
        }
    }
}

/// Status of one app.
struct UpdatesStatusBadge: View {
    var status: UpdatesStatus

    var body: some View {
        Badge(text: status.title, symbol: status.symbol, tint: tint)
    }

    private var tint: Color {
        switch status {
        case .updateAvailable: return AppSection.updates.tint
        case .upToDate: return .green
        case .incompatible: return .orange
        case .failed: return .red
        case .checking, .notChecked, .unknown: return .gray
        }
    }
}

private struct UpdatesTable: View {
    @Bindable var model: UpdatesViewModel

    var body: some View {
        let rows = model.visibleRows
        Table(rows, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \UpdatesAppRow.sortName) { row in
                HStack(spacing: 8) {
                    FileIcon(path: row.app.path, size: 22)
                    Text(row.name).lineLimit(1)
                    if row.result?.isCritical == true, row.status == .updateAvailable {
                        Badge(text: "Important", symbol: "exclamationmark.shield.fill", tint: .red)
                            .help("The developer marked this update as important.")
                    }
                }
                .help(row.app.path)
            }
            .width(min: 180, ideal: 240)

            TableColumn("Installed", value: \UpdatesAppRow.sortInstalled) { row in
                Text(row.installedVersion).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 60, ideal: 90)

            TableColumn("Latest", value: \UpdatesAppRow.sortLatest) { row in
                Text(row.latestVersion ?? "—")
                    .foregroundStyle(row.status == .updateAvailable ? Color.primary : Color.secondary)
                    .fontWeight(row.status == .updateAvailable ? .semibold : .regular)
                    .lineLimit(1)
            }
            .width(min: 60, ideal: 90)

            TableColumn("Source", value: \UpdatesAppRow.sortSource) { row in
                if row.displaySource == .none {
                    Text(row.mechanism.updatesItself ? "Updates itself" : "—")
                        .foregroundStyle(.secondary)
                        .help(row.mechanism.hint ?? "No update source Mac Cleaner can check.")
                } else {
                    Label(row.displaySource.title, systemImage: row.displaySource.symbol)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .width(min: 90, ideal: 120)

            TableColumn("Size", value: \UpdatesAppRow.sortSize) { row in
                if let usage = row.app.usage {
                    SizeText(bytes: usage.allocatedBytes).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.mini).accessibilityLabel("Measuring")
                }
            }
            .width(min: 70, ideal: 85)

            TableColumn("Last Used", value: \UpdatesAppRow.sortLastUsed) { row in
                if let date = row.app.lastUsed {
                    Text(DateFormatting.relative(date)).foregroundStyle(.secondary).help(DateFormatting.short(date))
                } else {
                    Text("No record").foregroundStyle(.tertiary).help("Spotlight has no record of this app being opened.")
                }
            }
            .width(min: 80, ideal: 110)

            TableColumn("Status", value: \UpdatesAppRow.sortStatus) { row in
                UpdatesStatusBadge(status: row.status)
                    .help(row.result?.detail ?? "")
            }
            .width(min: 110, ideal: 130)
        }
        .contextMenu(forSelectionType: UpdatesAppRow.ID.self) { ids in
            if let id = ids.first, let row = model.rows.first(where: { $0.id == id }) {
                if row.result?.storeURL != nil {
                    Button("Open in App Store", systemImage: "bag") { model.openInAppStore(row) }
                }
                Button("Open App", systemImage: "arrow.up.forward.app") { model.openApp(row) }
                if row.result?.releaseNotesURL != nil {
                    Button("Release Notes", systemImage: "doc.text") { model.openReleaseNotes(row) }
                }
                if let cask = model.homebrewCask(for: row) {
                    Button("Copy Homebrew Command", systemImage: "terminal") { UpdatesPasteboard.copy(cask.upgradeCommand) }
                }
                Divider()
                Button("Reveal in Finder", systemImage: "folder") { FinderActions.reveal(row.app.path) }
            }
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
        case .updates: return model.lastCheckDate == nil ? "Check for updates to see which apps have newer versions." : "All apps with update information are up to date."
        case .appStore: return "No apps from the App Store are installed."
        case .sparkle: return "No installed app publishes a developer update feed."
        case .homebrew: return "No installed app was installed with Homebrew, or Homebrew wasn't checked yet."
        case .unknown: return "Every app has update information."
        case .all: return "No apps match."
        }
    }
}
