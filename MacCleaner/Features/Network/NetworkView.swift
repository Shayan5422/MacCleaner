import SwiftUI

/// The Ports & Network page: Ports · Connections · Network Check.
struct NetworkView: View {
    @Bindable var model: NetworkViewModel

    var body: some View {
        PageScroll {
            PageHeader(section: .network, subtitle: subtitle) {
                NetworkHeaderActions(model: model)
            }

            Picker("View", selection: $model.tab) {
                ForEach(NetworkViewModel.Tab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Ports & Network view")

            switch model.tab {
            case .ports:
                PortsTab(page: model, model: model.ports)
            case .connections:
                ConnectionsTab(page: model, model: model.connections)
            case .check:
                NetworkCheckTab(page: model, model: model.check)
            }
        }
        .background {
            // ⌘F focuses the current tab's search field.
            Button("Find") { model.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
        .onAppear { model.pageAppeared() }
        .onDisappear { model.pageDisappeared() }
    }

    private var subtitle: String {
        switch model.tab {
        case .ports: return "Every open port, the project it belongs to, and one-click Stop."
        case .connections: return "Every app's connections, checked against malware feeds."
        case .check: return "Your Wi-Fi, router, DNS, proxies, firewall and open services."
        }
    }
}

/// "Updated 12:03 · Refresh" for the current tab.
private struct NetworkHeaderActions: View {
    let model: NetworkViewModel

    var body: some View {
        HStack(spacing: 10) {
            if isBusy {
                ProgressView().controlSize(.small)
            } else if let date = updated {
                Text("Updated \(date.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 112, alignment: .trailing)
            }
            Button {
                model.refreshCurrentTab()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Scan again (⌘R)")
        }
    }

    private var isBusy: Bool {
        switch model.tab {
        case .ports: return model.ports.isScanning && model.ports.lastUpdated == nil
        case .connections: return model.connections.isScanning && !model.connections.hasScanned
        case .check: return model.check.isChecking
        }
    }

    private var updated: Date? {
        switch model.tab {
        case .ports: return model.ports.lastUpdated
        case .connections: return model.connections.hasScanned ? model.connections.scan.date : nil
        case .check: return model.check.report?.date
        }
    }
}

/// `InfoCallout`'s look with buttons inside it, on the trailing side (like the Full Disk Access banner).
struct NetCallout<Actions: View>: View {
    var style: InfoCallout.Style = .info
    var title: String?
    var message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: style.symbol)
                    .foregroundStyle(style.tint)
                    .font(.system(size: 15))
                VStack(alignment: .leading, spacing: 3) {
                    if let title {
                        Text(title)
                            .font(.callout.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) { actions }
                .fixedSize()
        }
        .padding(12)
        .background(style.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(style.tint.opacity(0.18)))
    }
}
