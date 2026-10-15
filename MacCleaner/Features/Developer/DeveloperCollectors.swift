import Foundation

/// Per-tool detection. Each collector lists folders and runs read-only queries,
/// then describes what can be cleaned and how it comes back.
extension DeveloperToolsScanner {
    func collect(_ tool: DeveloperToolKind, environment: DeveloperEnvironment, xcodeRunning: Bool) async -> DeveloperToolDraft {
        switch tool {
        case .xcode: return await collectXcode(environment, xcodeRunning: xcodeRunning)
        case .simulators: return await collectSimulators(environment)
        case .swiftPM: return await collectSwiftPM()
        case .cocoaPods: return await collectCocoaPods(environment)
        case .carthage: return await collectCarthage(environment)
        case .homebrew: return await collectHomebrew(environment)
        case .npm: return await collectNPM(environment)
        case .pnpm: return await collectPNPM(environment)
        case .yarn: return await collectYarn(environment)
        case .bun: return await collectBun(environment)
        case .pip: return await collectPip(environment)
        case .uv: return await collectUV(environment)
        case .go: return await collectGo(environment)
        case .cargo: return await collectCargo(environment)
        case .docker: return await collectDocker(environment)
        case .gradle: return await collectGradle(environment)
        case .maven: return await collectMaven(environment)
        case .temporaryFiles: return await collectTemporaryFiles(environment)
        }
    }

    // MARK: - Helpers

    static func isDirectory(_ path: String) -> Bool {
        DeveloperPathProbe.isDirectory(path)
    }

    private func item(
        _ tool: DeveloperToolKind,
        id: String,
        group: String,
        title: String,
        detail: String? = nil,
        explanation: String,
        regeneration: String,
        safety: CleanupSafety,
        command: DeveloperCommand? = nil,
        path: String? = nil
    ) -> DeveloperItem {
        DeveloperItem(
            id: tool.rawValue + "." + id,
            tool: tool,
            group: group,
            title: title,
            detail: detail,
            explanation: explanation,
            regeneration: regeneration,
            safety: safety,
            action: command.map { .command($0) } ?? .delete([]),
            bytes: 0,
            path: path
        )
    }

    private func command(_ executable: String, _ arguments: [String], timeout: TimeInterval, environment: [String: String] = [:]) -> DeveloperCommand {
        DeveloperCommand(
            executable: executable,
            displayName: (executable as NSString).lastPathComponent,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        )
    }

    /// Whole folder when the safety policy allows removing it, otherwise its contents.
    private func folderSize(_ folder: String) -> DeveloperItemDraft.Size {
        policy.evaluate(path: folder, purpose: .developerData).isAllowed ? .paths([folder]) : .children(of: folder)
    }

    private func abbreviated(_ path: String) -> String {
        PathUtilities.abbreviate(path)
    }

    // MARK: - Xcode

    private func collectXcode(_ environment: DeveloperEnvironment, xcodeRunning: Bool) async -> DeveloperToolDraft {
        let xcode = home + "/Library/Developer/Xcode"
        let mode = self.mode
        return await BackgroundWork.run(qos: .userInitiated) { [self] in
            var draft = DeveloperToolDraft(tool: .xcode)
            draft.isDetected = environment.hasXcode || Self.isDirectory(xcode)
            guard draft.isDetected else { return draft }
            draft.location = environment.xcodeApplicationPath
            if !environment.hasXcode {
                draft.notes.append(.info("Xcode isn’t installed or selected, so this data is probably left over from an earlier installation."))
            }
            if xcodeRunning {
                draft.notes.append(.warning("Xcode is open. Folders it’s using are skipped during cleanup; quit Xcode to clean everything."))
            }

            for info in DeveloperXcodeInspector.derivedDataFolders(in: xcode + "/DerivedData") {
                draft.drafts.append(derivedDataDraft(info))
            }

            let caches: [(String, String, String, String)] = [
                ("UserData/Previews", "SwiftUI previews", "Simulator devices and builds Xcode uses to render SwiftUI previews.", "Recreated the next time a preview runs."),
                ("DocumentationCache", "Documentation cache", "Developer documentation Xcode downloaded.", "Downloaded again when you open the documentation."),
                ("DocumentationIndex", "Documentation index", "The search index for developer documentation.", "Rebuilt when you next open the documentation window."),
            ]
            for (relative, title, explanation, regeneration) in caches where Self.isDirectory(xcode + "/" + relative) {
                let path = xcode + "/" + relative
                draft.drafts.append(DeveloperItemDraft(
                    item: item(.xcode, id: "cache." + relative, group: "Caches", title: title, detail: abbreviated(path), explanation: explanation, regeneration: regeneration, safety: .safe, path: path),
                    size: .paths([path])
                ))
            }

            guard mode == .full else { return draft }

            let ageLimit: TimeInterval = 90 * 86_400
            for archive in DeveloperXcodeInspector.archives(in: xcode + "/Archives") {
                let isOld = archive.creationDate.map { Date().timeIntervalSince($0) > ageLimit } ?? false
                var parts: [String] = []
                if let date = archive.creationDate { parts.append("Archived \(DateFormatting.day(date))") }
                if let bundleID = archive.bundleIdentifier { parts.append(bundleID) }
                if !isOld { parts.append("less than 90 days old") }
                var archiveItem = item(
                    .xcode, id: "archive." + archive.path, group: "Archives", title: archive.title,
                    detail: parts.joined(separator: " · "),
                    explanation: "An app build you archived for distribution. It includes the debug symbols (dSYMs) needed to read crash reports from this version.",
                    regeneration: "Can’t be recreated exactly. Keep archives of versions people still use.",
                    safety: isOld ? .review : .caution, path: archive.path
                )
                archiveItem.warning = "Archives contain the dSYM files needed to symbolicate crash reports. They’re moved to the Trash, so you can restore them until you empty it."
                archiveItem.trashOnly = true
                archiveItem.date = archive.creationDate
                draft.drafts.append(DeveloperItemDraft(item: archiveItem, size: .paths([archive.path])))
            }

            for platform in DeveloperXcodeInspector.deviceSupportPlatforms {
                let entries = DeveloperXcodeInspector.deviceSupportEntries(in: xcode + "/\(platform) DeviceSupport", platform: platform)
                guard let newest = entries.first else { continue }
                for entry in entries where DeveloperXcodeInspector.compareVersions(entry.version, newest.version) == .orderedAscending {
                    var supportItem = item(
                        .xcode, id: "devicesupport.\(platform).\(entry.name)", group: "Device Support",
                        title: "\(platform) \(entry.versionString)" + (entry.build.map { " (\($0))" } ?? ""),
                        detail: "\(entry.name) · newest kept: \(platform) \(newest.versionString)",
                        explanation: "Debug symbols Xcode copied from a device running \(platform) \(entry.versionString).",
                        regeneration: "Xcode copies them again the next time you connect a device with this version, which can take several minutes.",
                        safety: .review, path: entry.path
                    )
                    supportItem.date = entry.modificationDate
                    draft.drafts.append(DeveloperItemDraft(item: supportItem, size: .paths([entry.path])))
                }
            }

            let deviceLogs = xcode + "/iOS Device Logs"
            if Self.isDirectory(deviceLogs) {
                draft.drafts.append(DeveloperItemDraft(
                    item: item(.xcode, id: "devicelogs", group: "Logs", title: "Device logs", detail: abbreviated(deviceLogs),
                               explanation: "Crash and console logs Xcode copied from connected devices.",
                               regeneration: "Copied again from a device the next time Xcode collects its logs; logs no longer on the device are gone.",
                               safety: .review, path: deviceLogs),
                    size: .paths([deviceLogs])
                ))
            }
            return draft
        }
    }

