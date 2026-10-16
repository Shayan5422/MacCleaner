import SwiftUI

/// Web Shield status, watched browsers, last check and recent warnings. Embed in the Antivirus
/// page's Shields tab.
struct WebShieldCard: View {
    @Bindable var model: WebShieldModel
    @Environment(PermissionManager.self) private var permissions: PermissionManager?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GuardianCardHeader(title: "Web Shield", symbol: "globe.badge.chevron.backward", tint: AppSection.antivirus.tint,
                               subtitle: "Warns you when a browser opens a site that URLhaus or ThreatFox list for malware.") {
                statusBadge
                Toggle("Web Shield", isOn: Binding(get: { model.settings.webShieldEnabled }, set: { model.settings.webShieldEnabled = $0 }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel("Web Shield")
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                statusLine
                if model.settings.webShieldEnabled {
                    browserList
                    accessCallout
                }
            }
            .padding(14)
            if model.settings.webShieldEnabled && model.feedsLoaded {
                Divider()
                warningsSection
            }
            Divider()
            GuardianFootnote(symbol: "lock.shield",
                             text: "Mac Cleaner reads only the visits added to your browsers' history since its last check, on this Mac, keeps only matches, and never stores or sends the sites you visit. Private windows aren't saved in history, so they can't be checked. A warning can take up to a minute after a page opens. Mac Cleaner can't block sites.")
                .padding(12)
        }
        .card(padding: 0)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch model.status {
        case .off: Badge(text: "Off", symbol: "minus.circle", tint: .gray)
        case .waitingForFeeds: Badge(text: "Waiting for feeds", symbol: "hourglass", tint: .orange)
        case .idle: Badge(text: "On", symbol: "checkmark.shield.fill", tint: .green)
        case .watching: Badge(text: "Watching", symbol: "eye.fill", tint: .green)
        case .needsAccess: Badge(text: "Needs access", symbol: "lock.fill", tint: .orange)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.status {
        case .off:
            Text("Off. Turn it on to be warned when a browser opens a known malware site.")
                .font(.callout).foregroundStyle(.secondary)
        case .waitingForFeeds:
            HStack(spacing: 10) {
                InfoCallout(style: .warning, title: "Threat feeds aren't loaded yet",
                            message: "The Web Shield checks sites against the URLhaus and ThreatFox feeds. Until they're downloaded on the Antivirus page, nothing is checked.")
            }
        case .idle:
            HStack(spacing: 8) {
                Text(idleText).font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                checkButton
            }
        case .watching:
            HStack(spacing: 8) {
                Text(watchingText).font(.callout)
                Spacer(minLength: 8)
                checkButton
            }
        case .needsAccess:
            HStack(spacing: 8) {
                Text("On, but nothing is checked right now: macOS blocks the history of the open browser.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                checkButton
            }
        }
    }

    private var idleText: String {
        var text = "On. No watched browser is open right now."
        if let date = model.lastCheck { text += " Last checked \(DateFormatting.relative(date))." }
        return text
    }

    private var watchingText: String {
        let names = model.watchedRunningBrowsers.map(\.browser.name)
        let list = ListFormatter.localizedString(byJoining: names)
        if let date = model.lastCheck { return "Watching \(list) · checked \(DateFormatting.relative(date))" }
        return "Watching \(list)"
    }

    private var checkButton: some View {
        Button {
            Task { await model.checkAllNow() }
        } label: {
            if model.isChecking {
                ProgressView().controlSize(.small)
            } else {
                Label("Check Now", systemImage: "arrow.clockwise")
            }
        }
        .controlSize(.small)
        .disabled(model.isChecking || !model.feedsLoaded)
    }

    @ViewBuilder
    private var browserList: some View {
        let installed = model.installedBrowsers
        if installed.isEmpty {
            Text("No supported browser is installed (Safari, Chrome, Firefox, Edge, Brave, Arc, Vivaldi, Opera, Chromium).")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(installed) { state in
                    HStack(spacing: 8) {
                        GuardianItemIcon(path: state.applicationPath, symbol: "globe", size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(state.browser.name).font(.callout).lineLimit(1)
                            Label(browserStateText(state), systemImage: browserStateSymbol(state))
                                .font(.caption2)
                                .foregroundStyle(browserStateTint(state))
                                .labelStyle(.titleAndIcon)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .help(state.lastError ?? "")
                }
            }
        }
    }

    private func browserStateText(_ state: WebShieldModel.BrowserState) -> String {
        if !state.isWatched { return "Not watched" }
        if state.access == .needsFullDiskAccess { return "Needs Full Disk Access" }
        if state.access == .noHistory { return "No history yet" }
        if !state.isRunning { return "Not open" }
        if model.status != .watching { return "Not checked now" }
        return state.profileCount > 1 ? "Watching \(state.profileCount) profiles" : "Watching"
    }

    private func browserStateSymbol(_ state: WebShieldModel.BrowserState) -> String {
        if !state.isWatched { return "eye.slash" }
        if state.access == .needsFullDiskAccess { return "lock.fill" }
        if !state.isRunning { return "moon.zzz" }
        return model.status == .watching ? "eye.fill" : "pause.circle"
    }

    private func browserStateTint(_ state: WebShieldModel.BrowserState) -> Color {
        if state.access == .needsFullDiskAccess && state.isWatched { return .orange }
        if state.isWatched && state.isRunning && model.status == .watching { return .green }
        return .secondary
    }

    @ViewBuilder
    private var accessCallout: some View {
        let blocked = model.browsersNeedingAccess
        if !blocked.isEmpty {
            let names = ListFormatter.localizedString(byJoining: blocked.map(\.browser.name))
            VStack(alignment: .leading, spacing: 8) {
                InfoCallout(style: .warning, title: "macOS protects the history of \(names)",
                            message: "Allow Full Disk Access for Mac Cleaner so the Web Shield can read new visits. Until then, \(blocked.count == 1 ? "this browser isn't" : "these browsers aren't") checked.")
                HStack {
                    Spacer()
                    Button("Open Full Disk Access Settings") {
                        if let permissions { permissions.open(.fullDiskAccess) } else { NSWorkspace.shared.open(SystemSettingsPane.fullDiskAccess.url) }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var warningsSection: some View {
        let warnings = model.recentWarnings
        if warnings.isEmpty {
            let checked = model.browsers.filter { $0.isInstalled && $0.isWatched && $0.access == .readable && $0.lastCheck != nil }
            HStack(spacing: 10) {
                Image(systemName: checked.isEmpty ? "clock" : "checkmark.circle.fill").foregroundStyle(checked.isEmpty ? Color.secondary : Color.green)
                Text(checked.isEmpty
                     ? "No warnings. No browser history has been checked yet."
                     : "No known malware sites in the history checked so far (\(ListFormatter.localizedString(byJoining: checked.map(\.browser.name)))).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Recent Warnings").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Check My Downloads") { model.checkMyDownloads() }
                        .controlSize(.small)
                        .help("Open the Antivirus page to scan your Downloads folder")
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)
                ForEach(warnings) { warning in
                    WebShieldWarningRow(warning: warning, model: model)
                    if warning.id != warnings.last?.id { Divider().padding(.leading, 50) }
                }
            }
        }
    }
}

struct WebShieldWarningRow: View {
    let warning: WebShieldWarning
    var model: WebShieldModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 18))
                .foregroundStyle(.red)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(warning.host)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(warning.listingPhrase + ".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text([warning.browserName, warning.profileName].compactMap { $0 }.joined(separator: " · ") + " · opened " + DateFormatting.relative(warning.visitDate ?? warning.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let reference = warning.reference {
                Link(destination: reference) {
                    Image(systemName: "info.circle")
                }
                .help("Open the feed's page about this entry")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contextMenu {
            Button("Copy Host", systemImage: "doc.on.doc") { FinderActions.copyPath(warning.host) }
            Button("Remove Warning", systemImage: "trash") { model.removeWarning(warning) }
        }
        .accessibilityElement(children: .combine)
    }
}
