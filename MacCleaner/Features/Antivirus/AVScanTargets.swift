import Darwin
import Foundation

/// A folder a scan walks.
struct AVScanTarget: Sendable, Hashable {
    enum Filter: String, Sendable, Hashable {
        /// Every file.
        case all
        /// Programs, scripts and libraries only (executables, `.dylib`, shell and other scripts).
        case code
    }

    var path: String
    var filter: Filter = .all
    var maxDepth: Int = .max
    /// "your Downloads folder", for limitations.
    var label: String
    /// macOS asks before an app reads it (Desktop, Documents, Downloads).
    var isPrivacyProtected = false
    /// Folders with these names aren't entered (caches that hold no programs).
    var skippedFolderNames: Set<String> = []
}

/// What a scan will look at.
struct AVScanPlan: Sendable {
    var kind: AVScanKind
    var targets: [AVScanTarget] = []
    var files: [String] = []
    var limitations: [AVLimitation] = []
    /// Documented adware components found while planning (Security feature rules).
    var ruleMatches: [AVThreat] = []
}

/// Which files in a folder are worth scanning for the `.code` filter.
enum AVCodeFilter {
    static let scriptExtensions: Set<String> = [
        "sh", "bash", "zsh", "csh", "ksh", "fish", "command", "tool", "py", "pyc", "pl", "pm", "rb", "js", "mjs", "cjs", "jxa",
        "scpt", "applescript", "php", "tcl", "ps1", "jar", "vbs", "lua", "workflow",
    ]
    static let libraryExtensions: Set<String> = ["dylib", "so"]
    static let installerExtensions: Set<String> = ["pkg", "mpkg", "dmg"]

    /// `name` lives in a folder called `parent`; `path` is used for the executable-bit check
    /// of files without an extension.
    static func includes(name: String, parent: String, path: String) -> Bool {
        if parent == "MacOS" { return true }
        let dot = name.lastIndex(of: ".")
        let ext = dot.map { name[name.index(after: $0)...].lowercased() } ?? ""
        if scriptExtensions.contains(ext) || libraryExtensions.contains(ext) || installerExtensions.contains(ext) { return true }
        guard dot == nil || dot == name.startIndex else { return false }
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && (info.st_mode & 0o111) != 0
    }
}

/// Paths no scan enters.
enum AVScanScope {
    /// The signed, read-only system volume and folders only macOS uses.
    static let systemRoots = ["/System", "/bin", "/sbin", "/usr", "/dev", "/private/var/vm", "/private/var/db", "/Library/Apple"]

    static func isSystemPath(_ path: String) -> Bool {
        let canonical = PathUtilities.firmlinkCanonical(PathUtilities.normalize(path))
        if PathUtilities.isSameOrDescendant(canonical, of: "/usr/local") { return false }
        return systemRoots.contains { PathUtilities.isSameOrDescendant(canonical, of: $0) }
    }

    /// Caches and data stores below `~/Library/Application Support` that never hold programs.
    static let cacheFolderNames: Set<String> = [
        "Cache", "Caches", "cache", "Code Cache", "GPUCache", "ShaderCache", "GrShaderCache", "DawnCache", "DawnGraphiteCache",
        "Service Worker", "IndexedDB", "blob_storage", "CacheStorage", "Crashpad", "MobileSync", "CrashReporter",
        "Local Storage", "Session Storage", "WebStorage", "File System", "optimization_guide_model_store", ".git",
    ]
}

/// Inputs for planning a Quick Scan, injectable for tests.
struct AVQuickScanSources: Sendable {
    var home: String
    var runningExecutables: @Sendable () -> [String]
    var launchdFolders: [String]
    /// Login items' paths; nil when they couldn't be read (no Automation permission).
    var loginItemPaths: @Sendable () async -> [String]?
    var applicationFolders: [String]
    /// Downloads and Desktop: macOS may ask for permission, so the background agent skips them.
    var includesPrivacyProtectedFolders: Bool
    var knownAdwareLocations: @Sendable () -> [SecurityPUAMatch]
    var extraRoots: [String] = ["/Users/Shared", "/private/tmp", "/private/var/tmp"]

