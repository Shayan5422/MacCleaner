import AppKit
import SwiftUI

/// One installed tool: what it can give back, grouped, with checkboxes for
/// files and Run buttons for official cleanup commands.
struct DeveloperToolCard: View {
    var report: DeveloperToolReport
    @Bindable var model: DeveloperToolsViewModel
    var onQuickLook: (String) -> Void

    private var isCollapsed: Bool { model.collapsedTools.contains(report.tool) }
    private var isRefreshing: Bool { model.refreshingTools.contains(report.tool) }
    private var hasFileItems: Bool { report.items.contains(where: \.isFileItem) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !isCollapsed {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(report.notes) { note in
                        DeveloperNoteRow(note: note)
                    }
                    if report.items.isEmpty {
                        Text("Nothing to clean right now.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    ForEach(report.groups, id: \.self) { group in
                        let items = report.items.filter { $0.group == group }
                        let isExpanded = model.isGroupExpanded(group, in: report)
                        DeveloperGroupHeader(
                            title: group,
                            items: items,
                            isExpanded: isExpanded,
                            selectionState: model.selectionState(of: items),
                            onToggleExpanded: { withAnimation(.easeInOut(duration: 0.2)) { model.toggleGroup(group, in: report) } },
                            onSelectAll: { model.setSelection(of: items, selected: $0) }
                        )
                        if isExpanded {
                            ForEach(items) { item in
                                DeveloperItemRow(
                                    item: item,
                                    isSelected: model.isSelected(item),
                                    isBusy: model.isBusy,
                                    onToggle: { model.toggle(item) },
                                    onRun: { model.requestCommand(item) },
                                    onQuickLook: onQuickLook,
                                    onExclude: item.canExclude ? { model.exclude(item) } : nil
                                )
                                Divider().padding(.leading, 44)
                            }
                        }
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Color.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(Color.subtleBorder))
    }

    private var header: some View {
        HStack(spacing: 12) {
            if hasFileItems {
                let state = model.selectionState(of: report)
                Toggle(isOn: Binding(get: { state ?? false }, set: { model.setSelection(of: report, selected: $0) })) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .overlay {
                        if state == nil {
                            Image(systemName: "minus").font(.system(size: 8, weight: .bold)).allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Select all removable \(report.tool.title) items")
            }
            IconTile(symbol: report.tool.symbol, gradient: AppSection.developer.gradient, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(report.tool.title).font(.headline)
                Text(report.location.map { PathUtilities.abbreviate($0) } ?? report.tool.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if isRefreshing {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .trailing, spacing: 1) {
                SizeText(bytes: report.recoverableBytes, font: .callout.weight(.semibold))
                if report.possibleExtraBytes > 0 {
                    Text("+ up to \(ByteFormatting.string(report.possibleExtraBytes))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 80, alignment: .trailing)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { model.toggleCollapsed(report.tool) }
            } label: {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCollapsed ? "Expand \(report.tool.title)" : "Collapse \(report.tool.title)")
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            withAnimation(.easeInOut(duration: 0.2)) { model.toggleCollapsed(report.tool) }
        }
    }
}

/// Title of a group inside a tool card, with its count, total and selection.
private struct DeveloperGroupHeader: View {
    var title: String
    var items: [DeveloperItem]
    var isExpanded: Bool
    var selectionState: Bool?
    var onToggleExpanded: () -> Void
    var onSelectAll: (Bool) -> Void

    private var totalBytes: Int64 {
        items.filter { $0.countsTowardTotal && !$0.sizeIsUpperBound }.reduce(0) { $0 + $1.bytes }
    }

    private var hasFileItems: Bool { items.contains(where: \.isFileItem) }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleExpanded) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                    Text("\(items.count)")
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(NumberFormatting.count(items.count, "item"))")
            .accessibilityHint(isExpanded ? "Collapses the group" : "Expands the group")
            .accessibilityAddTraits(.isHeader)
            Spacer()
            if hasFileItems {
                Button(selectionState == true ? "Deselect All" : "Select All") {
                    onSelectAll(selectionState != true)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            if totalBytes > 0 {
                SizeText(bytes: totalBytes, font: .caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

private struct DeveloperNoteRow: View {
    var note: DeveloperNote

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: note.style == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(note.style == .warning ? Color.orange : Color.secondary)
            Text(note.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }
}

/// One cleanable item: a checkbox for files, a Run button for commands.
struct DeveloperItemRow: View {
    var item: DeveloperItem
    var isSelected: Bool
    var isBusy: Bool
    var onToggle: () -> Void
    var onRun: () -> Void
    var onQuickLook: (String) -> Void
    var onExclude: (() -> Void)?

    @State private var isHovering = false

    private var sizeLabel: String {
        if item.bytes == 0 { return item.command == nil ? ByteFormatting.string(0) : "—" }
        return (item.sizeIsUpperBound ? "up to " : "") + ByteFormatting.string(item.bytes)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if item.isFileItem {
                Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel("Select \(item.title)")
            } else {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
            }
            if let path = item.path, item.isFileItem {
                FileIcon(path: path, size: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).lineLimit(1)
                    if item.safety != .safe { SafetyBadge(safety: item.safety) }
                }
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let command = item.command {
                    Text(command.commandLine)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(item.regeneration)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if isHovering, let path = item.path, item.isFileItem {
                Button { onQuickLook(path) } label: { Image(systemName: "eye") }
                    .buttonStyle(.borderless)
                    .help("Quick Look")
            }
            Text(sizeLabel)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 84, alignment: .trailing)
            if item.command != nil {
                Button("Run…", action: onRun)
                    .disabled(isBusy)
                    .help("Shows the exact command before running it")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isHovering ? Color.hoverFill : .clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            if item.isFileItem { onToggle() }
        }
        .help(item.explanation)
        .contextMenu {
            if let path = item.path {
                FileContextMenu(path: path, onQuickLook: { onQuickLook(path) }, onExclude: onExclude)
            }
            if let command = item.command {
                Divider()
                Button("Copy Command", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command.commandLine, forType: .string)
                }
                Button("Run…", systemImage: "terminal", action: onRun)
                    .disabled(isBusy)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.title), \(sizeLabel)")
    }
}
