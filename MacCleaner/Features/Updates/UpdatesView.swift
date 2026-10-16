import SwiftUI

/// The Updates page: apps grouped by whether a newer version exists, with the way to
/// install each update, inline release notes and details in an inspector.
struct UpdatesView: View {
    @Bindable var model: UpdatesViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        PageScroll {
            PageHeader(section: .updates, subtitle: subtitle) {
                UpdatesHeaderActions(model: model)
            }
            UpdatesSummaryTiles(model: model)
            UpdatesNotices(model: model)
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
            content
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search apps")
        .inspector(isPresented: $model.isInspectorPresented) {
            UpdatesInspector(model: model) { openMacCleanerUpdate() }
                .inspectorColumnWidth(min: 300, ideal: 330, max: 420)
        }
        .task { model.loadIfNeeded() }
        .sheet(item: $model.homebrewRun) { run in
            UpdatesHomebrewRunSheet(run: run)
        }
        .sheet(isPresented: $model.isShowingUpdateAll) {
            UpdatesUpdateAllSheet(model: model) { openMacCleanerUpdate() }
        }
        .alert(
            "Update with Homebrew?",
            isPresented: Binding(get: { model.pendingHomebrewItems != nil }, set: { if !$0 { model.pendingHomebrewItems = nil } })
        ) {
            Button("Cancel", role: .cancel) { model.pendingHomebrewItems = nil }
            Button("Run Update") { model.confirmHomebrewUpgrade() }
        } message: {
            Text(homebrewConfirmation)
        }
        .onExitCommand { model.inspectedRowID = nil }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.rows.isEmpty {
            ScanProgressCard(title: "Reading installed apps…", message: "Reading app versions from the Applications folders", fraction: nil, tint: AppSection.updates.tint)
        } else if model.hasLoaded && model.allRows.isEmpty {
            EmptyStateView(title: "No Apps Found", symbol: "app.dashed", message: "No apps were found in the Applications folders.", actionTitle: "Reload", action: { model.reload() })
        } else if model.hasLoaded {
            let sections = model.sections
            if sections.isEmpty {
                if model.searchText.isEmpty {
                    EmptyStateView(title: "No Apps", symbol: "line.3.horizontal.decrease.circle", message: emptyFilterMessage, actionTitle: "Show All Apps", action: { model.filter = .all })
                } else {
                    ContentUnavailableView.search(text: model.searchText)
                        .frame(minHeight: 220)
                }
            } else {
                ForEach(sections) { section in
                    UpdatesSectionCard(section: section, model: model, onUpdateMacCleaner: openMacCleanerUpdate)
                }
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let date = model.lastCheckDate {
            parts.append("Last checked \(DateFormatting.relative(date))")
            let count = model.availableUpdateCount
            parts.append(count == 0 ? "no updates found" : "\(count) update\(count == 1 ? "" : "s") available")
            return parts.joined(separator: " · ") + "."
        }
        return "Versions of your apps and their updates from the App Store, developers' update feeds, Homebrew and GitHub."
    }

    private var emptyFilterMessage: String {
        switch model.filter {
        case .updates: return model.hasChecked ? "Every app with update information is up to date." : "Check for updates to see which apps have newer versions."
        case .appStore: return "No apps from the App Store are installed."
        case .sparkle: return "No installed app publishes a developer update feed."
        case .homebrew: return "No installed app was installed with Homebrew, or Homebrew wasn't checked yet."
        case .unknown: return "Every app has update information."
        case .all: return "No apps match."
        }
    }

    private var homebrewConfirmation: String {
        guard let items = model.pendingHomebrewItems, let brew = model.brewPath else { return "" }
        let run = UpdatesHomebrewRun(items: items, brewPath: brew)
        let names = ListFormatter.localizedString(byJoining: items.map(\.appName))
        return "Mac Cleaner will run “\(run.command)”. Homebrew downloads the new version of \(names) and replaces the installed app; an open app may be quit. This can take a few minutes. If Homebrew needs an administrator password, run the command in Terminal instead."
    }

    private func openMacCleanerUpdate() {
        AppPresence.shared.open(windowID: AppWindowID.update, using: openWindow)
    }
}

// MARK: - Header

private struct UpdatesHeaderActions: View {
    @Bindable var model: UpdatesViewModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            actions(compact: false)
            actions(compact: true)
        }
    }

