import SwiftUI

/// "Recently Stopped": Relaunch with the original arguments, environment and folder, Copy Command, Reveal.
/// Kept in memory only (the environment can contain secrets), at most 20 entries.
struct PortRecentlyStoppedCard: View {
    let model: PortsModel

    var body: some View {
        Card("Recently Stopped", symbol: "clock.arrow.circlepath") {
            Button("Clear") { model.clearRecentlyStopped() }
                .buttonStyle(.borderless)
                .font(.callout)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.recentlyStopped) { record in
                    PortStoppedRow(record: record, model: model)
                    if record.id != model.recentlyStopped.last?.id { Divider().padding(.leading, 38) }
                }
                Text("Kept in memory only and forgotten when Mac Cleaner quits, because commands can contain passwords "
                     + "and keys. Relaunched servers write their output to ~/Library/Logs/Mac Cleaner/Relaunched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
    }
}

private struct PortStoppedRow: View {
    let record: PortStoppedRecord
    let model: PortsModel

    private var isRelaunching: Bool { model.relaunchingRecordIDs.contains(record.id) }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "stop.circle")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !record.ports.isEmpty {
                        Text(record.ports.map { ":\($0)" }.joined(separator: " "))
                            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                            .strikethrough()
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Text(PortFormat.abbreviatePath(record.commandLine))
                    .font(PortTheme.command)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(record.commandLine)
            }
            Spacer(minLength: 8)
            PortTimeAgoText(date: record.date)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize()
            relaunch
            PortIconButton(systemImage: "doc.on.doc", label: "Copy Command") { model.copy(record.commandLine) }
            if let cwd = record.cwd {
                PortIconButton(systemImage: "folder", label: "Reveal Folder in Finder") { model.revealInFinder(cwd) }
            }
        }
        .padding(.vertical, 5)
        .contextMenu {
            Button("Copy Command") { model.copy(record.commandLine) }
            if let cwd = record.cwd { Button("Reveal Folder in Finder") { model.revealInFinder(cwd) } }
        }
    }

    @ViewBuilder
    private var relaunch: some View {
        if isRelaunching {
            ProgressView().controlSize(.small)
                .frame(width: 80)
        } else if PortStopReport.canRelaunch(record) {
            Button {
                model.relaunch(record)
            } label: {
                Label("Relaunch", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .help("Start it again with its original arguments, environment and folder")
        } else {
            Text(reason)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help(reason)
        }
    }

    private var reason: String {
        switch record.manager {
        case .launchd, .pm2, .docker:
            return "Start it with \(record.manager.badge ?? "its manager")"
        case .none, .watcher:
            return record.arguments.isEmpty ? "Command unknown" : "Renamed itself"
        }
    }
}

/// "Still running · no open port": tools whose ports closed while some of their processes kept running.
struct PortStillRunningCard: View {
    let model: PortsModel

    var body: some View {
        Card("Still Running · No Open Port", symbol: "hourglass") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.stillRunning) { item in
                    PortStillRunningRow(item: item, model: model)
                }
                Text("These tools closed their ports, but some of their processes kept running and use CPU or memory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PortStillRunningRow: View {
    let item: PortStillRunningItem
    let model: PortsModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "hourglass")
                .font(.system(size: 15))
                .foregroundStyle(.orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(item.formerPorts.map { ":\($0)" }.joined(separator: " "))
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .strikethrough()
                        .foregroundStyle(.tertiary)
                }
                Text(item.processSummary)
                    .font(PortTheme.command)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Text("closed")
                PortTimeAgoText(date: item.closedAt)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize()
            PortUsagePill(usage: item.usage)
            PortStopControl(title: item.title, safety: .oneClick, isBusy: model.busyGroupIDs.contains(item.busyID)) { mode in
                model.stopStillRunning(item, mode: mode)
            }
        }
        .contextMenu {
            if let path = item.path { Button("Reveal in Finder") { model.revealInFinder(path) } }
            Button("Stop") { model.stopStillRunning(item) }
            Button("Force Stop") { model.stopStillRunning(item, mode: .force) }
        }
    }
}
