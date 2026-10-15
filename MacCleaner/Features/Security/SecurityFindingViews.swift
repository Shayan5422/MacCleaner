import SwiftUI

// MARK: - Findings tab

struct SecurityFindingsTab: View {
    @Bindable var model: SecurityViewModel
    let report: SecurityReport

    var body: some View {
        let active = model.activeFindings
        if active.isEmpty {
            EmptyStateView(
                title: model.searchText.isEmpty ? "No Threats or Suspicious Items" : "No Matching Findings",
                symbol: model.searchText.isEmpty ? "checkmark.shield" : "magnifyingglass",
                message: model.searchText.isEmpty
                    ? "Nothing unusual was found in the \(report.persistenceItems.count) startup items, \(report.applications.count) apps and \(report.quarantinedFiles.count) downloads Mac Cleaner reviewed."
                    : "No findings match “\(model.searchText)”."
            )
        } else {
            ForEach(FindingSeverity.allCases.reversed(), id: \.self) { severity in
                let findings = active.filter { $0.severity == severity }
                if !findings.isEmpty {
                    SecurityFindingGroup(severity: severity, findings: findings, model: model)
                }
            }
        }
        let ignored = model.ignoredFindings
        if !ignored.isEmpty {
            SecurityIgnoredFindings(findings: ignored, model: model)
        }
    }
}

private struct SecurityFindingGroup: View {
    let severity: FindingSeverity
    let findings: [SecurityFinding]
    var model: SecurityViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: severity.symbolName)
                    .foregroundStyle(SecurityStyle.color(severity))
                Text(SecurityStyle.groupTitle(severity)).font(.headline)
                Text("\(findings.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(14)
            Divider()
            LazyVStack(spacing: 0) {
                ForEach(findings) { finding in
                    SecurityFindingRow(finding: finding, model: model)
                    if finding.id != findings.last?.id {
                        Divider().padding(.leading, 50)
                    }
                }
            }
        }
        .card(padding: 0)
    }

    private var explanation: String {
        switch severity {
        case .threat: return "Matches a documented adware or unwanted-program rule."
        case .suspicious: return "Unusual and worth checking, but not proven harmful."
        case .recommendation: return "Settings that would make this Mac safer."
        case .info: return "Good to know. No action needed unless you want to tidy up."
        }
    }
}

