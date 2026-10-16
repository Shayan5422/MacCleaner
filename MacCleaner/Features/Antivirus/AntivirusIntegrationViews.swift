import AppKit
import SwiftUI

// Views other parts of the app embed: the Dashboard card, the menu bar section and the
// real-time detection alert.

/// Compact Antivirus status for the Dashboard.
struct AntivirusDashboardCard: View {
    var model: AntivirusViewModel

    var body: some View {
        let state = model.protectionState
        Card("Antivirus", symbol: "shield.lefthalf.filled", fillsHeight: true, accessory: {
            Button("Open") { model.navigate?(.antivirus) }.buttonStyle(.link)
        }) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: state.symbolName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(state.tint)
                    .frame(width: 40, height: 40)
                    .background(state.tint.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title).font(.headline)
                    Text(model.statusExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 6) {
                KeyValueRow(key: "Real-time protection", value: model.isRealTimeProtectionOn ? "On" : "Off",
                            valueColor: model.isRealTimeProtectionOn ? .primary : .orange)
                KeyValueRow(key: "Definitions", value: model.definitionsInstalled ? (model.definitionsUpdatedAt.map { "Updated \(AVFormat.age($0))" } ?? "Installed") : "Not installed",
                            valueColor: model.definitionsInstalled && (model.definitionsAgeDays ?? 0) < 7 ? .primary : .orange)
                KeyValueRow(key: "Last scan", value: model.lastScan.map { "\($0.threatsFound == 0 ? "Clean" : "\($0.threatsFound) found"), \(AVFormat.relative($0.finishedAt))" } ?? "Never")
            }
            HStack(spacing: 8) {
                if model.isScanning, let progress = model.scanProgress {
                    ProgressView().controlSize(.small)
                    Text("\(NumberFormatting.count(progress.filesScanned, "file")) checked").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { model.cancelScan() }.controlSize(.small)
                } else if model.activeThreatCount > 0 {
                    Button("Review Threats") { model.tab = .scan; model.navigate?(.antivirus) }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    Spacer()
                } else if !model.definitionsInstalled {
                    Button("Set Up Antivirus") { model.navigate?(.antivirus) }
                        .buttonStyle(.borderedProminent)
                        .tint(AppSection.antivirus.tint)
                    Spacer()
                } else {
                    Button("Quick Scan") { model.startQuickScan() }
                        .buttonStyle(.borderedProminent)
                        .tint(AppSection.antivirus.tint)
                    Spacer()
                }
            }
        }
    }
}

/// The antivirus part of the menu bar popover (about 360 pt wide): status, real-time
/// protection, definitions, a Quick Scan with progress, threats and the Virus Chest.
struct AntivirusMenuBarSection: View {
    var model: AntivirusViewModel

    init(model: AntivirusViewModel) {
        self.model = model
    }

    var body: some View {
        let state = model.protectionState
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: state.symbolName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(state.tint)
                    .frame(width: 32, height: 32)
                    .background(state.tint.opacity(0.15), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title).font(.headline)
                    Text(state == .notSetUp ? "Virus definitions aren't installed" : model.definitionsAgeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if model.definitionsInstalled {
                    Button {
                        model.updateDefinitions()
                    } label: {
                        if model.isUpdatingDefinitions { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isUpdatingDefinitions)
                    .help("Update the virus definitions")
                    .accessibilityLabel("Update virus definitions")
                }
            }

            HStack {
                Label("Real-time protection", systemImage: "shield.lefthalf.filled")
                    .font(.callout)
                Spacer()
                Toggle("Real-time protection", isOn: Binding(get: { model.isRealTimeProtectionOn }, set: { model.setRealTimeProtection($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            if model.isScanning, let progress = model.scanProgress {
                VStack(alignment: .leading, spacing: 5) {
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction).tint(AppSection.antivirus.tint)
                    } else {
                        ProgressView().progressViewStyle(.linear).tint(AppSection.antivirus.tint)
                    }
                    HStack {
                        Text("\(progress.kind.title): \(NumberFormatting.count(progress.filesScanned, "file")) · \(progress.threatsFound) threat\(progress.threatsFound == 1 ? "" : "s")")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(progress.threatsFound > 0 ? .red : .secondary)
                        Spacer()
                        Button("Stop") { model.cancelScan() }.controlSize(.small)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Button {
                        model.startQuickScan()
                    } label: {
                        Label("Quick Scan", systemImage: "bolt.shield").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppSection.antivirus.tint)
                    if !model.definitionsInstalled {
                        Button("Set Up…") { model.navigate?(.antivirus) }
                    }
                }
                if let last = model.lastScan {
                    Text("\(last.kind.title), \(AVFormat.relative(last.finishedAt)): \(last.resultLine)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if model.activeThreatCount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(model.activeThreatCount == 1 ? "1 threat needs your decision" : "\(model.activeThreatCount) threats need your decision")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button("Review") {
                        model.tab = .scan
                        model.navigate?(.antivirus)
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack(spacing: 6) {
                Image(systemName: "archivebox").foregroundStyle(.secondary)
                Text(model.chestCount == 0 ? "Virus Chest is empty" : model.chestCount == 1 ? "1 item in the Virus Chest" : "\(model.chestCount) items in the Virus Chest")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.chestCount > 0 {
                    Button("Open") {
                        model.tab = .chest
                        model.navigate?(.antivirus)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
        .frame(width: 332, alignment: .leading)
    }
}

/// One line for compact places: status and the real-time protection switch.
struct AntivirusMenuBarStatus: View {
    var model: AntivirusViewModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: model.protectionState.symbolName).foregroundStyle(model.protectionState.tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.protectionState.title).font(.callout.weight(.medium))
                Text(model.definitionsAgeText).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Real-time protection", isOn: Binding(get: { model.isRealTimeProtectionOn }, set: { model.setRealTimeProtection($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }
}

extension View {
    /// Shows an alert when the shields detect a threat. Attach it once near the root of the
    /// window; the Antivirus page attaches one too and defers to the root's when both exist.
    func antivirusAlerts(_ model: AntivirusViewModel) -> some View {
        modifier(AVShieldAlertModifier(model: model))
    }
}

private struct AVShieldAlertModifier: ViewModifier {
    @Bindable var model: AntivirusViewModel
    @State private var presenter = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { model.registerAlertPresenter(presenter) }
            .onDisappear { model.unregisterAlertPresenter(presenter) }
            .alert(
                model.shieldAlert?.title ?? "",
                isPresented: Binding(get: { model.shieldAlert != nil && model.primaryAlertPresenter == presenter },
                                     set: { if !$0 { model.shieldAlert = nil } }),
                presenting: model.shieldAlert
            ) { alert in
                Button(alert.wasQuarantined ? "Open Virus Chest" : "Review") {
                    model.shieldAlert = nil
                    model.tab = alert.wasQuarantined ? .chest : .scan
                    model.navigate?(.antivirus)
                    NSApplication.shared.activate()
                }
                Button("OK", role: .cancel) { model.shieldAlert = nil }
            } message: { alert in
                Text(alert.message)
            }
    }
}
