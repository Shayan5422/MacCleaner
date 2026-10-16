import SwiftUI

struct SystemJunkView: View {
    @Bindable var model: SystemJunkViewModel

    var body: some View {
        VStack(spacing: 0) {
            PageScroll {
                PageHeader(section: .systemJunk, subtitle: "Caches, logs, temporary files and other data apps leave behind. Nothing is removed until you review and confirm.") {
                    if model.phase == .results {
                        Button {
                            model.scan()
                        } label: {
                            Label("Scan Again", systemImage: "arrow.clockwise")
                        }
                        .keyboardShortcut("r", modifiers: .command)
                    }
                }
                FullDiskAccessBanner(reason: "Without Full Disk Access, caches inside app containers and some logs can't be checked.")
                content
            }
            if model.phase == .results && !model.groups.isEmpty {
                SelectionActionBar(selectedCount: model.selectedCount, selectedBytes: model.selectedBytes) {
                    Button("Select Recommended") { model.selectRecommended() }
                    Button {
                        model.cleanSelected()
                    } label: {
                        Text("Clean")
                            .frame(minWidth: 80)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppSection.systemJunk.tint)
                    .disabled(model.selectedCount == 0)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Filter results")
        .cleanupFlow(model.cleanupFlow, services: model.services)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            ScanLaunchView(
                section: .systemJunk,
                headline: "Find junk safely",
                message: "Mac Cleaner looks only in places where apps keep regenerable data. Your documents, photos and settings are never part of System Junk.",
                buttonTitle: "Scan for Junk",
                bullets: [
                    "Application caches and temporary files",
                    "Old logs and crash reports",
                    "Xcode build data and device updates",
                    "Installers and old items in Downloads (for review)",
                ],
                action: model.scan
            )
        case .scanning:
            ScanProgressCard(
                title: "Scanning for junk",
                message: model.progressMessage,
                fraction: model.progress,
                tint: AppSection.systemJunk.tint,
                onCancel: model.cancelScan
            )
        case .failed(let message):
            InfoCallout(style: .danger, title: "The scan couldn't finish", message: message)
            Button("Try Again", action: model.scan)
        case .results:
            results
        }
    }

    @ViewBuilder
    private var results: some View {
        TileRow {
            StatTile(title: "Found", value: ByteFormatting.string(model.totalBytes),
                     caption: "\(NumberFormatting.count(model.allCandidates.count, "item"))", symbol: "magnifyingglass", tint: AppSection.systemJunk.tint, fillsHeight: true)
            StatTile(title: "Safe to remove", value: ByteFormatting.string(model.safeBytes),
                     caption: "Selected for you", symbol: "checkmark.shield", tint: .green, fillsHeight: true)
            StatTile(title: "Needs review", value: ByteFormatting.string(model.totalBytes - model.safeBytes),
                     caption: "Not selected", symbol: "eye", tint: .orange, fillsHeight: true)
            trashTile
        }
        if let date = model.lastScanDate {
            Text("Scanned \(DateFormatting.relative(date)). Sizes are space on disk; files shared with other items are counted once.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if model.groups.isEmpty {
            EmptyStateView(title: "No junk found", symbol: "sparkles", message: "There's nothing worth cleaning right now. Scan again any time.", actionTitle: "Scan Again", action: model.scan)
        } else {
            CandidateGroupsView(groups: model.groups, selection: model.selection, searchText: model.searchText) { candidate in
                model.exclude(candidate)
            }
        }
    }

    private var trashTile: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "trash")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("In the Trash").font(.caption).foregroundStyle(.secondary)
                Text(model.trashSize.map { ByteFormatting.string($0) } ?? "Not measured")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .help(model.trashSize == nil ? "Mac Cleaner needs Full Disk Access to measure the Trash." : "")
                Button("Open Trash") { FinderActions.openTrash() }
                    .buttonStyle(.link)
                    .font(.caption2)
                    .help(model.trashSize == nil ? "Mac Cleaner needs Full Disk Access to measure the Trash." : "Space is freed when you empty the Trash.")
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(padding: 12)
    }
}