struct SecurityFindingRow: View {
    let finding: SecurityFinding
    var model: SecurityViewModel
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: finding.category.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SecurityStyle.color(finding.severity))
                .frame(width: 24, height: 24)
                .background(SecurityStyle.color(finding.severity).opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Text(finding.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let path = finding.path {
                    PathText(path: path, font: .caption2)
                }
            }
            Spacer(minLength: 8)
            if finding.severity == .threat {
                Badge(text: "Rule match", symbol: "checkmark.seal", tint: .red)
                    .help(finding.ruleName ?? "Known adware/PUP rule match")
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isHovering ? Color.hoverFill : .clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { model.selectedFinding = finding }
        .contextMenu {
            Button("Show Details", systemImage: "info.circle") { model.selectedFinding = finding }
            if let path = finding.path {
                Button("Reveal in Finder", systemImage: "folder") { FinderActions.reveal(path) }
                Button("Copy Path", systemImage: "doc.on.doc") { FinderActions.copyPath(path) }
            }
            Divider()
            if model.isIgnored(finding) {
                Button("Stop Ignoring", systemImage: "eye") { model.setIgnored(finding, ignored: false) }
            } else {
                Button("Ignore", systemImage: "eye.slash") { model.setIgnored(finding, ignored: true) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(finding.severity.title): \(finding.title)")
        .accessibilityHint("Shows details and actions")
        .accessibilityAddTraits(.isButton)
    }
}

private struct SecurityIgnoredFindings: View {
    let findings: [SecurityFinding]
    @Bindable var model: SecurityViewModel

    var body: some View {
        DisclosureGroup(isExpanded: $model.showsIgnored) {
            VStack(spacing: 0) {
                ForEach(findings) { finding in
                    HStack(spacing: 10) {
                        SeverityBadge(severity: finding.severity)
                        Text(finding.title).lineLimit(1)
                        Spacer()
                        Button("Stop Ignoring") { model.setIgnored(finding, ignored: false) }
                            .controlSize(.small)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedFinding = finding }
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Ignored (\(findings.count))", systemImage: "eye.slash")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Detail

struct SecurityFindingDetailSheet: View {
    let finding: SecurityFinding
    @Bindable var model: SecurityViewModel
    @State private var pending: SecurityPendingAction?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(finding.summary)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if finding.reasons.count > 1 || finding.reasons.first.map({ $0 != finding.summary }) == true {
                        Card("Why it was flagged", symbol: "list.bullet") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(finding.reasons, id: \.self) { reason in
                                    Label {
                                        Text(reason).font(.callout).fixedSize(horizontal: false, vertical: true)
                                    } icon: {
                                        Image(systemName: "smallcircle.filled.circle").foregroundStyle(SecurityStyle.color(finding.severity))
                                    }
                                }
                            }
                        }
                    }
                    if !finding.evidence.isEmpty {
                        Card("Evidence", symbol: "doc.text.magnifyingglass") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(finding.evidence) { evidence in
                                    SecurityEvidenceRow(evidence: evidence)
                                }
                            }
                        }
                    }
                    if let path = verifiablePath {
                        SecurityDeepVerifyCard(path: path, model: model)
                    }
                    if let recommendation = finding.recommendation {
                        SecurityRecommendationView(text: recommendation)
                    }
                }
                .padding(20)
            }
            Divider()
            footer.padding(16)
        }
        .frame(width: 660, height: 620)
        .confirmationDialog(
            pending?.title ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { action in
            Button(action.confirmTitle, role: .destructive) {
                Task {
                    await model.perform(action)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { action in
            Text(action.message)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: finding.severity.symbolName)
                .font(.system(size: 30))
                .foregroundStyle(SecurityStyle.color(finding.severity))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(finding.title)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    SeverityBadge(severity: finding.severity)
                    Badge(text: finding.category.title, symbol: finding.category.symbolName, tint: .gray)
                    if let rule = finding.ruleName {
                        Badge(text: rule, symbol: "checkmark.seal", tint: finding.severity == .threat ? .red : .orange)
                    }
                    if model.isIgnored(finding) {
                        Badge(text: "Ignored", symbol: "eye.slash", tint: .gray)
                    }
                }
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            SecurityRemediationButtons(finding: finding, model: model, pending: $pending)
            Spacer()
            if model.isPerformingAction {
                ProgressView().controlSize(.small)
            }
            if model.isIgnored(finding) {
                Button("Stop Ignoring") { model.setIgnored(finding, ignored: false) }
            } else {
                Button("Ignore") {
                    model.setIgnored(finding, ignored: true)
                    dismiss()
                }
                .help("Hide this finding in future scans. You can show it again from Ignored.")
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
    }

    /// Apps and installer packages can be deep-verified from the detail view.
    private var verifiablePath: String? {
        switch finding.remediation {
        case .application(let path): return path
        case .quarantinedFiles(let paths) where paths.count == 1:
            let path = paths[0]
            return path.hasSuffix(".app") || path.hasSuffix(".pkg") || path.hasSuffix(".mpkg") ? path : nil
        default: return nil
        }
    }
}

/// Buttons for what can be done about a finding (only supported, reversible or confirmed actions).
private struct SecurityRemediationButtons: View {
    let finding: SecurityFinding
    var model: SecurityViewModel
    @Binding var pending: SecurityPendingAction?

    var body: some View {
        switch finding.remediation {
        case .userLaunchAgent(let label, let plist):
            let name = label ?? ((plist as NSString).lastPathComponent as NSString).deletingPathExtension
            if let label, LaunchctlClient.isValidLabel(label), !LaunchctlClient.isProtectedLabel(label), FileManager.default.fileExists(atPath: plist) {
                Button("Turn Off…") { pending = .disableAgent(label: label, name: name) }
            }
            Button("Move to Trash…", role: .destructive) {
                model.requestTrashLaunchAgent(plistPath: plist, label: label, name: name)
            }
            Button("Reveal") { FinderActions.reveal(plist) }
        case .systemLaunchItem(let path):
            Button("Reveal in Finder") { FinderActions.reveal(path) }
            Button("Login Items Settings") { model.open(.loginItems) }
        case .appBackgroundItem(let appPath):
            Button("Reveal App") { FinderActions.reveal(appPath) }
            Button("Login Items Settings") { model.open(.loginItems) }
        case .loginItem(let name, let path):
            Button("Remove from Login Items…", role: .destructive) { pending = .removeLoginItem(name: name, path: path) }
            Button("Login Items Settings") { model.open(.loginItems) }
        case .application(let path):
            Button("Reveal in Finder") { FinderActions.reveal(path) }
        case .quarantinedFiles(let paths):
            Button(paths.count == 1 ? "Move to Trash…" : "Move \(paths.count) to Trash…", role: .destructive) {
                model.requestTrash(paths: paths, purpose: .userFile,
                                   title: paths.count == 1 ? "Move “\((paths[0] as NSString).lastPathComponent)” to the Trash" : "Move \(paths.count) downloads to the Trash",
                                   warning: nil)
            }
            if paths.count == 1 {
                Button("Reveal") { FinderActions.reveal(paths[0]) }
            }
        case .shellStartupFile(let path):
            Button("Open in TextEdit") { model.openInTextEdit(path) }
            Button("Reveal") { FinderActions.reveal(path) }
        case .cronJobs:
            EmptyView()
        case .settings(let pane):
            Button("Open \(pane.title) Settings") { model.open(pane) }
        case .deviceManagement:
            Button("Open Device Management") { model.openDeviceManagementSettings() }
        case .authorizationPlugin(let path):
            Button("Reveal in Finder") { FinderActions.reveal(path) }
        case .libraryItem(let path):
            Button("Move to Trash…", role: .destructive) {
                model.requestTrash(paths: [path], purpose: .applicationData,
                                   title: "Remove “\((path as NSString).lastPathComponent)”",
                                   warning: "This is a documented component of known adware. Restart your Mac afterwards so nothing keeps running from memory.")
            }
            Button("Reveal") { FinderActions.reveal(path) }
        case .reviewApplications:
            Button("Show Apps") { model.showUnidentifiedApps() }
        case .none:
            EmptyView()
        }
    }
}

struct SecurityEvidenceRow: View {
    let evidence: SecurityEvidence

    var body: some View {
        if evidence.isPath {
            StartupPathRow(label: evidence.label, path: evidence.value)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(evidence.label)
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                Text(evidence.value)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.callout)
        }
    }
}

private struct SecurityRecommendationView: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 3) {
                Text("What you can do").font(.callout.weight(.semibold))
                Text(SecurityStyle.markdown(text))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.blue.opacity(0.18)))
    }
}

