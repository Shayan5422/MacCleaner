import AppKit
import SwiftUI

/// The Network Check tab: the current connection, Wi-Fi security, router, DNS, proxies, firewall, services other
/// devices can reach, and the devices this Mac talked to — each explained, with what to do.
struct NetworkCheckTab: View {
    let page: NetworkViewModel
    let model: NetworkCheckModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            if let report = model.report {
                hero(report)
                Card {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(report.items.filter { $0.kind != .devices }.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().padding(.leading, 40) }
                            NetCheckRow(item: item, model: model)
                        }
                    }
                }
                devicesCard(report)
                InfoCallout(style: .info, message: "Network Check reads this Mac's own settings and caches. It doesn't scan "
                    + "other devices, probe your router or send anything to the network"
                    + (page.preferences.reverseDNS ? ", except DNS queries for device names (Look up host names is on)." : "."))
            } else {
                ScanProgressCard(title: "Checking your network…",
                                 message: "Reading the connection, router, DNS, proxies, firewall and open ports.",
                                 fraction: nil, tint: AppSection.network.tint)
            }
        }
    }

    // MARK: Hero

    private func hero(_ report: NetCheckReport) -> some View {
        let count = report.attentionCount
        let tint: Color = count == 0 ? .green : (report.items.contains { $0.severity == .risk } ? .red : .orange)
        return HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().fill(tint.opacity(0.14))
                Image(systemName: count == 0 ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(count == 0 ? "No problems found" : "\(count) thing\(count == 1 ? "" : "s") to check")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(heroSubtitle(report))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text("Checked")
                    PortTimeAgoText(date: report.date)
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            if model.isChecking {
                ProgressView().controlSize(.small)
            }
            Button {
                model.check()
            } label: {
                Label("Check Again", systemImage: "arrow.clockwise")
            }
            .disabled(model.isChecking)
        }
        .padding(Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Color.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 1))
    }

    private func heroSubtitle(_ report: NetCheckReport) -> String {
        var parts: [String] = []
        if let interface = report.interface {
            if interface.kind == .wifi, let wifi = report.wifi {
                parts.append("Wi-Fi " + (wifi.ssid.map { "“\($0)” " } ?? "") + "· \(wifi.security.title)")
            } else {
                parts.append(interface.kind == .vpn ? "VPN" : interface.displayName)
            }
        } else {
            parts.append("Not connected")
        }
        if let router = report.router { parts.append("Router \(router.address)") }
        let others = report.devices.filter { !$0.isThisMac }.count
        parts.append(others == 1 ? "1 other device seen" : "\(others) other devices seen")
        return parts.joined(separator: " · ")
    }

    // MARK: Devices

    private func devicesCard(_ report: NetCheckReport) -> some View {
        let item = report.items.first { $0.kind == .devices }
        return Card("Devices on This Network", symbol: "desktopcomputer.and.iphone") {
            Text(item?.status ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                if let item {
                    Text(item.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if report.devices.isEmpty {
                    Text("No devices in the address cache yet.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                        GridRow {
                            Text("Address").gridColumnAlignment(.leading)
                            Text("Hardware address")
                            Text("Name")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(report.devices) { device in
                            GridRow {
                                HStack(spacing: 6) {
                                    Image(systemName: device.isRouter ? "wifi.router" : device.isThisMac ? "laptopcomputer" : "circle.fill")
                                        .font(.system(size: device.isRouter || device.isThisMac ? 12 : 5))
                                        .foregroundStyle(device.isRouter || device.isThisMac ? AnyShapeStyle(AppSection.network.tint) : AnyShapeStyle(.tertiary))
                                        .frame(width: 16)
                                    Text(device.address).font(.callout.monospacedDigit()).textSelection(.enabled)
                                }
                                Text(device.macAddress).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                HStack(spacing: 6) {
                                    if device.isThisMac { Badge(text: "This Mac", tint: AppSection.network.tint) }
                                    if device.isRouter { Badge(text: "Router", tint: .blue) }
                                    if let name = model.deviceNames[device.address] {
                                        Text(name).font(.callout).lineLimit(1).truncationMode(.middle)
                                    } else if !device.isThisMac && !device.isRouter {
                                        Text(page.preferences.reverseDNS ? "No name" : "—")
                                            .font(.callout)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .contextMenu {
                                Button("Copy Address") { model.copy(device.address) }
                                Button("Copy Hardware Address") { model.copy(device.macAddress) }
                            }
                        }
                    }
                }
                if !page.preferences.reverseDNS {
                    Text("Turn on “Look up host names” in Settings › Ports & Network to show device names (sends DNS queries).")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// One check: severity, title and status, what was found, what to do, details and actions.
private struct NetCheckRow: View {
    let item: NetCheckItem
    let model: NetworkCheckModel

    private var tint: Color {
        switch item.severity {
        case .good: return .green
        case .info: return .secondary
        case .attention: return .orange
        case .risk: return .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.severity.symbolName)
                .font(.system(size: 18))
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.title).font(.headline)
                    Badge(text: item.status, tint: item.severity == .info ? .gray : tint)
                }
                Text(item.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let recommendation = item.recommendation {
                    Text(recommendation)
                        .font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !item.details.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(item.details, id: \.self) { detail in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•").foregroundStyle(.tertiary)
                                Text(detail)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(item.actions, id: \.self) { action in
                    Button(action.title) { model.open(action) }
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 10)
    }
}
