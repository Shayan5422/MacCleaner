import AppKit
import SwiftUI

/// The Connections tab: every process's network connections, checked against the downloaded threat feeds.
struct ConnectionsTab: View {
    let page: NetworkViewModel
    @Bindable var model: ConnectionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            feedStatus

            ForEach(model.threatHits) { hit in
                NetThreatHitCard(hit: hit, model: model)
            }

            if let banner = model.banner {
                PortBannerView(banner: banner, onDismiss: { model.dismissBanner() })
            }

            if !model.hasScanned {
                ScanProgressCard(title: "Reading network connections…",
                                 message: "Listing every process's TCP and UDP sockets.", fraction: nil,
                                 tint: AppSection.network.tint)
            } else {
                tiles
                controls
                content
            }

            blockingNote
        }
        .confirmationDialog(confirmationTitle, isPresented: Binding(
            get: { model.pendingStop != nil }, set: { if !$0 { model.pendingStop = nil } }),
            titleVisibility: .visible, presenting: model.pendingStop) { confirmation in
            Button("Stop", role: .destructive) { model.confirmStop(confirmation) }
            Button("Force Stop") { model.confirmStop(confirmation, mode: .force) }
            Button("Cancel", role: .cancel) { model.pendingStop = nil }
        } message: { confirmation in
            Text(confirmationMessage(confirmation))
        }
    }

    private var confirmationTitle: String {
        model.pendingStop.map { "Stop \($0.process.displayName)?" } ?? ""
    }

    private func confirmationMessage(_ confirmation: NetStopConfirmation) -> String {
        var lines = ["Stop will end:"] + confirmation.plan.summary.prefix(8).map { "• " + $0 }
        if confirmation.plan.summary.count > 8 { lines.append("• …and \(confirmation.plan.summary.count - 8) more") }
        lines += confirmation.plan.warnings.map { "⚠︎ " + $0 }
        if confirmation.category == .app {
            lines.append("Apps are asked to quit first, so they can save your work.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Feeds

    @ViewBuilder
    private var feedStatus: some View {
        if !model.feedsLoaded {
            NetCallout(style: .warning, title: "Threat feeds aren't downloaded yet — download them on the Antivirus page",
                       message: "Until then Mac Cleaner can list connections but can't tell whether a server is known to be malicious.") {
                Button("Open Antivirus") { page.navigate?(.antivirus) }
            }
        } else if model.hasScanned && model.threatHits.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                Text("No connections to known malicious servers")
                    .font(.callout.weight(.medium))
                Text("· \(model.remoteHostCount) remote addresses checked against the downloaded threat feeds")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.green.opacity(0.18)))
        }
    }

    // MARK: Tiles

    private var tiles: some View {
        TileRow {
            StatTile(title: "Established", value: NumberFormatting.count(model.establishedCount),
                     caption: "Open TCP connections", symbol: "arrow.left.arrow.right", tint: .blue,
                     fillsHeight: true)
            StatTile(title: "Listening", value: NumberFormatting.count(model.listeningCount),
                     caption: "TCP, open for incoming", symbol: "ear", tint: .teal, fillsHeight: true)
            StatTile(title: "UDP Sockets", value: NumberFormatting.count(model.udpCount),
                     caption: "DNS, calls, device discovery", symbol: "dot.radiowaves.left.and.right", tint: .purple,
                     fillsHeight: true)
            StatTile(title: "Processes", value: NumberFormatting.count(model.processCount),
                     caption: model.scan.kernelListAvailable ? "Including macOS and other users" : "Your own processes only",
                     symbol: "cpu", tint: AppSection.network.tint, fillsHeight: true)
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                NetSearchField(text: $model.searchText, prompt: "Filter by app, address, host or port",
                               focusRequest: page.searchFocusRequest)
                Picker("Show", selection: $model.grouping) {
                    ForEach(ConnectionsModel.Grouping.allCases) { grouping in
                        Text(grouping.rawValue).tag(grouping)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            // One row when it fits, else the checkboxes go under the filter.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    filterPicker
                    Spacer(minLength: 8)
                    optionToggles
                }
                VStack(alignment: .leading, spacing: 8) {
                    filterPicker
                    HStack(spacing: 16) { optionToggles }
                }
            }
        }
    }

    private var filterPicker: some View {
        Picker("Filter", selection: $model.filter) {
            ForEach(NetConnectionFilter.allCases) { filter in
                Text("\(filter.title) \(model.count(for: filter))").tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder
    private var optionToggles: some View {
        Toggle("macOS and other users", isOn: $model.showSystemProcesses)
            .toggleStyle(.checkbox)
            .fixedSize()
            .help("Also list connections of macOS's own services and other users' processes")
        Toggle("Look up host names", isOn: Binding(get: { page.preferences.reverseDNS },
                                                   set: { page.preferences.reverseDNS = $0; if $0 { model.refreshNow() } }))
            .toggleStyle(.checkbox)
            .fixedSize()
            .help("Shows names like github.com for remote addresses. Sends DNS queries to your DNS server.")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let groups = model.processGroups
        if groups.isEmpty {
            EmptyStateView(
                title: model.searchText.isEmpty ? "No \(model.filter.title) Connections" : "No Matches",
                symbol: "network.slash",
                message: model.searchText.isEmpty
                    ? "Nothing matches this filter right now."
                    : "No connection matches “\(model.searchText)”.",
                actionTitle: model.filter == .all && model.searchText.isEmpty ? nil : "Show All",
                action: {
                    model.filter = .all
                    model.searchText = ""
                })
        } else if model.grouping == .flat {
            NetConnectionsTable(model: model)
                .frame(height: min(520, max(220, CGFloat(model.rows.count) * 24 + 34)))
                .card(padding: 0)
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(groups) { group in
                    NetProcessGroupRow(group: group, model: model)
                }
            }
            .card(padding: 8)
        }
    }

    private var blockingNote: some View {
        NetCallout(style: .info, title: "Mac Cleaner can't block connections",
                   message: "Blocking needs a network extension, which Mac Cleaner doesn't install. It shows what connects "
                       + "where and can stop a process you don't trust. To block incoming connections, turn on the macOS firewall.") {
            Button("Open Firewall Settings") { NSWorkspace.shared.open(SystemSettingsPane.firewall.url) }
        }
    }
}

// MARK: - Threat card

/// A connection to a server listed by a threat feed, with what the feed says and what can be done.
struct NetThreatHitCard: View {
    let hit: NetThreatHit
    let model: ConnectionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                NetProcessIcon(process: hit.process, size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Badge(text: "Known malicious server", symbol: "exclamationmark.octagon.fill", tint: .red)
                        Text(NetThreatMatcher.feedName(hit.match.source))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("“\(hit.process.displayName)” is connected to \(hit.remoteText)")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if let path = hit.process.executablePath {
                        PathText(path: path)
                    }
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 3) {
                KeyValueRow(key: "Threat", value: NetThreatMatcher.threatTypeTitle(hit.match.threatType)
                            + (hit.match.malware.map { " — \($0)" } ?? ""))
                KeyValueRow(key: "Listed indicator", value: hit.match.indicator)
                if let host = hit.host { KeyValueRow(key: "Matched host name", value: host) }
                if let confidence = hit.match.confidence { KeyValueRow(key: "Feed confidence", value: "\(confidence)%") }
                if let firstSeen = hit.match.firstSeen {
                    KeyValueRow(key: "First reported", value: DateFormatting.day(firstSeen))
                }
                KeyValueRow(key: "Process", value: "pid \(hit.process.pid)" + (hit.process.isCurrentUser ? "" : " · another user"))
            }
            HStack(spacing: 8) {
                Button(role: .destructive) {
                    model.requestStop(hit.process)
                } label: {
                    Label("Stop Process…", systemImage: "stop.fill")
                }
                .disabled(model.busyProcessIDs.contains("\(hit.process.pid)@\(hit.process.startTime)"))
                Button("Reveal in Finder") { model.reveal(hit.process) }
                    .disabled(hit.process.executablePath == nil)
                Button("Copy Details") { model.copy(ConnectionsModel.describe(hit)) }
                if let reference = hit.match.reference {
                    Link("View Report", destination: reference)
                        .font(.callout)
                }
                Spacer()
            }
            Text("A threat feed lists this server as \(NetThreatMatcher.threatTypeTitle(hit.match.threatType)). Stop the process if you don't trust it, then scan it on the Antivirus page.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(Color.red.opacity(0.3), lineWidth: 1.5))
    }
}

// MARK: - Grouped view

/// One process with its connections (collapsed to a summary; click to expand).
private struct NetProcessGroupRow: View {
    let group: NetProcessConnections
    let model: ConnectionsModel

    @State private var isHovering = false

    private var isExpanded: Bool { model.expandedProcessIDs.contains(group.id) || model.hasThreat(group) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                PortDisclosureChevron(isExpanded: isExpanded)
                    .frame(width: 12)
                NetProcessIcon(process: group.process, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(group.process.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(verbatim: "pid \(group.process.pid)")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.tertiary)
                        if !group.process.isCurrentUser && !group.process.hasExited {
                            Badge(text: group.process.uid == 0 ? "root" : "System", symbol: "lock.fill", tint: .gray)
                        }
                        if model.hasThreat(group) {
                            Badge(text: "Known malicious server", symbol: "exclamationmark.octagon.fill", tint: .red)
                        }
                    }
                    signature
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                Text(summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle() }

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(group.connections.prefix(60)) { connection in
                        NetConnectionLine(connection: connection, model: model)
                    }
                    if group.connections.count > 60 {
                        Text("…and \(group.connections.count - 60) more. Use the filter to narrow the list.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 6)
                            .padding(.top, 4)
                    }
                }
                .padding(.leading, 46)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(isExpanded ? PortTheme.insetFill : isHovering ? PortTheme.hoverFill : .clear))
        .onHover { isHovering = $0 }
        .contextMenu { NetProcessMenu(process: group.process, model: model) }
    }

    @ViewBuilder
    private var signature: some View {
        if let path = group.process.executablePath {
            if let info = model.signatures[path] {
                Label(info.connectionSummary, systemImage: info.isConcerning ? "exclamationmark.shield" : "checkmark.shield")
                    .labelStyle(PortCompactLabelStyle())
                    .font(.system(size: 11))
                    .foregroundStyle(info.isConcerning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .help(info.trustSummary)
            } else {
                Text(PortFormat.abbreviatePath(path))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            Text(group.process.hasExited ? "Exited — the kernel still holds its socket" : "Path not readable")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private var summary: String {
        var parts: [String] = []
        if group.establishedCount > 0 { parts.append("\(group.establishedCount) active") }
        if group.listeningCount > 0 { parts.append("\(group.listeningCount) listening") }
        if group.udpCount > 0 { parts.append("\(group.udpCount) UDP") }
        let other = group.connections.count - group.establishedCount - group.listeningCount - group.udpCount
        if other > 0 { parts.append("\(other) closing") }
        return parts.joined(separator: " · ")
    }

    private func toggle() {
        withAnimation(.snappy(duration: 0.2)) {
            if model.expandedProcessIDs.contains(group.id) {
                model.expandedProcessIDs.remove(group.id)
            } else {
                model.expandedProcessIDs.insert(group.id)
            }
        }
    }
}

/// "TCP  192.168.1.81:52344 → lb-140-82-112-3.github.com (140.82.112.3:443)  Established · 4m".
private struct NetConnectionLine: View {
    let connection: NetConnection
    let model: ConnectionsModel

    var body: some View {
        let hit = model.threatHit(for: connection)
        HStack(spacing: 8) {
            Text(connection.transport.title + (connection.record.family == .ipv6 ? "6" : "4"))
                .font(.system(size: 10.5, weight: .semibold).monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            Text(NetAddress.endpoint(connection.record.localAddress, port: connection.record.localPort))
                .font(PortTheme.command)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 120, maxWidth: 220, alignment: .leading)
            Image(systemName: connection.record.remoteAddress == nil ? "minus" : "arrow.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            remote(hit: hit)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(connection.state?.title ?? (connection.record.remoteAddress == nil ? "Open" : "Connected"))
                .font(.system(size: 11))
                .foregroundStyle(connection.state?.isActive == true ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .fixedSize()
                .help(connection.state?.systemName ?? "UDP")
            Text(PortFormat.uptime(since: connection.firstSeen))
                .font(PortTheme.metric)
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .trailing)
                .help("Seen for this long since Mac Cleaner started watching (it can't know when the connection was opened)")
        }
        .padding(.vertical, 2)
        .contextMenu {
            if let remote = connection.record.remoteAddress {
                Button("Copy Remote Address") { model.copy(NetAddress.endpoint(remote, port: connection.record.remotePort)) }
                if let host = model.hostNames[remote] { Button("Copy Host Name") { model.copy(host) } }
            }
            Button("Copy Local Address") {
                model.copy(NetAddress.endpoint(connection.record.localAddress, port: connection.record.localPort))
            }
            Divider()
            NetProcessMenu(process: connection.process, model: model)
        }
    }

    @ViewBuilder
    private func remote(hit: NetThreatHit?) -> some View {
        if let address = connection.record.remoteAddress {
            let endpoint = NetAddress.endpoint(address, port: connection.record.remotePort)
            HStack(spacing: 5) {
                if let host = model.hostNames[address] {
                    Text(host).font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
                    Text(endpoint).font(PortTheme.command).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(endpoint).font(PortTheme.command).lineLimit(1).truncationMode(.middle)
                }
                if hit != nil {
                    Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                        .help("Listed by a threat feed")
                }
            }
        } else {
            Text(connection.isListening ? "waiting for connections" : "no peer")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }
}

/// Reveal / Copy / Stop for a process.
private struct NetProcessMenu: View {
    let process: NetProcessInfo
    let model: ConnectionsModel

    var body: some View {
        if process.executablePath != nil {
            Button("Reveal in Finder") { model.reveal(process) }
        }
        Button("Copy PID") { model.copy(String(process.pid)) }
        if let path = process.executablePath { Button("Copy Path") { model.copy(path) } }
        if !process.hasExited && process.pid > 1 {
            Divider()
            Button("Stop Process…") { model.requestStop(process) }
        }
    }
}

// MARK: - Flat table

/// Sortable table of every filtered connection.
private struct NetConnectionsTable: View {
    @Bindable var model: ConnectionsModel

    var body: some View {
        let rows = model.rows
        Table(rows, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Process", value: \.processName) { row in
                HStack(spacing: 6) {
                    NetProcessIcon(process: row.connection.process, size: 16)
                    Text(row.processName).lineLimit(1).truncationMode(.middle)
                    if model.threatHit(for: row.connection) != nil {
                        Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                    }
                }
                .help(row.connection.process.executablePath ?? row.processName)
            }
            .width(min: 120, ideal: 170)
            TableColumn("PID", value: \.pid) { row in
                Text(String(row.pid)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 40, ideal: 52)
            TableColumn("Proto", value: \.transportTitle) { row in
                Text(row.transportTitle).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .width(min: 40, ideal: 44)
            TableColumn("Local", value: \.local) { row in
                Text(row.local).font(PortTheme.command).lineLimit(1).truncationMode(.middle)
            }
            .width(min: 100, ideal: 150)
            TableColumn("Remote", value: \.remoteSortKey) { row in
                Text(row.remote).font(PortTheme.command).lineLimit(1).truncationMode(.middle)
                    .help(row.remote)
            }
            .width(min: 120, ideal: 240)
            TableColumn("State", value: \.stateTitle) { row in
                Text(row.stateTitle).foregroundStyle(.secondary).lineLimit(1)
                    .help(row.connection.state?.systemName ?? row.transportTitle)
            }
            .width(min: 80, ideal: 110)
            TableColumn("Seen", value: \.firstSeen) { row in
                Text(PortFormat.uptime(since: row.firstSeen)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 44, ideal: 56)
        }
        .contextMenu(forSelectionType: NetConnectionRow.ID.self) { selection in
            if let id = selection.first, let row = rows.first(where: { $0.id == id }) {
                if let remote = row.connection.record.remoteAddress {
                    Button("Copy Remote Address") { model.copy(NetAddress.endpoint(remote, port: row.connection.record.remotePort)) }
                }
                Divider()
                NetProcessMenu(process: row.connection.process, model: model)
            }
        }
    }
}

// MARK: - Icons

/// App icon for app processes, a symbol otherwise.
struct NetProcessIcon: View {
    let process: NetProcessInfo
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let bundle = process.appBundlePath {
                FileIcon(path: bundle, size: size)
            } else {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                    .overlay(Image(systemName: process.isCurrentUser ? "terminal" : "gearshape")
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .foregroundStyle(.secondary))
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}
