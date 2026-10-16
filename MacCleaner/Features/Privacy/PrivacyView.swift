import AppKit
import Combine
import SwiftUI

/// Privacy cleaner: browser caches, history, cookies and website data, plus
/// macOS recent-items lists and download history.
struct PrivacyView: View {
    @Bindable var model: PrivacyViewModel

    private static let workspaceChanges = NSWorkspace.shared.notificationCenter
        .publisher(for: NSWorkspace.didLaunchApplicationNotification)
        .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification))
        .receive(on: RunLoop.main)

    var body: some View {
        PageScroll {
            PageHeader(
                section: .privacy,
                subtitle: "Remove browsing traces, website data and recent-item lists. Saved passwords and bookmarks are never touched."
            ) {
                headerAccessory
            }
            FullDiskAccessBanner(reason: model.protectionSummary)
            content
        }
        .safeAreaInset(edge: .bottom) {
            if model.phase == .ready {
                actionBar
            }
        }
        .searchable(text: $model.searchText, prompt: "Search browser data")
        .cleanupFlow(model.cleanupFlow, services: model.services)
        .alert(
            "Clear Firefox history?",
            isPresented: Binding(get: { model.pendingFirefoxClear != nil }, set: { if !$0 { model.pendingFirefoxClear = nil } }),
            presenting: model.pendingFirefoxClear
        ) { status in
            Button("Clear History", role: .destructive) { model.clearFirefoxHistory(status) }
            Button("Cancel", role: .cancel) { model.pendingFirefoxClear = nil }
        } message: { status in
            Text(firefoxConfirmationMessage(status))
        }
        .alert("Clear macOS download history?", isPresented: $model.isConfirmingQuarantineClear) {
            Button("Clear Download History", role: .destructive) { model.clearDownloadHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the record of \(NumberFormatting.count(model.quarantine?.eventCount ?? 0)) downloaded files: where each came from and when. The files themselves stay where they are, and Gatekeeper keeps protecting you because it uses the quarantine information stored on each file. This can’t be undone.")
        }
        .onReceive(Self.workspaceChanges) { _ in model.refreshRunningState() }
        .onAppear { model.refreshRunningState() }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerAccessory: some View {
        if model.phase == .ready {
            HStack(spacing: 14) {
                VStack(alignment: .trailing, spacing: 1) {
                    SizeText(bytes: model.totalBytes, font: .title3.weight(.semibold))
                    if let date = model.lastScanDate {
                        TimelineView(.periodic(from: date, by: 60)) { context in
                            Text(context.date.timeIntervalSince(date) < 60 ? "Scanned just now" : "Scanned \(DateFormatting.relative(date, to: context.date))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                Button {
                    model.scan()
                } label: {
                    Label("Scan Again", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.cleanupFlow.isCleaning || model.isClearingDatabase)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            ScanLaunchView(
                section: .privacy,
                headline: "Clear your browsing traces",
                message: "Mac Cleaner looks for caches, history, cookies and website data in Safari, Chrome, Firefox, Edge, Brave, Arc, Vivaldi, Opera and Chromium, and for the recent-items lists macOS keeps.",
                buttonTitle: "Scan",
                bullets: [
                    "Only caches are selected automatically",
                    "Browsers must be closed before their data is cleaned",
                    "Passwords, bookmarks and autofill are never removed",
                ],
                action: model.scan
            )
        case .scanning:
            ScanProgressCard(
                title: "Scanning browsers…",
                message: model.progressMessage,
                fraction: model.progressFraction,
                tint: AppSection.privacy.tint,
                onCancel: model.cancelScan
            )
        case .ready:
            results
        }
    }

    @ViewBuilder
    private var results: some View {
        if let notice = model.notice {
            PrivacyNoticeBanner(notice: notice) { model.notice = nil }
        }

        ForEach(model.runningBrowsersWithData) { report in
            PrivacyRunningBrowserCallout(
                report: report,
                isQuitting: model.quittingBrowserIDs.contains(report.id),
                onQuit: { model.quit(report) }
            )
        }

        if model.hasProtectedLocations {
            PrivacyProtectedLocationsCallout(
                protectedThings: model.protectedThings,
                onOpenSettings: model.openFullDiskAccessSettings
            )
        }

        if model.visibleBrowsers.isEmpty {
            EmptyStateView(
                title: "No Browsers Found",
                symbol: "globe",
                message: "Mac Cleaner didn’t find data from a supported browser in your Library folder."
            )
        } else {
            BalancedGrid(minimumItemWidth: 250, spacing: 12) {
                ForEach(model.visibleBrowsers) { report in
                    PrivacyBrowserCard(
                        report: report,
                        isRunning: model.runningBrowserIDs.contains(report.id),
                        isQuitting: model.quittingBrowserIDs.contains(report.id),
                        isSelected: model.browserFilter == report.id,
                        onSelect: { model.toggleFilter(report.id) },
                        onQuit: { model.quit(report) },
                        onOpenSettings: model.openFullDiskAccessSettings
                    )
                }
            }
        }

        listHeader

        if model.groups.isEmpty {
            EmptyStateView(
                title: model.browserFilter == nil ? "Nothing to Clean" : "Nothing to Clean in \(model.filteredBrowserName ?? "This Browser")",
                symbol: "checkmark.seal",
                message: emptyListMessage
            )
        } else {
            CandidateGroupsView(
                groups: model.groups,
                selection: model.selection,
                searchText: model.searchText,
                onExclude: { model.exclude($0) }
            )
        }

        if !model.firefoxHistory.isEmpty || model.quarantine != nil {
            PrivacyDatabaseHistoryCard(
                firefoxHistory: model.browserFilter == nil || model.browserFilter == PrivacyBrowser.firefox.id ? model.firefoxHistory : [],
                isFirefoxRunning: model.isFirefoxRunning,
                quarantine: model.browserFilter == nil ? model.quarantine : nil,
                isBusy: model.isClearingDatabase,
                onClearFirefox: { model.pendingFirefoxClear = $0 },
                onClearDownloads: { model.isConfirmingQuarantineClear = true },
                onShowBackups: model.revealBackups
            )
        }

        InfoCallout(
            style: .info,
            title: "Always kept",
            message: "Saved passwords and passkeys, bookmarks, autofill and payment data, extensions and their settings, browser preferences, site icons and keychains are never removed."
        )
    }

    private var listHeader: some View {
        HStack(spacing: 8) {
            Text("Browser Data")
                .font(.title3.weight(.semibold))
            if let name = model.filteredBrowserName {
                Badge(text: name, symbol: "line.3.horizontal.decrease.circle", tint: AppSection.privacy.tint)
                Button("Show All Browsers") { model.browserFilter = nil }
                    .buttonStyle(.link)
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    private var emptyListMessage: String {
        if !model.runningBrowsersWithData.isEmpty {
            return "Quit the open browsers listed above to clean their data."
        }
        if model.hasProtectedLocations {
            return "Some data is protected by macOS. Grant Full Disk Access to include it."
        }
        return "No caches, history or website data were found."
    }

    private var actionBar: some View {
        SelectionActionBar(selectedCount: model.selectedItems.count, selectedBytes: model.selectedBytes) {
            Button {
                model.cleanSelected()
            } label: {
                Text("Clean…").frame(minWidth: 80)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(AppSection.privacy.tint)
            .disabled(model.selectedItems.isEmpty || model.cleanupFlow.isCleaning)
            .help("Review and remove the selected items")
        }
    }

    private func firefoxConfirmationMessage(_ status: PrivacyFirefoxHistoryStatus) -> String {
        let visits = status.visitCount.map { "\(NumberFormatting.count($0)) visits" } ?? "all visits"
        return "Removes \(visits) from the “\(status.profile.displayName)” profile, along with its download list and address-bar suggestions. "
            + "Bookmarks, saved passwords and site icons are kept. A backup copy of the history database is saved first in Mac Cleaner’s Backups folder."
    }
}
