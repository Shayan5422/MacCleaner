import Foundation
import ServiceManagement
import Testing
@testable import MacCleaner

/// Real features, real macOS services, throwaway fixtures. See `EndToEnd` for how to run them.
@MainActor
@Suite("End to end", .serialized, .enabled(if: EndToEnd.isEnabled, "Set TEST_RUNNER_MACCLEANER_E2E=1 to run end-to-end tests"))
struct EndToEndTests {
    // MARK: - Uninstaller

    /// Installs a test app in ~/Applications with preferences, caches, support files, saved state and a
    /// loaded launch agent; uninstalls it through the Uninstaller exactly as the UI does; checks that
    /// everything went to the Trash and the agent stopped; then restores it all from History.
    @Test func uninstallsAnAppWithItsLeftoversAndRestoresThem() async throws {
        let id = EndToEnd.makeIdentifier()
        let home = EndToEnd.home
        let appName = "Mac Cleaner E2E \(id.suffix(10))"
        let appPath = home + "/Applications/\(appName).app"
        let agentLabel = id + ".helper"
        let agentPlist = home + "/Library/LaunchAgents/\(agentLabel).plist"
        let leftovers = [
            home + "/Library/Application Support/\(id)",
            home + "/Library/Caches/\(id)",
            home + "/Library/Preferences/\(id).plist",
            home + "/Library/Saved Application State/\(id).savedState",
            home + "/Library/HTTPStorages/\(id)",
            agentPlist,
        ]
        let createdApplicationsFolder = !EndToEnd.exists(home + "/Applications")
        let (services, support) = try EndToEnd.makeServices()
        defer {
            LaunchAgentProbe.bootout(agentLabel)
            EndToEnd.removeFixtures([appPath] + leftovers)
            if createdApplicationsFolder { try? FileManager.default.removeItem(atPath: home + "/Applications") }
            try? FileManager.default.removeItem(at: support)
        }

        // The app and its data.
        try EndToEnd.writePlist(appPath + "/Contents/Info.plist", [
            "CFBundleIdentifier": id,
            "CFBundleName": appName,
            "CFBundleExecutable": "e2e",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
        ])
        try EndToEnd.writeFile(appPath + "/Contents/MacOS/e2e", "#!/bin/sh\nexit 0\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appPath + "/Contents/MacOS/e2e")
        try EndToEnd.writeFile(leftovers[0] + "/Settings.json", "{\"e2e\": true}")
        try EndToEnd.writeFile(leftovers[1] + "/Cache.db")
        try EndToEnd.writePlist(leftovers[2], ["E2E": true])
        try EndToEnd.writeFile(leftovers[3] + "/windows.plist")
        try EndToEnd.writeFile(leftovers[4] + "/httpstorages.sqlite")
        try LaunchAgentProbe.makeAgent(label: agentLabel, plist: agentPlist)
        #expect(LaunchAgentProbe.bootstrap(plist: agentPlist))
        #expect(LaunchAgentProbe.isLoaded(agentLabel))

        let model = UninstallerViewModel(services: services)
        model.reload()
        await model.waitForInventory()
        let app = try #require(model.apps.first { PathUtilities.normalize($0.path) == PathUtilities.normalize(appPath) },
                               "The test app isn't in the Uninstaller's list")
        #expect(app.canUninstall)

        // Preview: every leftover must be found, then everything is selected (as a person would).
        model.beginUninstall([app])
        let preview = try #require(model.preview)
        try await EndToEnd.waitUntil("the uninstall preview is ready", seconds: 120) { preview.isReady }
        let found = Set(preview.allLeftovers.map { PathUtilities.normalize($0.path) })
        for path in leftovers {
            #expect(found.contains(PathUtilities.normalize(path)), "Leftover not found: \(path)")
        }
        preview.setSelected(preview.allLeftovers, true)
        #expect(preview.canConfirm)

        // Confirm the preview, then the cleanup sheet.
        model.confirmPreview()
        model.previewDismissed()
        #expect(model.flow.request != nil, "Removing apps must always ask for confirmation")
        model.flow.confirm(services: services)
        try await EndToEnd.waitUntil("the uninstall finishes", seconds: 120) { model.flow.report != nil }
        let report = try #require(model.flow.report)
        #expect(report.failed.isEmpty, "Failures: \(report.failed.map { "\($0.path): \($0.message)" })")
        #expect(report.skipped.isEmpty, "Skipped: \(report.skipped.map { "\($0.path): \($0.reason)" })")
        #expect(report.method == .moveToTrash)

        // Everything is in the Trash, nothing is left behind, and the agent stopped running.
        for path in [appPath] + leftovers {
            #expect(!EndToEnd.exists(path), "Still at its original location: \(path)")
        }
        for removed in report.removed {
            let trashed = try #require(removed.trashedPath, "\(removed.path) wasn't moved to the Trash")
            #expect(EndToEnd.exists(trashed))
        }
        #expect(!model.apps.contains { $0.path == app.path })
        try await EndToEnd.waitUntil("the launch agent is stopped", seconds: 20) { !LaunchAgentProbe.isLoaded(agentLabel) }

        // History records it and can put everything back.
        let entry = try #require(await services.history.allEntries().first)
        #expect(entry.id == report.historyEntryID)
        #expect(entry.restorableCount == leftovers.count + 1)
        let restored = await services.history.restore(entryID: entry.id)
        #expect(restored.failed.isEmpty, "Restore failures: \(restored.failed.map(\.reason))")
        for path in [appPath] + leftovers {
            #expect(EndToEnd.exists(path), "Not restored: \(path)")
        }
        #expect(FileManager.default.contents(atPath: leftovers[0] + "/Settings.json") == Data("{\"e2e\": true}".utf8))
    }

