import SwiftUI

extension GuardianLoginCause {
    var tint: Color {
        switch self {
        case .loginItem: return .blue
        case .appLoginItem: return .purple
        case .reopened: return .orange
        case .launchAgent: return .indigo
        case .appHelper: return .teal
        case .openedByApp, .unknown: return .gray
        }
    }
}

/// "Opened automatically at your last login": what opened by itself, why, and what to do about it.
/// Embed on the Startup Items page.
struct StartupGuardOpenedAtLoginView: View {
    @Bindable var model: StartupGuardModel
    /// Background programs shown before "Show All".
    var collapsedProgramCount = 3
    @State private var showsAllPrograms = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GuardianCardHeader(title: "Opened Automatically at Your Last Login", symbol: "power.circle", subtitle: subtitle) {
                if model.isAnalyzingLogin {
                    ProgressView().controlSize(.small)
                } else if model.settings.analyzeLogin {
                    Button {
                        Task { await model.analyzeLoginIfNeeded(force: true) }
                    } label: {
                        Label("Analyze Again", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .help("Look again at what opened when you logged in")
                }
            }
            Divider()
            StartupGuardStatusBanner(model: model, presenter: .openedAtLogin)
            content
            if let analysis = model.loginAnalysis {
                footnotes(analysis)
            }
        }
        .card(padding: 0)
        .startupGuardActions(model, presenter: .openedAtLogin)
    }

    private var subtitle: String {
        guard let analysis = model.loginAnalysis else {
            return "Apps and background programs that opened by themselves when you logged in, and why."
        }
        let day = Calendar.current.isDateInToday(analysis.loginDate) ? "today" : "on \(DateFormatting.day(analysis.loginDate))"
        let time = analysis.loginDate.formatted(date: .omitted, time: .shortened)
        let minutes = Int(analysis.window / 60)
        return "You logged in \(day) at \(time). These opened by themselves within \(minutes) minute\(minutes == 1 ? "" : "s")."
    }

    @ViewBuilder
    private var content: some View {
        if let analysis = model.loginAnalysis {
            if analysis.items.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Nothing opened by itself at your last login.")
                        .font(.callout)
                }
                .padding(14)
            } else {
                let apps = analysis.apps
                let programs = analysis.backgroundPrograms
                if !apps.isEmpty {
                    groupHeader("Apps", count: apps.count)
                    rows(apps, loginDate: analysis.loginDate)
                }
                if !programs.isEmpty {
                    if !apps.isEmpty { Divider() }
                    groupHeader("Background programs", count: programs.count)
                    let shown = showsAllPrograms ? programs : Array(programs.prefix(collapsedProgramCount))
                    rows(shown, loginDate: analysis.loginDate)
                    if programs.count > shown.count || showsAllPrograms && programs.count > collapsedProgramCount {
                        Divider().padding(.leading, 58)
                        Button(showsAllPrograms ? "Show Fewer" : "Show \(programs.count - shown.count) More") { showsAllPrograms.toggle() }
                            .buttonStyle(.borderless)
                            .font(.callout)
                            .padding(.horizontal, 58)
                            .padding(.vertical, 8)
                    }
                }
            }
        } else if model.isAnalyzingLogin {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Looking at what opened when you logged in…").font(.callout).foregroundStyle(.secondary)
            }
            .padding(14)
        } else if !model.settings.analyzeLogin {
            HStack(spacing: 10) {
                Text("The login analysis is turned off in Settings › Guardian.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Analyze Now") { Task { await model.analyzeLoginIfNeeded(force: true) } }
                    .controlSize(.small)
            }
            .padding(14)
        } else {
            HStack(spacing: 10) {
                Text("Mac Cleaner looks at this a couple of minutes after you log in.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Analyze Now") { Task { await model.analyzeLoginIfNeeded(force: true) } }
                    .controlSize(.small)
            }
            .padding(14)
        }
    }

    private func groupHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private func rows(_ items: [GuardianOpenedAtLoginItem], loginDate: Date) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(items) { item in
                StartupGuardLoginRow(item: item, loginDate: loginDate, model: model)
                if item.id != items.last?.id {
                    Divider().padding(.leading, 58)
                }
            }
        }
    }

    @ViewBuilder
    private func footnotes(_ analysis: GuardianLoginAnalysis) -> some View {
        Divider()
        VStack(alignment: .leading, spacing: 6) {
            GuardianFootnote(text: "Only apps and programs that are still running are listed.")
            if !analysis.isComplete {
                GuardianFootnote(symbol: "clock", text: "Mac Cleaner started more than 15 minutes after you logged in, so anything that opened and quit before then isn't listed.")
            }
            if analysis.openedByYouCount > 0 {
                GuardianFootnote(symbol: "hand.tap",
                                 text: "\(analysis.openedByYouCount) app\(analysis.openedByYouCount == 1 ? "" : "s") you opened yourself in that time (from the Dock, Finder or Spotlight) \(analysis.openedByYouCount == 1 ? "isn't" : "aren't") counted.")
            }
            if !analysis.hasLaunchParents {
                GuardianFootnote(symbol: "questionmark.circle", text: "macOS didn't report which app opened which, so some causes are less certain.")
            }
        }
        .padding(12)
    }
}

