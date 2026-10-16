import SwiftUI

/// Right-hand panel: details of the selected app, or a summary of several.
struct UninstallerDetailPanel: View {
    @Bindable var model: UninstallerViewModel
    var onClose: (() -> Void)?

    var body: some View {
        Group {
            if let app = model.singleSelection {
                UninstallerAppDetail(model: model, app: app, onClose: onClose)
            } else if model.selection.count > 1 {
                UninstallerMultiSelectionSummary(model: model)
            } else {
                ContentUnavailableView(
                    "Select an App",
                    systemImage: "app.dashed",
                    description: Text("See its size, the files it keeps in your Library folder, and uninstall options. Select several apps to remove them together.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.windowBackground)
    }
}

private struct UninstallerAppDetail: View {
    @Bindable var model: UninstallerViewModel
    var app: UninstallerApp
    var onClose: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let protection = app.protection {
                    InfoCallout(style: .info, title: protection.title, message: protection.explanation)
                }
                facts
                relatedFiles
                actions
            }
            .padding(16)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            FileIcon(path: app.path, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Version \(UninstallerAppTable.shortVersion(app))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .help(UninstallerAppTable.versionHelp(app))
                UninstallerAppBadges(app: app, isRunning: model.isRunning(app))
            }
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Hide details")
                .accessibilityLabel("Hide details")
            }
        }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 8) {
            KeyValueRow(key: "Developer", value: app.developer ?? (app.isEnriched ? "Unknown" : "Checking…"))
            if let build = app.info.buildVersion, !build.isEmpty, build != app.info.shortVersion {
                KeyValueRow(key: "Build", value: build)
            }
            KeyValueRow(key: "Signature", value: app.signature?.trustSummary ?? "Checking…", valueColor: signatureColor)
            KeyValueRow(key: "App size", value: app.usage.map { ByteFormatting.string($0.allocatedBytes) } ?? "Measuring…")
            KeyValueRow(key: "Last used", value: lastUsedText)
            if let count = app.useCount, count > 0 {
                KeyValueRow(key: "Opened", value: "\(NumberFormatting.count(count)) time\(count == 1 ? "" : "s")")
            }
            if let installed = app.info.installedDate {
                KeyValueRow(key: "Installed", value: DateFormatting.day(installed))
            }
            if let bundleID = app.bundleIdentifier {
                KeyValueRow(key: "Identifier", value: bundleID)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Location").foregroundStyle(.secondary)
                Spacer(minLength: 12)
                PathText(path: (app.path as NSString).deletingLastPathComponent, font: .callout)
                Button {
                    FinderActions.reveal(app.path)
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal in Finder")
            }
            .font(.callout)
        }
        .card(padding: 12)
    }

    private var signatureColor: Color {
        guard let status = app.signature?.status else { return .primary }
        switch status {
        case .valid: return .primary
        case .unsigned, .unknown: return .orange
        case .invalid, .revoked: return .red
        }
    }

    private var lastUsedText: String {
        guard let date = app.lastUsed else {
            return model.hasUsageData ? "No record" : "Unavailable (no Spotlight data)"
        }
        return DateFormatting.relative(date)
    }

    @ViewBuilder
    private var relatedFiles: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Related Files", systemImage: "folder.badge.gearshape")
                    .font(.headline)
                Spacer()
                if case .loaded(let result) = model.details(for: app), !result.leftovers.isEmpty {
                    UninstallerTotalSize(leftovers: result.leftovers, font: .callout.weight(.semibold))
                }
            }
            switch model.details(for: app) {
            case .loading, nil:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking in your Library folders…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .loaded(let result):
                if result.leftovers.isEmpty {
                    Text("No related files were found in your Library folders.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    let groups = Dictionary(grouping: result.leftovers, by: \.kind).sorted { $0.key < $1.key }
                    VStack(spacing: 6) {
                        ForEach(groups, id: \.key) { kind, items in
                            HStack(spacing: 8) {
                                Image(systemName: kind.symbol)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(kind.title)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(items.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                UninstallerTotalSize(leftovers: items)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            .help(kind.explanation)
                        }
                    }
                    let review = result.leftovers.filter { $0.safety != .safe }.count
                    if review > 0 {
                        Label("\(review) item\(review == 1 ? " needs" : "s need") a look before removing — they're matched by name or may hold your data.", systemImage: CleanupSafety.review.symbolName)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                if !result.excluded.isEmpty {
                    Label("\(result.excluded.count) item\(result.excluded.count == 1 ? " is" : "s are") kept because other apps may use \(result.excluded.count == 1 ? "it" : "them").", systemImage: "hand.raised.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !result.receipts.isEmpty {
                    Label("Installed with an installer package (\(result.receipts.count) receipt\(result.receipts.count == 1 ? "" : "s")). The developer may provide an uninstaller for system components.", systemImage: "shippingbox")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .card(padding: 12)
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button {
                model.beginUninstall([app])
            } label: {
                Label("Uninstall…", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(AppSection.uninstaller.tint)
            .disabled(!app.canUninstall || model.flow.isCleaning)

            Button {
                model.beginReset(app)
            } label: {
                Label("Reset App…", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(app.protection == .macCleanerItself || model.flow.isCleaning)
            .help("Keep the app, but remove its caches and settings so it starts fresh")

            Text("Removed items go to the Trash, so you can restore them until you empty it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }
}

private struct UninstallerMultiSelectionSummary: View {
    @Bindable var model: UninstallerViewModel

    var body: some View {
        let selected = model.selectedApps.sorted { $0.sortName < $1.sortName }
        let removable = selected.filter(\.canUninstall)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    IconTile(section: .uninstaller, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(selected.count) Apps Selected")
                            .font(.title3.weight(.semibold))
                        Text("\(ByteFormatting.string(model.selectedBytes)) in app bundles")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(spacing: 6) {
                    ForEach(selected) { app in
                        HStack(spacing: 8) {
                            FileIcon(path: app.path, size: 18)
                            Text(app.name).lineLimit(1)
                            if !app.canUninstall {
                                Image(systemName: "lock.fill").foregroundStyle(.secondary).imageScale(.small)
                                    .help(app.protection?.explanation ?? "")
                            }
                            Spacer()
                            if let usage = app.usage {
                                SizeText(bytes: usage.allocatedBytes, font: .callout).foregroundStyle(.secondary)
                            }
                        }
                        .font(.callout)
                    }
                }
                .card(padding: 12)
                if removable.count < selected.count {
                    InfoCallout(style: .info, message: "\(selected.count - removable.count) of the selected apps can't be uninstalled and will be skipped.")
                }
                Button {
                    model.beginUninstall(selected)
                } label: {
                    Label("Uninstall \(removable.count) App\(removable.count == 1 ? "" : "s")…", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(AppSection.uninstaller.tint)
                .disabled(removable.isEmpty || model.flow.isCleaning)
                Text("You'll see every file before anything is removed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .padding(16)
        }
    }
}
