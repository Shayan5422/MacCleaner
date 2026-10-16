import SwiftUI

/// Timeline of startup-item changes: added, removed and changed items with their program,
/// signature and the antivirus verdict, plus actions. Embed on the Startup Items page.
struct StartupGuardChangesView: View {
    @Bindable var model: StartupGuardModel
    /// Rows shown before "Show More".
    var initialLimit = 20

    @State private var limit: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GuardianCardHeader(title: "Startup Changes", symbol: "clock.arrow.circlepath", subtitle: subtitle) {
                StartupGuardCheckButton(model: model)
            }
            StartupGuardStatusBanner(model: model, presenter: .changes)

            if !model.changes.isEmpty {
                Picker("Show", selection: $model.changeFilter) {
                    ForEach(StartupGuardModel.ChangeFilter.allCases) { filter in
                        Text(filterTitle(filter)).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .accessibilityLabel("Filter changes")
            }

            Divider()
            let changes = model.filteredChanges
            if changes.isEmpty {
                emptyState
            } else {
                let shown = Array(changes.prefix(limit ?? initialLimit))
                ForEach(GuardianDayGrouping.groups(shown, date: \.date), id: \.title) { group in
                    Text(group.title.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                    ForEach(group.items) { change in
                        StartupGuardChangeRow(change: change, model: model)
                        if change.id != group.items.last?.id {
                            Divider().padding(.leading, 58)
                        }
                    }
                }
                if changes.count > shown.count {
                    Divider()
                    Button("Show \(min(changes.count - shown.count, 50)) More") { limit = shown.count + 50 }
                        .buttonStyle(.borderless)
                        .frame(maxWidth: .infinity)
                        .padding(10)
                }
            }

            Divider()
            HStack(spacing: 10) {
                GuardianFootnote(text: "Startup Guard checks at launch, every 10 minutes, and right away when a launch agent folder changes.")
                Button("Open Startup Items") { model.openStartupItems() }
                    .controlSize(.small)
            }
            .padding(12)
        }
        .card(padding: 0)
        .startupGuardActions(model, presenter: .changes)
    }

    private var subtitle: String {
        guard let since = model.watchingSince else { return "Startup Guard records when something starts automatically for the first time, stops, or changes." }
        return "What was added, removed or changed since Startup Guard started watching on \(DateFormatting.day(since))."
    }

    private func filterTitle(_ filter: StartupGuardModel.ChangeFilter) -> String {
        switch filter {
        case .all: return "All \(model.changes.count)"
        case .added: return "Added \(model.count(of: .added))"
        case .removed: return "Removed \(model.count(of: .removed))"
        case .changed: return "Changed \(model.count(of: .changed))"
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.snapshot == nil ? "hourglass" : "checkmark.circle")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(model.snapshot == nil ? Color.secondary : Color.green)
            Text(model.snapshot == nil ? "Taking the first inventory…" : model.changeFilter == .all ? "No changes yet" : "No \(model.changeFilter.title.lowercased()) items")
                .font(.headline)
            Text(emptyMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 14)
    }

    private var emptyMessage: String {
        guard let snapshot = model.snapshot else {
            return "Startup Guard is reading everything that starts automatically. Later checks are compared with this first inventory."
        }
        let count = snapshot.records.filter(\.willStartAutomatically).count
        return "\(count) item\(count == 1 ? " starts" : "s start") automatically and nothing has changed since \(DateFormatting.day(snapshot.createdAt)). You'll see here when an app adds, removes or changes one."
    }
}

/// "Checked 3 min ago" with a Check Now button.
struct StartupGuardCheckButton: View {
    var model: StartupGuardModel

    var body: some View {
        HStack(spacing: 8) {
            if model.isChecking {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.caption).foregroundStyle(.secondary)
            } else if let date = model.lastCheck {
                GuardianTimeText(date: date, prefix: "Checked ")
            }
            Button {
                Task { await model.check(reason: .manual) }
            } label: {
                Label("Check Now", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(model.isChecking)
            .help("Compare everything that starts automatically with the last check")
        }
    }
}

struct StartupGuardChangeRow: View {
    let change: GuardianStartupChange
    var model: StartupGuardModel
    @State private var isHovering = false

    var body: some View {
        let record = change.record
        let current = model.currentRecord(for: change)
        HStack(alignment: .top, spacing: 12) {
            GuardianChangeIcon(change: change)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(record.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(record.kind.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                (Text(change.summary)
                    .foregroundStyle(change.severity >= .suspicious ? AnyShapeStyle(change.severity.tint) : AnyShapeStyle(.secondary))
                 + Text(record.displayName != record.name ? "  ·  " + record.name : "").foregroundStyle(.tertiary))
                    .font(.caption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let program = record.programPath {
                    PathText(path: program, font: .caption)
                } else if let note = record.note {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if record.programPath != nil || record.signature != nil {
                        GuardianSignatureBadge(signature: record.signature)
                    }
                    if change.kind != .removed && record.isEnabled == false {
                        Badge(text: "Turned off", symbol: "power", tint: .gray)
                    }
                    GuardianVerdictBadge(verdict: change.verdict, isScanning: change.isScanning)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                GuardianTimeText(date: change.date)
                StartupGuardRecordMenu(record: current ?? record, isCurrent: current != nil, model: model, presenter: .changes)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isHovering ? Color.hoverFill : .clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu { StartupGuardRecordMenuItems(record: current ?? record, isCurrent: current != nil, model: model, presenter: .changes) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(change.kind.title): \(record.displayName), \(record.kind.title)")
    }
}

/// "…" menu for a startup record.
struct StartupGuardRecordMenu: View {
    let record: GuardianStartupRecord
    var isCurrent: Bool
    var model: StartupGuardModel
    var presenter: GuardianPresenter

    var body: some View {
        Menu {
            StartupGuardRecordMenuItems(record: record, isCurrent: isCurrent, model: model, presenter: presenter)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Actions")
        .accessibilityLabel("Actions for \(record.name)")
    }
}

struct StartupGuardRecordMenuItems: View {
    let record: GuardianStartupRecord
    var isCurrent: Bool
    var model: StartupGuardModel
    var presenter: GuardianPresenter

    var body: some View {
        if let path = record.revealPath, FileManager.default.fileExists(atPath: path) {
            Button("Reveal in Finder", systemImage: "folder") { model.reveal(record) }
        }
        if let program = record.programPath, program != record.revealPath, FileManager.default.fileExists(atPath: program) {
            Button("Reveal Program in Finder", systemImage: "app.badge") { FinderActions.reveal(program) }
        }
        if isCurrent && (model.canTurnOff(record) || model.canMoveToTrash(record) || model.canRemoveLoginItem(record)) {
            Divider()
            if model.canTurnOff(record) {
                Button("Turn Off…", systemImage: "power") { model.requestTurnOff(record, from: presenter) }
            }
            if model.canMoveToTrash(record) {
                Button("Move to Trash…", systemImage: "trash", role: .destructive) { model.requestMoveToTrash(record, from: presenter) }
            }
            if model.canRemoveLoginItem(record) {
                Button("Remove from Login Items…", systemImage: "minus.circle", role: .destructive) { model.requestRemoveLoginItem(record, from: presenter) }
            }
        }
        Divider()
        if let path = record.revealPath {
            Button("Copy Path", systemImage: "doc.on.doc") { FinderActions.copyPath(path) }
        }
        Button("Open Startup Items", systemImage: "power.circle") { model.openStartupItems() }
        Button("Open Login Items Settings", systemImage: "gearshape") { model.openLoginItemsSettings() }
    }
}