    private func derivedDataDraft(_ info: DeveloperDerivedDataInfo) -> DeveloperItemDraft {
        let title: String
        let detail: String?
        let explanation: String
        switch info.kind {
        case .project:
            title = info.projectName
            var parts: [String] = []
            switch info.projectStatus {
            case .exists: if let workspace = info.workspacePath { parts.append(abbreviated(workspace)) }
            case .missing: parts.append("Project no longer exists")
            case .onDisconnectedVolume: parts.append("Project is on a disconnected drive")
            case .unknown: break
            }
            if let date = info.lastAccessed { parts.append("used \(DateFormatting.relative(date))") }
            detail = parts.isEmpty ? nil : parts.joined(separator: " · ")
            explanation = "Build products, indexes and logs Xcode created for this project."
        case .moduleCache:
            title = "Module cache"
            detail = "Shared by all projects"
            explanation = "Precompiled Clang and Swift modules shared by every project."
        case .sharedCache(let name):
            title = name
            detail = "Shared by all projects"
            explanation = "A cache Xcode’s build system shares between projects."
        }
        var derived = item(
            .xcode, id: "derived." + info.folderName, group: "DerivedData", title: title, detail: detail,
            explanation: explanation,
            regeneration: "Xcode recreates it on the next build; that build and indexing take longer.",
            safety: .safe, path: info.path
        )
        derived.date = info.lastAccessed
        return DeveloperItemDraft(item: derived, size: .paths([info.path]))
    }

    // MARK: - Simulators

    private func collectSimulators(_ environment: DeveloperEnvironment) async -> DeveloperToolDraft {
        let coreSimulator = home + "/Library/Developer/CoreSimulator"
        var draft = DeveloperToolDraft(tool: .simulators)
        draft.isDetected = environment.hasXcode || Self.isDirectory(coreSimulator)
        guard draft.isDetected else { return draft }

        if environment.hasXcode, let xcrun = environment.executable("xcrun") {
            draft.location = "xcrun simctl"
            var deviceList: DeveloperSimulatorDeviceList?
            if let result = await DeveloperCLI.run(xcrun, ["simctl", "list", "devices", "--json"], timeout: 60, home: home), result.succeeded {
                deviceList = try? DeveloperSimctlParser.parseDevices(Data(result.standardOutput.utf8))
            }
            if let deviceList {
                let unavailable = deviceList.unavailableDevices
                if !unavailable.isEmpty {
                    let count = unavailable.count
                    let unavailableItem = item(
                        .simulators, id: "unavailable", group: "Devices", title: "Unavailable simulators",
                        detail: "\(count) simulator\(count == 1 ? "" : "s") whose system version is no longer installed",
                        explanation: "Simulator devices that can’t start because their iOS, watchOS, tvOS or visionOS version was removed.",
                        regeneration: "Nothing to recreate: these simulators can’t run. Create new ones in Xcode if you need them.",
                        safety: .safe, command: command(xcrun, ["simctl", "delete", "unavailable"], timeout: 600)
                    )
                    // Data size only: their logs are counted with the simulator logs below.
                    draft.drafts.append(DeveloperItemDraft(
                        item: unavailableItem,
                        size: .known(unavailable.reduce(0) { $0 + ($1.dataPathSize ?? 0) }),
                        keepWhenEmpty: true
                    ))
                }
            } else {
                draft.notes.append(.warning("Couldn’t read the simulator list. Open Xcode once to finish installing its components, then scan again."))
            }

            if let result = await DeveloperCLI.run(xcrun, ["simctl", "runtime", "list", "--json"], timeout: 60, home: home), result.succeeded,
               let runtimes = try? DeveloperSimctlParser.parseRuntimes(Data(result.standardOutput.utf8)) {
                var keptBytes: Int64 = 0
                var keptCount = 0
                for runtime in runtimes where runtime.deletable && runtime.state?.lowercased() != "deleting" {
                    let runtimeID = runtime.runtimeIdentifier ?? ""
                    // Without a device list, assume the runtime is in use.
                    let usedBy = deviceList?.availableDeviceCount(runtimeIdentifier: runtimeID) ?? 1
                    let unusable = !runtime.isReady
                    guard usedBy == 0 || unusable else {
                        keptBytes += runtime.sizeBytes ?? 0
                        keptCount += 1
                        continue
                    }
                    var parts = [unusable ? "Unusable (\(runtime.state ?? "unknown state"))" : "No simulators use it"]
                    if let build = runtime.build { parts.append("build \(build)") }
                    if let lastUsed = runtime.lastUsedAt { parts.append("last used \(DateFormatting.relative(lastUsed))") }
                    var runtimeItem = item(
                        .simulators, id: "runtime." + runtime.identifier, group: "Runtimes", title: "\(runtime.displayName) runtime",
                        detail: parts.joined(separator: " · "),
                        explanation: "A simulator system image for \(runtime.displayName).",
                        regeneration: "Download it again in Xcode › Settings › Components if you need it.",
                        safety: .review, command: command(xcrun, ["simctl", "runtime", "delete", runtime.identifier], timeout: 900)
                    )
                    let devices = deviceList?.deviceCount(runtimeIdentifier: runtimeID) ?? 0
                    if devices > 0 {
                        runtimeItem.warning = "\(devices) simulator\(devices == 1 ? "" : "s") created with this runtime will become unavailable."
                    }
                    draft.drafts.append(DeveloperItemDraft(item: runtimeItem, size: .known(runtime.sizeBytes ?? 0), keepWhenEmpty: true))
                }
                if keptCount > 0 {
                    draft.notes.append(.info("\(keptCount) runtime\(keptCount == 1 ? "" : "s") used by your simulators (\(ByteFormatting.string(keptBytes))) \(keptCount == 1 ? "is" : "are") kept."))
                }
            }
        } else {
            draft.notes.append(.info("Install Xcode to manage simulator runtimes and devices."))
        }

        let folders: [(String, String, String, String, String)] = [
            (coreSimulator + "/Caches", "caches", "Simulator caches", "Caches CoreSimulator builds for each runtime, such as the shared system library cache.", "Rebuilt the next time a simulator starts, which makes that start slower."),
            (home + "/Library/Logs/CoreSimulator", "logs", "Simulator logs", "Diagnostic logs written by simulators.", "Recreated as simulators run."),
            (home + "/Library/Developer/XCTestDevices", "testdevices", "Test runner clones", "Simulator clones Xcode creates to run tests in parallel.", "Recreated the next time tests run in parallel."),
        ]
        for (path, id, title, explanation, regeneration) in folders where Self.isDirectory(path) {
            draft.drafts.append(DeveloperItemDraft(
                item: item(.simulators, id: id, group: "Caches", title: title, detail: abbreviated(path), explanation: explanation, regeneration: regeneration, safety: .safe, path: path),
                size: folderSize(path)
            ))
        }
        return draft
    }

