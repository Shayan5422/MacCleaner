#if DEBUG
import AppKit
import SwiftUI

/// The pages captured for the README and design reviews, each prepared with a real
/// scan of this Mac. Run with `--pretend-version 0.9.0` to capture the update-available
/// states with the real latest release from GitHub.
@MainActor
enum ScreenshotPlan {
    static var steps: [ScreenshotAutomation.Step] {
        [
            .init(name: "dashboard", section: .dashboard, prepare: { _ in
                await checkMacCleanerUpdates()
            }, settle: .seconds(4)),
            .init(name: "smart-scan", section: .smartScan, prepare: { environment in
                environment.smartScan.start()
                await ScreenshotAutomation.wait(timeout: .seconds(300)) { environment.smartScan.phase == .results }
                environment.smartScan.focusedArea = .junk
            }, settle: .seconds(2)),
            .init(name: "system-junk", section: .systemJunk, prepare: { environment in
                environment.systemJunk.scan()
                await ScreenshotAutomation.wait { environment.systemJunk.phase == .results }
            }),
            .init(name: "storage", section: .storage, prepare: { environment in
                await StorageScreenshotSupport.prepare(environment.storage)
            }, settle: .seconds(3)),
            .init(name: "performance", section: .performance, settle: .seconds(12)),
            .init(name: "uninstaller", section: .uninstaller, prepare: { environment in
                environment.uninstaller.loadIfNeeded()
                await ScreenshotAutomation.wait { !environment.uninstaller.isLoading }
            }, apply: { environment in
                environment.uninstaller.selection = []
            }, settle: .seconds(3)),
            .init(name: "uninstaller-detail", section: .uninstaller, apply: { environment in
                let app = environment.uninstaller.visibleApps.first { $0.canUninstall && $0.usage != nil }
                    ?? environment.uninstaller.visibleApps.first
                if let app { environment.uninstaller.selection = [app.id] }
            }, reset: { environment in
                environment.uninstaller.selection = []
            }, settle: .seconds(3)),
            .init(name: "duplicates", section: .duplicates, prepare: { environment in
                environment.duplicates.startScan()
                await ScreenshotAutomation.wait(timeout: .seconds(300)) { !environment.duplicates.isScanning }
            }),
            .init(name: "security", section: .security, prepare: { environment in
                environment.security.startScan()
                await ScreenshotAutomation.wait(timeout: .seconds(300)) {
                    !environment.security.isScanning && environment.security.report != nil
                }
            }, settle: .seconds(2)),
            .init(name: "privacy", section: .privacy, prepare: { environment in
                environment.privacy.scan()
                await ScreenshotAutomation.wait { !environment.privacy.isScanning }
            }),
            .init(name: "developer", section: .developer, prepare: { environment in
                environment.developer.scan()
                await ScreenshotAutomation.wait(timeout: .seconds(300)) { environment.developer.hasScanned && environment.developer.phase != .scanning }
            }, settle: .seconds(3)),
            .init(name: "startup", section: .startup, prepare: { environment in
                await environment.startup.refresh()
            }),
            .init(name: "startup-opened-at-login", section: .startup, apply: { environment in
                environment.startup.page = .openedAtLogin
            }, reset: { environment in
                environment.startup.page = .items
            }, settle: .seconds(4)),
            .init(name: "startup-changes", section: .startup, apply: { environment in
                environment.startup.page = .changes
            }, reset: { environment in
                environment.startup.page = .items
            }, settle: .seconds(2)),
            .init(name: "startup-background-items", section: .startup, apply: { environment in
                environment.startup.page = .everything
            }, reset: { environment in
                environment.startup.page = .items
            }, settle: .seconds(2)),
            .init(name: "antivirus-definitions", section: .antivirus, prepare: { environment in
                let antivirus = environment.antivirus
                if !antivirus.hasDefinitions { antivirus.installDefinitions() }
                await ScreenshotAutomation.wait(timeout: .seconds(900)) { !antivirus.isUpdatingDefinitions && antivirus.hasDefinitions }
            }, apply: { environment in
                environment.antivirus.tab = .definitions
            }, settle: .seconds(2)),
            .init(name: "antivirus-test", section: .antivirus, prepare: { environment in
                let antivirus = environment.antivirus
                antivirus.testProtection()
                await ScreenshotAutomation.wait(timeout: .seconds(60)) { !antivirus.isTestingProtection }
            }, apply: { environment in
                environment.antivirus.tab = .scan
            }, settle: .seconds(2)),
            .init(name: "antivirus-quick-scan", section: .antivirus, prepare: { environment in
                let antivirus = environment.antivirus
                antivirus.startQuickScan()
                await ScreenshotAutomation.wait(timeout: .seconds(900)) { !antivirus.isScanning && antivirus.lastReport != nil }
            }, apply: { environment in
                environment.antivirus.tab = .scan
            }, settle: .seconds(2)),
            .init(name: "antivirus-shields", section: .antivirus, apply: { environment in
                environment.antivirus.tab = .shields
            }, settle: .seconds(2)),
            .init(name: "antivirus-history", section: .antivirus, apply: { environment in
                environment.antivirus.tab = .history
            }, settle: .seconds(1)),
            .init(name: "network-ports", section: .network, apply: { environment in
                environment.network.tab = .ports
            }, settle: .seconds(5)),
            .init(name: "network-connections", section: .network, apply: { environment in
                environment.network.tab = .connections
            }, settle: .seconds(5)),
            .init(name: "network-check", section: .network, apply: { environment in
                environment.network.tab = .check
            }, settle: .seconds(6)),
            .init(name: "automation", section: .automation),
            .init(name: "cloud", section: .cloud, settle: .seconds(4)),
            .init(name: "updates", section: .updates, prepare: { environment in
                environment.updates.loadIfNeeded()
                await ScreenshotAutomation.wait { environment.updates.hasLoaded }
                if !CommandLine.arguments.contains("--screenshot-reuse-update-results") || environment.updates.lastCheckDate == nil {
                    environment.updates.checkForUpdates()
                    await ScreenshotAutomation.wait(timeout: .seconds(240)) { !environment.updates.isChecking }
                }
                // Let sizes of the apps with updates arrive.
                await ScreenshotAutomation.wait(timeout: .seconds(60)) {
                    environment.updates.sections.first?.rows.allSatisfy { $0.app.usage != nil } ?? true
                }
            }, apply: { environment in
                resetUpdates(environment.updates)
            }, settle: .seconds(3)),
            .init(name: "updates-notes", section: .updates, apply: { environment in
                let model = environment.updates
                resetUpdates(model)
                let rows = model.sections.first { $0.group == .updates }?.rows ?? []
                if let row = rows.first(where: { model.hasReleaseNotes($0) && !$0.isMacCleaner && $0.hasEmbeddedReleaseNotes })
                    ?? rows.first(where: { model.hasReleaseNotes($0) }) {
                    model.toggleReleaseNotes(row)
                    await ScreenshotAutomation.wait(timeout: .seconds(20)) {
                        if case .loading? = model.notes[row.id] { return false }
                        return true
                    }
                }
            }, reset: { environment in
                resetUpdates(environment.updates)
            }, settle: .seconds(2)),
            .init(name: "updates-detail", section: .updates, apply: { environment in
                let model = environment.updates
                resetUpdates(model)
                let rows = model.sections.first { $0.group == .updates }?.rows ?? []
                if let row = rows.first(where: { !$0.isMacCleaner }) ?? rows.first ?? model.allRows.first {
                    model.inspectedRowID = row.id
                }
            }, reset: { environment in
                resetUpdates(environment.updates)
            }, settle: .seconds(3)),
            .init(name: "updates-all", section: .updates, apply: { environment in
                resetUpdates(environment.updates)
                environment.updates.isShowingUpdateAll = !environment.updates.updateAllPlan.isEmpty
            }, reset: { environment in
                environment.updates.isShowingUpdateAll = false
            }, settle: .seconds(2)),
            .init(name: "history", section: .history, settle: .seconds(2)),
            .init(name: "about", section: .dashboard, target: .window(title: "About Mac Cleaner"), apply: { _ in
                ScreenshotAutomation.openWindow?(id: AppWindowID.about)
            }, reset: { _ in
                ScreenshotAutomation.closeWindow(titled: "About Mac Cleaner")
            }, settle: .seconds(2)),
            .init(name: "app-update", section: .dashboard, target: .window(title: "Mac Cleaner Update"), prepare: { _ in
                await checkMacCleanerUpdates()
            }, apply: { _ in
                ScreenshotAutomation.openWindow?(id: AppWindowID.update)
            }, reset: { _ in
                ScreenshotAutomation.closeWindow(titled: "Mac Cleaner Update")
            }, settle: .seconds(2)),
            .init(name: "settings", section: .dashboard, target: .settings, apply: { _ in
                ScreenshotAutomation.openSettings?()
            }, reset: { _ in
                ScreenshotAutomation.closeSettings()
            }, settle: .seconds(2)),
            .init(name: "menubar", section: .dashboard, target: .menuBarHub, settle: .seconds(3)),
            .init(name: "activity", section: .dashboard, target: .window(title: "Activity"), apply: { _ in
                ScreenshotAutomation.openWindow?(id: AppWindowID.activity)
            }, reset: { _ in
                ScreenshotAutomation.closeWindow(titled: "Activity")
            }, settle: .seconds(2)),
            .init(name: "onboarding", section: .dashboard, target: .onboarding, settle: .seconds(1)),
        ]
    }

    /// The Updates page's default state: list, no details panel, no notes, no sheet.
    private static func resetUpdates(_ model: UpdatesViewModel) {
        model.inspectedRowID = nil
        model.isShowingUpdateAll = false
        model.filter = .all
        for row in model.allRows where model.isShowingNotes(row) { model.toggleReleaseNotes(row) }
    }

    /// One real request to GitHub (with `--pretend-version`, the latest release shows as an update).
    private static func checkMacCleanerUpdates() async {
        let updates = AppUpdateController.shared
        guard updates.lastCheckDate == nil || updates.isSimulated else { return }
        await updates.performCheck(manual: false)
    }
}

/// Starts a home-folder scan in the Storage Analyzer and waits for the result.
@MainActor
enum StorageScreenshotSupport {
    static func prepare(_ model: StorageAnalyzerViewModel) async {
        model.scanHome()
        await ScreenshotAutomation.wait(timeout: .seconds(300)) { model.phase == .ready }
    }
}
#endif
