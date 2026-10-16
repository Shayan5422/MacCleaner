import SwiftUI

struct AVScanTab: View {
    var model: AntivirusViewModel

    var body: some View {
        if let result = model.testResult {
            AVTestResultCallout(result: result)
        }
        if model.isScanning, let progress = model.scanProgress {
            AVScanProgressCard(progress: progress, model: model)
        }
        if !model.threats.isEmpty {
            AVThreatList(model: model)
        } else if !model.isScanning, let report = model.lastReport {
            AVScanResultCard(report: report, model: model)
        } else if !model.isScanning {
            AVNoScanYetCard(model: model)
        }
        if let report = model.lastReport, !model.isScanning {
            if !report.usedDefinitions {
                InfoCallout(style: .warning, title: "This scan didn't use virus definitions",
                            message: "Only the built-in EICAR test signature and Mac Cleaner's adware rules were available, so most malware can't be detected. Download the free definitions to scan properly.")
            }
            if !report.limitations.isEmpty {
                AVLimitationsView(limitations: report.limitations, services: model.services)
            }
        }
    }
}

// MARK: - Progress

struct AVScanProgressCard: View {
    var progress: AVScanProgress
    var model: AntivirusViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("\(progress.kind.title) in progress").font(.headline)
                Spacer()
                if let fraction = progress.fraction {
                    Text(NumberFormatting.percent(fraction)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button("Stop", role: .cancel) { model.cancelScan() }
                    .keyboardShortcut(.cancelAction)
            }
            if let fraction = progress.fraction {
                ProgressView(value: fraction).tint(AppSection.antivirus.tint)
            } else {
                ProgressView().progressViewStyle(.linear).tint(AppSection.antivirus.tint)
            }
            HStack(spacing: 0) {
                stat("Files scanned", NumberFormatting.count(progress.filesScanned))
                stat("Data checked", ByteFormatting.string(progress.bytesScanned))
                stat("Threats", NumberFormatting.count(progress.threatsFound), tint: progress.threatsFound > 0 ? .red : .primary)
                stat("Elapsed", AVFormat.duration(progress.elapsed))
                stat("Time left", remaining)
            }
            Text(progress.currentPath.isEmpty ? (progress.listingComplete ? "Finishing…" : "Looking for files…") : PathUtilities.abbreviate(progress.currentPath))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .card()
    }

    private var remaining: String {
        if !progress.listingComplete { return "Counting…" }
        guard let seconds = progress.estimatedRemaining else { return "Estimating…" }
        return seconds < 60 ? "Under a minute" : "About " + AVFormat.duration(seconds)
    }

    private func stat(_ title: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit().foregroundStyle(tint).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Results

struct AVThreatList: View {
    var model: AntivirusViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "xmark.shield.fill").foregroundStyle(.red).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.threats.count == 1 ? "1 threat found" : "\(model.threats.count) threats found").font(.headline)
                    Text("Moving a threat to the Virus Chest stops it from running. You can restore it from there.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.threats.contains(where: { $0.enclosingApp == nil }) {
                    Button {
                        model.moveAllToChest()
                    } label: {
                        Label("Move All to Virus Chest", systemImage: "archivebox")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!model.busyThreatIDs.isEmpty)
                }
            }
            .padding(14)
            Divider()
            LazyVStack(spacing: 0) {
                ForEach(model.threats) { threat in
                    AVThreatRow(threat: threat, model: model)
                    if threat.id != model.threats.last?.id { Divider().padding(.leading, 56) }
                }
            }
        }
        .card(padding: 0)
    }
}