    // MARK: - Swift and Objective-C dependency managers

    private func collectSwiftPM() async -> DeveloperToolDraft {
        let cache = home + "/Library/Caches/org.swift.swiftpm"
        var draft = DeveloperToolDraft(tool: .swiftPM)
        draft.isDetected = Self.isDirectory(cache)
        guard draft.isDetected else { return draft }
        draft.drafts.append(DeveloperItemDraft(
            item: item(.swiftPM, id: "cache", group: "Cache", title: "Package cache", detail: abbreviated(cache),
                       explanation: "Git repositories and archives of Swift packages that Xcode and SwiftPM downloaded.",
                       regeneration: "Downloaded again the next time a project resolves its packages.", safety: .safe, path: cache),
            size: .paths([cache])
        ))
        return draft
    }

    private func collectCocoaPods(_ environment: DeveloperEnvironment) async -> DeveloperToolDraft {
        let cache = home + "/Library/Caches/CocoaPods"
        let repos = home + "/.cocoapods/repos"
        var draft = DeveloperToolDraft(tool: .cocoaPods)
        draft.location = environment.executable("pod")
        draft.isDetected = draft.location != nil || Self.isDirectory(cache) || Self.isDirectory(home + "/.cocoapods")
        guard draft.isDetected else { return draft }
        if Self.isDirectory(cache) {
            draft.drafts.append(DeveloperItemDraft(
                item: item(.cocoaPods, id: "cache", group: "Cache", title: "Pod cache", detail: abbreviated(cache),
                           explanation: "Pods CocoaPods downloaded for your projects. Each project’s Pods folder isn’t touched.",
                           regeneration: "Downloaded again on the next pod install.", safety: .safe, path: cache),
                size: .paths([cache])
            ))
        }
        if mode == .full, let names = try? FileManager.default.contentsOfDirectory(atPath: repos) {
            for name in names.sorted() where !name.hasPrefix(".") && Self.isDirectory(repos + "/" + name) {
                let path = repos + "/" + name
                draft.drafts.append(DeveloperItemDraft(
                    item: item(.cocoaPods, id: "repo." + name, group: "Spec Repositories", title: "Spec repository “\(name)”", detail: abbreviated(path),
                               explanation: "A local copy of a pod spec repository.",
                               regeneration: name == "trunk" ? "Recreated from the CocoaPods CDN on the next pod install." : "Cloned again by pod repo update or the next pod install.",
                               safety: .review, path: path),
                    size: .paths([path])
                ))
            }
        }
        return draft
    }

    private func collectCarthage(_ environment: DeveloperEnvironment) async -> DeveloperToolDraft {
        let cache = home + "/Library/Caches/org.carthage.CarthageKit"
        var draft = DeveloperToolDraft(tool: .carthage)
        draft.location = environment.executable("carthage")
        draft.isDetected = draft.location != nil || Self.isDirectory(cache)
        guard Self.isDirectory(cache) else { return draft }
        draft.drafts.append(DeveloperItemDraft(
            item: item(.carthage, id: "cache", group: "Cache", title: "Dependency cache", detail: abbreviated(cache),
                       explanation: "Repositories and prebuilt frameworks Carthage downloaded.",
                       regeneration: "Downloaded again on the next carthage bootstrap or update.", safety: .safe, path: cache),
            size: .paths([cache])
        ))
        return draft
    }

