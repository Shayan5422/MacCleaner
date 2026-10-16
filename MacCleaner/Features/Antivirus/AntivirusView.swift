import SwiftUI
import UniformTypeIdentifiers

/// The Antivirus page.
struct AntivirusView: View {
    @Bindable var model: AntivirusViewModel
    /// Guardian's Web Shield, shown with the other shields.
    var webShield: WebShieldModel? = nil
    @State private var isDropTargeted = false

    var body: some View {
        PageScroll {
            PageHeader(section: .antivirus, subtitle: "Scans for malware with free, automatically updated virus definitions and watches new files as they arrive.") {
                AVHeaderActions(model: model)
            }
            if let message = model.statusMessage {
                AVStatusBanner(message: message) { model.statusMessage = nil }
            }
            AVHeroCard(model: model, isDropTargeted: isDropTargeted)
            if !model.definitionsInstalled {
                AVFirstRunCard(model: model)
            }
            AVStatusTiles(model: model)
            Picker("Section", selection: $model.tab) {
                ForEach(AntivirusViewModel.Tab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Antivirus section")

            switch model.tab {
            case .scan: AVScanTab(model: model)
            case .shields:
                AVShieldsTab(model: model)
                if let webShield { WebShieldCard(model: webShield) }
            case .chest: AVChestTab(model: model)
            case .definitions: AVDefinitionsTab(model: model)
            case .history: AVHistoryTab(model: model)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let paths = urls.filter(\.isFileURL).map(\.path)
            guard !paths.isEmpty, !model.isScanning else { return false }
            model.scan(paths: paths)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .task { model.start() }
        .sheet(item: $model.selectedThreat) { threat in
            AVThreatDetailSheet(threat: threat, model: model)
        }
        .sheet(item: $model.homebrewInstall) { run in
            AVHomebrewInstallSheet(run: run)
        }
        .confirmationDialog(
            "Always allow “\(model.threatToAllow?.fileName ?? "")”?",
            isPresented: Binding(get: { model.threatToAllow != nil && model.selectedThreat == nil }, set: { if !$0 { model.threatToAllow = nil } }),
            titleVisibility: .visible,
            presenting: model.threatToAllow
        ) { threat in
            Button("Always Allow") { model.alwaysAllow(threat) }
            Button("Cancel", role: .cancel) { model.threatToAllow = nil }
        } message: { threat in
            Text("Mac Cleaner won't report this exact file again (\(threat.name)). Only do this if you're sure it's safe; a changed copy would be checked again.")
        }
        .confirmationDialog(
            "Delete “\(model.chestItemToDelete?.name ?? "")” permanently?",
            isPresented: Binding(get: { model.chestItemToDelete != nil }, set: { if !$0 { model.chestItemToDelete = nil } }),
            titleVisibility: .visible,
            presenting: model.chestItemToDelete
        ) { item in
            Button("Delete Permanently", role: .destructive) { model.deleteFromChest(item) }
            Button("Cancel", role: .cancel) { model.chestItemToDelete = nil }
        } message: { _ in
            Text("The stored copy is deleted and can't be restored.")
        }
        .confirmationDialog(
            "Install ClamAV with Homebrew?",
            isPresented: $model.confirmsHomebrewInstall,
            titleVisibility: .visible
        ) {
            Button("Install") { model.installClamAVWithHomebrew() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Mac Cleaner will run “brew install clamav”. Homebrew downloads ClamAV and its dependencies; this can take a few minutes. Mac Cleaner then updates the virus definitions with ClamAV's own updater, freshclam.")
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil; model.errorPath = nil } }),
            presenting: model.errorMessage
        ) { _ in
            if let path = model.errorPath {
                Button("Reveal in Finder") { FinderActions.reveal(path) }
            }
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .alert(
            "Choose Another Folder?",
            isPresented: Binding(get: { model.restoreNeedingFolder != nil && model.errorMessage == nil }, set: { if !$0 { model.restoreNeedingFolder = nil } }),
            presenting: model.restoreNeedingFolder
        ) { item in
            Button("Choose Folder…") {
                model.restoreNeedingFolder = nil
                model.restore(item, chooseFolder: true)
            }
            Button("Cancel", role: .cancel) { model.restoreNeedingFolder = nil }
        } message: { item in
            Text("“\(item.name)” can't go back to its original place. Choose where to restore it.")
        }
        .antivirusAlerts(model)
    }
}

private struct AVHeaderActions: View {
    var model: AntivirusViewModel

    var body: some View {
        HStack(spacing: 10) {
            if let last = model.lastScan, !model.isScanning {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Last scan").font(.caption2).foregroundStyle(.secondary)
                    Text(AVFormat.relative(last.finishedAt)).font(.caption)
                }
                .accessibilityElement(children: .combine)
            }
            Button {
                model.testProtection()
            } label: {
                if model.isTestingProtection {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Test Protection", systemImage: "checkmark.seal")
                }
            }
            .disabled(model.isTestingProtection)
            .help("Scans the harmless EICAR test file to show that detection works.")
        }
    }
}

// MARK: - Hero

struct AVHeroCard: View {
    var model: AntivirusViewModel
    var isDropTargeted: Bool

    var body: some View {
        let state = model.protectionState
        HStack(alignment: .center, spacing: 20) {
            ZStack {
                Circle().fill(state.tint.opacity(0.14))
                Image(systemName: state.symbolName)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(state.tint)
                    .symbolRenderingMode(.hierarchical)
            }
            .frame(width: 68, height: 68)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.title)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(model.statusExplanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                AVScanButtons(model: model)
                Label(isDropTargeted ? "Drop to scan these items" : "You can also drop files or folders on this page to scan them.",
                      systemImage: isDropTargeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                    .font(.caption)
                    .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .fill(LinearGradient(colors: [state.tint.opacity(0.10), Color.cardBackground], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(isDropTargeted ? Color.accentColor : state.tint.opacity(0.22), style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: isDropTargeted ? [6, 4] : []))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Protection status: \(state.title). \(model.statusExplanation)")
    }
}

struct AVScanButtons: View {
    var model: AntivirusViewModel

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.startQuickScan()
            } label: {
                Label("Quick Scan", systemImage: "bolt.shield")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppSection.antivirus.tint)
            .controlSize(.large)
            .keyboardShortcut("r", modifiers: .command)
            Button("Full Scan") { model.startFullScan() }
                .controlSize(.large)
            Button("Scan Files…") { model.chooseAndScan() }
                .controlSize(.large)
            let volumes = model.scannableVolumes
            if !volumes.isEmpty {
                Menu {
                    ForEach(volumes) { volume in
                        Button(volume.name, systemImage: volume.symbolName) { model.scan(volume: volume) }
                    }
                } label: {
                    Text("Scan Drive")
                }
                .menuStyle(.button)
                .fixedSize()
                .controlSize(.large)
            }
        }
        .disabled(model.isScanning)
    }
}

// MARK: - Tiles

struct AVStatusTiles: View {
    var model: AntivirusViewModel

    var body: some View {
        TileRow {
            AVStatusTile(title: "Real-time Shield", value: model.isRealTimeProtectionOn ? "On" : "Off",
                         caption: shieldCaption, symbol: "shield.lefthalf.filled",
                         tint: model.isRealTimeProtectionOn ? .green : .orange) {
                Toggle("Real-time protection", isOn: Binding(get: { model.isRealTimeProtectionOn }, set: { model.setRealTimeProtection($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            AVStatusTile(title: "Virus definitions", value: definitionsValue, caption: definitionsCaption,
                         symbol: "arrow.triangle.2.circlepath", tint: definitionsTint) {
                Button {
                    model.definitionsInstalled ? model.updateDefinitions() : model.installDefinitions()
                } label: {
                    if model.isUpdatingDefinitions { ProgressView().controlSize(.small) } else { Text(model.definitionsInstalled ? "Update Now" : "Download") }
                }
                .controlSize(.small)
                .disabled(model.isUpdatingDefinitions)
            }
            AVStatusTile(title: "Last scan", value: lastScanValue, caption: lastScanCaption, symbol: "clock", tint: lastScanTint) { EmptyView() }
            AVStatusTile(title: "Virus Chest", value: model.chestCount == 1 ? "1 item" : "\(NumberFormatting.count(model.chestCount)) items",
                         caption: model.chestCount == 0 ? "Nothing quarantined" : "Can't run; restore any time",
                         symbol: "archivebox", tint: .purple) {
                if model.chestCount > 0 {
                    Button("Open") { model.tab = .chest }
                        .controlSize(.small)
                }
            }
        }
    }

    private var shieldCaption: String {
        guard model.isRealTimeProtectionOn else { return model.definitionsInstalled ? "New files aren't checked" : "Starts with definitions" }
        if !model.shieldStatistics.deniedFolders.isEmpty { return "Some folders need permission" }
        return "\(NumberFormatting.count(model.shieldStatistics.filesScanned, "file")) checked"
    }

    private var definitionsValue: String {
        if model.isUpdatingDefinitions { return "Updating…" }
        guard model.definitionsInstalled else { return "Not installed" }
        if let daily = model.definitionsState.installed?.clamavVersions["daily"] { return "Version \(daily)" }
        return "Installed"
    }

    private var definitionsCaption: String {
        guard model.definitionsInstalled else { return "Free ClamAV and abuse.ch data" }
        var parts: [String] = []
        if let count = model.signatureCount { parts.append("\(AVText.compactCount(count)) signatures") }
        if let date = model.definitionsUpdatedAt { parts.append("updated \(AVFormat.age(date))") }
        return parts.joined(separator: " · ")
    }

    private var definitionsTint: Color {
        guard model.definitionsInstalled else { return .gray }
        return (model.definitionsAgeDays ?? 0) >= 7 ? .orange : .blue
    }

    private var lastScanValue: String {
        guard let last = model.lastScan else { return "Never" }
        if last.threatsFound > 0 { return last.threatsFound == 1 ? "1 threat" : "\(last.threatsFound) threats" }
        return last.wasCancelled ? "Stopped" : "Clean"
    }

    private var lastScanTint: Color {
        guard let last = model.lastScan else { return .gray }
        if last.threatsFound > 0 { return .red }
        return last.wasCancelled ? .orange : .green
    }

    private var lastScanCaption: String {
        guard let last = model.lastScan else { return "Run a Quick Scan to start" }
        return "\(last.kind.title), \(AVFormat.relative(last.finishedAt))"
    }
}

// MARK: - First run

struct AVFirstRunCard: View {
    var model: AntivirusViewModel

    private var estimate: Int64 {
        var total = AVClamAVDatabase.allCases.reduce(Int64(0)) { $0 + $1.typicalDownloadBytes }
        for feed in AVFeedID.allCases where feed.isEnabled(in: model.settings.sources) { total += feed.typicalDownloadBytes }
        return total
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(AppSection.antivirus.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set up virus definitions").font(.title3.weight(.semibold))
                    Text("Mac Cleaner detects malware with free, public data. It's downloaded once, then kept up to date automatically while Mac Cleaner runs. Only these files are downloaded; nothing about your Mac or your files is sent anywhere.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                AVSourceLine(symbol: "shield.lefthalf.filled", title: "ClamAV® signatures",
                             detail: "main and daily databases from database.clamav.net (Cisco Talos), about 112 MB")
                if model.settings.sources.malwareBazaarRecent {
                    AVSourceLine(symbol: "number", title: "MalwareBazaar", detail: "hashes of new malware samples from bazaar.abuse.ch, under 1 MB")
                }
                if model.settings.sources.urlhaus || model.settings.sources.threatFox {
                    AVSourceLine(symbol: "network.badge.shield.half.filled", title: "URLhaus and ThreatFox",
                                 detail: "malware sites and command-and-control servers from abuse.ch, about 8 MB")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let progress = model.updateProgress, model.isUpdatingDefinitions {
                AVUpdateProgressView(progress: progress)
            } else if let problem = model.updateProblem {
                InfoCallout(style: .warning, title: "The virus definitions couldn't be installed", message: problem)
            }
            HStack {
                Button {
                    model.installDefinitions()
                } label: {
                    Text("Download Virus Definitions (≈ \(ByteFormatting.string(estimate)))")
                        .font(.headline)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppSection.antivirus.tint)
                .controlSize(.large)
                .disabled(model.isUpdatingDefinitions)
                Spacer()
            }
            Text("Until then, Quick Scan uses only the built-in EICAR test signature and Mac Cleaner's adware rules, which can't detect most malware.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 0)
    }
}

struct AVSourceLine: View {
    var symbol: String
    var title: String
    var detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            Text(title).font(.callout.weight(.medium))
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AVUpdateProgressView: View {
    var progress: AVUpdateProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fraction = progress.fraction {
                ProgressView(value: max(0, min(1, fraction))).tint(AppSection.antivirus.tint)
            } else {
                ProgressView().progressViewStyle(.linear).tint(AppSection.antivirus.tint)
            }
            HStack {
                Text(progress.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if progress.bytesReceived > 0 {
                    Text(progress.bytesExpected.map { "\(ByteFormatting.string(progress.bytesReceived)) of \(ByteFormatting.string($0))" }
                         ?? ByteFormatting.string(progress.bytesReceived))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