    static func live(includesPrivacyProtectedFolders: Bool, readsLoginItems: Bool) -> AVQuickScanSources {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return AVQuickScanSources(
            home: home,
            runningExecutables: { Array(Set(ProcessInspector.listPIDs().compactMap(ProcessInspector.executablePath(of:)))).sorted() },
            launchdFolders: [home + "/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"],
            loginItemPaths: {
                guard readsLoginItems, let records = await StartupLoginItemsService.recordsIfAuthorized() else { return nil }
                return records.compactMap(\.path)
            },
            applicationFolders: ["/Applications", home + "/Applications"],
            includesPrivacyProtectedFolders: includesPrivacyProtectedFolders,
            knownAdwareLocations: { SecurityPUARules.installedKnownPaths(home: home) }
        )
    }
}

enum AVScanPlanner {
    /// Where Mac malware usually lives; meant to finish in a minute or two.
    static func quickScan(sources: AVQuickScanSources, kind: AVScanKind = .quick) async -> AVScanPlan {
        var plan = AVScanPlan(kind: kind)
        let home = sources.home
        var files = Set<String>()

        for executable in sources.runningExecutables() where !AVScanScope.isSystemPath(executable) {
            files.insert(executable)
        }

        let launchd = await BackgroundWork.run(qos: .userInitiated) { () -> (programs: [String], rules: [AVThreat]) in
            var programs: [String] = []
            var rules: [AVThreat] = []
            for folder in sources.launchdFolders {
                for plist in LaunchdLocations.plistFiles(in: folder) ?? [] {
                    guard let job = try? LaunchdPlistParser.parse(contentsOf: plist.path) else { continue }
                    let analysis = LaunchdProgramAnalyzer.analyze(job, plistPath: plist.path)
                    programs += [analysis.executable, analysis.scriptPath, analysis.targetPath].compactMap { $0 }
                    if let label = job.label, let match = SecurityPUARules.match(identifier: label), match.strength == .exact {
                        rules.append(AVThreat(path: plist.path, ruleMatch: AVRuleMatch(title: match.ruleTitle, family: match.rule.family,
                                                                                        isMalware: match.rule.classification == .malware),
                                              snapshot: FileSnapshot.capture(path: plist.path)))
                    }
                }
            }
            return (programs, rules)
        }
        for program in launchd.programs where program.hasPrefix("/") && !AVScanScope.isSystemPath(program) && !program.hasSuffix(".app") {
            files.insert(program)
        }
        plan.ruleMatches += launchd.rules
        for folder in sources.launchdFolders {
            plan.targets.append(AVScanTarget(path: folder, maxDepth: 1, label: "launch agents and daemons"))
        }

        if let loginItems = await sources.loginItemPaths() {
            for path in loginItems where !AVScanScope.isSystemPath(path) {
                if path.hasSuffix(".app") {
                    plan.targets.append(AVScanTarget(path: path + "/Contents/MacOS", maxDepth: 1, label: "login items"))
                } else {
                    files.insert(path)
                }
            }
        } else {
            plan.limitations.append(AVLimitation(
                title: "Login items weren't checked",
                detail: "Reading them needs Automation access to System Events. Their apps are still scanned if they're in an Applications folder.",
                settingsPane: SystemSettingsPane.automation.rawValue
            ))
        }

        if sources.includesPrivacyProtectedFolders {
            plan.targets.append(AVScanTarget(path: home + "/Downloads", maxDepth: 6, label: "your Downloads folder", isPrivacyProtected: true))
            plan.targets.append(AVScanTarget(path: home + "/Desktop", maxDepth: 6, label: "your Desktop", isPrivacyProtected: true))
        } else {
            plan.limitations.append(AVLimitation(
                title: "Downloads and Desktop weren't scanned",
                detail: "Scheduled scans skip folders that macOS protects with a permission prompt. Run a Quick Scan in Mac Cleaner to include them."
            ))
        }

        for folder in sources.applicationFolders {
            plan.targets.append(AVScanTarget(path: folder, filter: .code, label: "apps in \(PathUtilities.abbreviate(folder))"))
        }
        plan.targets += browserExtensionTargets(home: home)
        for root in sources.extraRoots {
            plan.targets.append(AVScanTarget(path: root, maxDepth: 8, label: PathUtilities.abbreviate(root)))
        }
        plan.targets.append(AVScanTarget(path: home + "/Library/Application Support", filter: .code, label: "Application Support",
                                         skippedFolderNames: AVScanScope.cacheFolderNames))

        let known = await BackgroundWork.run(qos: .userInitiated) { sources.knownAdwareLocations() }
        let flagged = Set(plan.ruleMatches.map(\.path))
        for match in known where !flagged.contains(match.matchedValue) {
            plan.ruleMatches.append(AVThreat(path: match.matchedValue,
                                             ruleMatch: AVRuleMatch(title: match.ruleTitle, family: match.rule.family, isMalware: match.rule.classification == .malware),
                                             snapshot: FileSnapshot.capture(path: match.matchedValue)))
        }
        plan.files = files.sorted()
        return plan
    }

