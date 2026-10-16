import AppKit
import SwiftUI

/// The Ports section of Mac Cleaner's menu bar popover (about 360 pt wide): open project ports with one-click Stop,
/// like PortPilot's panel. It scans at the page's refresh rate while its window is on screen; the counts it shows
/// stay current in the background once `NetworkViewModel.start()` ran.
struct NetworkMenuBarSection: View {
    let model: NetworkViewModel

    @State private var query = ""
    @State private var lookup: PortLookup?
    @State private var lookupTask: Task<Void, Never>?
    @State private var holdsClaim = false
    @State private var showsServices = false

    /// Rows shown before "+N more".
    private static let maxProjectRows = 6
    private static let maxServiceRows = 5

    private var ports: PortsModel { model.ports }

    init(model: NetworkViewModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            searchField
            if let lookup {
                NetMenuLookupView(lookup: lookup, model: ports)
            }
            if !ports.hasScanned {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading open ports…").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else {
                list
            }
            if let banner = ports.banner {
                NetMenuBanner(banner: banner, model: ports)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PortWindowVisibilityReader { visible in setClaim(visible) })
        .onDisappear { setClaim(false) }
        .onChange(of: query) { _, newValue in updateLookup(newValue) }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Ports")
                .font(.system(size: 13, weight: .semibold))
            if let countText {
                Text(countText)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button("Open Ports & Network") { model.navigate?(.network) }
                .buttonStyle(.link)
                .font(.system(size: 12))
        }
    }

    /// "3 project ports" (the rows listed first); nothing before the first scan or when none are open.
    private var countText: String? {
        let count = model.openProjectPortCount
        guard ports.hasScanned, count > 0 else { return nil }
        return count == 1 ? "1 project port" : "\(count) project ports"
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Port or name", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isPortQuery = PortsModel.portQuery(trimmed) != nil
        let hidden = Set(model.preferences.hiddenGroupIDs)
        let all = ports.snapshot.groups.filter { !hidden.contains($0.id) }
            .sorted(by: PortsModel.sortPredicate(model.preferences.sortOrder))
        let matches = trimmed.isEmpty ? all : all.filter { PortsModel.matches($0, query: trimmed) }
        let projects = matches.filter { $0.category == .project }
        let services = matches.filter { $0.category == .service }

        if !trimmed.isEmpty && !isPortQuery {
            // Searching: everything that matches, apps and system included.
            let found = matches.prefix(Self.maxProjectRows + Self.maxServiceRows)
            if found.isEmpty {
                Text("Nothing matches “\(query)”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 1) {
                    ForEach(Array(found)) { group in NetMenuGroupRow(group: group, model: ports) }
                }
            }
        } else if !isPortQuery {
            if projects.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                    Text("No project ports are open")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 1) {
                    ForEach(projects.prefix(Self.maxProjectRows)) { group in
                        NetMenuGroupRow(group: group, model: ports)
                    }
                }
                if projects.count > Self.maxProjectRows {
                    moreButton(projects.count - Self.maxProjectRows, noun: "project")
                }
            }
            if !services.isEmpty {
                servicesSection(services)
            }
        }
    }

    private func servicesSection(_ services: [PortListenerGroup]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { showsServices.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(showsServices ? 90 : 0))
                    Text("Background Services")
                        .font(.system(size: 11, weight: .semibold))
                    Text("\(services.count)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(PortTheme.chipFill))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .accessibilityValue(showsServices ? "Expanded" : "Collapsed")

            if showsServices {
                VStack(spacing: 1) {
                    ForEach(services.prefix(Self.maxServiceRows)) { group in
                        NetMenuGroupRow(group: group, model: ports)
                    }
                }
                if services.count > Self.maxServiceRows {
                    moreButton(services.count - Self.maxServiceRows, noun: "service")
                }
            }
        }
    }

    private func moreButton(_ count: Int, noun: String) -> some View {
        Button("\(count) more \(noun)\(count == 1 ? "" : "s") — Open Ports & Network") { model.navigate?(.network) }
            .buttonStyle(.link)
            .font(.system(size: 11.5))
            .padding(.leading, 4)
    }

    // MARK: Behaviour

    private func setClaim(_ visible: Bool) {
        guard visible != holdsClaim else { return }
        holdsClaim = visible
        visible ? model.acquire() : model.release()
    }

    private func updateLookup(_ text: String) {
        lookupTask?.cancel()
        guard let port = PortsModel.portQuery(text) else {
            lookup = nil
            return
        }
        let ids = ports.snapshot.groups.filter { $0.ports.contains(port) }.map(\.id)
        if !ids.isEmpty {
            lookup = .inUse(port: port, groupIDs: ids)
            return
        }
        lookup = .checking(port: port)
        let uid = ports.engine.currentUID
        lookupTask = Task {
            let result = await BackgroundWork.run(qos: .userInitiated) { PortsModel.systemLookup(port: port, currentUID: uid) }
            guard !Task.isCancelled, PortsModel.portQuery(query) == port else { return }
            lookup = result
        }
    }
}

