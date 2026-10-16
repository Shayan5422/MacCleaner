#if DEBUG
import Foundation

/// The pages captured for the README, each prepared with a real scan of this Mac.
@MainActor
enum ScreenshotPlan {
    static var steps: [ScreenshotAutomation.Step] {
        [
            .init(name: "dashboard", section: .dashboard, settle: .seconds(4)),
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
            .init(name: "automation", section: .automation),
            .init(name: "cloud", section: .cloud, settle: .seconds(4)),
            .init(name: "updates", section: .updates, prepare: { environment in
                environment.updates.loadIfNeeded()
                await ScreenshotAutomation.wait { environment.updates.hasLoaded }
                environment.updates.checkForUpdates()
                await ScreenshotAutomation.wait(timeout: .seconds(240)) { !environment.updates.isChecking }
            }, settle: .seconds(3)),
            .init(name: "history", section: .history, settle: .seconds(2)),
        ]
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
