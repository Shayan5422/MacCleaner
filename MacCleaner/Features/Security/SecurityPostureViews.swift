import SwiftUI

/// The state of macOS's built-in protections, with shortcuts to the right settings.
struct SecurityPostureSection: View {
    @Bindable var model: SecurityViewModel

    var body: some View {
        Card("macOS Protections", symbol: "lock.shield") {
            Button {
                Task { await model.refreshPosture() }
            } label: {
                Label("Check Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.isCheckingPosture || model.isScanning)
            .help("Check the protections again")
        } content: {
            if let posture = model.posture {
                SecurityPostureOverview(posture: posture)
                // Five protections: one row when they fit, otherwise 3 + 2 that fill the width.
                BalancedGrid(minimumItemWidth: 168, spacing: 10) {
                    ForEach(posture.protections) { protection in
                        SecurityProtectionTile(protection: protection, model: model)
                    }
                }
            } else if model.isCheckingPosture {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking Gatekeeper, System Integrity Protection, FileVault, the firewall and updates…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Button("Check Protections") { Task { await model.refreshPosture() } }
            }
        }
    }
}

private struct SecurityPostureOverview: View {
    let posture: SecurityPosture

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            RingGauge(fraction: posture.score, tint: tint, lineWidth: 8) {
                VStack(spacing: 0) {
                    Text("\(posture.enabledCount)/\(posture.totalCount)")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit()
                    Text("on").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 84, height: 84)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(posture.summary)

            VStack(alignment: .leading, spacing: 5) {
                Text(posture.summary).font(.headline)
                Text(headline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundStyle(.secondary)
                    Text(xprotectText)
                        .font(.caption)
                        .foregroundStyle(xprotectIsStale ? .orange : .secondary)
                }
                .help("XProtect is macOS's built-in malware scanner. Apple updates its definitions in the background.")
            }
            Spacer(minLength: 0)
        }
    }

    private var tint: Color {
        if posture.enabledCount == posture.totalCount { return .green }
        return posture.protections.contains { $0.isOn == false } ? .orange : AppSection.security.tint
    }

    private var headline: String {
        let off = posture.protections.filter { $0.isOn == false }.map(\.kind.title)
        if off.isEmpty && posture.undeterminedCount == 0 { return "All of macOS's core protections are on." }
        if off.isEmpty { return "Every protection that could be checked is on." }
        return "Off: " + off.joined(separator: ", ") + ". Turning \(off.count == 1 ? "it" : "them") on makes this Mac safer."
    }

    private var xprotectIsStale: Bool { (posture.xprotectAgeDays() ?? 0) > 60 }

    private var xprotectText: String {
        var text = "XProtect"
        if let version = posture.xprotectVersion { text += " definitions version \(version)" }
        if let updated = posture.xprotectUpdated {
            text += ", updated \(DateFormatting.relative(updated))"
        } else if posture.xprotectVersion == nil {
            text += " version couldn't be read"
        }
        return text
    }
}

private struct SecurityProtectionTile: View {
    let protection: SecurityProtectionStatus
    var model: SecurityViewModel
    @State private var showsHowTo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: protection.kind.symbolName)
                    .foregroundStyle(color)
                    .frame(width: 18)
                Text(protection.kind.shortTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Badge(text: protection.statusText, symbol: statusSymbol, tint: color)
            }
            Text(protection.detail ?? protection.kind.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            if protection.isOn != true {
                HStack(spacing: 6) {
                    if let pane = protection.kind.settingsPane {
                        Button("Open Settings") { model.open(pane) }
                    }
                    Button("How to Turn On") { showsHowTo = true }
                        .popover(isPresented: $showsHowTo, arrowEdge: .bottom) {
                            Text(SecurityStyle.markdown(protection.kind.howToTurnOn))
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(14)
                                .frame(width: 340)
                        }
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Metrics.tileRadius, style: .continuous).fill(color.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: Metrics.tileRadius, style: .continuous).strokeBorder(color.opacity(0.16)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(protection.kind.title): \(protection.statusText)")
    }

    private var color: Color {
        switch protection.isOn {
        case true?: return .green
        case false?: return .orange
        case nil: return .gray
        }
    }

    private var statusSymbol: String {
        switch protection.isOn {
        case true?: return "checkmark.circle.fill"
        case false?: return "exclamationmark.triangle.fill"
        case nil: return "questionmark.circle"
        }
    }
}
