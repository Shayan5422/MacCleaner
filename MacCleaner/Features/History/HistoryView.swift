import Observation
import SwiftUI

@MainActor
@Observable
final class HistoryViewModel {
    let services: AppServices
    private(set) var entries: [CleanupHistoryEntry] = []
    var selectedEntryID: CleanupHistoryEntry.ID?
    var selectedItems: Set<String> = []
    var filter: CleanupHistoryEntry.Source?
    private(set) var message: String?
    private(set) var isRestoring = false
    var showClearConfirmation = false

    init(services: AppServices) {
        self.services = services
    }

    var filteredEntries: [CleanupHistoryEntry] {
        guard let filter else { return entries }
        return entries.filter { $0.source == filter }
    }

    var selectedEntry: CleanupHistoryEntry? {
        entries.first { $0.id == selectedEntryID }
    }

    var totalCleaned: Int64 {
        entries.filter { !$0.dryRun }.reduce(0) { $0 + $1.bytes }
    }

    func load() async {
        entries = await services.history.allEntries()
        if selectedEntryID == nil { selectedEntryID = entries.first?.id }
    }

    func restore(all: Bool) {
        guard let entry = selectedEntry else { return }
        isRestoring = true
        let paths: Set<String>? = all ? nil : selectedItems
        Task {
            let result = await services.history.restore(entryID: entry.id, paths: paths)
            isRestoring = false
            if result.failed.isEmpty {
                message = "Restored \(result.restored.count) item\(result.restored.count == 1 ? "" : "s")."
            } else {
                message = "Restored \(result.restored.count). \(result.failed.count) couldn't be restored: \(result.failed.first?.reason ?? "")"
            }
            selectedItems.removeAll()
            services.logger.info("History restore: \(result.restored.count) restored, \(result.failed.count) failed", category: .cleanup)
            await load()
        }
    }

    func clear() {
        Task {
            await services.history.clear()
            selectedEntryID = nil
            await load()
        }
    }
}

struct HistoryView: View {
    @Bindable var model: HistoryViewModel

    var body: some View {
        PageScroll {
            PageHeader(section: .history, subtitle: "Everything Mac Cleaner removed. Items moved to the Trash can be put back where they were.") {
                Picker("Show", selection: $model.filter) {
                    Text("All").tag(CleanupHistoryEntry.Source?.none)
                    Text("Manual").tag(CleanupHistoryEntry.Source?.some(.manual))
                    Text("Smart Scan").tag(CleanupHistoryEntry.Source?.some(.smartScan))
                    Text("Uninstaller").tag(CleanupHistoryEntry.Source?.some(.uninstaller))
                    Text("Automatic").tag(CleanupHistoryEntry.Source?.some(.automation))
                }
                .pickerStyle(.menu)
                .frame(width: 160)
                Button("Clear History…", role: .destructive) { model.showClearConfirmation = true }
                    .disabled(model.entries.isEmpty)
            }

            HStack(spacing: 12) {
                StatTile(title: "Total cleaned", value: ByteFormatting.string(model.totalCleaned), caption: "All recorded cleanups",
                         symbol: "sparkles", tint: AppSection.history.tint)
                StatTile(title: "Cleanups", value: NumberFormatting.count(model.entries.filter { !$0.dryRun }.count), caption: nil,
                         symbol: "list.bullet", tint: .blue)
                StatTile(title: "Restorable items", value: NumberFormatting.count(model.entries.reduce(0) { $0 + $1.restorableCount }),
                         caption: "Still in the Trash", symbol: "arrow.uturn.backward", tint: .green)
            }

            if let message = model.message {
                InfoCallout(style: .success, message: message)
            }

            if model.filteredEntries.isEmpty {
                EmptyStateView(title: "No history yet", symbol: "clock.arrow.circlepath",
                               message: "When you clean something, it's recorded here so you can review it and restore items from the Trash.")
            } else {
                HStack(alignment: .top, spacing: 16) {
                    entryList
                        .frame(width: 320)
                    entryDetail
                }
            }
        }
        .task { await model.load() }
        .confirmationDialog("Clear the cleanup history?", isPresented: $model.showClearConfirmation) {
            Button("Clear History", role: .destructive) { model.clear() }
        } message: {
            Text("Items already in the Trash stay there, but Mac Cleaner won't be able to put them back automatically.")
        }
    }

    private var entryList: some View {
        VStack(spacing: 0) {
            ForEach(model.filteredEntries) { entry in
                Button {
                    model.selectedEntryID = entry.id
                    model.selectedItems.removeAll()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: entry.method == .moveToTrash ? "trash" : "trash.slash")
                            .foregroundStyle(entry.dryRun ? Color.secondary : AppSection.history.tint)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(entry.title).lineLimit(1)
                                if entry.dryRun { Badge(text: "Dry run", symbol: nil, tint: .secondary) }
                            }
                            Text("\(entry.source.title) · \(DateFormatting.short(entry.date))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        SizeText(bytes: entry.bytes, font: .callout).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(model.selectedEntryID == entry.id ? Color.accentColor.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .card(padding: 6)
    }

    @ViewBuilder
    private var entryDetail: some View {
        if let entry = model.selectedEntry {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(.title3.weight(.semibold))
                        Text("\(DateFormatting.short(entry.date)) · \(entry.method.title) · \(entry.itemCount) removed, \(entry.skippedCount) skipped, \(entry.failedCount) failed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if entry.restorableCount > 0 {
                        Button("Restore Selected") { model.restore(all: false) }
                            .disabled(model.selectedItems.isEmpty || model.isRestoring)
                        Button("Restore All") { model.restore(all: true) }
                            .disabled(model.isRestoring)
                            .buttonStyle(.borderedProminent)
                    }
                }
                if entry.method == .deletePermanently && !entry.dryRun {
                    InfoCallout(style: .info, message: "These items were deleted immediately to free space, so they can't be restored.")
                }
                Table(entry.items, selection: $model.selectedItems) {
                    TableColumn("Item") { item in
                        HStack(spacing: 6) {
                            FileIcon(path: item.trashedPath ?? item.originalPath, size: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((item.originalPath as NSString).lastPathComponent).lineLimit(1)
                                PathText(path: item.originalPath, font: .caption2)
                            }
                        }
                        .contextMenu {
                            if let trashed = item.trashedPath, FileManager.default.fileExists(atPath: trashed) {
                                Button("Show in Trash") { FinderActions.reveal(trashed) }
                            }
                            Button("Copy Original Path") { FinderActions.copyPath(item.originalPath) }
                        }
                    }
                    TableColumn("Category", value: \.category).width(140)
                    TableColumn("Status") { item in
                        Text(status(of: item, entry: entry)).foregroundStyle(.secondary)
                    }
                    .width(110)
                    TableColumn("Size") { item in
                        SizeText(bytes: item.bytes).foregroundStyle(.secondary)
                    }
                    .width(80)
                }
                .frame(minHeight: 320)
            }
            .card()
        }
    }

    private func status(of item: CleanupHistoryEntry.Item, entry: CleanupHistoryEntry) -> String {
        if entry.dryRun { return "Not removed" }
        if item.restored { return "Restored" }
        guard let trashed = item.trashedPath else { return "Deleted" }
        return FileManager.default.fileExists(atPath: trashed) ? "In Trash" : "Trash emptied"
    }
}
