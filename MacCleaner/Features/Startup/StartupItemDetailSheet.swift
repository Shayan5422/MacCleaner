import SwiftUI

/// Everything known about one startup item, with its actions.
struct StartupItemDetailSheet: View {
    let item: StartupItem
    @Bindable var model: StartupViewModel
    @State private var service: LaunchctlServiceInfo?
    @State private var pending: StartupPendingAction?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            StartupDetailHeader(item: item)
                .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(item.concerns) { concern in
                        InfoCallout(style: .warning, title: concern.title, message: concern.explanation)
                    }
                    StartupDetailStatusCard(item: item, service: service)
                    if item.kind.isUserManageable && !item.isProtected {
                        Card("If you turn it off", symbol: "power") {
                            Text(item.consequenceOfDisabling)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    StartupDetailProgramCard(item: item)
                    if let code = item.code {
                        StartupDetailSignatureCard(code: code)
                    }
                    if let definition = item.definition, !definition.entries.isEmpty {
                        StartupPlistContentsCard(rows: definition.displayRows)
                    }
                    InfoCallout(style: .info, title: "How to manage it", message: item.managementNote)
                }
                .padding(20)
            }
            Divider()
            footer
                .padding(16)
        }
        .frame(width: 660, height: 640)
        .task(id: item.id) {
            if item.label != nil && item.kind != .loginItem {
                service = await StartupInventoryScanner.refreshedServiceInfo(for: item)
            }
        }
        .confirmationDialog(
            pending?.title ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { action in
            Button(action.confirmTitle, role: action.isDestructive ? .destructive : nil) {
                Task {
                    await model.perform(action)
                    service = await StartupInventoryScanner.refreshedServiceInfo(for: item)
                }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { action in
            Text(action.message)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let path = item.plistPath ?? item.targetPath {
                Button("Reveal in Finder") { FinderActions.reveal(path) }
            }
            Button("Login Items Settings") { model.openLoginItemsSettings() }
            Spacer()
            if model.isBusy(item) {
                ProgressView().controlSize(.small)
            }
            if item.canToggle {
                if item.isEnabled == false {
                    Button("Turn On…") { pending = .enable(item) }
                } else {
                    Button("Turn Off…") { pending = .disable(item) }
                }
            }
            if item.canMoveToTrash {
                Button("Move to Trash…", role: .destructive) { model.requestMoveToTrash(item) }
            }
            if item.canRemoveLoginItem {
                Button("Remove from Login Items…", role: .destructive) { pending = .removeLoginItem(item) }
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .disabled(model.isBusy(item))
    }
}

private struct StartupDetailHeader: View {
    let item: StartupItem

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            StartupItemIcon(item: item, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                    .lineLimit(2)
                Text("\(item.kind.title) · \(item.developerDescription)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    StartupStateBadge(item: item)
                    if item.isPotentiallyUnnecessary {
                        Badge(text: "May be unnecessary", symbol: "exclamationmark.circle.fill", tint: .orange)
                    }
                    if item.isProtected {
                        Badge(text: "Part of macOS", symbol: "lock.fill", tint: .gray)
                    }
                    if let usage = item.usage, item.state.isRunning {
                        Badge(text: usage.impact.title, symbol: "gauge.with.dots.needle.33percent", tint: usage.impact == .high ? .red : usage.impact == .medium ? .orange : .green)
                    }
                }
            }
            Spacer()
        }
    }
}

private struct StartupDetailStatusCard: View {
    let item: StartupItem
    let service: LaunchctlServiceInfo?

    var body: some View {
        Card("Status", symbol: "waveform.path.ecg") {
            VStack(alignment: .leading, spacing: 6) {
                KeyValueRow(key: "Status", value: item.state.explanation)
                KeyValueRow(key: "Starts", value: item.triggerSummary)
                if item.kind != .loginItem {
                    KeyValueRow(key: "Turned on", value: item.isEnabled.map { $0 ? "Yes" : "No" } ?? "Unknown")
                }
                if let approval = item.backgroundApproval, approval != .notFound {
                    KeyValueRow(key: "System Settings", value: approval.title,
                                valueColor: approval == .requiresApproval ? .orange : .primary)
                }
                if let keepAlive = item.definition?.keepAlive, keepAlive != .off {
                    KeyValueRow(key: "Keep alive", value: keepAlive.summary)
                }
                KeyValueRow(key: "Runs as", value: runsAs)
                if let usage = item.usage {
                    KeyValueRow(key: "Resource use", value: usage.summary)
                }
                if let service {
                    if let pid = service.pid { KeyValueRow(key: "Process ID", value: String(pid)) }
                    if let runs = service.runs { KeyValueRow(key: "Starts this session", value: NumberFormatting.count(runs)) }
                    if let exit = service.lastExitSummary { KeyValueRow(key: "Last exit", value: exit) }
                    if let signal = service.lastTerminatingSignal { KeyValueRow(key: "Last signal", value: signal) }
                }
                if let owner = item.owner {
                    KeyValueRow(key: "Belongs to", value: owner.name)
                    if let lastUsed = owner.lastUsedDate {
                        KeyValueRow(key: "\(owner.name) last opened", value: DateFormatting.relative(lastUsed))
                    }
                }
            }
        }
    }

    private var runsAs: String {
        if let user = item.definition?.userName { return user }
        switch item.kind {
        case .systemDaemon: return "System (root)"
        case .appBackgroundItem where item.plistPath?.contains("/LaunchDaemons/") == true: return "System (root)"
        default: return "Your account"
        }
    }
}

private struct StartupDetailProgramCard: View {
    let item: StartupItem

    var body: some View {
        Card("Program", symbol: "terminal") {
            VStack(alignment: .leading, spacing: 8) {
                if let plist = item.plistPath {
                    StartupPathRow(label: "Property list", path: plist)
                }
                if let link = item.plistLinkDestination {
                    StartupPathRow(label: "Links to", path: link)
                }
                if let analysis = item.analysis {
                    Text(analysis.targetDescription)
                        .font(.callout)
                    if let target = analysis.targetPath {
                        StartupPathRow(label: label(for: analysis), path: target)
                    } else if let open = analysis.openTarget {
                        KeyValueRow(key: "Opens", value: open)
                    }
                    if let executable = analysis.executable, executable != analysis.targetPath {
                        StartupPathRow(label: "Executable", path: executable)
                    }
                    if analysis.arguments.count > 1 || analysis.inlineCode != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Command").font(.callout).foregroundStyle(.secondary)
                            Text(analysis.commandLine)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    if let directory = item.definition?.workingDirectory {
                        StartupPathRow(label: "Working folder", path: directory)
                    }
                } else if let target = item.targetPath {
                    StartupPathRow(label: item.kind == .loginItem ? "App" : "Helper", path: target)
                } else if item.kind == .loginItem {
                    Text("System Events doesn't know where this app is any more.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let error = item.parseError {
                    InfoCallout(style: .warning, message: error)
                }
            }
        }
    }

    private func label(for analysis: LaunchdProgramAnalysis) -> String {
        switch analysis.targetKind {
        case .application: return "App"
        case .script: return "Script"
        default: return "Program"
        }
    }
}

private struct StartupDetailSignatureCard: View {
    let code: SecurityCodeEvaluation

    var body: some View {
        Card("Code signature", symbol: "signature") {
            VStack(alignment: .leading, spacing: 6) {
                KeyValueRow(key: "Trust", value: code.summary,
                            valueColor: code.category.isSignatureProblem ? .orange : .primary)
                if let developer = code.developer {
                    KeyValueRow(key: "Developer", value: developer)
                }
                if let team = code.signature.teamIdentifier {
                    KeyValueRow(key: "Team ID", value: team)
                }
                if let identifier = code.signature.identifier {
                    KeyValueRow(key: "Identifier", value: identifier)
                }
                KeyValueRow(key: "Notarization", value: code.notarization)
                if code.signature.status == .valid {
                    KeyValueRow(key: "Hardened runtime", value: code.signature.hasHardenedRuntime ? "Yes" : "No")
                }
            }
        }
    }
}

private struct StartupPlistContentsCard: View {
    let rows: [LaunchdPlistRow]

    var body: some View {
        Card("Property list contents", symbol: "doc.plaintext") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(row.key)
                                .fontWeight(row.value == nil ? .semibold : .regular)
                                .foregroundStyle(row.value == nil ? .primary : .secondary)
                            if let value = row.value {
                                Text(value)
                                    .textSelection(.enabled)
                                    .lineLimit(4)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, CGFloat(row.depth) * 14)
                        .font(.system(.caption, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
        }
    }
}

/// A labeled path with a Reveal in Finder button (or "Missing").
struct StartupPathRow: View {
    var label: String
    var path: String

    var body: some View {
        let status = LaunchdPathProbe.status(path)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(PathUtilities.abbreviate(path))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(path)
            Spacer(minLength: 4)
            switch status {
            case .exists:
                Button {
                    FinderActions.reveal(path)
                } label: {
                    Image(systemName: "arrow.right.circle")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \(label) in Finder")
            case .missing:
                Text("Missing").font(.caption.weight(.semibold)).foregroundStyle(.red)
            case .inaccessible:
                Text("No access").font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}
