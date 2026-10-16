import SwiftUI

struct AVShieldsTab: View {
    var model: AntivirusViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AVShieldCard(
                title: "File Shield",
                symbol: "doc.badge.gearshape",
                description: "Scans new and changed files in Downloads, Desktop, Documents, your Applications folders, launch agent folders and /Users/Shared as soon as they stop changing. Downloads in progress are checked once they finish.",
                isOn: model.isRealTimeProtectionOn,
                status: fileShieldStatus,
                statusTint: model.isRealTimeProtectionOn ? (model.shieldStatistics.deniedFolders.isEmpty ? .green : .orange) : .secondary,
                toggle: { model.setRealTimeProtection($0) }
            ) {
                if model.isRealTimeProtectionOn {
                    VStack(alignment: .leading, spacing: 4) {
                        AVInfoRow(label: "Files checked", value: NumberFormatting.count(model.shieldStatistics.filesScanned))
                        AVInfoRow(label: "Last check", value: model.shieldStatistics.lastScanAt.map { AVFormat.relative($0) } ?? "Waiting for new files")
                        if model.shieldStatistics.droppedEvents > 0 {
                            AVInfoRow(label: "Skipped", value: "\(model.shieldStatistics.droppedEvents) changes arrived too fast; run a Quick Scan to check them", valueColor: .orange)
                        }
                    }
                }
                if !model.shieldStatistics.deniedFolders.isEmpty {
                    InfoCallout(style: .warning, title: "Some folders can't be checked",
                                message: "macOS didn't allow Mac Cleaner to read \(model.shieldStatistics.deniedFolders.map { PathUtilities.abbreviate($0) }.joined(separator: ", ")). Allow it under System Settings › Privacy & Security › Files & Folders, or grant Full Disk Access.")
                    Button("Open Privacy Settings") { model.services.permissions.open(.filesAndFolders) }
                        .controlSize(.small)
                }
            }
            AVShieldCard(
                title: "Download Shield",
                symbol: "arrow.down.circle",
                description: "Checks where new downloads came from (the address your browser records) against the URLhaus and ThreatFox lists of malware sites, and flags matches even when no virus signature matches the file.",
                isOn: model.settings.downloadShield,
                status: downloadShieldStatus,
                statusTint: model.settings.downloadShield && model.isRealTimeProtectionOn && model.intelIndicatorCount > 0 ? .green : .secondary,
                toggle: { model.setDownloadShield($0) }
            ) {
                AVInfoRow(label: "Malware addresses", value: model.intelIndicatorCount > 0 ? AVText.compactCount(model.intelIndicatorCount) : "Not downloaded")
                Button("Check Downloads Now") { model.checkDownloads() }
                    .controlSize(.small)
                    .disabled(model.isScanning)
                    .help("Scans your Downloads folder and checks where each file came from.")
            }
        }
        .fixedSize(horizontal: false, vertical: true)

        AVKeepRunningCard(model: model)

        Card("Recent detections", symbol: "list.bullet.rectangle") {
            if model.shieldRecords.isEmpty {
                Text("Nothing detected by the shields yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.shieldRecords.prefix(12)) { record in
                        AVShieldRecordRow(record: record)
                        if record.id != model.shieldRecords.prefix(12).last?.id { Divider() }
                    }
                }
            }
        }
        if model.isRealTimeProtectionOn, !model.shieldStatistics.recent.isEmpty {
            Card("Recently checked", symbol: "clock") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.shieldStatistics.recent.prefix(6)) { activity in
                        HStack(spacing: 8) {
                            FileIcon(path: activity.path, size: 16)
                            Text(PathUtilities.abbreviate(activity.path)).font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Self.title(activity.outcome)).font(.caption).foregroundStyle(Self.tint(activity.outcome))
                            Text(AVFormat.relative(activity.date)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var fileShieldStatus: String {
        guard model.isRealTimeProtectionOn else { return model.definitionsInstalled ? "Off" : "Off until definitions are installed" }
        if !model.definitionsInstalled { return "On, with built-in test signatures only" }
        return model.shieldStatistics.deniedFolders.isEmpty ? "Watching \(model.watchedFolderCount) folders" : "On, some folders need permission"
    }

    private var downloadShieldStatus: String {
        guard model.settings.downloadShield else { return "Off" }
        guard model.isRealTimeProtectionOn else { return "Needs real-time protection" }
        return model.intelIndicatorCount > 0 ? "Checking new downloads" : "Waiting for the threat feeds"
    }

    static func title(_ outcome: AVShieldActivity.Outcome) -> String {
        switch outcome {
        case .clean: return "Clean"
        case .threat(let name): return name
        case .skipped(let reason): return "Skipped (\(reason))"
        }
    }

    static func tint(_ outcome: AVShieldActivity.Outcome) -> Color {
        switch outcome {
        case .clean: return .green
        case .threat: return .red
        case .skipped: return .secondary
        }
    }
}

private struct AVShieldCard<Content: View>: View {
    var title: String
    var symbol: String
    var description: String
    var isOn: Bool
    var status: String
    var statusTint: Color
    var toggle: @MainActor @Sendable (Bool) -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isOn ? AppSection.antivirus.tint : .secondary)
                    .frame(width: 30, height: 30)
                    .background((isOn ? AppSection.antivirus.tint : Color.secondary).opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(status).font(.caption).foregroundStyle(statusTint).lineLimit(1)
                }
                Spacer()
                Toggle(title, isOn: Binding(get: { isOn }, set: toggle))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

private struct AVKeepRunningCard: View {
    var model: AntivirusViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "menubar.rectangle")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text("Protection runs while Mac Cleaner is open").font(.headline)
                Text("Closing the window keeps Mac Cleaner running in the menu bar, so the shields keep working. To be protected from the moment you log in, open Mac Cleaner at login.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.openAtLoginStatus == .requiresApproval {
                    Button("Allow in Login Items Settings") { model.openLoginItemsSettings() }
                        .buttonStyle(.link)
                }
            }
            Spacer()
            Toggle("Open at login", isOn: Binding(get: { model.openAtLoginStatus == .enabled || model.openAtLoginStatus == .requiresApproval },
                                                  set: { model.setOpenAtLogin($0) }))
                .toggleStyle(.switch)
                .disabled(model.openAtLoginStatus == .notFound)
                .help(model.openAtLoginStatus.title)
        }
        .card()
    }
}

private struct AVShieldRecordRow: View {
    let record: AVShieldRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text((record.path as NSString).lastPathComponent).font(.callout.weight(.medium)).lineLimit(1)
                    AVCategoryBadge(category: record.category)
                }
                Text("\(record.name) · \(actionText) · \(record.shield.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(AVFormat.relative(record.date)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Reveal in Finder", systemImage: "folder") { FinderActions.reveal(record.path) }
        }
    }

    private var actionText: String {
        switch record.action {
        case .quarantined: return "moved to the Virus Chest"
        case .notified: return "waiting for your decision"
        case .quarantineFailed: return "couldn't be moved"
        }
    }

    private var symbol: String {
        switch record.action {
        case .quarantined: return "archivebox.fill"
        case .notified: return "exclamationmark.triangle.fill"
        case .quarantineFailed: return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch record.action {
        case .quarantined: return .purple
        case .notified: return .orange
        case .quarantineFailed: return .red
        }
    }
}
