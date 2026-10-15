import SwiftUI

/// Security & Malware Detection.
struct SecurityView: View {
    @Bindable var model: SecurityViewModel

    var body: some View {
        PageScroll {
            PageHeader(section: .security, subtitle: "Reviews startup items, app signatures, downloads and macOS protections.") {
                SecurityHeaderActions(model: model)
            }
            SecurityDisclaimer()
            if let message = model.statusMessage {
                StartupStatusBanner(message: message) { model.statusMessage = nil }
            }
            SecurityPostureSection(model: model)
            if model.isScanning {
                ScanProgressCard(title: "Scanning…", message: model.progressMessage, fraction: model.progress,
                                 tint: AppSection.security.tint, onCancel: { model.cancelScan() })
            } else if let report = model.report {
                SecurityResultsView(model: model, report: report)
            } else {
                ScanLaunchView(
                    section: .security,
                    headline: "Check this Mac for unwanted software",
                    message: "Reviews everything that starts automatically, the signatures of your apps, installers in Downloads and documented adware locations. Nothing is changed without your confirmation.",
                    buttonTitle: "Scan Now",
                    bullets: [
                        "Launch agents, daemons, login items and cron jobs",
                        "Code signatures and notarization of installed apps",
                        "Quarantined apps, installers and scripts in Downloads",
                        "Known adware and unwanted-program rules",
                    ],
                    action: { model.startScan() }
                )
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search findings, apps and downloads")
        .task { await model.onAppear() }
        .sheet(item: $model.selectedFinding) { finding in
            SecurityFindingDetailSheet(finding: finding, model: model)
        }
        .confirmationDialog(
            model.pendingAction?.title ?? "",
            isPresented: Binding(get: { model.pendingAction != nil && model.selectedFinding == nil },
                                 set: { if !$0 { model.pendingAction = nil } }),
            titleVisibility: .visible,
            presenting: model.pendingAction
        ) { action in
            Button(action.confirmTitle, role: .destructive) { Task { await model.perform(action) } }
            Button("Cancel", role: .cancel) { model.pendingAction = nil }
        } message: { action in
            Text(action.message)
        }
        .alert("Something Went Wrong",
               isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } }),
               presenting: model.alertMessage) { _ in
            Button("OK", role: .cancel) { model.alertMessage = nil }
        } message: { message in
            Text(message)
        }
        .cleanupFlow(model.cleanupFlow, services: model.services)
    }
}

/// The persistent statement of what this feature is and isn't.
struct SecurityDisclaimer: View {
    var body: some View {
        InfoCallout(style: .info, message: "Mac Cleaner checks persistence locations, code signatures and known adware rules. It isn't an antivirus — macOS XProtect provides built-in malware protection.")
    }
}

private struct SecurityHeaderActions: View {
    @Bindable var model: SecurityViewModel

    var body: some View {
        HStack(spacing: 10) {
            if let last = model.lastScan, !model.isScanning {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Last scan").font(.caption2).foregroundStyle(.secondary)
                    Text(SecurityStyle.relative(last.date)).font(.caption)
                }
                .accessibilityElement(children: .combine)
            }
            if model.isScanning {
                Button("Stop", role: .cancel) { model.cancelScan() }
            } else if model.report != nil {
                Button {
                    model.startScan()
                } label: {
                    Label("Scan Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppSection.security.tint)
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

// MARK: - Results

private struct SecurityResultsView: View {
    @Bindable var model: SecurityViewModel
    let report: SecurityReport

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            SecuritySeverityTile(severity: .threat, count: model.count(.threat))
            SecuritySeverityTile(severity: .suspicious, count: model.count(.suspicious))
            SecuritySeverityTile(severity: .recommendation, count: model.count(.recommendation))
            SecuritySeverityTile(severity: .info, count: model.count(.info))
        }

        Text(SecurityReport.summaryLine(threats: model.count(.threat), suspicious: model.count(.suspicious), recommendations: model.count(.recommendation))
             + " · scanned \(SecurityStyle.relative(report.finishedAt))")
            .font(.callout)
            .foregroundStyle(.secondary)

        if report.wasCancelled {
            InfoCallout(style: .warning, title: "Scan stopped", message: "The scan was stopped before it finished, so these results are incomplete.")
        }
        if !report.limitations.isEmpty {
            SecurityLimitationsView(limitations: report.limitations)
        }

        Picker("Section", selection: $model.tab) {
            ForEach(SecurityViewModel.Tab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Results section")

        switch model.tab {
        case .findings: SecurityFindingsTab(model: model, report: report)
        case .persistence: SecurityPersistenceTab(model: model)
        case .applications: SecurityApplicationsTab(model: model)
        case .downloads: SecurityDownloadsTab(model: model)
        }
    }
}

private struct SecuritySeverityTile: View {
    let severity: FindingSeverity
    let count: Int

    var body: some View {
        StatTile(title: SecurityStyle.groupTitle(severity), value: NumberFormatting.count(count),
                 caption: SecurityStyle.groupCaption(severity), symbol: severity.symbolName,
                 tint: count == 0 ? .green : SecurityStyle.color(severity))
    }
}

private struct SecurityLimitationsView: View {
    let limitations: [String]
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(limitations, id: \.self) { note in
                    Label {
                        Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Label("\(limitations.count) thing\(limitations.count == 1 ? "" : "s") couldn't be checked", systemImage: "eye.trianglebadge.exclamationmark")
                .font(.callout.weight(.medium))
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Shared colors and wording for severities.
enum SecurityStyle {
    static func color(_ severity: FindingSeverity) -> Color {
        switch severity {
        case .info: return .gray
        case .recommendation: return .blue
        case .suspicious: return .orange
        case .threat: return .red
        }
    }

    static func groupTitle(_ severity: FindingSeverity) -> String {
        switch severity {
        case .threat: return "Threats"
        case .suspicious: return "Suspicious"
        case .recommendation: return "Recommendations"
        case .info: return "Information"
        }
    }

    static func groupCaption(_ severity: FindingSeverity) -> String {
        switch severity {
        case .threat: return "Adware rule matches"
        case .suspicious: return "Worth checking"
        case .recommendation: return "Settings to improve"
        case .info: return "Good to know"
        }
    }

    /// "just now" for the last minute, otherwise "3 hours ago".
    static func relative(_ date: Date, now: Date = Date()) -> String {
        abs(now.timeIntervalSince(date)) < 60 ? "just now" : DateFormatting.relative(date, to: now)
    }

    static func trustColor(_ category: SecurityTrustCategory) -> Color {
        switch category {
        case .apple, .appStore, .developerIDNotarized: return .green
        case .developerID: return .teal
        case .appleDevelopment, .packageManager, .script, .unknown, .missing: return .gray
        case .adHoc, .unsigned: return .orange
        case .untrustedCertificate, .invalid, .revoked: return .red
        }
    }

    /// Renders inline Markdown (code spans for Terminal commands).
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
