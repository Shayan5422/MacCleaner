import AppKit
import SwiftUI

enum UpdatesPasteboard {
    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Details and actions for the selected app.
struct UpdatesDetailPanel: View {
    @Bindable var model: UpdatesViewModel

    var body: some View {
        Group {
            if let row = model.selectedRow {
                UpdatesAppDetail(model: model, row: row)
            } else {
                ContentUnavailableView(
                    "Select an App",
                    systemImage: "arrow.down.app",
                    description: Text("See where its updates come from and how to install them.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.windowBackground)
    }
}

private struct UpdatesAppDetail: View {
    @Bindable var model: UpdatesViewModel
    var row: UpdatesAppRow
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                statusCard
                actions
                if let cask = model.homebrewCask(for: row) {
                    homebrewCard(cask)
                }
                if let notes = row.result?.releaseNotesText, !notes.isEmpty {
                    releaseNotes(notes)
                }
                appDataCard
            }
            .padding(16)
        }
        .onChange(of: row.id) { copied = false }
    }

    private var header: some View {
        HStack(spacing: 12) {
            FileIcon(path: row.app.path, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text("Version \(row.installedVersion)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    UpdatesStatusBadge(status: row.status)
                    if row.result?.isCritical == true, row.status == .updateAvailable {
                        Badge(text: "Important", symbol: "exclamationmark.shield.fill", tint: .red)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            KeyValueRow(key: "Installed", value: row.installedVersion)
            KeyValueRow(key: "Latest", value: row.latestVersion ?? "—", valueColor: row.status == .updateAvailable ? AppSection.updates.tint : .primary)
            KeyValueRow(key: "Source", value: sourceText)
            if let date = row.result?.releaseDate {
                KeyValueRow(key: "Released", value: DateFormatting.day(date))
            }
            if let minimum = row.result?.minimumSystemVersion, !minimum.isEmpty {
                KeyValueRow(key: "Requires", value: "macOS \(minimum) or later")
            }
            if let checked = row.result?.checkedAt, row.status != .checking {
                KeyValueRow(key: "Checked", value: DateFormatting.relative(checked))
            }
            KeyValueRow(key: "Size", value: row.app.usage.map { ByteFormatting.string($0.allocatedBytes) } ?? "Measuring…")
            KeyValueRow(key: "Last used", value: row.app.lastUsed.map { DateFormatting.relative($0) } ?? "No record")
            Divider()
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: 12)
    }

    private var sourceText: String {
        switch row.displaySource {
        case .none:
            switch row.mechanism {
            case .squirrel, .electronUpdater, .sparkleInApp, .sparkleInsecureFeed, .mozilla: return "The app's own updater"
            case .microsoftAutoUpdate: return "Microsoft AutoUpdate"
            case .googleSoftwareUpdate: return "Google's updater"
            case .adobeCreativeCloud: return "Adobe Creative Cloud"
            case .jetBrains: return "JetBrains"
            default: return "None found"
            }
        default:
            return row.displaySource.title
        }
    }

    private var explanation: String {
        if row.status == .checking { return "Checking…" }
        if let detail = row.result?.detail, !detail.isEmpty {
            if let hint = row.mechanism.hint, row.result?.source == .homebrew, row.mechanism.updatesItself {
                return detail + " " + hint
            }
            return detail
        }
        switch row.checkableSource {
        case .appStore: return "Check for updates to compare this version with the App Store."
        case .sparkle: return "Check for updates to read the developer's update feed."
        default: return row.mechanism.hint ?? "Check for updates to see whether Homebrew knows this app. Otherwise no reliable update information is available."
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 8) {
            if row.result?.storeURL != nil {
                Button {
                    model.openInAppStore(row)
                } label: {
                    Label(row.status == .updateAvailable ? "Update in App Store" : "Open in App Store", systemImage: "bag")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppSection.updates.tint)
                .controlSize(.large)
            }
            Button {
                model.openApp(row)
            } label: {
                Label("Open \(row.name)", systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            if usesInAppUpdater && row.status == .updateAvailable {
                Text("Choose “Check for Updates…” in the app's menu to install the update the developer's way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if row.result?.releaseNotesURL != nil {
                    Button {
                        model.openReleaseNotes(row)
                    } label: {
                        Label(row.result?.source == .homebrew ? "Website" : "Release Notes", systemImage: "doc.text")
                    }
                }
                Spacer()
                Button {
                    FinderActions.reveal(row.app.path)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
            }
            .buttonStyle(.borderless)
        }
    }

    private var usesInAppUpdater: Bool {
        switch row.mechanism {
        case .sparkleFeed, .sparkleInApp, .sparkleInsecureFeed, .squirrel, .electronUpdater: return true
        default: return false
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
            if row.status == .updateAvailable, row.displaySource == .homebrew || row.result?.homebrewToken != nil {
                Button("Run Update…") { model.requestHomebrewUpgrade(row) }
                    .disabled(model.brewPath == nil || !cask.hasSafeToken || model.homebrewRun?.isRunning == true)
                    .help("Runs the command after you confirm and shows Homebrew's output")
            }
        }
        .card(padding: 12)
    }

    private func releaseNotes(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What's New").font(.headline)
            ScrollView {
                Text(notes)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
        }
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

/// Shows a running or finished `brew upgrade`.
struct UpdatesHomebrewRunSheet: View {
    @Bindable var run: UpdatesHomebrewRun
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(section: .updates, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Updating \(run.appName) with Homebrew")
                        .font(.title3.weight(.semibold))
                    Text(run.cask.upgradeCommand)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
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
                    message: succeeded ? "\(run.appName) was updated." : "Homebrew couldn't finish the update. Its output is below."
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
                    Button("Copy Command") { UpdatesPasteboard.copy(run.cask.upgradeCommand) }
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
