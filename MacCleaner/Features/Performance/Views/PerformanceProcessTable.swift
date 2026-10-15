import AppKit
import SwiftUI

/// Sortable, searchable table of processes with Activity Monitor-style columns.
struct PerformanceProcessTable: View {
    @Bindable var model: PerformanceViewModel

    var body: some View {
        let rows = model.processRows
        Table(rows, selection: $model.processSelection, sortOrder: $model.processSortOrder) {
            TableColumn("Process", value: \.name) { row in
                HStack(spacing: 8) {
                    PerformanceProcessIcon(pid: row.role.actionableApp?.pid, path: row.iconPath)
                    Text(row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.process.executablePath ?? row.name)
                }
            }
            .width(min: 160, ideal: 240)

            TableColumn("% CPU", value: \.cpuSortKey) { row in
                usageText(PerformanceFormat.cpuColumn(row.process.cpu), available: row.process.hasUsageInfo)
                    .help("Share of one CPU core during the last update. 100% is one fully busy core.")
            }
            .width(min: 52, ideal: 60)

            TableColumn("% of Total", value: \.cpuTotalSortKey) { row in
                usageText(row.cpuTotalSortKey >= 0 ? NumberFormatting.percent(row.cpuTotalSortKey, digits: 1) : "—", available: row.process.hasUsageInfo)
                    .help("Share of all \(model.monitor.topology.logicalCoreCount) cores.")
            }
            .width(min: 60, ideal: 70)

            TableColumn("Memory", value: \.memorySortKey) { row in
                usageText(row.process.memoryFootprint.map(PerformanceFormat.memory) ?? "—", available: row.process.hasUsageInfo)
            }
            .width(min: 64, ideal: 80)

            TableColumn("Kind", value: \.kindTitle) { row in
                Text(row.kindTitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(row.processCount > 1 ? "Includes \(row.processCount - 1) helper process\(row.processCount == 2 ? "" : "es")." : row.kindTitle)
            }
            .width(min: 56, ideal: 84)

            TableColumn("PID", value: \.pid) { row in
                Text(String(row.pid)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 44, ideal: 54)

            TableColumn("User", value: \.userName) { row in
                Text(row.userName).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .width(min: 50, ideal: 90)
        }
        .contextMenu(forSelectionType: pid_t.self) { selection in
            if let pid = selection.first, let row = rows.first(where: { $0.id == pid }) {
                contextMenu(for: row)
            }
        }
        .accessibilityLabel("Processes")
    }

    @ViewBuilder
    private func usageText(_ text: String, available: Bool) -> some View {
        if available {
            Text(text).monospacedDigit()
        } else {
            Text("—")
                .foregroundStyle(.tertiary)
                .help("macOS doesn't let apps read the resource usage of other users' processes.")
        }
    }

    @ViewBuilder
    private func contextMenu(for row: PerformanceProcessRow) -> some View {
        let target = model.target(for: row)
        ForEach(model.actions(for: row)) { action in
            Button(menuTitle(action, row: row), systemImage: action.symbol) {
                model.perform(action, target: target)
            }
        }
        if !model.actions(for: row).isEmpty { Divider() }
        if let path = row.process.executablePath {
            Button("Reveal in Finder", systemImage: "folder") {
                FinderActions.reveal(row.role.actionableApp?.bundlePath ?? path)
            }
        }
        Button("Copy Process ID", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(row.pid), forType: .string)
        }
    }

    private func menuTitle(_ action: PerformanceAction, row: PerformanceProcessRow) -> String {
        let appName = row.role.actionableApp?.name ?? row.name
        switch action {
        case .quit: return "Quit \(appName)"
        case .forceQuit: return "Force Quit \(appName)…"
        case .stopProcess: return "Stop \(row.name)…"
        case .openStartupItems: return action.title
        }
    }
}

/// App or executable icon for process lists. Running apps use the icon
/// `NSRunningApplication` reports; helpers use their app's icon.
struct PerformanceProcessIcon: View {
    var pid: pid_t?
    var path: String?
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = PerformanceAppIconCache.shared.icon(pid: pid, bundlePath: path) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "gearshape")
                    .font(.system(size: size * 0.75))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Icons of running apps (by pid, from `NSRunningApplication`) and app bundles.
@MainActor
final class PerformanceAppIconCache {
    static let shared = PerformanceAppIconCache()

    private struct Key: Hashable {
        var pid: pid_t
        var bundlePath: String?
    }

    private var running: [Key: NSImage] = [:]

    func icon(pid: pid_t?, bundlePath: String?) -> NSImage? {
        if let pid {
            let key = Key(pid: pid, bundlePath: bundlePath)
            if let cached = running[key] { return cached }
            if let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
               app.bundleURL?.path == bundlePath, let icon = app.icon {
                if running.count > 500 { running.removeAll() }
                running[key] = icon
                return icon
            }
        }
        guard let bundlePath, bundlePath.hasSuffix(".app") else { return nil }
        return IconCache.shared.icon(for: bundlePath)
    }
}