    // MARK: - Homebrew

    private func collectHomebrew(_ environment: DeveloperEnvironment) async -> DeveloperToolDraft {
        var draft = DeveloperToolDraft(tool: .homebrew)
        guard let brew = environment.executable("brew") else { return draft }
        draft.isDetected = true
        draft.location = brew

        let cacheFolder = await DeveloperCLI.existingPath(brew, ["--cache"], home: home) ?? (home + "/Library/Caches/Homebrew")
        let cacheUsage = Self.isDirectory(cacheFolder) ? try? await fileScanner.measure(path: cacheFolder) : nil
        if let cacheUsage, cacheUsage.allocatedBytes > 0 {
            draft.notes.append(.info("Download cache: \(ByteFormatting.string(cacheUsage.allocatedBytes)). Homebrew keeps downloads of the versions you have installed."))
        }

        let arguments = ["cleanup", "--prune=all", "-s"]
        let cleanup = command(brew, arguments, timeout: 900, environment: ["HOMEBREW_NO_AUTOREMOVE": "1"])
        var cleanupItem = item(
            .homebrew, id: "cleanup", group: "Cleanup", title: "Old versions and downloads",
            explanation: "Previous versions of installed formulae and casks, and downloads Homebrew no longer needs.",
            regeneration: "Nothing you use is removed. Homebrew downloads files again only if you reinstall an old version.",
            safety: .safe, command: cleanup, path: cacheFolder
        )

        guard mode == .full else {
            // Smart Scan: the download cache is an upper bound; Homebrew decides what's outdated.
            if let cacheUsage, cacheUsage.reclaimableBytes > 0 {
                cleanupItem.sizeIsUpperBound = true
                cleanupItem.detail = "Download cache"
                draft.drafts.append(DeveloperItemDraft(item: cleanupItem, size: .known(cacheUsage.reclaimableBytes)))
            }
            return draft
        }

        guard let result = await DeveloperCLI.run(brew, arguments + ["--dry-run"], timeout: 240, home: home) else {
            draft.notes.append(.warning("Couldn’t run Homebrew to see what it would clean up."))
            return draft
        }
        let plan = DeveloperHomebrewParser.parseCleanupDryRun(result.standardOutput)
        guard result.succeeded || !plan.isEmpty else {
            let reason = result.combinedOutput.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit code \(result.exitCode)"
            draft.notes.append(.warning("Homebrew couldn’t estimate its cleanup: \(reason)"))
            return draft
        }
        if plan.isEmpty {
            draft.notes.append(.info("Homebrew has no old versions or outdated downloads to remove."))
            return draft
        }
        var parts: [String] = []
        let versions = plan.oldVersionCount
        if versions > 0 { parts.append("\(versions) old version\(versions == 1 ? "" : "s")") }
        let downloads = plan.entries(inside: cacheFolder).count
        if downloads > 0 { parts.append("\(downloads) outdated download\(downloads == 1 ? "" : "s")") }
        cleanupItem.detail = parts.isEmpty ? nil : parts.joined(separator: " · ")
        draft.drafts.append(DeveloperItemDraft(item: cleanupItem, size: .known(plan.estimatedBytes), keepWhenEmpty: !plan.entries.isEmpty))
        if !plan.autoremoveFormulae.isEmpty {
            draft.notes.append(.info("Homebrew also lists unneeded dependencies (\(plan.autoremoveFormulae.joined(separator: ", "))). Mac Cleaner leaves installed formulae alone; run “brew autoremove” yourself if you don’t need them."))
        }
        return draft
    }

    // MARK: - JavaScript

    private func collectNPM(_ environment: DeveloperEnvironment) async -> DeveloperToolDraft {
        var draft = DeveloperToolDraft(tool: .npm)
        let npm = environment.executable("npm")
        draft.location = npm
        var cacheRoot = home + "/.npm"
        if let npm, let path = await DeveloperCLI.existingPath(npm, ["config", "get", "cache"], home: home) { cacheRoot = path }
        draft.isDetected = npm != nil || Self.isDirectory(home + "/.npm")
        let cache = cacheRoot + "/_cacache"
        guard Self.isDirectory(cache) else { return draft }
        let explanation = "Packages npm downloaded before. The node_modules folders in your projects aren’t touched."
        let regeneration = "npm downloads packages again the next time a project installs them."
        if let npm, mode == .full {
            draft.drafts.append(DeveloperItemDraft(
                item: item(.npm, id: "cache", group: "Cache", title: "Package cache", detail: abbreviated(cache), explanation: explanation, regeneration: regeneration,
                           safety: .safe, command: command(npm, ["cache", "clean", "--force"], timeout: 600), path: cache),
                size: .folder(cache)
            ))
        } else {
            draft.drafts.append(DeveloperItemDraft(
                item: item(.npm, id: "cache", group: "Cache", title: "npm package cache", detail: abbreviated(cache), explanation: explanation, regeneration: regeneration, safety: .safe, path: cache),
                size: folderSize(cache)
            ))
        }
        return draft
    }