struct AVThreatRow: View {
    let threat: AVThreat
    var model: AntivirusViewModel
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            FileIcon(path: threat.enclosingApp ?? threat.path, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(threat.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    AVCategoryBadge(category: threat.category)
                }
                PathText(path: threat.path)
                Text(detailLine).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if model.busyThreatIDs.contains(threat.id) {
                ProgressView().controlSize(.small)
            } else {
                Button(threat.enclosingApp == nil ? "Move to Virus Chest" : "Move App to Virus Chest") {
                    model.moveToChest(threat, wholeApp: threat.enclosingApp != nil)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)
                Menu {
                    AVThreatMenuItems(threat: threat, model: model)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More actions")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isHovering ? Color.hoverFill : .clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { model.selectedThreat = threat }
        .contextMenu { AVThreatMenuItems(threat: threat, model: model) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(threat.category.badgeTitle): \(threat.name) in \(threat.fileName)")
    }

    private var detailLine: String {
        var parts: [String] = []
        if let member = threat.memberPath { parts.append("Inside the archive: \(member)") }
        if let app = threat.enclosingApp { parts.append("Inside \((app as NSString).lastPathComponent)") }
        parts.append(threat.sourceTitle)
        if threat.foundBy != .scan { parts.append("found by \(threat.foundBy.title)") }
        parts.append(AVFormat.relative(threat.detectedAt))
        return parts.joined(separator: " · ")
    }
}

struct AVThreatMenuItems: View {
    let threat: AVThreat
    var model: AntivirusViewModel

    var body: some View {
        Button("Details…", systemImage: "info.circle") { model.selectedThreat = threat }
        Button("Reveal in Finder", systemImage: "folder") { FinderActions.reveal(threat.path) }
        if threat.enclosingApp != nil {
            Button("Move Only This File to Virus Chest", systemImage: "doc") { model.moveToChest(threat) }
        }
        Divider()
        Button("Ignore Once", systemImage: "eye.slash") { model.ignoreOnce(threat) }
        Button("Always Allow…", systemImage: "checkmark.shield") { model.threatToAllow = threat }
    }
}

struct AVScanResultCard: View {
    let report: AVScanReport
    var model: AntivirusViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: report.wasCancelled ? "pause.circle.fill" : "checkmark.shield.fill")
                .font(.system(size: 30))
                .foregroundStyle(report.wasCancelled ? .orange : .green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(report.wasCancelled ? "Scan stopped, no threats found so far" : "No threats found").font(.headline)
                Text("\(report.kind.title) checked \(NumberFormatting.count(report.filesScanned)) file\(report.filesScanned == 1 ? "" : "s") (\(ByteFormatting.string(report.bytesScanned)) read) in \(AVFormat.duration(report.duration)), \(AVFormat.relative(report.finishedAt)).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let skipped = skippedLine {
                    Text(skipped).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if report.ignoredSignatureDatabases > 0 {
                    Text("\(NumberFormatting.count(report.ignoredSignatureDatabases)) file\(report.ignoredSignatureDatabases == 1 ? " is" : "s are") ClamAV's own signature database\(report.ignoredSignatureDatabases == 1 ? "" : "s"), verified by ClamAV's signature. They contain malware patterns by design, so their matches weren't reported.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let definitions = report.definitionsDescription {
                    Text("Definitions: \(definitions)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .card()
    }

    private var skippedLine: String? {
        var parts: [String] = []
        if report.encryptedArchives > 0 { parts.append("contents of \(NumberFormatting.count(report.encryptedArchives)) password-protected archive\(report.encryptedArchives == 1 ? "" : "s")") }
        if report.partiallyScannedArchives > 0 { parts.append("parts of \(NumberFormatting.count(report.partiallyScannedArchives)) archive\(report.partiallyScannedArchives == 1 ? "" : "s") that are too large, too deeply nested or use unsupported compression") }
        if report.skippedTooLarge > 0 { parts.append("\(NumberFormatting.count(report.skippedTooLarge)) larger than \(model.settings.maxFileSizeMB) MB") }
        if report.skippedCloudOnly > 0 { parts.append("\(NumberFormatting.count(report.skippedCloudOnly)) stored only in the cloud") }
        if report.skippedUnreadable > 0 { parts.append("\(NumberFormatting.count(report.skippedUnreadable)) unreadable") }
        if report.allowedCount > 0 { parts.append("\(report.allowedCount) on your allow list") }
        return parts.isEmpty ? nil : "Not scanned: " + parts.joined(separator: ", ") + "."
    }
}

struct AVNoScanYetCard: View {
    var model: AntivirusViewModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No scan yet").font(.title3.weight(.semibold))
            Text("Quick Scan checks the places where Mac malware usually hides: running programs, startup items, apps, browser extensions, Downloads and Desktop. It usually takes a minute or two.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Button("Start Quick Scan") { model.startQuickScan() }
                .buttonStyle(.borderedProminent)
                .tint(AppSection.antivirus.tint)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .card(padding: 0)
    }
}

struct AVTestResultCallout: View {
    let result: AVProtectionTestResult

    var body: some View {
        if result.detected {
            InfoCallout(style: .success, title: "Protection works",
                        message: "The EICAR test file was detected as \(result.signatureName ?? "a test file")\(result.usedDefinitions ? "" : " by the built-in test signature")"
                            + (result.removedTestFile ? ", and the test file was deleted." : ".")
                            + " EICAR is a harmless file that every antivirus reports; nothing was harmful.")
        } else if result.blockedByOtherSoftware {
            InfoCallout(style: .info, title: "Another antivirus removed the test file",
                        message: "Other security software on this Mac deleted or blocked the EICAR test file before Mac Cleaner could scan it. That software is protecting the Mac too.")
        } else {
            InfoCallout(style: .warning, title: "The test file wasn't detected",
                        message: "The engine didn't report the EICAR test file. Try updating the virus definitions, then test again.")
        }
    }
}