/// Full signature check (every resource) plus Gatekeeper's own assessment, on request.
struct SecurityDeepVerifyCard: View {
    let path: String
    var model: SecurityViewModel

    var body: some View {
        Card("Deep verification", symbol: "checkmark.shield") {
            if model.verifyingPaths.contains(path) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Verifying every file and asking Gatekeeper… Large apps can take a minute.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let result = model.deepVerifications[path] {
                VStack(alignment: .leading, spacing: 6) {
                    KeyValueRow(key: "Signature", value: result.evaluation.summary,
                                valueColor: result.evaluation.category.isSignatureProblem ? .red : .primary)
                    if let gatekeeper = result.gatekeeper {
                        KeyValueRow(key: "Gatekeeper", value: gatekeeper.summary, valueColor: gatekeeper.accepted ? .green : .orange)
                        if let origin = gatekeeper.origin {
                            KeyValueRow(key: "Origin", value: origin)
                        }
                    }
                    KeyValueRow(key: "Checked", value: DateFormatting.short(result.date))
                    Button("Verify Again") { model.deepVerify(path) }
                        .controlSize(.small)
                }
            } else {
                HStack {
                    Text("Checks every file of the bundle against its signature and asks Gatekeeper for its verdict. Nothing is changed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Deep Verify") { model.deepVerify(path) }
                }
            }
        }
    }
}