    private func collectPNPM(_ environment: DeveloperEnvironment) async -> DeveloperToolDraft {
        var draft = DeveloperToolDraft(tool: .pnpm)
        let pnpm = environment.executable("pnpm")
        draft.location = pnpm
        var stores: [String] = []
        if let pnpm, let path = await DeveloperCLI.existingPath(pnpm, ["store", "path"], home: home) { stores.append(path) }
        for candidate in [home + "/Library/pnpm/store", home + "/.pnpm-store", home + "/.local/share/pnpm/store"] where Self.isDirectory(candidate) {
            let overlaps = stores.contains { PathUtilities.isSameOrDescendant($0, of: candidate) || PathUtilities.isSameOrDescendant(candidate, of: $0) }
            if !overlaps { stores.append(candidate) }
        }
        draft.isDetected = pnpm != nil || !stores.isEmpty
        let explanation = "pnpm’s shared package store. Projects keep working: their node_modules folders hold their own links to the files."
        if let pnpm, mode == .full, let store = stores.first {
            var prune = item(
                .pnpm, id: "prune", group: "Store", title: "Unreferenced packages", detail: "Store: " + abbreviated(store),
                explanation: "Packages in pnpm’s store that no project on this Mac references anymore.",
                regeneration: "pnpm downloads a removed package again only if a project needs it.",
                safety: .safe, command: command(pnpm, ["store", "prune"], timeout: 900), path: store
            )
            prune.sizeIsUpperBound = true
            draft.drafts.append(DeveloperItemDraft(item: prune, size: .folder(store)))
        } else {
            for store in stores {
                draft.drafts.append(DeveloperItemDraft(
                    item: item(.pnpm, id: "store." + store, group: "Store", title: "pnpm package store", detail: abbreviated(store), explanation: explanation,
                               regeneration: "pnpm downloads packages again the next time a project installs them.", safety: .safe, path: store),
                    size: folderSize(store)
                ))
            }
        }
        return draft
    }

    private func collectYarn(_ environment: DeveloperEnvironment) async -> DeveloperToolDraft {
        var draft = DeveloperToolDraft(tool: .yarn)
        let yarn = environment.executable("yarn")
        draft.location = yarn
        var isClassic = false
        if let yarn, let version = await DeveloperCLI.firstLine(yarn, ["--version"], home: home) {
            isClassic = version.hasPrefix("1.")
        }
        var classicCache: String?
        if let yarn, isClassic { classicCache = await DeveloperCLI.existingPath(yarn, ["cache", "dir"], home: home) }
        if classicCache == nil, Self.isDirectory(home + "/Library/Caches/Yarn") { classicCache = home + "/Library/Caches/Yarn" }
        let berryCache = home + "/.yarn/berry/cache"
        draft.isDetected = yarn != nil || classicCache != nil || Self.isDirectory(berryCache)
        let regeneration = "Yarn downloads packages again the next time a project installs them."

        if let classicCache {
            if let yarn, isClassic, mode == .full {
                draft.drafts.append(DeveloperItemDraft(
                    item: item(.yarn, id: "classic", group: "Cache", title: "Package cache", detail: abbreviated(classicCache),
                               explanation: "Packages Yarn 1 downloaded before. Your projects’ node_modules folders aren’t touched.",
                               regeneration: regeneration, safety: .safe, command: command(yarn, ["cache", "clean"], timeout: 600), path: classicCache),
                    size: .folder(classicCache)
                ))
            } else {
                draft.drafts.append(DeveloperItemDraft(
                    item: item(.yarn, id: "classic", group: "Cache", title: "Yarn package cache", detail: abbreviated(classicCache),
                               explanation: "Packages Yarn 1 downloaded before. Your projects’ node_modules folders aren’t touched.",
                               regeneration: regeneration, safety: .safe, path: classicCache),
                    size: folderSize(classicCache)
                ))
            }
        }
        if Self.isDirectory(berryCache) {
            draft.drafts.append(DeveloperItemDraft(
                item: item(.yarn, id: "berry", group: "Cache", title: "Global cache (Yarn 2 and later)", detail: abbreviated(berryCache),
                           explanation: "Package archives shared by projects that use Yarn 2 or later. Projects that commit their own .yarn/cache aren’t affected.",
                           regeneration: regeneration, safety: .safe, path: berryCache),
                size: folderSize(berryCache)
            ))
        }
        return draft
    }

    private func collectBun(_ environment: DeveloperEnvironment) async -> DeveloperToolDraft {
        var draft = DeveloperToolDraft(tool: .bun)
        let bun = environment.executable("bun")
        draft.location = bun
        let cache = home + "/.bun/install/cache"
        draft.isDetected = bun != nil || Self.isDirectory(home + "/.bun")
        guard Self.isDirectory(cache) else { return draft }
        let explanation = "Packages Bun downloaded before. Your projects’ node_modules folders aren’t touched."
        let regeneration = "Bun downloads packages again the next time a project installs them."
        if let bun {
            draft.drafts.append(DeveloperItemDraft(
                item: item(.bun, id: "cache", group: "Cache", title: "Package cache", detail: abbreviated(cache), explanation: explanation, regeneration: regeneration,
                           safety: .safe, command: command(bun, ["pm", "cache", "rm"], timeout: 600), path: cache),
                size: .folder(cache)
            ))
        } else {
            draft.drafts.append(DeveloperItemDraft(
                item: item(.bun, id: "cache", group: "Cache", title: "Package cache", detail: abbreviated(cache), explanation: explanation, regeneration: regeneration, safety: .safe, path: cache),
                size: folderSize(cache)
            ))
        }
        return draft
    }

    // MARK: - Python

    private func collectPip(_ environment: DeveloperEnvironment) async -> DeveloperToolDraft {
        var draft = DeveloperToolDraft(tool: .pip)
        let pip = environment.executable("pip3") ?? environment.executable("pip")
        draft.location = pip
        var cache = home + "/Library/Caches/pip"
        if let pip, let path = await DeveloperCLI.existingPath(pip, ["cache", "dir"], home: home) { cache = path }
        draft.isDetected = pip != nil || Self.isDirectory(cache)
        guard Self.isDirectory(cache) else { return draft }
        let explanation = "Wheels and downloads pip cached. Installed packages and virtual environments aren’t touched."
        let regeneration = "pip downloads or builds packages again the next time you install them."
        if let pip, mode == .full {
            draft.drafts.append(DeveloperItemDraft(
                item: item(.pip, id: "cache", group: "Cache", title: "Package cache", detail: abbreviated(cache), explanation: explanation, regeneration: regeneration,
                           safety: .safe, command: command(pip, ["cache", "purge"], timeout: 600), path: cache),
                size: .folder(cache)
            ))
        } else {
            draft.drafts.append(DeveloperItemDraft(
                item: item(.pip, id: "cache", group: "Cache", title: "pip cache", detail: abbreviated(cache), explanation: explanation, regeneration: regeneration, safety: .safe, path: cache),
                size: folderSize(cache)
            ))
        }
        return draft
    }

