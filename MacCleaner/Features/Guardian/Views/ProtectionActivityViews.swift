import SwiftUI

extension ProtectionEvent.Kind {
    /// Filter groups for the activity list.
    enum Group: String, CaseIterable, Identifiable {
        case all, threats, startup, network, updates

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .threats: return "Threats"
            case .startup: return "Startup"
            case .network: return "Network"
            case .updates: return "Scans & Updates"
            }
        }

        func contains(_ kind: ProtectionEvent.Kind) -> Bool {
            switch self {
            case .all: return true
            case .threats: return [.threatFound, .threatQuarantined, .downloadFlagged, .maliciousSite, .maliciousConnection].contains(kind)
            case .startup: return [.startupItemAdded, .startupItemRemoved, .startupItemChanged, .openedAtLogin].contains(kind)
            case .network: return [.portOpened, .portClosed, .maliciousConnection].contains(kind)
            case .updates: return [.definitionsUpdated, .scanCompleted, .appUpdateAvailable].contains(kind)
            }
        }
    }
}

extension ProtectionEvent {
    /// The icon tint: severity first, then a calm color for good news.
    var tint: Color {
        switch severity {
        case .threat: return .red
        case .suspicious: return .orange
        case .recommendation: return .blue
        case .info:
            switch kind {
            case .threatQuarantined, .scanCompleted, .definitionsUpdated: return .green
            case .startupItemRemoved, .portClosed: return .gray
            default: return section?.tint ?? .accentColor
            }
        }
    }
}

/// One event: kind icon tinted by severity, title, detail and time.
struct ProtectionEventRow: View {
    let event: ProtectionEvent
    var isUnseen = false
    var compact = false
    var showsChevron = false

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 9 : 11) {
            Image(systemName: event.kind.symbolName)
                .font(.system(size: compact ? 13 : 15, weight: .semibold))
                .foregroundStyle(event.tint)
                .frame(width: compact ? 26 : 30, height: compact ? 26 : 30)
                .background(event.tint.opacity(0.14), in: Circle())
                .overlay(alignment: .topTrailing) {
                    if isUnseen {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(Color.cardBackground, lineWidth: 1.5))
                            .offset(x: 2, y: -2)
                            .accessibilityLabel("New")
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(event.title)
                        .font((compact ? Font.callout : Font.body).weight(isUnseen ? .semibold : .medium))
                        .lineLimit(compact ? 2 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    GuardianTimeText(date: event.date, style: .caption2, compact: compact)
                        .layoutPriority(1)
                }
                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(compact ? 1 : 2)
                        .truncationMode(.tail)
                }
            }
            if showsChevron && event.section != nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isUnseen ? "New: " : "")\(event.title)\(event.detail.map { ". \($0)" } ?? "")")
    }
}

/// Compact activity feed for the ~360 pt wide menu bar popover: the last few events, unseen ones
/// highlighted, an empty state, and "Show All".
///
/// Events count as seen when the feed disappears (the popover closes), which clears the badge.
struct ProtectionActivityFeedView: View {
    var log: ProtectionEventLog
    var onOpen: (ProtectionEvent) -> Void
    /// "Show All": by default the full list opens in a sheet.
    var onShowAll: (() -> Void)?
    var maximumCount = 8
    var marksSeenOnDisappear = true

    @State private var showsAll = false
    @State private var hovered: ProtectionEvent.ID?