    private func actions(compact: Bool) -> some View {
        HStack(spacing: 8) {
            if model.isChecking {
                Button("Stop", role: .cancel) { model.cancelCheck() }
            } else {
                let plan = model.updateAllPlan
                if !plan.isEmpty {
                    Button {
                        model.isShowingUpdateAll = true
                    } label: {
                        if compact {
                            Image(systemName: "arrow.down.circle")
                        } else {
                            Label("Update All…", systemImage: "arrow.down.circle")
                        }
                    }
                    .help("Update All: see how each update is installed, then update the App Store and Homebrew apps together")
                    .accessibilityLabel("Update All")
                }
                Button {
                    model.checkForUpdates()
                } label: {
                    Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppSection.updates.tint)
                .disabled(!model.hasLoaded)
                .keyboardShortcut("r", modifiers: .command)
                .help("Check the App Store, developers' update feeds, Homebrew and GitHub (⌘R)")
            }
        }
        .fixedSize()
    }
}

private struct UpdatesSummaryTiles: View {
    var model: UpdatesViewModel

    var body: some View {
        let checked = model.hasChecked
        TileRow(minimumTileWidth: 200) {
            StatTile(
                title: "Updates Available",
                value: checked || model.availableUpdateCount > 0 ? NumberFormatting.count(model.availableUpdateCount) : "—",
                caption: updatesCaption,
                symbol: "arrow.down.circle.fill",
                tint: AppSection.updates.tint,
                fillsHeight: true
            )
            StatTile(
                title: "Up to Date",
                value: checked ? NumberFormatting.count(model.upToDateCount) : "—",
                caption: "\(NumberFormatting.count(model.allRows.count)) apps installed",
                symbol: "checkmark.circle.fill",
                tint: .green,
                fillsHeight: true
            )
            StatTile(
                title: "Other Apps",
                value: checked ? NumberFormatting.count(model.otherCount) : "—",
                caption: "Update themselves, or no update info",
                symbol: "questionmark.circle.fill",
                tint: .gray,
                fillsHeight: true
            )
        }
    }

    private var updatesCaption: String {
        guard model.hasChecked || model.availableUpdateCount > 0 else { return "Not checked yet" }
        let plan = model.updateAllPlan
        if model.availableUpdateCount == 0 { return "Everything checked is current" }
        var parts: [String] = []
        if !plan.appStore.isEmpty { parts.append("\(plan.appStore.count) App Store") }
        if !plan.homebrew.isEmpty { parts.append("\(plan.homebrew.count) Homebrew") }
        let other = model.availableUpdateCount - plan.appStore.count - plan.homebrew.count
        if other > 0 { parts.append("\(other) other") }
        return parts.joined(separator: " · ")
    }
}

private struct UpdatesNotices: View {
    @Bindable var model: UpdatesViewModel