    private func collectUV(_ environment: DeveloperEnvironment) async -> DeveloperToolDraft {
        var draft = DeveloperToolDraft(tool: .uv)
        let uv = environment.executable("uv")
        draft.location = uv
        var cache = home + "/.cache/uv"
        if let uv, let path = await DeveloperCLI.existingPath(uv, ["cache", "dir"], home: home) { cache = path }
        draft.isDetected = uv != nil || Self.isDirectory(cache)
        guard Self.isDirectory(cache) else { return draft }
        if let uv, mode == .full {
            var prune = item(
                .uv, id: "prune", group: "Cache", title: "Unused cache entries", detail: abbreviated(cache),
                explanation: "Cached packages and builds that no environment uses anymore.",
                regeneration: "uv downloads or builds them again only when needed.",
                safety: .safe, command: command(uv, ["cache", "prune"], timeout: 900), path: cache
            )
            prune.sizeIsUpperBound = true
            prune.countsTowardTotal = false
            draft.drafts.append(DeveloperItemDraft(item: prune, size: .folder(cache)))
            draft.drafts.append(DeveloperItemDraft(
                item: item(.uv, id: "clean", group: "Cache", title: "Entire cache", detail: abbreviated(cache),
                           explanation: "Every package and build uv cached, including ones your environments use. Existing virtual environments keep working.",
                           regeneration: "uv downloads and builds packages again the next time you install them, which is slower and needs a network connection.",
                           safety: .review, command: command(uv, ["cache", "clean"], timeout: 900), path: cache),
                size: .folder(cache)
            ))
        } else {
            draft.drafts.append(DeveloperItemDraft(
                item: item(.uv, id: "cache", group: "Cache", title: "uv cache", detail: abbreviated(cache),
                           explanation: "Packages and builds uv cached. Existing virtual environments keep working.",
                           regeneration: "uv downloads and builds packages again the next time you install them.", safety: .safe, path: cache),
                size: folderSize(cache)
            ))
        }
        return draft
    }

    // MARK: - Go and Rust

    private func collectGo(_ environment: DeveloperEnvironment) async -> DeveloperToolDraft {
        var draft = DeveloperToolDraft(tool: .go)
        let go = environment.executable("go")
        draft.location = go
        var buildCache = home + "/Library/Caches/go-build"
        var moduleCache = home + "/go/pkg/mod"
        if let go, let result = await DeveloperCLI.run(go, ["env", "GOCACHE", "GOMODCACHE"], timeout: 30, home: home), result.succeeded {
            let lines = result.standardOutput.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            if lines.count > 0, lines[0].hasPrefix("/") { buildCache = lines[0] }
            if lines.count > 1, lines[1].hasPrefix("/") { moduleCache = lines[1] }
        }
        draft.isDetected = go != nil || Self.isDirectory(buildCache) || Self.isDirectory(moduleCache)
        if Self.isDirectory(buildCache) {
            let explanation = "Compiled packages and test results Go keeps to speed up builds."
            let regeneration = "Go rebuilds what it needs on the next build or test run."
            if let go {
                draft.drafts.append(DeveloperItemDraft(
                    item: item(.go, id: "buildcache", group: "Caches", title: "Build cache", detail: abbreviated(buildCache), explanation: explanation, regeneration: regeneration,
                               safety: .safe, command: command(go, ["clean", "-cache"], timeout: 600), path: buildCache),
                    size: .folder(buildCache)
                ))
            } else {
                draft.drafts.append(DeveloperItemDraft(
                    item: item(.go, id: "buildcache", group: "Caches", title: "Build cache", detail: abbreviated(buildCache), explanation: explanation, regeneration: regeneration, safety: .safe, path: buildCache),
                    size: folderSize(buildCache)
                ))
            }
        }
        if Self.isDirectory(moduleCache) {
            if let go {
                draft.drafts.append(DeveloperItemDraft(
                    item: item(.go, id: "modcache", group: "Caches", title: "Module cache", detail: abbreviated(moduleCache),
                               explanation: "Source code of the modules your projects depend on.",
                               regeneration: "Go downloads modules again on the next build, which needs a network connection.",
                               safety: .review, command: command(go, ["clean", "-modcache"], timeout: 900), path: moduleCache),
                    size: .folder(moduleCache)
                ))
            } else {
                draft.notes.append(.info("Go’s module cache is read-only, so only the go command can remove it. Install Go to clean it."))
            }
        }
        return draft
    }

    private func collectCargo(_ environment: DeveloperEnvironment) async -> DeveloperToolDraft {
        let cargoHome = home + "/.cargo"
        var draft = DeveloperToolDraft(tool: .cargo)
        draft.location = environment.executable("cargo")
        draft.isDetected = draft.location != nil || Self.isDirectory(cargoHome)
        let folders: [(String, String, String, String)] = [
            ("registry/cache", "Downloaded crates", "Compressed crates Cargo downloaded from registries.", "Cargo downloads crates again the next time a project builds."),
            ("registry/src", "Extracted crate sources", "Crate sources Cargo unpacked from its downloads.", "Cargo unpacks them again on the next build."),
            ("git/checkouts", "Git dependency checkouts", "Working copies of dependencies fetched from Git.", "Cargo checks them out again on the next build."),
        ]
        for (relative, title, explanation, regeneration) in folders where Self.isDirectory(cargoHome + "/" + relative) {
            let path = cargoHome + "/" + relative
            draft.drafts.append(DeveloperItemDraft(
                item: item(.cargo, id: relative, group: "Registry", title: title, detail: abbreviated(path), explanation: explanation, regeneration: regeneration, safety: .review, path: path),
                size: .paths([path])
            ))
        }
        return draft
    }

    // MARK: - Docker