    init(log: ProtectionEventLog, onOpen: @escaping (ProtectionEvent) -> Void, onShowAll: (() -> Void)? = nil,
         maximumCount: Int = 8, marksSeenOnDisappear: Bool = true) {
        self.log = log
        self.onOpen = onOpen
        self.onShowAll = onShowAll
        self.maximumCount = maximumCount
        self.marksSeenOnDisappear = marksSeenOnDisappear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label("Activity", systemImage: "waveform.path.ecg.rectangle")
                    .font(.subheadline.weight(.semibold))
                if log.unseenCount > 0 {
                    Text("\(log.unseenCount) new")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                }
                Spacer()
                if !log.events.isEmpty {
                    Button("Show All") {
                        if let onShowAll { onShowAll() } else { showsAll = true }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            if log.events.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.green)
                        .symbolRenderingMode(.hierarchical)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("All quiet").font(.callout.weight(.semibold))
                        Text("Mac Cleaner is keeping an eye on things.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(log.events.prefix(maximumCount).enumerated()), id: \.element.id) { index, event in
                        Button {
                            onOpen(event)
                        } label: {
                            ProtectionEventRow(event: event, isUnseen: index < log.unseenCount, compact: true)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(hovered == event.id ? Color.hoverFill : (index < log.unseenCount ? Color.accentColor.opacity(0.07) : .clear))
                                )
                        }
                        .buttonStyle(.plain)
                        .onHover { hovered = $0 ? event.id : (hovered == event.id ? nil : hovered) }
                        .contextMenu { ProtectionEventMenu(event: event, log: log) }
                    }
                }
                .padding(.horizontal, -6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear {
            if marksSeenOnDisappear { log.markAllSeen() }
        }
        .sheet(isPresented: $showsAll) {
            VStack(spacing: 0) {
                ProtectionActivityListView(log: log, onOpen: { event in
                    showsAll = false
                    onOpen(event)
                })
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { showsAll = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
            .frame(width: 520, height: 560)
        }
    }
}

/// Context menu actions for an event.
struct ProtectionEventMenu: View {
    let event: ProtectionEvent
    var log: ProtectionEventLog

    var body: some View {
        if let path = event.path, FileManager.default.fileExists(atPath: path) {
            Button("Reveal in Finder", systemImage: "folder") { FinderActions.reveal(path) }
        }
        Button("Copy", systemImage: "doc.on.doc") {
            FinderActions.copyPath([event.title, event.detail].compactMap { $0 }.joined(separator: "\n"))
        }
        Divider()
        Button("Remove", systemImage: "trash") { log.remove(event.id) }
    }
}

/// The full activity list, for a sheet or a page: filters, day groups and Clear.
struct ProtectionActivityListView: View {
    var log: ProtectionEventLog
    var onOpen: ((ProtectionEvent) -> Void)?

    @State private var group: ProtectionEvent.Kind.Group = .all
    @State private var confirmsClear = false

    init(log: ProtectionEventLog, onOpen: ((ProtectionEvent) -> Void)? = nil) {
        self.log = log
        self.onOpen = onOpen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Activity").font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("What Mac Cleaner noticed while watching over your Mac. Kept on this Mac for 30 days.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    confirmsClear = true
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(log.events.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Picker("Show", selection: $group) {
                ForEach(ProtectionEvent.Kind.Group.allCases) { group in
                    Text(title(for: group)).tag(group)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()
            let events = log.events.filter { group.contains($0.kind) }
            if events.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.green)
                        .symbolRenderingMode(.hierarchical)
                    Text(group == .all ? "All quiet" : "Nothing here").font(.headline)
                    Text(group == .all ? "Mac Cleaner is keeping an eye on things." : "No \(group.title.lowercased()) events in the last 30 days.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(30)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(GuardianDayGrouping.groups(events, date: \.date), id: \.title) { day in
                            Text(day.title.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            ForEach(day.items) { event in
                                let unseen = (log.events.firstIndex(where: { $0.id == event.id }) ?? .max) < log.unseenCount
                                Button {
                                    onOpen?(event)
                                } label: {
                                    ProtectionEventRow(event: event, isUnseen: unseen, showsChevron: onOpen != nil)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 7)
                                }
                                .buttonStyle(.plain)
                                .disabled(onOpen == nil)
                                .contextMenu { ProtectionEventMenu(event: event, log: log) }
                                if event.id != day.items.last?.id {
                                    Divider().padding(.leading, 57)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .background(Color.windowBackground)
        .confirmationDialog("Clear all activity?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear Activity", role: .destructive) { log.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the list of past events. Mac Cleaner keeps protecting your Mac as before.")
        }
    }

    private func title(for group: ProtectionEvent.Kind.Group) -> String {
        guard group != .all else { return group.title }
        let count = log.events.filter { group.contains($0.kind) }.count
        return count > 0 ? "\(group.title) \(count)" : group.title
    }
}