    var body: some View {
        if !model.services.settings.checkUpdatesOnline {
            HStack(spacing: 12) {
                InfoCallout(
                    style: .warning,
                    title: "Online update checks are off",
                    message: "Only Homebrew's local catalog can be checked. Turn on online checks to also ask the App Store, the update feeds app developers publish, and GitHub for Mac Cleaner."
                )
                Button("Allow Online Checks") { model.allowOnlineChecks() }
            }
        } else if let notice = model.checkNotice {
            InfoCallout(style: .info, message: notice)
        } else if model.lastCheckDate == nil && !model.isChecking {
            InfoCallout(
                style: .info,
                message: "Checking contacts the App Store, the update feeds app developers publish (always over HTTPS) and GitHub, and reads Homebrew's local catalog. Nothing about your apps is sent anywhere else."
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
        HStack(alignment: .top, spacing: 12) {
            FlowLayout(spacing: 8, lineSpacing: 8) {
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
                        .help(filter.help)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Picker("Sort By", selection: $model.sortKey) {
                    ForEach(UpdatesViewModel.SortKey.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort apps within each group")
            .padding(.top, 4)
        }
    }
}

// MARK: - Sections and rows

/// A collapsible group of apps.
struct UpdatesSectionCard: View {
    var section: UpdatesViewModel.Section
    @Bindable var model: UpdatesViewModel
    var onUpdateMacCleaner: () -> Void

    var body: some View {
        let expanded = model.isExpanded(section.group)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { model.toggle(section.group) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 14)
                    Image(systemName: section.group.symbol)
                        .font(.system(size: 17))
                        .foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(section.group.title).font(.headline)
                            Text(NumberFormatting.count(section.rows.count))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(section.group.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(section.group.title), \(section.rows.count) apps")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(expanded ? "Collapses the group" : "Expands the group")

            if expanded {
                Divider()
                LazyVStack(spacing: 0) {
                    ForEach(section.rows) { row in
                        UpdatesRowView(row: row, model: model, onUpdateMacCleaner: onUpdateMacCleaner)
                        if row.id != section.rows.last?.id {
                            Divider().padding(.leading, 60)
                        }
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Color.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(Color.subtleBorder))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    private var tint: Color {
        switch section.group {
        case .updates: return AppSection.updates.tint
        case .upToDate: return .green
        case .notChecked, .other: return .gray
        }
    }
}

/// One app: icon, name, versions, source and the way to update it.
struct UpdatesRowView: View {
    var row: UpdatesAppRow
    @Bindable var model: UpdatesViewModel
    var onUpdateMacCleaner: () -> Void
    @State private var isHovering = false

    private var isInspected: Bool { model.inspectedRowID == row.id }
    private var group: UpdatesViewModel.Group { UpdatesViewModel.group(of: row) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                FileIcon(path: row.app.path, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    titleLine
                    detailLine
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(isInspected ? AppSection.updates.tint.opacity(0.09) : (isHovering ? Color.hoverFill : .clear))
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .onTapGesture(count: 2) { model.inspect(row) }
            .contextMenu { UpdatesRowMenu(row: row, model: model, onUpdateMacCleaner: onUpdateMacCleaner) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilitySummary)

            if model.isShowingNotes(row) {
                UpdatesInlineNotes(row: row, model: model)
                    .padding(.leading, 58)
                    .padding(.trailing, 14)
                    .padding(.bottom, 12)
            }
        }
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(row.name)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
            if row.result?.isCritical == true, row.result?.status == .updateAvailable {
                Badge(text: "Important", symbol: "exclamationmark.shield.fill", tint: .red)
                    .help("The developer marked this update as important.")
            }
            if row.result?.status == .incompatible, let minimum = row.result?.minimumSystemVersion {
                Badge(text: "Needs macOS \(minimum)", symbol: "exclamationmark.triangle.fill", tint: .orange)
                    .help(row.result?.detail ?? "")
            }
            if row.isSkipped {
                Badge(text: "Skipped", symbol: "forward.end", tint: .gray)
                    .help("You chose to skip this version. Newer versions are still announced.")
            }
            if row.isChecking {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Checking")
            }
        }
    }

    private var detailLine: some View {
        ViewThatFits(in: .horizontal) {
            detailContent(showsSize: true, showsDate: true)
            detailContent(showsSize: true, showsDate: false)
            detailContent(showsSize: false, showsDate: false)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func detailContent(showsSize: Bool, showsDate: Bool) -> some View {
        HStack(spacing: 6) {
            versionText
                .help(row.versionHelp)
            if group == .updates || group == .upToDate || row.displaySource != .none {
                UpdatesSourceChip(source: row.displaySource)
            } else {
                Text(otherDescription)
                    .lineLimit(1)
                    .help(row.result?.detail ?? row.mechanism.hint ?? "")
            }
            if showsSize, let usage = row.app.usage {
                Text("·")
                SizeText(bytes: usage.allocatedBytes, font: .caption)
            }
            if showsDate, group == .updates, let date = row.result?.releaseDate {
                Text("·")
                Text("Released \(DateFormatting.day(date))")
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var versionText: Text {
        if group == .updates, let latest = row.shortLatestVersion {
            return Text(row.shortInstalledVersion)
                + Text("  \(Image(systemName: "arrow.right"))  ").foregroundStyle(.tertiary)
                + Text(latest).fontWeight(.semibold).foregroundStyle(.primary)
        }
        return Text(row.shortInstalledVersion).monospacedDigit()
    }

    private var otherDescription: String {
        if row.result?.status == .failed { return "Check failed" }
        if row.mechanism.updatesItself { return "Updates itself" }
        return row.result == nil ? "Not checked" : "No update information"
    }

    @ViewBuilder
    private var trailing: some View {
        if group == .updates {
            ViewThatFits(in: .horizontal) {
                updateButtons(compact: false)
                updateButtons(compact: true)
            }
        } else {
            infoButton
        }
    }

    private func updateButtons(compact: Bool) -> some View {
        HStack(spacing: 6) {
            if model.hasReleaseNotes(row) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { model.toggleReleaseNotes(row) }
                } label: {
                    if compact {
                        Image(systemName: model.isShowingNotes(row) ? "doc.text.fill" : "doc.text")
                    } else {
                        Label(model.isShowingNotes(row) ? "Hide Notes" : "Release Notes", systemImage: model.isShowingNotes(row) ? "chevron.up" : "doc.text")
                    }
                }
                .buttonStyle(.borderless)
                .help(model.isShowingNotes(row) ? "Hide the release notes" : "Show what's new in this version")
                .accessibilityLabel(model.isShowingNotes(row) ? "Hide release notes" : "Release notes")
            }
            UpdatesActionButton(row: row, model: model, onUpdateMacCleaner: onUpdateMacCleaner)
            infoButton
        }
        .controlSize(.small)
        .fixedSize()
    }

    private var infoButton: some View {
        Button {
            model.inspect(row)
        } label: {
            Image(systemName: isInspected ? "info.circle.fill" : "info.circle")
                .font(.system(size: 15))
                .foregroundStyle(isInspected ? AnyShapeStyle(AppSection.updates.tint) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.borderless)
        .help("Show details")
        .accessibilityLabel("Details for \(row.name)")
    }

    private var accessibilitySummary: String {
        var parts = [row.name]
        if group == .updates, let latest = row.shortLatestVersion {
            parts.append("version \(row.shortInstalledVersion), update to \(latest) available")
        } else {
            parts.append("version \(row.shortInstalledVersion)")
            parts.append(row.status.title)
        }
        if row.displaySource != .none { parts.append("from \(row.displaySource.title)") }
        return parts.joined(separator: ", ")
    }
}

/// The main button of a row with an update.
struct UpdatesActionButton: View {
    var row: UpdatesAppRow
    var model: UpdatesViewModel
    var onUpdateMacCleaner: () -> Void

    var body: some View {
        switch model.updateAction(for: row) {
        case .appStore:
            Button("Update") { model.performUpdate(row) }
                .buttonStyle(.borderedProminent)
                .tint(AppSection.updates.tint)
                .help("Opens \(row.name) in the App Store, which installs the update")
        case .homebrew:
            Button("Update") { model.performUpdate(row) }
                .buttonStyle(.borderedProminent)
                .tint(AppSection.updates.tint)
                .disabled(model.homebrewRun?.isRunning == true)
                .help("Runs “brew upgrade --cask \(model.homebrewCask(for: row)?.upgradeToken ?? "")” after you confirm")
        case .openApp:
            Button("Open App") { model.performUpdate(row) }
                .help("Opens \(row.name). Its own updater installs \(row.shortLatestVersion ?? "the update"); if it doesn't offer it, choose “Check for Updates…” in the app.")
        case .macCleaner:
            Button("Update…", action: onUpdateMacCleaner)
                .buttonStyle(.borderedProminent)
                .tint(AppSection.updates.tint)
                .help("Download, verify and install Mac Cleaner \(row.shortLatestVersion ?? "")")
        case .none:
            EmptyView()
        }
    }
}

/// A small capsule naming where update information comes from.
struct UpdatesSourceChip: View {
    var source: UpdatesSource

    var body: some View {
        if source != .none {
            HStack(spacing: 3) {
                Image(systemName: source.symbol).imageScale(.small)
                Text(source.title)
            }
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
            .fixedSize()
            .accessibilityLabel("Source: \(source.title)")
        }
    }

    private var tint: Color {
        switch source {
        case .appStore: return .blue
        case .sparkle: return .purple
        case .homebrew: return .orange
        case .github: return .primary
        case .none: return .secondary
        }
    }
}

/// Release notes shown under a row.
private struct UpdatesInlineNotes: View {
    var row: UpdatesAppRow
    var model: UpdatesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(row.shortLatestVersion.map { "What's New in \($0)" } ?? "What's New")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
            switch model.notes[row.id] {
            case .loading?, nil:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading the release notes…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
            case .loaded(let document)?:
                ScrollView {
                    ReleaseNotesView(document: document)
                        .padding(12)
                }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
            case .failed(let message)?:
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            if let url = row.result?.releaseNotesURL, row.displaySource != .homebrew {
                Button(row.isMacCleaner ? "View on GitHub" : "Open in Browser") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .help(url.absoluteString)
            }
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.subtleBorder))
    }
}

/// Actions of a row, as a context menu.
private struct UpdatesRowMenu: View {
    var row: UpdatesAppRow
    var model: UpdatesViewModel
    var onUpdateMacCleaner: () -> Void

    var body: some View {
        switch model.updateAction(for: row) {
        case .appStore: Button("Update in App Store", systemImage: "bag") { model.performUpdate(row) }
        case .homebrew: Button("Update with Homebrew…", systemImage: "mug") { model.performUpdate(row) }
        case .macCleaner: Button("Update Mac Cleaner…", systemImage: "arrow.down.circle", action: onUpdateMacCleaner)
        case .openApp, .none: EmptyView()
        }
        Button("Show Details", systemImage: "info.circle") { model.inspectedRowID = row.id }
        if model.hasReleaseNotes(row) {
            Button(model.isShowingNotes(row) ? "Hide Release Notes" : "Show Release Notes", systemImage: "doc.text") { model.toggleReleaseNotes(row) }
        }
        if !row.isMacCleaner {
            Button("Open App", systemImage: "arrow.up.forward.app") { model.openApp(row) }
        }
        if row.result?.storeURL != nil, model.updateAction(for: row) == .none {
            Button("Open in App Store", systemImage: "bag") { model.openInAppStore(row) }
        }
        if let cask = model.homebrewCask(for: row) {
            Button("Copy Homebrew Command", systemImage: "terminal") { UpdatesPasteboard.copy(cask.upgradeCommand) }
        }
        Divider()
        Button("Reveal in Finder", systemImage: "folder") { FinderActions.reveal(row.app.path) }
    }
}