    // MARK: - Startup items

    /// Turns a real, loaded user launch agent off and on again through the Startup Items page.
    @Test func turnsALaunchAgentOffAndOnAgain() async throws {
        let label = EndToEnd.makeIdentifier() + ".agent"
        let plist = EndToEnd.home + "/Library/LaunchAgents/\(label).plist"
        let (services, support) = try EndToEnd.makeServices()
        defer {
            LaunchAgentProbe.bootout(label)
            // Leave launchd without a "disabled" override for the removed test job.
            LaunchAgentProbe.run(["enable", "\(LaunchAgentProbe.domain)/\(label)"])
            EndToEnd.removeFixtures([plist])
            try? FileManager.default.removeItem(at: support)
        }
        try LaunchAgentProbe.makeAgent(label: label, plist: plist)
        #expect(LaunchAgentProbe.bootstrap(plist: plist))

        let model = StartupViewModel(services: services)
        await model.refresh()
        let item = try #require(model.items.first { $0.label == label }, "The test agent isn't listed")
        #expect(item.kind == .userAgent)
        #expect(item.canToggle)
        #expect(item.isEnabled == true)

        await model.perform(.disable(item))
        #expect(model.alertMessage == nil, "\(model.alertMessage ?? "")")
        #expect(!LaunchAgentProbe.isLoaded(label), "Turning it off must stop the agent")
        #expect(LaunchAgentProbe.isDisabled(label), "Turning it off must keep it from starting at login")
        #expect(EndToEnd.exists(plist), "Turning it off must keep the property list")
        let off = try #require(model.items.first { $0.label == label })
        #expect(off.isEnabled == false)

        await model.perform(.enable(off))
        #expect(model.alertMessage == nil, "\(model.alertMessage ?? "")")
        #expect(!LaunchAgentProbe.isDisabled(label))
        try await EndToEnd.waitUntil("the agent is loaded again", seconds: 10) { LaunchAgentProbe.isLoaded(label) }
        let on = try #require(model.items.first { $0.label == label })
        #expect(on.isEnabled == true)
    }

    /// Removes a launch agent the way the Startup Items page does: the property list goes to the
    /// Trash and the running job is stopped.
    @Test func movesALaunchAgentToTheTrashAndStopsIt() async throws {
        let label = EndToEnd.makeIdentifier() + ".agent"
        let plist = EndToEnd.home + "/Library/LaunchAgents/\(label).plist"
        let (services, support) = try EndToEnd.makeServices()
        defer {
            LaunchAgentProbe.bootout(label)
            EndToEnd.removeFixtures([plist])
            try? FileManager.default.removeItem(at: support)
        }
        try LaunchAgentProbe.makeAgent(label: label, plist: plist)
        #expect(LaunchAgentProbe.bootstrap(plist: plist))

        let model = StartupViewModel(services: services)
        await model.refresh()
        let item = try #require(model.items.first { $0.label == label })
        #expect(item.canMoveToTrash)
        model.requestMoveToTrash(item)
        #expect(model.cleanupFlow.request != nil)
        model.cleanupFlow.confirm(services: services)
        try await EndToEnd.waitUntil("the agent is removed", seconds: 30) { model.cleanupFlow.report != nil }
        let report = try #require(model.cleanupFlow.report)
        #expect(report.failed.isEmpty, "\(report.failed.map(\.message))")
        #expect(!EndToEnd.exists(plist))
        try await EndToEnd.waitUntil("the agent is stopped", seconds: 20) { !LaunchAgentProbe.isLoaded(label) }
        if let trashed = report.removed.first?.trashedPath {
            #expect(EndToEnd.exists(trashed))
            EndToEnd.removeFixtures([trashed])
            #expect(!EndToEnd.exists(trashed), "The test property list couldn't be removed from the Trash")
        } else {
            Issue.record("The property list wasn't moved to the Trash")
        }
    }