// MARK: - Rows

/// One compact row: icon, name or framework, port chips (click opens localhost), CPU/memory hint, ⋯ and Stop.
private struct NetMenuGroupRow: View {
    let group: PortListenerGroup
    let model: PortsModel

    @State private var isHovering = false

    private var isBusy: Bool { model.busyGroupIDs.contains(group.id) }

    var body: some View {
        HStack(spacing: 7) {
            PortGroupIcon(group: group, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(group.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(group.title.contains("/") ? .middle : .tail)
                    if let manager = group.autoRestartManager {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(PortTheme.autoRestart)
                            .help(manager.autoRestartExplanation ?? "Starts again automatically")
                            .accessibilityLabel("Starts again automatically")
                    }
                }
                detail
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)
            .help(help)
            Spacer(minLength: 4)
            PortChips(ports: group.ports, exposedPorts: group.exposedPorts, limit: 2, compact: true,
                      open: model.openInBrowser(port:), copy: model.copy)
            Menu {
                PortGroupActionsMenu(group: group, model: model, isBusy: isBusy)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .menuStyle(.button)
            .buttonStyle(PortHoverButtonStyle(padding: EdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1),
                                              foreground: AnyShapeStyle(.secondary)))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
            .accessibilityLabel("More actions for \(group.title)")
            PortStopControl(title: group.title, safety: PortStopSafety.forGroup(group), isBusy: isBusy, size: 14) { mode in
                model.stop(group, mode: mode)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isHovering ? PortTheme.hoverFill : .clear))
        .onHover { isHovering = $0 }
        .contextMenu { PortGroupActionsMenu(group: group, model: model, isBusy: isBusy) }
        .accessibilityElement(children: .contain)
    }

    /// "Vite · 41 MB", with the CPU when it's noticeable ("Vite · 41 MB · 12% CPU"); heavy usage in yellow.
    private var detail: Text {
        let name = group.frameworks.first ?? group.subtitle
        var usage = PortFormat.bytes(group.usage.memoryBytes)
        if group.usage.cpuPercent >= 1 { usage += " · \(PortFormat.cpu(group.usage.cpuPercent)) CPU" }
        let usageText = model.isHeavy(group)
            ? Text(usage).foregroundStyle(PortTheme.heavy).fontWeight(.semibold)
            : Text(usage)
        guard let name else { return usageText }
        return Text("\(name) · ") + usageText
    }

    private var help: String {
        var lines = [group.launchdLabel ?? group.title]
        if let path = group.path { lines.append(PortFormat.abbreviatePath(path)) }
        if let origin = group.origin { lines.append("Started from \(origin.name)") }
        return lines.joined(separator: "\n")
    }
}

/// The answer to a port-number search, with Stop for whoever holds it.
private struct NetMenuLookupView: View {
    let lookup: PortLookup
    let model: PortsModel

    var body: some View {
        switch lookup {
        case .checking(let port):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Checking port \(String(port))…").font(.callout).foregroundStyle(.secondary)
            }
        case .free(let port):
            Label("Port \(String(port)) is free", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case .freeForYou(let port):
            Label("No app of yours uses port \(String(port))", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("macOS didn't provide other users' ports, so a system service could still use it.")
        case .inUseElsewhere(let port, let owners):
            VStack(alignment: .leading, spacing: 2) {
                Label("Port \(String(port)) is in use", systemImage: "exclamationmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                ForEach(owners) { owner in
                    Text("\(owner.name) (pid \(owner.pid))" + (owner.uid == 0 ? " · root" : owner.uid == getuid() ? "" : " · another user"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .inUse(let port, let groupIDs):
            VStack(alignment: .leading, spacing: 2) {
                Label("Port \(String(port)) is in use", systemImage: "exclamationmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                ForEach(groupIDs.compactMap { id in model.snapshot.groups.first { $0.id == id } }) { group in
                    NetMenuGroupRow(group: group, model: model)
                }
            }
        }
    }
}

/// The result of the last Stop, compact.
private struct NetMenuBanner: View {
    let banner: PortBanner
    let model: PortsModel

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(banner.message)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let title = banner.actionTitle, banner.action != nil {
                Button(title) { model.performBannerAction(banner) }
                    .controlSize(.mini)
            }
            Button {
                model.dismissBanner()
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(7)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var tint: Color {
        switch banner.style {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var symbol: String {
        switch banner.style {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}
