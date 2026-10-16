import AppKit
import SwiftUI

enum UpdatesPasteboard {
    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Details and actions of the inspected app, in the panel beside the list.
struct UpdatesInspector: View {
    @Bindable var model: UpdatesViewModel
    var onUpdateMacCleaner: () -> Void

    var body: some View {
        Group {
            if let row = model.inspectedRow {
                UpdatesAppDetail(model: model, row: row, onUpdateMacCleaner: onUpdateMacCleaner)
            } else {
                ContentUnavailableView("No App Selected", systemImage: "arrow.down.app", description: Text("Click ⓘ next to an app to see where its updates come from."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.windowBackground)
    }
}

private struct UpdatesAppDetail: View {
    @Bindable var model: UpdatesViewModel
    var row: UpdatesAppRow
    var onUpdateMacCleaner: () -> Void
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actions
                statusCard
                if let cask = model.homebrewCask(for: row) {
                    homebrewCard(cask)
                }
                if model.hasReleaseNotes(row) {
                    releaseNotesCard
                }
                if !row.isMacCleaner {
                    appDataCard
                }
            }
            .padding(16)
        }
        .onChange(of: row.id) { copied = false }
        .task(id: row.id) {
            if model.hasReleaseNotes(row), row.hasEmbeddedReleaseNotes || row.isMacCleaner { model.loadReleaseNotes(row) }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            FileIcon(path: row.app.path, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Version \(row.shortInstalledVersion)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .help(row.versionHelp)
                HStack(spacing: 4) {
                    UpdatesStatusBadge(status: row.status)
                    if row.result?.isCritical == true, row.status == .updateAvailable {
                        Badge(text: "Important", symbol: "exclamationmark.shield.fill", tint: .red)
                    }
                }
            }
            // The name gets the room first, so it doesn't break mid-word beside the spacer.
            .layoutPriority(1)
            Spacer(minLength: 0)
            Button {
                model.inspectedRowID = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .help("Close (Esc)")
            .accessibilityLabel("Close details")
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.updateAction(for: row) {
            case .appStore:
                primaryButton("Update in App Store", symbol: "bag") { model.performUpdate(row) }
            case .homebrew:
                primaryButton("Update with Homebrew…", symbol: "mug") { model.performUpdate(row) }
                    .disabled(model.homebrewRun?.isRunning == true)
            case .macCleaner:
                primaryButton("Download & Install…", symbol: "arrow.down.circle", action: onUpdateMacCleaner)
            case .openApp:
                primaryButton("Open \(row.name)", symbol: "arrow.up.forward.app") { model.openApp(row) }
                Text("\(row.name) installs updates with its own updater. If it doesn't offer \(row.shortLatestVersion ?? "the update") right away, choose “Check for Updates…” in the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .none:
                if !row.isMacCleaner {
                    Button {
                        model.openApp(row)
                    } label: {
                        Label("Open \(row.name)", systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                }
            }
            HStack {
                if let url = row.result?.releaseNotesURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label(row.displaySource == .homebrew ? "Website" : (row.isMacCleaner ? "GitHub" : "Release Notes Page"), systemImage: "safari")
                    }
                    .help(url.absoluteString)
                }
                Spacer()
                if !row.isMacCleaner {
                    Button {
                        FinderActions.reveal(row.app.path)
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
    }

    private func primaryButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(AppSection.updates.tint)
        .controlSize(.large)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            KeyValueRow(key: "Installed", value: row.shortInstalledVersion)
            if let build = row.app.info.buildVersion, !build.isEmpty, build != row.app.info.shortVersion {
                KeyValueRow(key: "Build", value: build)
            }
            KeyValueRow(key: "Latest", value: row.latestVersion ?? "—", valueColor: row.status == .updateAvailable ? AppSection.updates.tint : .primary)
            KeyValueRow(key: "Source", value: sourceText)
            if let date = row.result?.releaseDate {
                KeyValueRow(key: "Released", value: DateFormatting.day(date))
            }
            if let minimum = row.result?.minimumSystemVersion, !minimum.isEmpty {
                KeyValueRow(key: "Requires", value: "macOS \(minimum) or later")
            }
            if let checked = row.result?.checkedAt, !row.isChecking {
                KeyValueRow(key: "Checked", value: DateFormatting.relative(checked))
            }
            KeyValueRow(key: "Size", value: row.app.usage.map { ByteFormatting.string($0.allocatedBytes) } ?? "Measuring…")
            if !row.isMacCleaner {
                KeyValueRow(key: "Last used", value: row.app.lastUsed.map { DateFormatting.relative($0) } ?? "No record")
            }
            Divider()
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 12)
    }

    private var sourceText: String {
        if row.displaySource != .none { return row.displaySource.title }
        return row.mechanism.updaterName ?? "None found"
    }

    private var explanation: String {
        if row.isChecking { return "Checking…" }
        if let detail = row.result?.detail, !detail.isEmpty {
            if let hint = row.mechanism.hint, row.result?.source == .homebrew, row.mechanism.updatesItself {
                return detail + " " + hint
            }
            return detail
        }
        switch row.checkableSource {
        case .appStore: return "Check for updates to compare this version with the App Store."
        case .sparkle: return "Check for updates to read the developer's update feed."
        case .github: return "Check for updates to ask GitHub for the newest release."
        default: return row.mechanism.hint ?? "Check for updates to see whether Homebrew knows this app. Otherwise no reliable update information is available."
        }
    }

    private func homebrewCard(_ cask: UpdatesHomebrewCask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Installed with Homebrew", systemImage: "mug")
                .font(.headline)
            Text(cask.isOutdated
                 ? "Homebrew's local catalog has version \(UpdatesVersionComparator.homebrewDisplayVersion(cask.latestVersion)). Run “brew update” in Terminal first to refresh the catalog."
                 : "Homebrew's local catalog lists version \(UpdatesVersionComparator.homebrewDisplayVersion(cask.latestVersion)).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(cask.upgradeCommand)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button {
                    UpdatesPasteboard.copy(cask.upgradeCommand)
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy the command")
                .accessibilityLabel("Copy the command")
            }
            .padding(8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            if model.canUpgradeWithHomebrew(row), model.updateAction(for: row) != .homebrew {
                Button("Update with Homebrew Instead…") {
                    model.requestHomebrewUpgrade(row)
                }
                .disabled(model.homebrewRun?.isRunning == true)
                .help("Runs the command after you confirm and shows Homebrew's output")
            }
        }
        .card(padding: 12)
    }

    @ViewBuilder
    private var releaseNotesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What's New").font(.headline)
            switch model.notes[row.id] {
            case .loaded(let document)?:
                ReleaseNotesView(document: document)
            case .loading?:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading the release notes…").font(.caption).foregroundStyle(.secondary)
                }
            case .failed(let message)?:
                Text(message).font(.caption).foregroundStyle(.secondary)
            case nil:
                Button("Show Release Notes") { model.loadReleaseNotes(row) }
                    .buttonStyle(.link)
                    .help("Reads the developer's release notes page")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 12)
    }

    private var appDataCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("App Data in Library", systemImage: "folder.badge.gearshape")
                    .font(.headline)
                Spacer()
                if let result = model.appData[row.id] {
                    SizeText(bytes: result.totalBytes, font: .callout.weight(.semibold))
                }
            }
            if let result = model.appData[row.id] {
                if result.leftovers.isEmpty {
                    Text("No settings, caches or data of this app were found in your Library folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let unmeasured = result.leftovers.filter { $0.usage == nil }.count
                    Text("\(result.leftovers.count) item\(result.leftovers.count == 1 ? "" : "s") (settings, caches and data). They stay behind if the app is dragged to the Trash; the Uninstaller removes them with the app.\(unmeasured > 0 ? " \(unmeasured) protected item\(unmeasured == 1 ? " isn't" : "s aren't") included in the size." : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let navigate = model.navigate {
                    Button("Manage in Uninstaller") { navigate(.uninstaller) }
                        .buttonStyle(.link)
                }
            } else if model.appDataLoading.contains(row.id) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Looking in your Library folder…").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Reading app details…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .card(padding: 12)
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

// MARK: - Update All

/// Explains how each available update is installed, then updates the App Store and
/// Homebrew apps together.
struct UpdatesUpdateAllSheet: View {
    @Bindable var model: UpdatesViewModel
    var onUpdateMacCleaner: () -> Void
    @State private var openAppStore = true
    @State private var runHomebrew = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let plan = model.updateAllPlan
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(section: .updates, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Update All Apps").font(.title3.weight(.semibold))
                    Text("\(model.availableUpdateCount) update\(model.availableUpdateCount == 1 ? "" : "s") available. Here's how each one is installed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !plan.appStore.isEmpty {
                        group(
                            toggle: $openAppStore,
                            title: "App Store",
                            symbol: "bag",
                            names: plan.appStore.map(\.name),
                            explanation: "Opens the App Store's Updates page, where these apps are updated."
                        )
                    }
                    if !plan.homebrew.isEmpty, let brew = model.brewPath {
                        let run = UpdatesHomebrewRun(items: plan.homebrew, brewPath: brew)
                        group(
                            toggle: $runHomebrew,
                            title: "Homebrew",
                            symbol: "mug",
                            names: plan.homebrew.map(\.appName),
                            explanation: "Runs “\(run.command)” and shows Homebrew's output. Open apps may be quit."
                        )
                    }
                    if let row = plan.macCleaner {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Mac Cleaner \(row.shortLatestVersion ?? "")", systemImage: "chevron.left.forwardslash.chevron.right")
                                .font(.headline)
                            HStack {
                                Text("Downloaded from GitHub and verified before it replaces this copy. Mac Cleaner restarts afterwards, so it's installed separately.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Button("Update…") {
                                    dismiss()
                                    onUpdateMacCleaner()
                                }
                            }
                        }
                        .card(padding: 12)
                    }
                    if !plan.selfUpdating.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Update in the App", systemImage: "arrow.up.forward.app")
                                .font(.headline)
                            Text("These apps install updates with their own updater, so Mac Cleaner can't update them for you. Open each one; if it doesn't offer the update, choose “Check for Updates…” in its menu.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(plan.selfUpdating) { row in
                                HStack(spacing: 8) {
                                    FileIcon(path: row.app.path, size: 18)
                                    Text(row.name).lineLimit(1)
                                    Text("\(row.shortInstalledVersion) → \(row.shortLatestVersion ?? "?")")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Open") { model.openApp(row) }
                                        .controlSize(.small)
                                }
                            }
                        }
                        .card(padding: 12)
                    }
                }
            }
            .frame(maxHeight: 360)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(primaryTitle(plan)) {
                    model.runUpdateAll(openAppStore: openAppStore, runHomebrew: runHomebrew)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!plan.canRun || (!(openAppStore && !plan.appStore.isEmpty) && !(runHomebrew && !plan.homebrew.isEmpty)))
            }
        }
        .padding(22)
        .frame(width: 540)
    }

    private func primaryTitle(_ plan: UpdatesViewModel.UpdateAllPlan) -> String {
        let count = (openAppStore ? plan.appStore.count : 0) + (runHomebrew ? plan.homebrew.count : 0)
        return count == 0 ? "Update" : "Update \(count) App\(count == 1 ? "" : "s")"
    }

    private func group(toggle: Binding<Bool>, title: String, symbol: String, names: [String], explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: toggle) {
                Label("\(title) · \(names.count) app\(names.count == 1 ? "" : "s")", systemImage: symbol)
                    .font(.headline)
            }
            .toggleStyle(.checkbox)
            Text(ListFormatter.localizedString(byJoining: names))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: 12)
    }
}

// MARK: - Homebrew

/// Shows a running or finished `brew upgrade`.
struct UpdatesHomebrewRunSheet: View {
    @Bindable var run: UpdatesHomebrewRun
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(section: .updates, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Updating \(run.title) with Homebrew")
                        .font(.title3.weight(.semibold))
                    Text(run.command)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
            switch run.state {
            case .running:
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(AppSection.updates.tint)
                    Text("Homebrew is downloading and installing the update. This can take a few minutes; the output appears when it finishes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            case .finished(let succeeded, let output):
                InfoCallout(
                    style: succeeded ? .success : .warning,
                    message: succeeded ? "\(run.title) \(run.items.count == 1 ? "was" : "were") updated." : "Homebrew couldn't finish the update. Its output is below."
                )
                ScrollView {
                    Text(output)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(maxHeight: .infinity)
            }
            HStack {
                if case .finished(false, _) = run.state {
                    Button("Copy Command") { UpdatesPasteboard.copy(run.command) }
                }
                Spacer()
                if run.isRunning {
                    Button("Stop", role: .cancel) { run.cancel() }
                } else {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(22)
        .frame(width: 560, height: 420)
        .interactiveDismissDisabled(run.isRunning)
    }
}
