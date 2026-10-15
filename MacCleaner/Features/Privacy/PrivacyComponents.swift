import AppKit
import SwiftUI

/// The icon of an installed app, or a symbol when the app isn't installed.
struct PrivacyAppIcon: View {
    var bundleIdentifier: String?
    var fallbackSymbol: String = "globe"
    var size: CGFloat = 32

    var body: some View {
        if let bundleIdentifier, let icon = IconCache.shared.appIcon(bundleIdentifier: bundleIdentifier) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: size * 0.55, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}

/// Summary card for one browser. Clicking it shows only that browser's data.
struct PrivacyBrowserCard: View {
    var report: PrivacyBrowserReport
    var isRunning: Bool
    var isQuitting: Bool
    var isSelected: Bool
    var onSelect: () -> Void
    var onQuit: () -> Void
    var onOpenSettings: () -> Void

    @State private var isHovering = false

    private var categoryRows: [(category: PrivacyCategory, bytes: Int64)] {
        PrivacyCategory.browserCategories.compactMap { category in
            let bytes = report.bytes(in: category)
            return bytes > 0 ? (category, bytes) : nil
        }
    }

    private var visitCount: Int? {
        let counts = report.firefoxHistory.compactMap(\.visitCount)
        return counts.isEmpty ? nil : counts.reduce(0, +)
    }

    private var subtitle: String {
        var parts: [String] = []
        if !report.isInstalled { parts.append("Not installed") }
        let profiles = report.profiles.count
        if profiles > 1 { parts.append("\(profiles) profiles") }
        if report.hasData { parts.append(ByteFormatting.string(report.totalBytes)) }
        if parts.isEmpty { parts.append(report.isBlocked ? "Protected by macOS" : "No data found") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                PrivacyAppIcon(bundleIdentifier: report.isInstalled ? report.browser.primaryBundleIdentifier : nil, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(report.browser.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isRunning {
                    Badge(text: isQuitting ? "Quitting" : "Open", symbol: "circle.fill", tint: .orange)
                        .help("\(report.browser.name) is open. Quit it to clean its data.")
                }
            }

            if !categoryRows.isEmpty || visitCount != nil {
                VStack(spacing: 4) {
                    ForEach(categoryRows, id: \.category) { row in
                        HStack(spacing: 4) {
                            Label(row.category.shortTitle, systemImage: row.category.symbol)
                                .labelStyle(PrivacyCompactLabelStyle())
                            Spacer()
                            if report.isProtected(row.category) {
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .help("Protected by macOS. Allow Full Disk Access to clean it.")
                                    .accessibilityLabel("Protected by macOS")
                            }
                            SizeText(bytes: row.bytes, font: .caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let visitCount {
                        HStack {
                            Label("History", systemImage: PrivacyCategory.history.symbol)
                                .labelStyle(PrivacyCompactLabelStyle())
                            Spacer()
                            Text("\(NumberFormatting.count(visitCount)) visits")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if report.isBlocked {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.orange)
                    Text(report.hasProtectedItems || report.hasData ? "Some data is protected by macOS." : "Protected by macOS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Allow Access…", action: onOpenSettings)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .fill(isSelected ? AppSection.privacy.tint.opacity(0.10) : (isHovering ? Color.hoverFill : Color.cardBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(isSelected ? AppSection.privacy.tint.opacity(0.7) : Color.subtleBorder, lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button(isSelected ? "Show All Browsers" : "Show Only \(report.browser.name)", systemImage: "line.3.horizontal.decrease.circle", action: onSelect)
            if let folder = report.dataFolder {
                Button("Reveal Data Folder in Finder", systemImage: "folder") { FinderActions.reveal(folder) }
            }
            if isRunning {
                Divider()
                Button("Quit \(report.browser.name)", systemImage: "xmark.circle", action: onQuit)
                    .disabled(isQuitting)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(report.browser.name), \(subtitle)\(isRunning ? ", open" : "")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: isSelected ? "Show all browsers" : "Show only this browser", onSelect)
        .help(isSelected ? "Showing only \(report.browser.name). Click to show all browsers." : "Click to show only \(report.browser.name)")
    }
}

private struct PrivacyCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .foregroundStyle(.secondary)
                .frame(width: 14)
            configuration.title
        }
        .font(.caption)
    }
}

/// Explains that an open browser's data is hidden and offers to quit it.
struct PrivacyRunningBrowserCallout: View {
    var report: PrivacyBrowserReport
    var isQuitting: Bool
    var onQuit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            PrivacyAppIcon(bundleIdentifier: report.browser.primaryBundleIdentifier, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(report.browser.name) is open")
                    .font(.callout.weight(.semibold))
                Text("A browser rewrites its data while it runs, so its items appear here once it’s closed. Quitting works like ⌘Q: the browser saves your open tabs first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if isQuitting {
                ProgressView().controlSize(.small)
                Text("Quitting…").font(.callout).foregroundStyle(.secondary)
            } else {
                Button("Quit \(report.browser.name)", action: onQuit)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.2)))
        .accessibilityElement(children: .contain)
    }
}

/// Lists what macOS privacy protection hid when Full Disk Access is on (or its
/// state is unknown) but access was still refused. When Full Disk Access is off,
/// the shared Full Disk Access banner explains it instead.
struct PrivacyProtectedLocationsCallout: View {
    var protectedThings: [String]
    var onOpenSettings: () -> Void

    @Environment(PermissionManager.self) private var permissions

    var body: some View {
        if permissions.fullDiskAccess != .notGranted {
            callout
        }
    }

    private var callout: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 15))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Protected by macOS: \(ListFormatter.localizedString(byJoining: protectedThings))")
                    .font(.callout.weight(.semibold))
                Text(permissions.fullDiskAccess == .granted
                     ? "macOS still blocked access. If you just turned on Full Disk Access, quit and reopen Mac Cleaner, then scan again."
                     : "macOS keeps this data private unless you give Mac Cleaner Full Disk Access in System Settings › Privacy & Security. Mac Cleaner never works around this protection.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Open Settings", action: onOpenSettings)
        }
        .padding(12)
        .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.18)))
    }
}

/// History that lives inside databases shared with data people keep, cleared in place.
struct PrivacyDatabaseHistoryCard: View {
    var firefoxHistory: [PrivacyFirefoxHistoryStatus]
    var isFirefoxRunning: Bool
    var quarantine: PrivacyQuarantineStatus?
    var isBusy: Bool
    var onClearFirefox: (PrivacyFirefoxHistoryStatus) -> Void
    var onClearDownloads: () -> Void
    var onShowBackups: () -> Void

