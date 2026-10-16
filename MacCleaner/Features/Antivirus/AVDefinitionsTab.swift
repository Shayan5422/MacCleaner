import SwiftUI

struct AVDefinitionsTab: View {
    @Bindable var model: AntivirusViewModel

    var body: some View {
        AVUpdaterCard(model: model)
        Card("Sources", symbol: "tray.full") {
            VStack(spacing: 0) {
                ForEach(AVClamAVDatabase.allCases) { database in
                    AVSourceRow(title: database.title, detail: clamavDetail(database), metrics: clamavMetrics(database), toggle: nil)
                    Divider()
                }
                AVSourceRow(title: AVFeedID.malwareBazaarRecent.title, detail: AVFeedID.malwareBazaarRecent.detail,
                            metrics: feedMetrics(.malwareBazaarRecent, noun: "hashes"),
                            toggle: Binding(get: { model.settings.sources.malwareBazaarRecent }, set: { model.setSource(\.malwareBazaarRecent, enabled: $0) }))
                Divider()
                AVSourceRow(title: AVFeedID.malwareBazaarFull.title,
                            detail: AVFeedID.malwareBazaarFull.detail + " About \(ByteFormatting.string(AVFeedID.malwareBazaarFull.typicalDownloadBytes)) to download, about 76 MB on disk.",
                            metrics: feedMetrics(.malwareBazaarFull, noun: "hashes"),
                            toggle: Binding(get: { model.settings.sources.malwareBazaarFull }, set: { model.setSource(\.malwareBazaarFull, enabled: $0) }))
                Divider()
                AVSourceRow(title: "URLhaus (malware sites)", detail: AVFeedID.urlhausOnline.detail + " Used by the Download Shield and the Network page.",
                            metrics: urlhausMetrics,
                            toggle: Binding(get: { model.settings.sources.urlhaus }, set: { model.setSource(\.urlhaus, enabled: $0) }))
                Divider()
                AVSourceRow(title: AVFeedID.threatFoxRecent.title, detail: AVFeedID.threatFoxRecent.detail,
                            metrics: feedMetrics(.threatFoxRecent, noun: "indicators"),
                            toggle: Binding(get: { model.settings.sources.threatFox }, set: { model.setSource(\.threatFox, enabled: $0) }))
            }
            Text("Changes to sources apply at the next update.").font(.caption).foregroundStyle(.secondary)
        }
        if let summary = model.engineSummary ?? model.definitionsState.installed?.summary {
            Card("Scanning database", symbol: "cpu") {
                VStack(alignment: .leading, spacing: 6) {
                    AVInfoRow(label: "Signatures in use", value: NumberFormatting.count(summary.signatureCount))
                    if summary.hashListCount > 0 { AVInfoRow(label: "Malware file hashes", value: NumberFormatting.count(summary.hashListCount)) }
                    if summary.unsupportedSignatureCount > 0 {
                        AVInfoRow(label: "Not supported", value: "\(NumberFormatting.count(summary.unsupportedSignatureCount)) ClamAV signatures use features this engine doesn't support and are skipped.")
                    }
                    AVInfoRow(label: "Prepared", value: DateFormatting.short(summary.builtAt))
                    if let verification = summary.clamavVerification, !verification.isEmpty {
                        AVInfoRow(label: "Verified", value: verification.keys.sorted().map { "\($0): \(Self.describe(verification[$0]!))" }.joined(separator: " · "),
                                  valueColor: verification.values.contains(.structureOnly) ? .orange : .primary)
                    }
                    AVInfoRow(label: "Status", value: model.hasDefinitions ? "Loaded and in use" : (model.engineProblem ?? "Not loaded"),
                              valueColor: model.hasDefinitions ? .green : .orange)
                }
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Virus signatures by ClamAV® (Cisco Talos), GPL-2.0. ClamAV is a registered trademark of Cisco Systems, Inc.; Mac Cleaner uses ClamAV signatures and isn't affiliated with Cisco.")
            Text("Threat feeds by abuse.ch (MalwareBazaar, URLhaus, ThreatFox), CC0.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    static func describe(_ verification: ClamAVVerification) -> String {
        switch verification {
        case .signedContainer: return "signed by ClamAV"
        case .signedIndex: return "patched, signed index"
        case .structureOnly: return "not signed"
        }
    }

    private func clamavDetail(_ database: AVClamAVDatabase) -> String {
        database == .main
            ? "ClamAV's base signature set. Downloaded again only when ClamAV publishes a new version."
            : "New signatures, published several times a week. Updated with small signed patches."
    }

    private func clamavMetrics(_ database: AVClamAVDatabase) -> String {
        let file = model.definitionsState[database]
        guard let version = file.version else { return file.lastError ?? "Not downloaded" }
        var parts = ["Version \(version)"]
        if let count = file.signatureCount { parts.append("\(AVText.compactCount(count)) signatures") }
        if let size = file.fileSize { parts.append(ByteFormatting.string(size) + " on disk") }
        if let updated = file.lastUpdated { parts.append("updated \(AVFormat.relative(updated))") }
        return parts.joined(separator: " · ")
    }

    private func feedMetrics(_ feed: AVFeedID, noun: String) -> String {
        guard feed.isEnabled(in: model.settings.sources) else { return "Off" }
        let file = model.definitionsState[feed]
        guard let checked = file.lastChecked else { return "Not downloaded yet" }
        var parts: [String] = []
        if file.entryCount > 0 { parts.append("\(NumberFormatting.count(file.entryCount)) \(noun)") }
        if file.bytesOnDisk > 0 { parts.append("about \(ByteFormatting.string(file.bytesOnDisk)) on disk") }
        parts.append("checked \(AVFormat.relative(checked))")
        if let error = file.lastError { parts.append(error) }
        return parts.joined(separator: " · ")
    }

    private var urlhausMetrics: String {
        guard model.settings.sources.urlhaus else { return "Off" }
        let urls = model.definitionsState[.urlhausOnline]
        let hosts = model.definitionsState[.urlhausHosts]
        guard let checked = urls.lastChecked ?? hosts.lastChecked else { return "Not downloaded yet" }
        var parts = ["\(NumberFormatting.count(urls.entryCount)) addresses", "\(NumberFormatting.count(hosts.entryCount)) hosts"]
        if urls.bytesOnDisk > 0 { parts.append("about \(ByteFormatting.string(urls.bytesOnDisk)) on disk") }
        parts.append("checked \(AVFormat.relative(checked))")
        return parts.joined(separator: " · ")
    }
}

private struct AVUpdaterCard: View {
    @Bindable var model: AntivirusViewModel

    var body: some View {
        Card("Updates", symbol: "arrow.triangle.2.circlepath", accessory: {
            Button {
                model.definitionsInstalled ? model.updateDefinitions() : model.installDefinitions()
            } label: {
                Text(model.definitionsInstalled ? "Update Now" : "Download Definitions")
            }
            .disabled(model.isUpdatingDefinitions)
        }) {
            HStack(spacing: 8) {
                Text("Updated by").foregroundStyle(.secondary)
                Badge(text: model.activeUpdater.title, symbol: model.activeUpdater == .freshclam ? "checkmark.seal.fill" : "gearshape.fill",
                      tint: model.activeUpdater == .freshclam ? .green : .blue)
                Spacer()
                Toggle("Update automatically", isOn: Binding(get: { model.settings.automaticUpdates },
                                                             set: { model.settings.automaticUpdates = $0; model.scheduleAutomaticUpdates() }))
                    .toggleStyle(.checkbox)
            }
            .font(.callout)
            Text(updaterExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.activeUpdater == .builtIn && model.toolsChecked && model.freshclam == nil {
                HStack(spacing: 10) {
                    if model.brewPath != nil {
                        Button("Install ClamAV with Homebrew…") { model.confirmsHomebrewInstall = true }
                            .disabled(model.homebrewInstall?.isRunning == true)
                    } else {
                        Text("To use freshclam, install Homebrew from brew.sh, then run “brew install clamav” in Terminal.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                AVInfoRow(label: "Last checked", value: model.definitionsState.lastCheck.map { AVFormat.relative($0) } ?? "Never")
                AVInfoRow(label: "Last updated", value: model.definitionsUpdatedAt.map { DateFormatting.short($0) } ?? "Not installed")
                AVInfoRow(label: "Next check", value: nextCheck)
                if let until = model.definitionsState.cdnRetryAfter, until > Date() {
                    AVInfoRow(label: "ClamAV servers", value: "Asked to wait until \(DateFormatting.short(until))", valueColor: .orange)
                }
            }
            if let progress = model.updateProgress, model.isUpdatingDefinitions {
                AVUpdateProgressView(progress: progress)
            } else if let problem = model.updateProblem {
                InfoCallout(style: .warning, message: problem)
            } else if let message = model.updateMessage {
                InfoCallout(style: .success, message: message)
            }
        }
    }

    private var updaterExplanation: String {
        switch model.activeUpdater {
        case .freshclam:
            let version = model.freshclam?.version.map { " (\($0))" } ?? ""
            return "Mac Cleaner runs ClamAV's own updater\(version) with a private configuration that only writes to Mac Cleaner's folder. It downloads small patches and follows ClamAV's download limits."
        case .builtIn:
            if model.freshclam != nil && !model.settings.useFreshclam {
                return "freshclam is installed, but “Use freshclam when it's installed” is off in Settings › Antivirus."
            }
            return "ClamAV recommends its own updater, freshclam. Installing ClamAV with Homebrew lets Mac Cleaner use it. Until then, the built-in updater checks for new versions at most every 4 hours, applies ClamAV's signed patches and downloads a full database at most once a day."
        }
    }

    private var nextCheck: String {
        guard model.settings.automaticUpdates, model.definitionsState.firstInstallRequested else { return "When you click Update Now" }
        guard let last = model.definitionsState.lastVersionCheck else { return "Within the hour" }
        let next = last.addingTimeInterval(AVUpdatePolicy.checkInterval)
        return next <= Date() ? "Within the hour" : "Around \(next.formatted(date: .omitted, time: .shortened))"
    }
}

private struct AVSourceRow: View {
    var title: String
    var detail: String
    var metrics: String
    var toggle: Binding<Bool>?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(metrics).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 12)
            if let toggle {
                Toggle(title, isOn: toggle)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            } else {
                Badge(text: "Required", symbol: nil, tint: .gray)
            }
        }
        .padding(.vertical, 8)
    }
}

/// `brew install clamav` with live output.
struct AVHomebrewInstallSheet: View {
    @Bindable var run: AVHomebrewInstallRun
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(section: .antivirus, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Installing ClamAV with Homebrew").font(.title3.weight(.semibold))
                    Text(run.displayCommand).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if let succeeded = run.succeeded {
                InfoCallout(style: succeeded ? .success : .warning,
                            message: succeeded ? "ClamAV is installed. Mac Cleaner will use freshclam for the next update."
                                : "Homebrew couldn't finish. Its output is below; you can also run the command in Terminal.")
            } else {
                ProgressView().progressViewStyle(.linear).tint(AppSection.antivirus.tint)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(run.lines.enumerated()), id: \.offset) { index, line in
                            Text(line).font(.caption.monospaced()).textSelection(.enabled).id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onChange(of: run.lines.count) { _, count in proxy.scrollTo(count - 1, anchor: .bottom) }
            }
            HStack {
                if run.succeeded == false {
                    Button("Copy Command") { FinderActions.copyPath(run.displayCommand) }
                }
                Spacer()
                if run.isRunning {
                    Button("Stop", role: .cancel) { run.cancel() }
                } else {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(22)
        .frame(width: 600, height: 440)
        .interactiveDismissDisabled(run.isRunning)
    }
}
