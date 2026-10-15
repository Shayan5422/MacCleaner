import SwiftUI

/// Files left behind by apps that are no longer installed.
struct UninstallerOrphansView: View {
    @Bindable var model: UninstallerViewModel
    @Environment(PermissionManager.self) private var permissions

    var body: some View {
        switch model.orphanState {
        case .notScanned:
            ScrollView {
                ScanLaunchView(
                    section: .uninstaller,
                    headline: "Find Leftovers of Removed Apps",
                    message: "Apps dragged to the Trash often leave settings, caches and data behind. Mac Cleaner looks for items named after apps that are no longer on this Mac.",
                    buttonTitle: "Scan for Leftovers",
                    bullets: [
                        "Only items no installed app can use are listed",
                        "Nothing is selected until you choose it",
                        "Everything goes to the Trash first",
                    ]
                ) {
                    model.scanOrphans()
                }
            }
        case .scanning(let fraction, let message):
            ScanProgressCard(
                title: "Looking for leftovers…",
                message: message,
                fraction: fraction,
                tint: AppSection.uninstaller.tint,
                onCancel: { model.cancelOrphanScan() }
            )
            .padding(Metrics.pagePadding)
            .frame(maxHeight: .infinity, alignment: .top)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                InfoCallout(style: .danger, title: "The scan couldn't finish", message: message)
                Button("Try Again") { model.scanOrphans() }
            }
            .padding(Metrics.pagePadding)
            .frame(maxHeight: .infinity, alignment: .top)
        case .loaded(let result):
            if result.groups.isEmpty && result.unmeasuredProtected.isEmpty {
                EmptyStateView(
                    title: "No Leftovers Found",
                    symbol: "checkmark.seal",
                    message: "No files of removed apps were found in your Library folder. Items changed in the last few days are skipped because something may still use them.",
                    actionTitle: "Scan Again",
                    action: { model.scanOrphans() }
                )
            } else {
                results(result)
            }
        }
    }

    private func results(_ result: UninstallerOrphanScanResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(result.groups.count) removed app\(result.groups.count == 1 ? "" : "s") left \(ByteFormatting.string(result.totalBytes)) behind")
                            .font(.headline)
                        Text(Date().timeIntervalSince(result.scannedAt) < 60 ? "Scanned just now." : "Scanned \(DateFormatting.relative(result.scannedAt)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Select All") { model.orphanSelection.set(model.orphanCandidates, selected: true) }
                        .disabled(model.orphanCandidates.isEmpty)
                }
                InfoCallout(
                    style: .info,
                    message: "These items are named after apps that aren't installed and that macOS doesn't know about. Command-line tools and plug-ins sometimes use such names too, so nothing is selected automatically. Quick Look or reveal an item to check it."
                )
                CandidateGroupsView(
                    groups: model.orphanGroups,
                    selection: model.orphanSelection,
                    searchText: model.searchText,
                    onExclude: { model.exclude($0) }
                )
                if !result.unmeasuredProtected.isEmpty {
                    protectedNotice(result.unmeasuredProtected)
                }
            }
            .padding(Metrics.pagePadding)
        }
    }

    private func protectedNotice(_ items: [UninstallerOrphanItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            InfoCallout(
                style: .warning,
                title: "\(items.count) container\(items.count == 1 ? "" : "s") of removed apps couldn't be checked",
                message: "macOS protects the data inside app containers. Grant Full Disk Access to Mac Cleaner, then scan again to measure and remove them."
            )
            HStack {
                Button("Open Full Disk Access Settings") { permissions.open(.fullDiskAccess) }
                Button("Scan Again") { model.scanOrphans() }
            }
            DisclosureGroup("Show containers") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { item in
                        HStack(spacing: 6) {
                            FileIcon(path: item.path, size: 16)
                            Text(item.identifier).font(.callout).lineLimit(1)
                            Spacer()
                            Text(item.kind.title).font(.caption).foregroundStyle(.secondary)
                        }
                        .contextMenu { FileContextMenu(path: item.path) }
                    }
                }
                .padding(.top, 4)
            }
            .font(.callout)
        }
    }
}