    var body: some View {
        if !firefoxHistory.isEmpty || quarantine != nil {
            Card("History Kept in Databases", symbol: "cylinder.split.1x2") {
                if isBusy { ProgressView().controlSize(.small) }
            } content: {
                Text("These histories share a database with data you want to keep, so Mac Cleaner removes the history entries inside the database instead of deleting the file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(firefoxHistory) { status in
                    Divider()
                    firefoxRow(status)
                }
                if let quarantine {
                    Divider()
                    downloadsRow(quarantine)
                }
            }
        }
    }

    private func firefoxRow(_ status: PrivacyFirefoxHistoryStatus) -> some View {
        HStack(spacing: 10) {
            PrivacyAppIcon(bundleIdentifier: PrivacyBrowser.firefox.primaryBundleIdentifier, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("Firefox — \(status.profile.displayName)")
                    .font(.callout.weight(.medium))
                if let problem = status.problem {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                } else if let visits = status.visitCount {
                    let downloads = status.downloadCount ?? 0
                    Text("\(NumberFormatting.count(visits)) visits\(downloads > 0 ? " · \(NumberFormatting.count(downloads)) downloads" : "") · bookmarks are kept, a backup is made first")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            SafetyBadge(safety: .review)
            Button("Clear History…") { onClearFirefox(status) }
                .disabled(isBusy || isFirefoxRunning || status.visitCount == 0 || status.problem != nil)
                .help(isFirefoxRunning ? "Quit Firefox first." : "Removes visits, typed addresses and the download list from this profile.")
        }
        .contextMenu {
            Button("Reveal Profile in Finder", systemImage: "folder") { FinderActions.reveal(status.profileDirectory) }
            Button("Show Backups", systemImage: "clock.arrow.circlepath", action: onShowBackups)
        }
        .accessibilityElement(children: .contain)
    }

    private func downloadsRow(_ status: PrivacyQuarantineStatus) -> some View {
        HStack(spacing: 10) {
            PrivacyAppIcon(bundleIdentifier: "com.apple.finder", fallbackSymbol: "arrow.down.circle", size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("macOS download history")
                    .font(.callout.weight(.medium))
                if let problem = status.problem {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(NumberFormatting.count(status.eventCount ?? 0)) downloaded files recorded with where they came from · Gatekeeper isn’t affected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            SafetyBadge(safety: .review)
            Button("Clear…", action: onClearDownloads)
                .disabled(isBusy || status.isBlocked || (status.eventCount ?? 0) == 0)
                .help("Removes the list of downloaded files that macOS keeps for every app.")
        }
        .contextMenu {
            Button("Reveal in Finder", systemImage: "folder") { FinderActions.reveal(status.path) }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Result of a database cleanup, with an optional Finder action.
struct PrivacyNoticeBanner: View {
    var notice: PrivacyNotice
    var onDismiss: () -> Void

    private var style: InfoCallout.Style {
        switch notice.style {
        case .success: return .success
        case .failure: return .danger
        case .info: return .info
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            InfoCallout(style: style, title: notice.title, message: notice.message)
            VStack(spacing: 6) {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
                if let path = notice.revealPath {
                    Button("Show Backup") { FinderActions.reveal(path) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding(.top, 6)
        }
    }
}
