import QuickLook
import SwiftUI

/// Shows exactly what an uninstall or reset will remove, lets people adjust the
/// selection, and makes sure the apps are quit first.
struct UninstallerPreviewSheet: View {
    var model: UninstallerViewModel
    @Bindable var preview: UninstallerPreviewModel
    @State private var collapsedKinds: Set<String> = []
    @State private var quickLookURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch preview.phase {
            case .preparing(let message, let fraction):
                VStack(alignment: .leading, spacing: 10) {
                    ProgressView(value: max(0.02, min(1, fraction)))
                        .tint(AppSection.uninstaller.tint)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Mac Cleaner checks Application Support, Caches, Preferences, Containers, Logs, launch agents and other Library folders, and leaves out anything other apps could use.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 20)
            case .ready:
                readyContent
            }
            footer
        }
        .padding(22)
        .frame(width: 680, height: 620)
        .quickLookPreview($quickLookURL)
        .alert("Force Quit?", isPresented: $preview.isConfirmingForceQuit) {
            Button("Cancel", role: .cancel) {}
            Button("Force Quit", role: .destructive) { preview.forceQuitRunningApps(logger: model.services.logger) }
        } message: {
            Text("Unsaved changes in \(runningNames) will be lost.")
        }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 12) {
            if preview.apps.count == 1, let app = preview.apps.first {
                FileIcon(path: app.path, size: 44)
            } else {
                IconTile(section: .uninstaller, size: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(preview.title)
                    .font(.title3.weight(.semibold))
                Text(preview.mode == .uninstall
                     ? "Review everything that will be moved to the Trash."
                     : "Choose what to remove. The app itself stays installed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            if preview.isReady {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summaryText)
                        .font(.callout.weight(.medium))
                    if preview.hasUnmeasuredSelection {
                        Text("Some sizes couldn't be measured, so more space may be freed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button("Cancel", role: .cancel) {
                model.cancelPreview()
            }
            .keyboardShortcut(.cancelAction)
            Button(preview.mode == .uninstall ? "Uninstall" : "Reset", role: .destructive) {
                model.confirmPreview()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!preview.canConfirm)
            .help(preview.runningProcesses.isEmpty ? "" : "Quit the running apps first")
        }
    }

    private var summaryText: String {
        let leftoverCount = preview.selectedLeftovers.count
        let itemCount = leftoverCount + (preview.mode == .uninstall ? preview.apps.count : 0)
        return "\(NumberFormatting.count(itemCount)) item\(itemCount == 1 ? "" : "s") · \(ByteFormatting.string(preview.selectedBytes))"
    }

    private var runningNames: String {
        let names = Array(Set(preview.runningProcesses.map(\.name))).sorted()
        return ListFormatter.localizedString(byJoining: Array(names.prefix(4)))
    }

    // MARK: Content

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !preview.runningProcesses.isEmpty {
                runningBanner
            }
            if preview.mode == .reset {
                InfoCallout(
                    style: .warning,
                    message: "Resetting removes the selected settings and data, so the app starts as if newly installed. You may need to sign in again. Sandboxed apps keep their settings in their container; select it to reset them completely (documents saved inside the app are removed too)."
                )
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12, pinnedViews: []) {
                    ForEach(preview.sections) { section in
                        sectionView(section)
                    }
                }
                .padding(.vertical, 2)
            }
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .frame(maxHeight: .infinity)
    }

    private var runningBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(runningNames) \(preview.runningProcesses.count == 1 ? "is" : "are") running")
                    .font(.callout.weight(.semibold))
                Text(preview.quitTimedOut
                     ? "Still running. If an app asks to save changes, answer it and try again, or force it to quit."
                     : "Apps must be quit before they're removed. Mac Cleaner asks them to quit and stops their background helpers until you log in again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if preview.isQuitting {
                ProgressView().controlSize(.small)
            } else {
                VStack(alignment: .trailing, spacing: 6) {
                    Button(preview.runningProcesses.count == 1 ? "Quit App" : "Quit Apps") {
                        preview.quitRunningApps(logger: model.services.logger)
                    }
                    if preview.quitTimedOut {
                        Button("Force Quit…") { preview.isConfirmingForceQuit = true }
                    } else {
                        Button("Check Again") { preview.refreshRunningProcesses() }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.2)))
    }

    @ViewBuilder
    private func sectionView(_ section: UninstallerPreviewModel.Section) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if preview.sections.count > 1 {
                HStack(spacing: 8) {
                    FileIcon(path: section.app.path, size: 20)
                    Text(section.app.name).font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }
            if preview.mode == .uninstall {
                appRow(section.app)
            }
            if section.leftovers.isEmpty {
                Text(preview.mode == .uninstall
                     ? "No related files were found in your Library folders."
                     : "No caches, settings or data of this app were found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            let groups = Dictionary(grouping: section.leftovers, by: \.kind).sorted { $0.key < $1.key }
            ForEach(groups, id: \.key) { kind, items in
                kindGroup(kind: kind, items: items, sectionID: section.id)
            }
            if !section.excluded.isEmpty {
                excludedGroup(section.excluded)
            }
            if !section.receipts.isEmpty {
                receiptsGroup(section.receipts)
            }
        }
    }

    private func appRow(_ app: UninstallerApp) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: .constant(true))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(true)
                .accessibilityLabel("\(app.name) is always included")
            FileIcon(path: app.path, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name + ".app").lineLimit(1)
                    Badge(text: "Application", symbol: "app.fill", tint: AppSection.uninstaller.tint)
                }
                Text("The app itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PathText(path: app.path, font: .caption2)
            }
            Spacer(minLength: 8)
            UninstallerSizeLabel(usage: app.usage, font: .callout)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .contextMenu {
            FileContextMenu(path: app.path, onQuickLook: { quickLookURL = app.info.url })
        }
    }

    private func kindGroup(kind: UninstallerLeftoverKind, items: [UninstallerLeftover], sectionID: String) -> some View {
        let key = sectionID + "|" + kind.rawValue
        let isCollapsed = collapsedKinds.contains(key)
        let state = preview.selectionState(of: items)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                UninstallerTriStateCheckbox(state: state, label: "Select all \(kind.title)") { selected in
                    preview.setSelected(items, selected)
                }
                Image(systemName: kind.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.title).font(.callout.weight(.semibold))
                    Text("\(kind.explanation) \(kind.consequence)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text("\(items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                UninstallerTotalSize(leftovers: items)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 70, alignment: .trailing)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if isCollapsed { collapsedKinds.remove(key) } else { collapsedKinds.insert(key) }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed ? "Expand \(kind.title)" : "Collapse \(kind.title)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            if !isCollapsed {
                ForEach(items) { leftover in
                    UninstallerLeftoverRow(
                        leftover: leftover,
                        isSelected: Binding(get: { preview.isSelected(leftover) }, set: { _ in preview.toggle(leftover) }),
                        onQuickLook: { quickLookURL = leftover.url }
                    )
                    .padding(.leading, 18)
                }
            }
        }
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 6)
    }

    private func excludedGroup(_ excluded: [UninstallerExcludedItem]) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(excluded) { item in
                    HStack(alignment: .top, spacing: 8) {
                        FileIcon(path: item.path, size: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).font(.callout).lineLimit(1)
                            Text(item.reason).font(.caption).foregroundStyle(.secondary)
                            PathText(path: item.path, font: .caption2)
                        }
                    }
                    .contextMenu { FileContextMenu(path: item.path, onQuickLook: { quickLookURL = URL(fileURLWithPath: item.path) }) }
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Kept: \(excluded.count) item\(excluded.count == 1 ? "" : "s") other apps may use", systemImage: "hand.raised.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func receiptsGroup(_ receipts: [String]) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                Text("macOS keeps a record of installer packages in a protected folder. These receipts take almost no space and are never removed by Mac Cleaner. If the app installed system components, the developer's uninstaller removes them best.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(receipts, id: \.self) { receipt in
                    Text(receipt)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Installer receipts (information only): \(receipts.count)", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
