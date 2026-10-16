import AppKit
import SwiftUI

/// One project / service / app on the Ports tab.
///
///     ›  [icon]  acme-shop  frontend, backend               :3000 :8000   3.9% · 501 MB   ⋯  ⊗
///                ~/Developer/acme-shop · 2h 14m
///                [Next.js] [uvicorn] [✦ Claude Code]
///
/// Clicking the row toggles its processes and stop plan; chips, path, menu and Stop handle their own clicks.
struct PortGroupRow: View {
    let group: PortListenerGroup
    let model: PortsModel

    @State private var isHovering = false

    private var isExpanded: Bool { model.expandedGroupIDs.contains(group.id) }
    private var isBusy: Bool { model.busyGroupIDs.contains(group.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
                .contentShape(Rectangle())
                .onTapGesture(perform: toggleExpanded)
            if isExpanded {
                PortGroupDetail(group: group, model: model, isBusy: isBusy)
                    .padding(.leading, PortTheme.textColumnInset)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isExpanded ? PortTheme.insetFill : isHovering ? PortTheme.hoverFill : .clear))
        .onHover { isHovering = $0 }
        .contextMenu { PortGroupActionsMenu(group: group, model: model, isBusy: isBusy) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAction(named: isExpanded ? "Hide processes" : "Show processes", toggleExpanded)
    }

    // MARK: Summary

    private var summary: some View {
        HStack(alignment: .top, spacing: 0) {
            Button(action: toggleExpanded) {
                PortDisclosureChevron(isExpanded: isExpanded)
                    .frame(width: PortTheme.chevronWidth, height: PortTheme.iconSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide processes" : "Show processes")

            PortGroupIcon(group: group)
                .padding(.leading, 8)

            VStack(alignment: .leading, spacing: 4) {
                titleLine
                detailLine
                let badges = PortBadgeModel.badges(for: group)
                if !badges.isEmpty {
                    PortFlowLayout(spacing: 5, lineSpacing: 4) {
                        ForEach(badges) { badge in
                            Badge(text: badge.text, symbol: badge.symbol, tint: badge.tint)
                                .help(badge.help ?? badge.text)
                        }
                    }
                    .padding(.top, 1)
                }
            }
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
                .padding(.leading, 8)
        }
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(group.title)
                .font(.system(size: 13.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(group.title.contains("/") ? .middle : .tail)
                .layoutPriority(1)
            if let subtitle = visibleSubtitle {
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .help(titleHelp)
    }

    private var visibleSubtitle: String? {
        guard let subtitle = group.subtitle, !subtitle.isEmpty, subtitle != group.title else { return nil }
        return subtitle
    }

    private var titleHelp: String {
        let name = group.launchdLabel ?? group.title
        return visibleSubtitle.map { "\(name) — \($0)" } ?? name
    }

    private var detailLine: some View {
        HStack(spacing: 5) {
            if let path = group.locationPath {
                PortPathLink(path: path, model: model)
                    .layoutPriority(-1)
            } else if let command = group.processes.first?.commandLine {
                Text(PortFormat.abbreviatePath(command))
                    .font(PortTheme.command)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }
            if let started = group.oldestStart {
                Text(verbatim: "·").foregroundStyle(.quaternary)
                Text(PortFormat.uptime(since: started))
                    .font(PortTheme.metric)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .help("Running since \(started.formatted(date: .abbreviated, time: .shortened))")
            }
        }
        .font(.system(size: 11.5))
    }

    private var trailing: some View {
        HStack(alignment: .center, spacing: 10) {
            PortChips(ports: group.ports, exposedPorts: group.exposedPorts, open: model.openInBrowser(port:), copy: model.copy)
            PortUsagePill(usage: group.usage)
                .frame(minWidth: 92, alignment: .trailing)
            HStack(spacing: 0) {
                Menu {
                    PortGroupActionsMenu(group: group, model: model, isBusy: isBusy)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .menuStyle(.button)
                .buttonStyle(PortHoverButtonStyle(padding: EdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2),
                                                  foreground: AnyShapeStyle(.secondary)))
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
                .accessibilityLabel("More actions for \(group.title)")

                PortStopControl(title: group.title, safety: PortStopSafety.forGroup(group), isBusy: isBusy) { mode in
                    model.stop(group, mode: mode)
                }
            }
        }
        .frame(height: PortTheme.iconSize)
    }

    private func toggleExpanded() {
        withAnimation(.snappy(duration: 0.22)) {
            if model.expandedGroupIDs.contains(group.id) {
                model.expandedGroupIDs.remove(group.id)
            } else {
                model.expandedGroupIDs.insert(group.id)
            }
        }
    }

    private var accessibilitySummary: String {
        let ports = group.ports.map { String($0) }.joined(separator: ", ")
        return "\(group.title), port\(group.ports.count == 1 ? "" : "s") \(ports), CPU \(PortFormat.cpu(group.usage.cpuPercent)), memory \(PortFormat.bytes(group.usage.memoryBytes))"
    }

    /// Text of the orange notice above "Stop & Disable". For launchd it says what the two buttons do: Stop unloads
    /// the job until next login; Stop & Disable keeps it off where Mac Cleaner can turn auto-start off, else the
    /// person is pointed to Login Items.
    static func autoRestartNotice(for manager: PortProcessManager, launchd: PortLaunchdService) -> String {
        if case .launchd(let job) = manager, job.keepAlive || job.runAtLoad {
            guard launchd.isManageable(plistPath: job.plistPath) else {
                return "launchd starts this again at next login. Turn that off in \(PortStopReport.loginItemsSettings)."
            }
            return "launchd starts this again at next login. Stop & Disable keeps it off (turn it back on under Startup Items)."
        }
        return manager.autoRestartExplanation ?? "Restarts automatically."
    }
}

// MARK: - Path link

/// Abbreviated path ("~/code/foo"); a click reveals it in Finder.
struct PortPathLink: View {
    let path: String
    let model: PortsModel
    @State private var isHovering = false

    var body: some View {
        Button {
            model.revealInFinder(path)
        } label: {
            Text(PortFormat.abbreviatePath(path))
                .font(.system(size: 11.5))
                .foregroundStyle(isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .underline(isHovering, color: .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Reveal \(path) in Finder")
        .accessibilityLabel("Reveal \(PortFormat.abbreviatePath(path)) in Finder")
    }
}

// MARK: - Expanded detail

/// Process list, stop plan preview, auto-restart notice and quick actions under an expanded group.
private struct PortGroupDetail: View {
    let group: PortListenerGroup
    let model: PortsModel
    let isBusy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(group.processes) { process in
                    PortProcessRow(process: process, model: model, isGroupBusy: isBusy)
                }
            }
            .padding(.horizontal, -6)

            let plan = model.killPlanPreview(for: group)
            if !plan.isEmpty {
                PortPlanPreview(lines: plan)
            } else if group.processes.contains(where: { !$0.isRestricted && $0.manager == .none }) {
                Text("Working out what Stop will end…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let manager = group.autoRestartManager {
                PortAutoRestartNotice(group: group, manager: manager, model: model, isBusy: isBusy)
            }

            quickActions
        }
        .padding(.bottom, 2)
    }

    private var quickActions: some View {
        HStack(spacing: 6) {
            if let port = group.ports.first {
                Button("Open localhost:\(String(port))", systemImage: "safari") { model.openInBrowser(port: port) }
            }
            if let path = group.path, path != "/" {
                Button("Reveal in Finder", systemImage: "folder") { model.revealInFinder(path) }
                if group.category == .project || group.category == .service {
                    Button("Terminal", systemImage: "terminal") { model.openInTerminal(path) }
                        .help("Open in Terminal")
                    if let editor = model.preferredEditorName {
                        Button(editor, systemImage: "chevron.left.forwardslash.chevron.right") { model.openInEditor(path) }
                            .help("Open in \(editor)")
                    }
                }
            }
            Button("Copy Command", systemImage: "doc.on.doc") {
                model.copy(group.processes.map(\.commandLine).joined(separator: "\n"))
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(PortHoverButtonStyle(foreground: AnyShapeStyle(.secondary)))
        .labelStyle(PortCompactLabelStyle())
        .font(.system(size: 11.5, weight: .medium))
        .padding(.leading, -7)
    }
}

/// Icon + title with a tight gap.
struct PortCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title.lineLimit(1)
        }
    }
}

/// "Stop will end: npm run dev (pid 1200) → node vite (pid 1201)".
struct PortPlanPreview: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Stop will end", systemImage: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let isWarning = line.hasPrefix("⚠︎ ")
                Text(isWarning ? String(line.dropFirst(3)) : line)
                    .font(isWarning ? .system(size: 11) : PortTheme.command)
                    .foregroundStyle(isWarning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(isWarning ? 3 : 1)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: isWarning)
                    .help(line)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PortTheme.insetFill))
    }
}

/// Orange notice for launchd / pm2 / Docker-managed groups with an inline-confirmed "Stop & Disable".
private struct PortAutoRestartNotice: View {
    let group: PortListenerGroup
    let manager: PortProcessManager
    let model: PortsModel
    let isBusy: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(PortTheme.autoRestart)
            Text(PortGroupRow.autoRestartNotice(for: manager, launchd: model.engine.launchd))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            PortConfirmButton(title: "Stop & Disable Auto-Start", confirmTitle: "Confirm", tint: PortTheme.autoRestart,
                              foreground: AnyShapeStyle(PortTheme.autoRestart),
                              font: .system(size: 11.5, weight: .semibold),
                              armedHelp: "Click again to stop it and keep it from starting again") { _ in
                model.stopAndDisableAutoStart(group)
            }
            .disabled(isBusy)
            .fixedSize()
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PortTheme.autoRestart.opacity(0.09)))
    }
}