    // MARK: - Immediate deletion

    /// "Delete Immediately" on a real cache folder: the folder is gone (not in the Trash), a file
    /// another process has open is skipped, and a symbolic link inside never leads deletion outside.
    @Test func deletesJunkImmediatelyWithoutFollowingLinksOrTouchingOpenFiles() async throws {
        let id = EndToEnd.makeIdentifier()
        let cache = EndToEnd.home + "/Library/Caches/\(id)"
        let openFileFolder = EndToEnd.home + "/Library/Caches/\(id).inuse"
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("MacCleanerE2E-canary-\(UUID().uuidString)").path
        let canary = outside + "/keep-me.txt"
        let (services, support) = try EndToEnd.makeServices(confirmBeforeCleaning: false)
        services.settings.junkCleanupMethod = .deletePermanently
        let holder = Process()
        defer {
            if holder.isRunning { holder.terminate() }
            EndToEnd.removeFixtures([cache, openFileFolder, outside])
            try? FileManager.default.removeItem(at: support)
        }

        try EndToEnd.writeFile(cache + "/a/b/c/blob.bin", String(repeating: "x", count: 64 * 1024))
        try EndToEnd.writeFile(cache + "/index.db")
        try EndToEnd.writeFile(canary, "must survive")
        try FileManager.default.createSymbolicLink(atPath: cache + "/a/link-to-outside", withDestinationPath: outside)
        try EndToEnd.writeFile(openFileFolder + "/open.log", "held open by another process")

        // A process that keeps the second folder's file open, like an app writing its cache.
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        holder.arguments = ["-f", openFileFolder + "/open.log"]
        holder.standardOutput = FileHandle.nullDevice
        try holder.run()
        try await Task.sleep(for: .milliseconds(500))

        let items = [cache, openFileFolder].map { path in
            CleanupItem(path: path, purpose: .junk, snapshot: FileSnapshot.capture(path: path), estimatedBytes: 0, category: "Application caches")
        }
        let flow = CleanupFlow()
        flow.requestCleanup(title: "E2E immediate deletion", items: items, services: services, regenerableData: true)
        #expect(flow.request == nil, "With confirmation off, regenerable junk is cleaned right away")
        try await EndToEnd.waitUntil("the cleanup finishes", seconds: 60) { flow.report != nil }
        let report = try #require(flow.report)

        #expect(report.method == .deletePermanently)
        #expect(!EndToEnd.exists(cache), "The cache folder must be deleted")
        #expect(report.removed.contains { $0.path == PathUtilities.normalize(cache) && $0.trashedPath == nil })
        #expect(EndToEnd.exists(canary), "Deletion followed a symbolic link out of the cache folder")
        #expect(FileManager.default.contents(atPath: canary) == Data("must survive".utf8))
        #expect(EndToEnd.exists(openFileFolder), "A folder with a file open in a running process must be skipped")
        #expect(report.skipped.contains { $0.path == PathUtilities.normalize(openFileFolder) })

        let entry = try #require(await services.history.allEntries().first)
        #expect(entry.restorableCount == 0, "Deleted items can't be restored, and History must say so")
    }

    // MARK: - Automation agent

    /// Registers and unregisters the background automation agent with `SMAppService`. macOS shows a
    /// "Background Items Added" notification for it, so it only runs with MACCLEANER_E2E_SYSTEM=1 too.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACCLEANER_E2E_SYSTEM"] == "1"))
    func registersAndUnregistersTheAutomationAgent() async throws {
        let controller = AutomationAgentController()
        let initial = controller.status
        try #require(initial != .notFound, "The agent's property list is missing from the app bundle")
        guard initial == .notRegistered else {
            // Don't change a registration the person made.
            Issue.record("The automation agent is already registered (\(initial.title)); skipping")
            return
        }
        defer { Task { try? await controller.unregister() } }
        try controller.register()
        #expect([AutomationAgentController.Status.enabled, .requiresApproval].contains(controller.status))
        try await controller.unregister()
        try await EndToEnd.waitUntil("the agent is unregistered", seconds: 10) { controller.status == .notRegistered }
    }
}
