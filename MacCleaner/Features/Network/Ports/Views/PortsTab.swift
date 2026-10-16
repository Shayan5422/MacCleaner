import AppKit
import SwiftUI

/// The Ports tab: every listening TCP port, grouped by project, with one-click Stop (PortPilot inside Mac Cleaner).
struct PortsTab: View {
    let page: NetworkViewModel
    @Bindable var model: PortsModel

    @State private var collapsed: Set<PortListenerCategory> = []

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            searchBar

            if let lookup = model.portLookup {
                PortLookupCard(lookup: lookup, model: model, includesSystem: page.preferences.includesSystemPorts)
            }

            if let banner = model.banner {
                PortBannerView(banner: banner, onAction: banner.action == nil ? nil : { model.performBannerAction(banner) },
                               onDismiss: { model.dismissBanner() })
            }

            notices

            if !model.hasScanned {
                ScanProgressCard(title: "Reading open ports…",
                                 message: "Listing every listening TCP port and the project it belongs to.",
                                 fraction: nil, tint: AppSection.network.tint)
            } else {
                tiles
                content
            }
        }
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 10) {
            NetSearchField(text: $model.searchText, prompt: "Find a port, process or project",
                           focusRequest: page.searchFocusRequest)
            Toggle("Include other users' and system ports", isOn: Binding(
                get: { page.preferences.includesSystemPorts },
                set: { page.preferences.includesSystemPorts = $0 }))
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("Also list ports opened by macOS and by other users (such as root). They appear under System.")
            sortMenu
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: Binding(get: { page.preferences.sortOrder },
                                                 set: { page.preferences.sortOrder = $0 })) {
                ForEach(PortSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Show Apps", isOn: Binding(get: { page.preferences.showApps }, set: { page.preferences.showApps = $0 }))
            Toggle("Show System", isOn: Binding(get: { page.preferences.showSystem }, set: { page.preferences.showSystem = $0 }))
            if page.preferences.hiddenItemCount > 0 {
                Divider()
                Button("Show \(page.preferences.hiddenItemCount) Hidden Item\(page.preferences.hiddenItemCount == 1 ? "" : "s")") {
                    model.unhideAll()
                }
            }
        } label: {
            Label("View", systemImage: "line.3.horizontal.decrease.circle")
        }
        .fixedSize()
        .help("Sort, and choose which sections to show")
    }

    // MARK: Notices

    @ViewBuilder
    private var notices: some View {
        if !model.foldersAwaitingAccess.isEmpty {
            let names = model.foldersAwaitingAccess.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            InfoCallout(style: .info, title: "Waiting for access to \(names)",
                        message: "macOS is asking whether Mac Cleaner may read this folder. Click Allow in its prompt so "
                            + "projects there get their real names; until then they're named after their folder.")
        }
        if model.otherUsersUnavailable && page.preferences.includeOtherUsers {
            InfoCallout(style: .warning, title: "Other users' ports aren't available",
                        message: "macOS didn't provide its list of system-wide ports, so only your own processes are shown.")
        }
    }

    // MARK: Tiles

    private var tiles: some View {
        TileRow {
            StatTile(title: "Project Ports", value: NumberFormatting.count(model.projectPortCount),
                     caption: countCaption(model.count(of: .project), noun: "project"),
                     symbol: "chevron.left.forwardslash.chevron.right", tint: .blue, fillsHeight: true)
            StatTile(title: "Service Ports", value: NumberFormatting.count(model.ports(of: .service)),
                     caption: countCaption(model.count(of: .service), noun: "service"),
                     symbol: "gearshape.2", tint: .teal, fillsHeight: true)
            StatTile(title: "Apps & System", value: NumberFormatting.count(model.ports(of: .app) + model.ports(of: .system)),
                     caption: appsCaption, symbol: "app.badge", tint: .indigo, fillsHeight: true)
            StatTile(title: "Server Memory",
                     value: PortFormat.bytes(model.devUsage.memoryBytes),
                     caption: "\(PortFormat.cpu(model.devUsage.cpuPercent)) CPU",
                     symbol: "memorychip", tint: AppSection.network.tint, fillsHeight: true)
                .help("Memory and CPU used by the processes of your projects and background services. CPU is per core, like in Activity Monitor.")
        }
    }

    private func countCaption(_ count: Int, noun: String) -> String {
        count == 0 ? "None open" : "in \(count) \(noun)\(count == 1 ? "" : "s")"
    }

    private var appsCaption: String {
        switch (page.preferences.showApps, page.preferences.showSystem) {
        case (true, true): return "Listed below"
        case (true, false): return "System ports hidden"
        case (false, true): return "App ports hidden"
        case (false, false): return "Hidden — turn on in View"
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let sections = model.sections
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if sections.isEmpty {
            if query.isEmpty {
                EmptyStateView(
                    title: "No Open Ports",
                    symbol: "point.3.connected.trianglepath.dotted",
                    message: model.hiddenCount > 0
                        ? "Nothing of yours is listening right now. \(model.hiddenCount) item\(model.hiddenCount == 1 ? " is" : "s are") hidden by your view settings."
                        : "Nothing of yours is listening on a TCP port right now. Start a dev server and it shows up here within a few seconds.")
            } else if PortsModel.portQuery(query) == nil {
                EmptyStateView(title: "No Matches", symbol: "magnifyingglass",
                               message: "No port, process or project matches “\(query)”. Searching also finds apps and system processes.",
                               actionTitle: "Clear Search", action: { model.searchText = "" })
            }
        } else {
            ForEach(sections, id: \.category) { section in
                sectionCard(section.category, groups: section.groups)
            }
        }

        if query.isEmpty {
            if !model.stillRunning.isEmpty { PortStillRunningCard(model: model) }
            if !model.recentlyStopped.isEmpty { PortRecentlyStoppedCard(model: model) }
            footer
        }
    }

    private func sectionCard(_ category: PortListenerCategory, groups: [PortListenerGroup]) -> some View {
        let isCollapsed = collapsed.contains(category)
        let ports = Set(groups.flatMap(\.ports)).count
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if isCollapsed { collapsed.remove(category) } else { collapsed.insert(category) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    Text(category.title).font(.headline)
                    Text("\(groups.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(PortTheme.chipFill))
                    Spacer()
                    Text(ports == 1 ? "1 port" : "\(ports) ports")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .accessibilityLabel("\(category.title), \(groups.count)")
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")

            if !isCollapsed {
                VStack(spacing: 2) {
                    ForEach(groups) { group in
                        PortGroupRow(group: group, model: model)
                    }
                }
                if category == .service, groups.contains(where: { $0.supervisingManager?.isAutoRestarting == true }) {
                    startupLink
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 10)
    }

    /// Where PortPilot listed launchd agents, Mac Cleaner has a whole page.
    private var startupLink: some View {
        HStack(spacing: 8) {
            Image(systemName: AppSection.startup.symbolName)
                .foregroundStyle(AppSection.startup.tint)
            Text("Services started by launchd at login are also listed under Startup Items, where you can turn them on or off.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Open Startup Items") { page.navigate?(.startup) }
                .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            let projects = model.stoppableProjects
            if !projects.isEmpty {
                PortConfirmButton(title: "Stop All Projects (\(projects.count))", confirmTitle: "Stop \(projects.count) Projects?",
                                  systemImage: "stop.circle", foreground: AnyShapeStyle(.secondary),
                                  font: .system(size: 12.5, weight: .medium),
                                  armedHelp: PortStopReport.stopAllConfirmHelp(projects)) { _ in
                    model.stopAllProjects()
                }
                .fixedSize()
            }
            Spacer()
            if model.hiddenCount > 0 {
                Menu {
                    if !page.preferences.showApps { Button("Show Apps") { page.preferences.showApps = true } }
                    if !page.preferences.showSystem { Button("Show System") { page.preferences.showSystem = true } }
                    if page.preferences.hiddenItemCount > 0 {
                        Button("Show Items You Hid") { model.unhideAll() }
                    }
                } label: {
                    Label(model.hiddenCount == 1 ? "1 hidden item" : "\(model.hiddenCount) hidden items", systemImage: "eye.slash")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Port lookup

/// "Port 3000 — used by acme-shop (node, pid 1201)" with Stop right there, or "Port 3000 is free".
struct PortLookupCard: View {
    let lookup: PortLookup
    let model: PortsModel
    let includesSystem: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                switch lookup {
                case .inUse(_, let groupIDs):
                    ForEach(groups(groupIDs)) { group in
                        holderRow(group)
                    }
                case .inUseElsewhere(_, let owners):
                    ForEach(owners) { owner in
                        HStack(spacing: 6) {
                            Text(owner.name).font(.callout.weight(.medium))
                            Text(verbatim: "pid \(owner.pid)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            if owner.uid != getuid() {
                                Badge(text: owner.uid == 0 ? "root" : "another user", symbol: "lock.fill", tint: .gray)
                            }
                        }
                    }
                    Text(includesSystem
                         ? "It belongs to another user or to macOS, so it isn't one of your rows."
                         : "It belongs to another user or to macOS. Turn on “Include other users' and system ports” to see and stop it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .free:
                    Text("Nothing on this Mac listens on TCP port \(String(lookup.port)), so a server can use it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .freeForYou:
                    Text("None of your processes listens on it. macOS didn't provide other users' ports, so a system service could still be using it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .checking:
                    EmptyView()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(tint.opacity(0.2)))
    }

    private var title: String {
        let port = String(lookup.port)
        switch lookup {
        case .inUse(_, let ids): return ids.count == 1 ? "Port \(port) is in use" : "Port \(port) is used by \(ids.count) items"
        case .inUseElsewhere: return "Port \(port) is in use"
        case .free: return "Port \(port) is free"
        case .freeForYou: return "Port \(port) looks free"
        case .checking: return "Checking port \(port)…"
        }
    }

    private var tint: Color {
        switch lookup {
        case .inUse, .inUseElsewhere: return .orange
        case .free, .freeForYou: return .green
        case .checking: return .gray
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch lookup {
        case .checking:
            ProgressView().controlSize(.small).frame(width: 28, height: 28)
        default:
            Image(systemName: tint == .green ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
        }
    }

    private func groups(_ ids: [String]) -> [PortListenerGroup] {
        ids.compactMap { id in model.snapshot.groups.first { $0.id == id } }
    }

    private func holderRow(_ group: PortListenerGroup) -> some View {
        let listeners = group.processes.filter { $0.ports.contains(lookup.port) }
        let names = listeners.map { "\($0.displayName) (pid \($0.basic.pid))" }.joined(separator: ", ")
        return HStack(spacing: 10) {
            PortGroupIcon(group: group, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.title).font(.callout.weight(.semibold)).lineLimit(1)
                Text(names).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Open") { model.openInBrowser(port: lookup.port) }
                .controlSize(.small)
            stopButton(for: group)
        }
    }

    @ViewBuilder
    private func stopButton(for group: PortListenerGroup) -> some View {
        let isBusy = model.busyGroupIDs.contains(group.id)
        switch PortStopSafety.forGroup(group) {
        case .unavailable:
            EmptyView()
        case .oneClick:
            Button {
                model.stop(group, mode: NSEvent.modifierFlags.contains(.option) ? .force : .graceful)
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .controlSize(.small)
            .disabled(isBusy)
            .help("Stop \(group.title) — ⌥-click to force stop")
        case .confirm(let reason):
            PortConfirmButton(title: "Stop", confirmTitle: "Stop?", systemImage: "stop.fill",
                              armedHelp: reason.armedHelp(title: group.title)) { flags in
                model.stop(group, mode: flags.contains(.option) ? .force : .graceful)
            }
            .disabled(isBusy)
            .fixedSize()
        }
    }
}

// MARK: - Search field

/// The page's prominent search field (⌘F focuses it).
struct NetSearchField: View {
    @Binding var text: String
    let prompt: String
    /// Incremented by ⌘F.
    var focusRequest: Int = 0

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isFocused)
                .onSubmit { isFocused = true }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            } else {
                Text("⌘F")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(isFocused ? Color.accentColor.opacity(0.6) : Color.subtleBorder, lineWidth: isFocused ? 2 : 1))
        .onChange(of: focusRequest) { _, _ in isFocused = true }
    }
}
