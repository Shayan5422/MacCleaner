import SwiftUI

/// The full list of background items macOS tracks (`sfltool dumpbtm`), after the person asks for it.
/// Shows items other lists miss, such as apps that registered themselves to open at login.
/// Embed on the Startup Items page.
struct StartupGuardBackgroundItemsView: View {
    @Bindable var model: StartupGuardModel
    /// Rows per group before "Show All".
    var rowsPerGroup = 6
    @State private var showsAppleItems = false
    @State private var expandedGroups: Set<String> = []

    private struct Group: Identifiable {
        var id: String
        var title: String
        var subtitle: String
        var items: [GuardianBTMItem]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GuardianCardHeader(title: "Every Background Item", symbol: "list.bullet.rectangle.portrait", tint: .purple, subtitle: subtitle) {
                if let state = model.backgroundItems, !model.isListingBackgroundItems {
                    GuardianTimeText(date: state.dump.date, prefix: "Listed ")
                    Button {
                        Task { await model.listBackgroundItems() }
                    } label: {
                        Label("List Again", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }
            }
            Divider()
            if model.isListingBackgroundItems {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Asking macOS for its list of background items…").font(.callout)
                        Text("This can take up to a minute. Nothing is changed.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
            } else if let state = model.backgroundItems {
                if let error = model.backgroundItemsError {
                    InfoCallout(style: .warning, title: "The list couldn't be refreshed", message: error).padding(14)
                }
                list(state)
            } else {
                intro
            }
        }
        .card(padding: 0)
        .task {
            // A list stored from an earlier session: check its files' signatures once.
            if model.backgroundItems != nil, model.backgroundItemSignatures.isEmpty { await model.refreshBackgroundItemSignatures() }
        }
    }

    private var subtitle: String {
        "macOS keeps its own list of login items, background agents and plug-ins that apps register — including apps that set themselves to open at login without appearing anywhere else."
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = model.backgroundItemsError {
                InfoCallout(style: .warning, title: "The list couldn't be read", message: error)
            }
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("See everything macOS lets run in the background")
                        .font(.callout.weight(.semibold))
                    Text("Mac Cleaner asks macOS (sfltool dumpbtm) for the list it keeps for System Settings › Login Items & Extensions. Depending on your macOS version, macOS asks for your administrator password first. It only reads; nothing is changed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button {
                    Task { await model.listBackgroundItems() }
                } label: {
                    Label("Show Every Background Item", systemImage: "list.bullet.rectangle.portrait")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .help("May ask for your administrator password")
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func list(_ state: GuardianBackgroundItemsState) -> some View {
        let all = state.dump.relevantItems().filter { $0.kind.isRunnable }
        let visible = all.filter { showsAppleItems || !$0.isApple }
        let groups = makeGroups(visible)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                summaryBadge("\(visible.filter(\.disposition.isActive).count) on", symbol: "checkmark.circle.fill", tint: .green)
                summaryBadge("\(visible.filter { !$0.disposition.isActive }.count) off", symbol: "minus.circle", tint: .gray)
                if !state.newItemIDs.isEmpty {
                    summaryBadge("\(state.newItemIDs.count) new since \(state.previousDate.map(DateFormatting.day) ?? "the last list")", symbol: "sparkles", tint: .blue)
                }
                if !state.removedItems.isEmpty {
                    summaryBadge("\(state.removedItems.count) gone", symbol: "minus.circle.fill", tint: .red)
                }
                Spacer()
                Toggle("Show macOS items", isOn: $showsAppleItems)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

        ForEach(groups) { group in
            Divider()
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(group.title).font(.subheadline.weight(.semibold))
                    Text("\(group.items.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(group.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
            // Apps that open at login are what people look for: never collapsed.
            let limit = group.id == "apps" ? Int.max : rowsPerGroup
            let expanded = expandedGroups.contains(group.id)
            let shown = expanded ? group.items : Array(group.items.prefix(limit))
            LazyVStack(spacing: 0) {
                ForEach(shown) { item in
                    StartupGuardBTMRow(item: item, isNew: state.newItemIDs.contains(item.id), signature: model.backgroundItemSignatures[item.id])
                    if item.id != shown.last?.id { Divider().padding(.leading, 54) }
                }
            }
            if group.items.count > limit {
                Button(expanded ? "Show Fewer" : "Show All \(group.items.count)") {
                    if expanded { expandedGroups.remove(group.id) } else { expandedGroups.insert(group.id) }
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .padding(.leading, 54)
                .padding(.vertical, 8)
            }
        }

        if !state.removedItems.isEmpty {
            Divider()
            Text("Gone since the last list").font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
            ForEach(state.removedItems.filter { showsAppleItems || !$0.isApple }) { item in
                StartupGuardBTMRow(item: item, isNew: false, isRemoved: true)
            }
        }

        Divider()
        VStack(alignment: .leading, spacing: 6) {
            GuardianFootnote(text: "To turn an item off, use the app's own settings or System Settings › General › Login Items & Extensions. macOS doesn't let other apps change background items.")
            if state.dump.otherAccountCount > 0 {
                GuardianFootnote(symbol: "person.2", text: "Items of \(state.dump.otherAccountCount) other user account\(state.dump.otherAccountCount == 1 ? "" : "s") on this Mac aren't shown.")
            }
        }
        .padding(12)
    }

    private func summaryBadge(_ text: String, symbol: String, tint: Color) -> some View {
        Badge(text: text, symbol: symbol, tint: tint)
    }

    private func makeGroups(_ items: [GuardianBTMItem]) -> [Group] {
        func sorted(_ items: [GuardianBTMItem]) -> [GuardianBTMItem] {
            items.sorted { lhs, rhs in
                if lhs.disposition.isActive != rhs.disposition.isActive { return lhs.disposition.isActive }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
        }
        let definitions: [(String, String, String, Set<GuardianBTMKind>)] = [
            ("apps", "Apps that open at login", "Registered by the app itself. These often don't appear in older login-item lists.", [.app, .userItem]),
            ("helpers", "Login helpers", "Small helper apps inside an app that open at login.", [.loginItem]),
            ("agents", "Background agents and daemons", "Programs launchd starts at login or startup, or keeps running.", [.agent, .daemon, .legacyAgent, .legacyDaemon]),
            ("tasks", "Background tasks", "Work an app schedules to run in the background.", [.backgroundTasks]),
            ("plugins", "Plug-ins", "Spotlight importers, Quick Look and Dock plug-ins that macOS loads.", [.spotlight, .quickLook, .dockTile, .unknown]),
        ]
        return definitions.compactMap { id, title, subtitle, kinds in
            // An app entry that only owns other items isn't something that opens.
            let members = items.filter { kinds.contains($0.kind) && ($0.kind != .app || $0.disposition.enabled == true) }
            return members.isEmpty ? nil : Group(id: id, title: title, subtitle: subtitle, items: sorted(members))
        }
    }
}

struct StartupGuardBTMRow: View {
    let item: GuardianBTMItem
    var isNew: Bool
    var isRemoved = false
    var signature: GuardianSignatureSummary?
    @State private var isHovering = false

    /// Where the item's file is, when that's worth pointing out.
    enum Location {
        case trash, otherVolume, missing

        var badge: (text: String, symbol: String, tint: Color, help: String) {
            switch self {
            case .trash: return ("In the Trash", "trash", .orange, "The app is in the Trash but macOS still has it registered.")
            case .otherVolume: return ("On another disk", "externaldrive", .orange, "The file is on a disk image or another disk, not in Applications.")
            case .missing: return ("File missing", "questionmark.folder", .gray, "macOS still lists it, but its file no longer exists.")
            }
        }
    }

    static func location(of path: String?, home: String = LaunchdLocations.home) -> Location? {
        guard let path, path.hasPrefix("/") else { return nil }
        if PathUtilities.isSameOrDescendant(path, of: home + "/.Trash") { return .trash }
        if LaunchdPathProbe.status(path) == .missing { return .missing }
        if path.hasPrefix("/Volumes/") { return .otherVolume }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            GuardianItemIcon(path: iconPath, symbol: item.kind.symbolName, tint: .purple, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isNew { Badge(text: "New", symbol: "sparkles", tint: .blue) }
                    if !isRemoved, let location = Self.location(of: item.path ?? item.executablePath) {
                        Badge(text: location.badge.text, symbol: location.badge.symbol, tint: location.badge.tint)
                            .help(location.badge.help)
                    }
                    if let signature, signature.isConcerning || signature.category.isSignatureProblem {
                        GuardianSignatureBadge(signature: signature)
                    }
                }
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let path = item.executablePath ?? item.path {
                    PathText(path: path, font: .caption)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                stateBadge
                if let lastUse = item.lastUse {
                    Text("Last ran \(DateFormatting.relative(lastUse))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .opacity(isRemoved ? 0.6 : 1)
        .background(isHovering ? Color.hoverFill : .clear)
        .onHover { isHovering = $0 }
        .contextMenu {
            if let path = item.path ?? item.executablePath, FileManager.default.fileExists(atPath: path) {
                Button("Reveal in Finder", systemImage: "folder") { FinderActions.reveal(path) }
                Button("Copy Path", systemImage: "doc.on.doc") { FinderActions.copyPath(path) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var iconPath: String? {
        if let path = item.path, path.hasSuffix(".app") || path.hasSuffix(".appex") { return path }
        if let executable = item.executablePath, let app = LaunchdProgramAnalyzer.outermostAppBundle(in: executable) { return app }
        if let path = item.path, let app = LaunchdProgramAnalyzer.outermostAppBundle(in: path) { return app }
        return nil
    }

    private var detailLine: String {
        var parts = [item.kind.title]
        if let developer = item.developerName { parts.append(developer) }
        if let team = item.teamIdentifier { parts.append("Team \(team)") }
        if item.isSandboxed { parts.append("sandboxed") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var stateBadge: some View {
        if isRemoved {
            Badge(text: "Gone", symbol: "minus.circle.fill", tint: .red)
        } else if item.disposition.enabled == true && item.disposition.allowed == false {
            Badge(text: "Not allowed", symbol: "hand.raised.fill", tint: .orange)
                .help("Turned off under Allow in the Background in System Settings")
        } else if item.disposition.isActive {
            Badge(text: "On", symbol: "checkmark.circle.fill", tint: .green)
        } else {
            Badge(text: "Off", symbol: "minus.circle", tint: .gray)
        }
    }
}

/// Startup sources the Startup Items page doesn't list: apps that open themselves at login,
/// cron jobs, Finder and background extensions, plug-ins, hooks, periodic and legacy items —
/// with what each source needed (Full Disk Access, an administrator). Embed on the Startup Items page.
struct StartupGuardMoreItemsView: View {
    @Bindable var model: StartupGuardModel
    @State private var showsSources = false

    private struct SourceGroup: Identifiable {
        var source: GuardianStartupSource
        var records: [GuardianStartupRecord]
        var id: String { source.rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GuardianCardHeader(title: "More Things That Start Automatically", symbol: "square.stack.3d.up", tint: .indigo,
                               subtitle: "Beyond login items and launch agents: apps that open themselves at login, cron jobs, extensions, plug-ins and older mechanisms.")
            StartupGuardStatusBanner(model: model, presenter: .moreItems)
            let groups = StartupGuardModel.extraSources.map { SourceGroup(source: $0, records: model.records(of: $0)) }.filter { !$0.records.isEmpty }
            Divider()
            if groups.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: model.snapshot == nil ? "hourglass" : "checkmark.circle.fill")
                        .foregroundStyle(model.snapshot == nil ? Color.secondary : Color.green)
                    Text(model.snapshot == nil ? "Reading…" : "Nothing else starts automatically on this Mac.")
                        .font(.callout)
                }
                .padding(14)
            } else {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Text(group.source.title).font(.subheadline.weight(.semibold))
                            Text("\(group.records.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                        ForEach(group.records) { record in
                            StartupGuardRecordRow(record: record, model: model)
                            if record.id != group.records.last?.id { Divider().padding(.leading, 54) }
                        }
                    }
                    if group.id != groups.last?.id { Divider() }
                }
            }
            Divider()
            DisclosureGroup(isExpanded: $showsSources) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.statuses) { status in
                        StartupGuardSourceStatusRow(status: status)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("What was checked").font(.caption.weight(.semibold))
            }
            .padding(12)
            if model.onDemandExtensionCount > 0 {
                GuardianFootnote(text: "\(model.onDemandExtensionCount) other app extensions (widgets, share and network extensions…) run only when you use them, so they aren't listed.")
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .card(padding: 0)
        .startupGuardActions(model, presenter: .moreItems)
    }
}

/// One record of the inventory (used for the extra sources).
struct StartupGuardRecordRow: View {
    let record: GuardianStartupRecord
    var model: StartupGuardModel
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            GuardianItemIcon(path: record.iconPath, symbol: record.kind.symbolName, tint: .indigo, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if let owner = record.ownerName, owner != record.name {
                        Text(owner).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Text([record.kind.title, record.trigger].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let command = record.kind == .cronJob ? record.commandLine : record.programPath {
                    Text(PathUtilities.abbreviate(command))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(command)
                }
                if let note = record.note {
                    Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    if record.programPath != nil { GuardianSignatureBadge(signature: record.signature) }
                    if record.isEnabled == false {
                        Badge(text: "Off", symbol: "minus.circle", tint: .gray)
                    } else if record.isRunning == true {
                        Badge(text: "Running", symbol: "play.circle.fill", tint: .green)
                    }
                }
                Text(record.isBaseline ? "Since \(DateFormatting.day(record.firstSeen))" : "First seen \(DateFormatting.day(record.firstSeen))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(record.isBaseline ? "Already there when Startup Guard started watching" : "First seen \(DateFormatting.short(record.firstSeen))")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isHovering ? Color.hoverFill : .clear)
        .onHover { isHovering = $0 }
        .contextMenu { StartupGuardRecordMenuItems(record: record, isCurrent: true, model: model, presenter: .moreItems) }
        .accessibilityElement(children: .combine)
    }
}

struct StartupGuardSourceStatusRow: View {
    let status: GuardianSourceStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
            Text(status.source.title).font(.caption)
            Spacer(minLength: 8)
            Text(stateText).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        .help(status.note ?? "")
    }

    private var stateText: String {
        switch status.state {
        case .read: return status.count == 1 ? "1 item" : "\(status.count) items"
        case .notPresent: return status.note ?? "None"
        case .needsFullDiskAccess: return "Needs Full Disk Access"
        case .needsAdministrator: return "Needs an administrator"
        case .needsAutomation: return "Needs Automation access"
        case .notChecked: return "Not checked yet"
        case .failed: return status.note ?? "Couldn't be read"
        }
    }

    private var symbol: String {
        switch status.state {
        case .read, .notPresent: return "checkmark.circle.fill"
        case .needsFullDiskAccess, .needsAdministrator, .needsAutomation: return "lock.fill"
        case .notChecked: return "clock"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch status.state {
        case .read, .notPresent: return .green
        case .needsFullDiskAccess, .needsAdministrator, .needsAutomation, .failed: return .orange
        case .notChecked: return .secondary
        }
    }
}