struct StartupGuardLoginRow: View {
    let item: GuardianOpenedAtLoginItem
    let loginDate: Date
    var model: StartupGuardModel
    @State private var isHovering = false

    var body: some View {
        let actions = model.actions(for: item)
        let primary = actions.first { $0 != .reveal }
        HStack(alignment: .top, spacing: 12) {
            GuardianItemIcon(path: item.path, symbol: item.isApp ? "app" : "gearshape.2", size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(offsetText + (item.isApp ? item.presentation.note.map { " · " + $0 } ?? "" : ""))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Label(item.cause.title, systemImage: item.cause.symbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(item.cause.tint)
                    .labelStyle(.titleAndIcon)
                Text(item.cause.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let signature = item.signature, signature.isConcerning {
                    GuardianSignatureBadge(signature: signature).padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if let primary {
                    Button(primary.title) { model.perform(primary, for: item) }
                        .controlSize(.small)
                }
                Menu {
                    ForEach(actions.filter { $0 != primary }, id: \.self) { action in
                        Button(action.title, systemImage: action.symbolName) { model.perform(action, for: item) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More actions for \(item.name)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isHovering ? Color.hoverFill : .clear)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.name), \(item.cause.title)")
    }

    private var offsetText: String {
        let seconds = max(0, Int(item.started.timeIntervalSince(loginDate).rounded()))
        return seconds < 60 ? "+\(seconds) s" : "+\(seconds / 60) min \(seconds % 60) s"
    }
}

/// The "Reopen windows when logging back in" status, the apps it reopened, and the switch.
/// Embed on the Startup Items page (near Open at Login).
struct StartupGuardReopenCard: View {
    @Bindable var model: StartupGuardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GuardianCardHeader(title: "Reopen Apps at Login", symbol: "macwindow.on.rectangle", tint: .orange, subtitle: subtitle) {
                if let reopen = model.reopen {
                    Badge(text: reopen.savesState ? "On" : "Off", symbol: reopen.savesState ? "checkmark.circle.fill" : "minus.circle",
                          tint: reopen.savesState ? .orange : .gray)
                    if model.isBusy(reopen.savesState ? "reopen|off" : "reopen|on") {
                        ProgressView().controlSize(.small)
                    } else if reopen.savesState {
                        Button("Don't Reopen Apps…") { model.requestReopenChange(turnOn: false, from: .reopen) }
                            .controlSize(.small)
                    } else {
                        Button("Turn On…") { model.requestReopenChange(turnOn: true, from: .reopen) }
                            .controlSize(.small)
                    }
                }
            }
            StartupGuardStatusBanner(model: model, presenter: .reopen)
            if let reopen = model.reopen {
                Divider()
                appsSection(reopen)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    GuardianFootnote(text: "macOS saves this list again every time you log out or restart. To keep one app from reopening, quit it before you log out; editing the saved list wouldn't last.")
                    if reopen.ignoredOtherHostFiles > 0 {
                        GuardianFootnote(symbol: "externaldrive", text: "A saved list from another Mac (copied when you migrated) is ignored; macOS doesn't use it on this Mac.")
                    }
                    if reopen.isHostUncertain {
                        GuardianFootnote(symbol: "questionmark.circle", text: "This Mac's hardware identifier couldn't be read, so the newest saved list is shown.")
                    }
                }
                .padding(12)
            } else {
                Divider()
                Text("The reopen setting hasn't been read yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
            }
        }
        .card(padding: 0)
        .startupGuardActions(model, presenter: .reopen)
    }

    private var subtitle: String {
        guard let reopen = model.reopen else { return "Apps macOS opens again because they were open when you logged out." }
        return reopen.savesState
            ? "On: when you log out or restart, macOS remembers the open apps and opens them again at your next login. That's often why an app “opens by itself”."
            : "Off: apps don't reopen by themselves after you log out or restart. You can still choose to reopen them in the logout dialog."
    }

    @ViewBuilder
    private func appsSection(_ reopen: GuardianReopenState) -> some View {
        let apps = reopen.apps
        VStack(alignment: .leading, spacing: 10) {
            if apps.isEmpty {
                Text(emptyText(reopen))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Reopened at your last login because \(apps.count == 1 ? "it was" : "they were") open when you logged out\(lastLogoutText(reopen)):")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(apps) { app in
                        HStack(spacing: 8) {
                            GuardianItemIcon(path: app.path, symbol: "app", size: 22)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(app.name).font(.callout).lineLimit(1)
                                if app.isHidden {
                                    Text("Reopens hidden").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .help(app.path ?? app.id)
                    }
                }
            }
        }
        .padding(14)
    }

    private func lastLogoutText(_ reopen: GuardianReopenState) -> String {
        guard let date = reopen.listDate else { return "" }
        return " (\(DateFormatting.short(date)))"
    }

    private func emptyText(_ reopen: GuardianReopenState) -> String {
        guard !reopen.savesState else { return "No apps were saved at your last logout, so none were reopened." }
        let when: String
        switch reopen.lastLogoutReason?.lowercased() {
        case "shut down"?: when = " when you last shut down"
        case "restart"?: when = " when you last restarted"
        case "log out"?: when = " when you last logged out"
        default: when = ""
        }
        return "No apps were reopened at your last login: reopening was off\(when)."
    }
}