// MARK: - Process row

/// One listening process inside an expanded group: name, package folder, ports, usage, PID, watcher, command and
/// its own Stop (its kill plan); "Stop Only This Process" in its menu ends just this PID.
struct PortProcessRow: View {
    let process: PortListenerProcess
    let model: PortsModel
    var isGroupBusy = false

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(process.displayName)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let subpath = process.project?.subpath {
                            Text(subpath)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .layoutPriority(1)
                    if process.isRestricted {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .help("Owned by another user — details unavailable; stopping it asks for an administrator password")
                            .accessibilityLabel("Owned by another user")
                    }
                    PortChips(ports: process.ports,
                              exposedPorts: Set(process.sockets.filter(\.isExposed).map(\.port)),
                              compact: true, open: model.openInBrowser(port:), copy: model.copy)
                    Spacer(minLength: 6)
                    PortUsagePill(usage: process.treeUsage, compact: true)
                }
                HStack(spacing: 6) {
                    Text(verbatim: "PID \(process.basic.pid)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                    if case .watcher(let name) = process.manager {
                        Label(name, systemImage: "eye")
                            .labelStyle(PortCompactLabelStyle())
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .help("\(name) restarts this server when files change; Stop ends the watcher too")
                    }
                    Text(PortFormat.abbreviatePath(process.commandLine))
                        .font(PortTheme.command)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            PortStopControl(title: process.displayName, safety: PortStopSafety.forProcess(process),
                            isBusy: isGroupBusy, size: 13) { mode in
                model.stop(process, mode: mode)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isHovering ? PortTheme.hoverFill : .clear))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(process.commandLine)
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(process.displayName), PID \(String(process.basic.pid))")
    }

    @ViewBuilder
    private var menu: some View {
        if let port = process.ports.first {
            Button("Open localhost:\(String(port))") { model.openInBrowser(port: port) }
        }
        if let cwd = process.details?.cwd, cwd != "/" {
            Button("Reveal Folder in Finder") { model.revealInFinder(cwd) }
        }
        Divider()
        Button("Copy Command") { model.copy(process.commandLine) }
        Button("Copy PID") { model.copy(String(process.basic.pid)) }
        if PortStopSafety.forProcess(process).isAvailable {
            Divider()
            Button("Stop") { model.stop(process, mode: .graceful) }.disabled(isGroupBusy)
            Button("Force Stop") { model.stop(process, mode: .force) }.disabled(isGroupBusy)
            Button("Stop Only This Process") { model.stop(process, mode: .graceful, onlyThisProcess: true) }
                .disabled(isGroupBusy)
        }
    }
}