    /// Browser extension folders: Chrome, Edge, Brave, Vivaldi, Chromium, Opera, Arc and Firefox profiles.
    static func browserExtensionTargets(home: String) -> [AVScanTarget] {
        let support = home + "/Library/Application Support"
        let chromium = [
            ("Google Chrome", "Google/Chrome"), ("Microsoft Edge", "Microsoft Edge"), ("Brave", "BraveSoftware/Brave-Browser"),
            ("Vivaldi", "Vivaldi"), ("Chromium", "Chromium"), ("Arc", "Arc/User Data"),
        ]
        var targets: [AVScanTarget] = []
        let manager = FileManager.default
        for (name, relative) in chromium {
            let root = support + "/" + relative
            guard let profiles = try? manager.contentsOfDirectory(atPath: root) else { continue }
            for profile in profiles.sorted() where profile == "Default" || profile.hasPrefix("Profile ") || profile == "Guest Profile" {
                let extensions = root + "/" + profile + "/Extensions"
                if manager.fileExists(atPath: extensions) {
                    targets.append(AVScanTarget(path: extensions, label: "\(name) extensions"))
                }
            }
        }
        let opera = support + "/com.operasoftware.Opera/Extensions"
        if manager.fileExists(atPath: opera) { targets.append(AVScanTarget(path: opera, label: "Opera extensions")) }
        let firefox = support + "/Firefox/Profiles"
        for profile in (try? manager.contentsOfDirectory(atPath: firefox))?.sorted() ?? [] {
            let extensions = firefox + "/" + profile + "/extensions"
            if manager.fileExists(atPath: extensions) { targets.append(AVScanTarget(path: extensions, label: "Firefox extensions")) }
        }
        return targets
    }

    /// The home folder, apps and system-wide software folders.
    static func fullScan(home: String, externalVolumes: [VolumeInfo] = []) -> AVScanPlan {
        var plan = AVScanPlan(kind: .full)
        plan.targets = [
            AVScanTarget(path: home, label: "your home folder"),
            AVScanTarget(path: "/Applications", label: "Applications"),
            AVScanTarget(path: "/Library", label: "the Library folder"),
            AVScanTarget(path: "/usr/local", label: "/usr/local"),
            AVScanTarget(path: "/opt", label: "/opt"),
            AVScanTarget(path: "/private/var", label: "/private/var"),
            AVScanTarget(path: "/Users/Shared", label: "/Users/Shared"),
        ]
        for volume in externalVolumes where !volume.isRootFileSystem {
            plan.targets.append(AVScanTarget(path: volume.path, label: volume.name))
        }
        return plan
    }

    /// Files and folders the person chose (or dropped on the page).
    static func custom(paths: [String]) -> AVScanPlan {
        var plan = AVScanPlan(kind: .custom)
        for raw in PathUtilities.removingNestedPaths(paths.map(PathUtilities.normalize)) {
            if AVScanScope.isSystemPath(raw) {
                plan.limitations.append(AVLimitation(
                    title: "System files weren't scanned",
                    detail: "\(PathUtilities.abbreviate(raw)) is part of macOS's signed, read-only system volume, which malware can't modify.",
                    path: raw
                ))
                continue
            }
            var info = stat()
            if lstat(raw, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR {
                plan.targets.append(AVScanTarget(path: raw, label: PathUtilities.abbreviate(raw)))
            } else {
                plan.files.append(raw)
            }
        }
        return plan
    }

    /// An external or removable drive.
    static func volume(_ volume: VolumeInfo) -> AVScanPlan {
        AVScanPlan(kind: .volume, targets: [AVScanTarget(path: volume.path, label: volume.name)])
    }

    /// The Downloads folder, with origin checks (Download Shield on demand).
    static func downloads(home: String) -> AVScanPlan {
        AVScanPlan(kind: .downloads, targets: [AVScanTarget(path: home + "/Downloads", maxDepth: 6, label: "your Downloads folder", isPrivacyProtected: true)])
    }
}