    private func collectDocker(_ environment: DeveloperEnvironment) async -> DeveloperToolDraft {
        var draft = DeveloperToolDraft(tool: .docker)
        guard let docker = environment.executable("docker") else { return draft }
        draft.isDetected = true
        draft.location = docker

        guard let result = await DeveloperCLI.run(docker, ["system", "df", "--format", "{{json .}}"], timeout: 30, home: home) else {
            draft.notes.append(.warning("Couldn’t run the docker command."))
            return draft
        }
        guard result.succeeded else {
            if result.timedOut || DeveloperDockerParser.isEngineUnavailable(result) {
                draft.notes.append(.info("Docker isn’t running. Start Docker Desktop (or your Docker engine) to see what can be cleaned."))
            } else {
                let reason = result.combinedOutput.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit code \(result.exitCode)"
                draft.notes.append(.warning("Docker reported an error: \(reason)"))
            }
            return draft
        }
        let rows = DeveloperDockerParser.parseSystemDF(result.standardOutput)
        func row(_ kind: DeveloperDockerUsage.Kind) -> DeveloperDockerUsage? { rows.first { $0.kind == kind } }
        draft.notes.append(.info("Docker decides what is unused: running containers and the images they use are never removed."))

        if let buildCache = row(.buildCache), buildCache.reclaimableBytes > 0 {
            draft.drafts.append(DeveloperItemDraft(
                item: item(.docker, id: "buildcache", group: "Build Cache", title: "Build cache",
                           detail: "\(NumberFormatting.count(buildCache.totalCount)) cache entries",
                           explanation: "Layers Docker cached while building images that no current build is using.",
                           regeneration: "Docker rebuilds layers the next time you build, so that build is slower.",
                           safety: .safe, command: command(docker, ["builder", "prune", "-f"], timeout: 900)),
                size: .known(buildCache.reclaimableBytes)
            ))
        }

        if mode == .full,
           let images = await DeveloperCLI.run(docker, ["image", "ls", "--filter", "dangling=true", "--format", "{{json .}}"], timeout: 30, home: home),
           images.succeeded {
            let dangling = DeveloperDockerParser.parseImages(images.standardOutput)
            if !dangling.isEmpty {
                var danglingItem = item(
                    .docker, id: "dangling", group: "Images", title: "Dangling images",
                    detail: "\(dangling.count) untagged image\(dangling.count == 1 ? "" : "s") shown as <none>",
                    explanation: "Untagged images left behind when an image was rebuilt or pulled again.",
                    regeneration: "Not needed: newer images replaced them.",
                    safety: .safe, command: command(docker, ["image", "prune", "-f"], timeout: 900)
                )
                danglingItem.sizeIsUpperBound = true
                draft.drafts.append(DeveloperItemDraft(item: danglingItem, size: .known(dangling.compactMap(\.sizeBytes).reduce(0, +)), keepWhenEmpty: true))
            }
        }

        if let containers = row(.containers), containers.inactiveCount > 0 {
            let count = containers.inactiveCount
            var containerItem = item(
                .docker, id: "containers", group: "Containers", title: "Stopped containers",
                detail: "\(count) stopped container\(count == 1 ? "" : "s")",
                explanation: "Containers that have exited and aren’t running.",
                regeneration: "Can’t be recreated: files written inside a removed container are lost. Images and volumes stay.",
                safety: .caution, command: command(docker, ["container", "prune", "-f"], timeout: 600)
            )
            containerItem.warning = "Removes \(count) stopped container\(count == 1 ? "" : "s") and any files written inside \(count == 1 ? "it" : "them"). Running containers and volumes aren’t affected."
            containerItem.requiresAcknowledgement = true
            draft.drafts.append(DeveloperItemDraft(item: containerItem, size: .known(containers.reclaimableBytes), keepWhenEmpty: true))
        }

        if let images = row(.images), images.reclaimableBytes > 0 {
            var unusedItem = item(
                .docker, id: "unusedimages", group: "Images", title: "All unused images",
                detail: "Images no container uses, including tagged ones",
                explanation: "Every image that isn’t used by a container, whether or not it has a tag.",
                regeneration: "Pull or rebuild the images when you need them again; this needs a network connection or the original build files.",
                safety: .caution, command: command(docker, ["image", "prune", "-a", "-f"], timeout: 900)
            )
            unusedItem.warning = "Removes every image no container uses, including images you pulled or built on purpose. You’ll have to pull or rebuild them before using them again."
            unusedItem.requiresAcknowledgement = true
            unusedItem.countsTowardTotal = false
            draft.drafts.append(DeveloperItemDraft(item: unusedItem, size: .known(images.reclaimableBytes)))
        }

        if let volumes = row(.volumes), volumes.reclaimableBytes > 0 {
            draft.notes.append(.info("Unused volumes hold \(ByteFormatting.string(volumes.reclaimableBytes)). Volumes can contain databases and other data, so Mac Cleaner never removes them. Use “docker volume prune” in Terminal only if you’re sure."))
        }
        return draft
    }

    // MARK: - JVM

