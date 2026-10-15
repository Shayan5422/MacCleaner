import SwiftUI

/// One startup item in a section card.
struct StartupItemRow: View {
    let item: StartupItem
    @Bindable var model: StartupViewModel
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            StartupItemIcon(item: item, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let category = item.code?.category, category.isSignatureProblem {
                        Badge(text: category.title, symbol: category.symbolName, tint: .orange)
                            .help(item.code?.summary ?? "")
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let concern = item.concerns.first {
                    Label(concern.title, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                        .help(item.concerns.map(\.explanation).joined(separator: "\n"))
                }
            }
            Spacer(minLength: 8)
            if item.state.isRunning, let usage = item.usage {
                StartupUsageLabel(usage: usage)
            }
            StartupStateBadge(item: item)
            trailingControl
            Button {
                model.inspectedItem = item
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("Show details")
            .accessibilityLabel("Details for \(item.name)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(isHovering ? Color.hoverFill : .clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { model.inspectedItem = item }
        .contextMenu { StartupItemContextMenu(item: item, model: model) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.name), \(item.kind.title), \(item.state.title)")
    }

    private var subtitle: String {
        var parts: [String] = []
        if item.kind == .appBackgroundItem, let owner = item.owner?.name {
            parts.append(owner)
        } else {
            parts.append(item.developerDescription)
        }
        parts.append(item.triggerSummary)
        if item.kind == .systemDaemon { parts.append("system daemon") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var trailingControl: some View {
        if model.isBusy(item) {
            ProgressView().controlSize(.small).frame(width: 40)
        } else if item.canToggle {
            Toggle("", isOn: Binding(
                get: { item.isEnabled ?? false },
                set: { model.requestToggle(item, enable: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help(item.isEnabled == false ? "Turn on" : "Turn off")
            .accessibilityLabel(item.isEnabled == false ? "Turn on \(item.name)" : "Turn off \(item.name)")
        } else if item.canRemoveLoginItem {
            Button("Remove…") { model.requestRemoveLoginItem(item) }
                .controlSize(.small)
                .help("Stop opening this app at login")
        } else {
            Menu {
                StartupItemContextMenu(item: item, model: model)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(item.isProtected ? "Part of macOS" : "Manage")
            .accessibilityLabel("Actions for \(item.name)")
        }
    }
}

/// App icon for items that belong to an app, otherwise a symbol tile.
struct StartupItemIcon: View {
    let item: StartupItem
    var size: CGFloat = 28

    var body: some View {
        if let path = iconPath {
            FileIcon(path: path, size: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(tint.opacity(0.14))
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.48, weight: .semibold))
                        .foregroundStyle(tint)
                )
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    private var iconPath: String? {
        guard item.state != .broken, item.state != .invalid else { return nil }
        // Embedded helpers rarely have icons of their own; show the app they belong to.
        if item.kind == .appBackgroundItem, let app = item.containingAppPath ?? item.owner?.path { return app }
        if item.kind == .loginItem, let target = item.targetPath, target.hasSuffix(".app") { return target }
        if let app = item.analysis?.enclosingAppPath, item.code?.exists == true { return app }
        return item.owner?.path
    }

    private var symbol: String {
        switch item.state {
        case .broken: return "exclamationmark.triangle.fill"
        case .invalid: return "doc.badge.ellipsis"
        default: break
        }
        if item.analysis?.interpreter != nil { return "terminal" }
        return item.kind.symbolName
    }

    private var tint: Color {
        switch item.state {
        case .broken: return .red
        case .invalid: return .orange
        default: return AppSection.startup.tint
        }
    }
}

struct StartupStateBadge: View {
    let item: StartupItem

    var body: some View {
        Badge(text: title, symbol: item.state.symbolName, tint: tint)
            .help(item.state.explanation)
    }

    private var title: String {
        if item.kind == .appBackgroundItem && item.state == .notLoaded { return "Inactive" }
        return item.state.title
    }

    private var tint: Color {
        switch item.state {
        case .running: return .green
        case .loaded: return .blue
        case .offInSettings, .invalid: return .orange
        case .broken: return .red
        case .notLoaded, .disabled, .notRunning, .unknown: return .gray
        }
    }
}

struct StartupUsageLabel: View {
    let usage: StartupResourceUsage

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help("\(usage.impact.title): \(usage.summary)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(usage.impact.title), \(usage.summary)")
    }

    private var text: String {
        var parts: [String] = []
        if usage.memoryBytes > 0 { parts.append(ByteFormatting.string(usage.memoryBytes)) }
        if let cpu = usage.averageCPU { parts.append(NumberFormatting.percent(cpu, digits: cpu < 0.1 ? 1 : 0)) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var color: Color {
        switch usage.impact {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }
}

/// Context-menu and "…" menu actions for an item.
struct StartupItemContextMenu: View {
    let item: StartupItem
    var model: StartupViewModel

    var body: some View {
        Button("Show Details", systemImage: "info.circle") { model.inspectedItem = item }
        if item.canToggle || item.canMoveToTrash || item.canRemoveLoginItem {
            Divider()
        }
        if item.canToggle {
            if item.isEnabled == false {
                Button("Turn On…", systemImage: "power") { model.requestToggle(item, enable: true) }
            } else {
                Button("Turn Off…", systemImage: "power") { model.requestToggle(item, enable: false) }
            }
        }
        if item.canMoveToTrash {
            Button("Move to Trash…", systemImage: "trash", role: .destructive) { model.requestMoveToTrash(item) }
        }
        if item.canRemoveLoginItem {
            Button("Remove from Login Items…", systemImage: "minus.circle", role: .destructive) { model.requestRemoveLoginItem(item) }
        }
        Divider()
        if let plist = item.plistPath {
            Button("Reveal Property List in Finder", systemImage: "folder") { FinderActions.reveal(plist) }
        }
        if let target = item.targetPath, item.code?.exists == true {
            Button("Reveal Program in Finder", systemImage: "app.badge") { FinderActions.reveal(target) }
        }
        if let path = item.plistPath ?? item.targetPath {
            Button("Copy Path", systemImage: "doc.on.doc") { FinderActions.copyPath(path) }
        }
        Divider()
        Button("Open Login Items Settings", systemImage: "gearshape") { model.openLoginItemsSettings() }
    }
}