// MARK: - Actions menu

/// Shared by the ⋯ button and the row's context menu.
struct PortGroupActionsMenu: View {
    let group: PortListenerGroup
    let model: PortsModel
    var isBusy = false

    var body: some View {
        let ports = group.ports
        if ports.count == 1, let port = ports.first {
            Button("Open in Browser") { model.openInBrowser(port: port) }
        } else if ports.count > 1 {
            Menu("Open in Browser") {
                ForEach(ports, id: \.self) { port in
                    Button("localhost:\(String(port))") { model.openInBrowser(port: port) }
                }
            }
        }
        if let path = group.path, path != "/" {
            Button("Reveal in Finder") { model.revealInFinder(path) }
            if group.category == .project || group.category == .service {
                Button("Open in Terminal") { model.openInTerminal(path) }
                if let editor = model.preferredEditorName {
                    Button("Open in \(editor)") { model.openInEditor(path) }
                }
            }
        }

        Divider()

        if let port = ports.first {
            Button("Copy URL") { model.copy("http://localhost:\(port)") }
            Button(ports.count > 1 ? "Copy Ports" : "Copy Port") { model.copy(ports.map { String($0) }.joined(separator: " ")) }
        }
        Button("Copy Command") {
            model.copy(group.processes.map(\.commandLine).joined(separator: "\n"))
        }
        Button(group.processes.count > 1 ? "Copy PIDs" : "Copy PID") {
            model.copy(group.processes.map { String($0.basic.pid) }.joined(separator: " "))
        }

        let safety = PortStopSafety.forGroup(group)
        if safety.isAvailable {
            Divider()
            if let reason = safety.reason {
                // Same two-step rule as the row's Stop button: the stop items sit one level down, under a note
                // that says what stopping this means.
                Menu("Stop") {
                    Text(reason.menuNote)
                    Divider()
                    stopItems(named: true)
                }
            } else {
                stopItems(named: false)
            }
        }

        Divider()

        Button("Hide This Item") { model.hide(group) }
    }

    @ViewBuilder
    private func stopItems(named: Bool) -> some View {
        Button(named ? "Stop \(group.title)" : "Stop") { model.stop(group, mode: .graceful) }
            .disabled(isBusy)
        Button(named ? "Force Stop \(group.title)" : "Force Stop") { model.stop(group, mode: .force) }
            .disabled(isBusy)
        if group.autoRestartManager != nil {
            Button("Stop & Disable Auto-Start") { model.stopAndDisableAutoStart(group) }
                .disabled(isBusy)
        }
    }
}