    private func collectGradle(_ environment: DeveloperEnvironment) async -> DeveloperToolDraft {
        let gradleHome = home + "/.gradle"
        var draft = DeveloperToolDraft(tool: .gradle)
        let gradle = environment.executable("gradle")
        draft.location = gradle
        draft.isDetected = gradle != nil || Self.isDirectory(gradleHome)
        guard draft.isDetected else { return draft }

        if Self.isDirectory(gradleHome + "/caches") {
            var caches = item(
                .gradle, id: "caches", group: "Caches", title: "Dependency and build caches", detail: abbreviated(gradleHome + "/caches"),
                explanation: "Dependencies Gradle downloaded, its build cache and transformed artifacts.",
                regeneration: "Gradle downloads dependencies again on the next build, which needs a network connection.",
                safety: .safe, path: gradleHome + "/caches"
            )
            caches.warning = "Stop Gradle daemons first so none of these files are in use."
            draft.drafts.append(DeveloperItemDraft(item: caches, size: .children(of: gradleHome + "/caches")))
        }

        let dists = gradleHome + "/wrapper/dists"
        if let names = try? FileManager.default.contentsOfDirectory(atPath: dists) {
            let versioned = names.compactMap { name in DeveloperXcodeInspector.gradleDistributionVersion(name).map { (name, $0) } }
            if let newest = versioned.map(\.1).max(by: { DeveloperXcodeInspector.compareVersions($0, $1) == .orderedAscending }) {
                for (name, version) in versioned.sorted(by: { $0.0 < $1.0 }) where DeveloperXcodeInspector.compareVersions(version, newest) == .orderedAscending {
                    let path = dists + "/" + name
                    draft.drafts.append(DeveloperItemDraft(
                        item: item(.gradle, id: "dist." + name, group: "Wrapper Distributions", title: name,
                                   detail: "Newest kept: Gradle \(newest.map(String.init).joined(separator: "."))",
                                   explanation: "A Gradle version a project’s wrapper downloaded.",
                                   regeneration: "Downloaded again the next time a project that uses this version builds.",
                                   safety: .review, path: path),
                        size: .paths([path])
                    ))
                }
            }
        }

        if Self.isDirectory(gradleHome + "/daemon") {
            draft.drafts.append(DeveloperItemDraft(
                item: item(.gradle, id: "daemon", group: "Caches", title: "Daemon logs", detail: abbreviated(gradleHome + "/daemon"),
                           explanation: "Logs and state files from Gradle’s background daemons.",
                           regeneration: "Recreated when a daemon starts.", safety: .safe, path: gradleHome + "/daemon"),
                size: .children(of: gradleHome + "/daemon")
            ))
        }

        if let gradle, mode == .full {
            var stop = item(
                .gradle, id: "stop", group: "Daemons", title: "Stop Gradle daemons",
                explanation: "Stops Gradle’s background processes so the caches above aren’t in use while they’re cleaned.",
                regeneration: "Gradle starts a new daemon on the next build.",
                safety: .safe, command: command(gradle, ["--stop"], timeout: 120)
            )
            stop.countsTowardTotal = false
            stop.warning = "Builds that are running right now will stop."
            draft.drafts.append(DeveloperItemDraft(item: stop, size: .known(0), keepWhenEmpty: true))
        }
        return draft
    }

    private func collectMaven(_ environment: DeveloperEnvironment) async -> DeveloperToolDraft {
        var draft = DeveloperToolDraft(tool: .maven)
        draft.location = environment.executable("mvn")
        draft.isDetected = draft.location != nil || Self.isDirectory(home + "/.m2")
        let repository = home + "/.m2/repository"
        guard Self.isDirectory(repository) else { return draft }
        var repo = item(
            .maven, id: "repository", group: "Repository", title: "Local repository", detail: abbreviated(repository),
            explanation: "Every dependency Maven downloaded for your projects, plus artifacts you installed locally with mvn install.",
            regeneration: "Maven downloads dependencies again on the next build, which needs a network connection. Artifacts you installed yourself must be built again.",
            safety: .caution, path: repository
        )
        repo.warning = "Offline builds fail until Maven has downloaded the dependencies again."
        draft.drafts.append(DeveloperItemDraft(item: repo, size: .children(of: repository)))
        return draft
    }

    // MARK: - Temporary files

    /// Leftover temporary folders of build tools in `$TMPDIR`, untouched for two days.
    static let temporaryPrefixes: [(prefix: String, tool: String)] = [
        ("go-build", "Go"), ("metro-", "Metro"), ("haste-map-", "Jest or Metro"), ("jest_", "Jest"),
        ("react-native-packager-cache-", "React Native"), ("node-compile-cache", "Node.js"), ("pip-", "pip"),
        ("npm-", "npm"), ("yarn--", "Yarn"), ("cargo-install", "Cargo"), ("kotlin-daemon.", "Kotlin"),
        ("TemporaryDirectory.", "Swift tools"),
    ]

    private func collectTemporaryFiles(_ environment: DeveloperEnvironment) async -> DeveloperToolDraft {
        var draft = DeveloperToolDraft(tool: .temporaryFiles)
        guard let temporary = environment.temporaryDirectory else { return draft }
        draft.isDetected = true
        draft.location = temporary
        let records = await BackgroundWork.run(qos: .userInitiated) { (try? FileSystemScanner().children(of: temporary)) ?? [] }
        let cutoff = Date().addingTimeInterval(-2 * 86_400)
        // One row per tool, so dozens of small leftovers don't flood the list.
        var byTool: [(tool: String, records: [FileRecord])] = []
        for record in records.sorted(by: { $0.name < $1.name })
        where (record.type == .directory || record.type == .regular) && record.modificationDate < cutoff {
            guard let match = Self.temporaryPrefixes.first(where: { record.name.hasPrefix($0.prefix) }) else { continue }
            if let index = byTool.firstIndex(where: { $0.tool == match.tool }) {
                byTool[index].records.append(record)
            } else {
                byTool.append((match.tool, [record]))
            }
        }
        for (tool, matches) in byTool {
            let newest = matches.map(\.modificationDate).max() ?? cutoff
            let count = matches.count
            var leftover = item(
                .temporaryFiles, id: tool, group: "Leftovers",
                title: count == 1 ? matches[0].name : "\(tool) temporary items",
                detail: "\(count == 1 ? "Left by \(tool)" : "\(count) items") · last changed \(DateFormatting.relative(newest))",
                explanation: "Temporary items \(tool) created and didn’t remove. Only items untouched for two days are listed.",
                regeneration: "Tools create new temporary files when they need them.",
                safety: .safe, path: count == 1 ? matches[0].path : temporary
            )
            leftover.date = newest
            leftover.canExclude = count == 1
            draft.drafts.append(DeveloperItemDraft(item: leftover, size: .paths(matches.map(\.path))))
        }
        return draft
    }
}

/// Minimal existence checks used while collecting (no symbolic links followed).
enum DeveloperPathProbe {
    static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return FileObjectType(mode: info.st_mode) == .directory
    }
}
