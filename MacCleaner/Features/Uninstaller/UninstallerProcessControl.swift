import AppKit
import Darwin
import Foundation

/// A process of this user that runs from inside an app bundle being removed.
struct UninstallerRunningProcess: Identifiable, Sendable, Hashable {
    var pid: pid_t
    var name: String
    /// The bundle the process runs from.
    var appPath: String
    /// Registered with LaunchServices (an app or helper app), so it can be asked to quit politely.
    var isApplication: Bool

    var id: pid_t { pid }
}

/// Detects and quits apps before they are removed. Only processes owned by this user
/// whose executable is inside the bundle being removed are ever touched, and only after
/// the person asks for it.
enum UninstallerProcessControl {
    /// This user's processes running from inside the given app bundles.
    static func runningProcesses(inside bundlePaths: [String]) -> [UninstallerRunningProcess] {
        guard !bundlePaths.isEmpty else { return [] }
        let bundles = bundlePaths.map { (original: $0, resolved: PathUtilities.resolvedPath($0) ?? $0) }
        let me = getpid()
        var result: [UninstallerRunningProcess] = []
        for process in ProcessInspector.allProcesses() where process.isOwnedByCurrentUser && process.pid != me {
            guard let executable = process.executablePath.map(PathUtilities.firmlinkCanonical),
                  let bundle = bundles.first(where: {
                      PathUtilities.isSameOrDescendant(executable, of: $0.original) || PathUtilities.isSameOrDescendant(executable, of: $0.resolved)
                  }) else { continue }
            let application = NSRunningApplication(processIdentifier: process.pid)
            result.append(UninstallerRunningProcess(
                pid: process.pid,
                name: application?.localizedName ?? process.name,
                appPath: bundle.original,
                isApplication: application != nil
            ))
        }
        return result.sorted { lhs, rhs in
            lhs.isApplication != rhs.isApplication ? lhs.isApplication : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Asks apps to quit like choosing Quit from their menu, and stops their launchd jobs
    /// so background helpers aren't restarted. Helpers without a user interface receive SIGTERM.
    static func requestQuit(_ processes: [UninstallerRunningProcess], jobLabels: [String]) async {
        await bootOut(labels: jobLabels)
        for process in processes where stillRunsFromBundle(process) {
            if let application = NSRunningApplication(processIdentifier: process.pid) {
                application.terminate()
            } else {
                kill(process.pid, SIGTERM)
            }
        }
    }

    /// Forces processes to quit. Unsaved changes in those apps are lost; only call after
    /// the person confirmed.
    static func forceQuit(_ processes: [UninstallerRunningProcess]) {
        for process in processes where stillRunsFromBundle(process) {
            if let application = NSRunningApplication(processIdentifier: process.pid), application.forceTerminate() {
                continue
            }
            kill(process.pid, SIGKILL)
        }
    }

    /// Waits until nothing runs from the bundles any more, or the timeout passes.
    /// Returns what's still running.
    static func waitUntilQuit(bundlePaths: [String], timeout: TimeInterval) async -> [UninstallerRunningProcess] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !Task.isCancelled {
            let remaining = await BackgroundWork.run { runningProcesses(inside: bundlePaths) }
            if remaining.isEmpty { return [] }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return await BackgroundWork.run { runningProcesses(inside: bundlePaths) }
    }

    /// Re-checks right before signalling, so a reused process ID is never affected.
    private static func stillRunsFromBundle(_ process: UninstallerRunningProcess) -> Bool {
        guard let info = ProcessInspector.snapshot(pid: process.pid), info.isOwnedByCurrentUser,
              let executable = ProcessInspector.executablePath(of: process.pid).map(PathUtilities.firmlinkCanonical) else { return false }
        let resolved = PathUtilities.resolvedPath(process.appPath) ?? process.appPath
        return PathUtilities.isSameOrDescendant(executable, of: process.appPath) || PathUtilities.isSameOrDescendant(executable, of: resolved)
    }

    // MARK: launchd and preferences housekeeping

    /// Stops launchd jobs in this user's session (`launchctl bootout gui/<uid>/<label>`).
    /// Jobs that aren't loaded are ignored. Apple's jobs are never touched.
    static func bootOut(labels: [String]) async {
        let uid = getuid()
        for label in Set(labels) where isSafeLabel(label) {
            _ = try? await ProcessRunner.run("/bin/launchctl", arguments: ["bootout", "gui/\(uid)/\(label)"], timeout: 10)
        }
    }

    static func isSafeLabel(_ label: String) -> Bool {
        !label.isEmpty && !label.hasPrefix("-") && !label.contains("/") && !label.contains(where: \.isNewline)
            && !UninstallerIdentifierRules.isAppleIdentifier(label)
    }

    /// macOS caches preferences in memory (`cfprefsd`). After an app's preference file
    /// was moved to the Trash, `defaults delete` drops the cached copy so the app really
    /// starts fresh. Only runs for files that are gone; never for Apple or global domains.
    static func flushPreferenceCaches(removedPaths: [String], homeLibrary: String) async {
        let preferences = PathUtilities.normalize(homeLibrary) + "/Preferences/"
        for path in removedPaths where path.hasPrefix(preferences) && path.hasSuffix(".plist") {
            let fileName = String(path.dropFirst(preferences.count))
            guard !fileName.contains("/") else { continue }
            let domain = String(fileName.dropLast(".plist".count))
            guard isSafeDomain(domain), !FileManager.default.fileExists(atPath: path) else { continue }
            _ = try? await ProcessRunner.run("/usr/bin/defaults", arguments: ["delete", domain], timeout: 10)
        }
    }

    static func isSafeDomain(_ domain: String) -> Bool {
        !domain.isEmpty && !domain.hasPrefix("-") && !domain.hasPrefix(".") && !domain.contains("/")
            && domain != "NSGlobalDomain" && !UninstallerIdentifierRules.isAppleIdentifier(domain)
    }
}

/// Locates an app's leftovers, checks them against the safety policy and measures them.
enum UninstallerLeftoverService {
    static func locateAndMeasure(
        targets: [UninstallerApp],
        otherApps: [UninstallerAppIdentity],
        canReadProtectedAppData: Bool,
        policy: SafetyPolicy,
        scanner: FileSystemScanner,
        locator: UninstallerLeftoverLocator = UninstallerLeftoverLocator(),
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async -> [UninstallerLocateResult] {
        progress?(0.05, "Looking for related files…")
        let identities = targets.map(\.identity)
        var results = await BackgroundWork.run(qos: .userInitiated) {
            locator.locate(for: identities, otherApps: otherApps).map { result in
                var checked = result
                checked.leftovers = []
                for leftover in result.leftovers {
                    if case .denied(let reason) = policy.evaluate(path: leftover.path, purpose: .applicationData) {
                        checked.excluded.append(UninstallerExcludedItem(path: leftover.path, kind: leftover.kind, reason: reason))
                    } else {
                        checked.leftovers.append(leftover)
                    }
                }
                return checked
            }
        }
        if Task.isCancelled { return results }

        let all = results.flatMap(\.leftovers)
        let measurable = all.filter { !$0.isProtectedAppData || canReadProtectedAppData }.map(\.path)
        progress?(0.2, "Measuring \(measurable.count) item\(measurable.count == 1 ? "" : "s")…")
        let usages = await UninstallerOrphanService.measure(measurable, scanner: scanner) { fraction in
            progress?(0.2 + 0.7 * fraction, "Measuring related files…")
        }
        if Task.isCancelled { return results }

        progress?(0.92, "Checking app containers…")
        let documentPaths = await BackgroundWork.run(qos: .userInitiated) {
            Set(all.filter { $0.kind == .containers && usages[$0.path].flatMap(knownUsage) != nil }.map(\.path).filter(containsSavedDocuments))
        }
        for index in results.indices {
            results[index].leftovers = results[index].leftovers.map { leftover in
                var updated = leftover
                updated.usage = usages[leftover.path].flatMap(knownUsage)
                let partlyUnreadable = (updated.usage?.unreadableDirectoryCount ?? 0) > 0
                if leftover.isProtectedAppData {
                    if updated.usage == nil {
                        updated.safety = max(updated.safety, .review)
                        updated.note = "macOS protects other apps' data, so its contents and size couldn't be checked. Grant Full Disk Access for a complete preview."
                    } else if partlyUnreadable {
                        updated.safety = max(updated.safety, .review)
                        updated.note = "Parts of this folder couldn't be read, so its size may be larger than shown."
                    }
                } else if updated.usage == nil, usages[leftover.path] != nil {
                    updated.note = "Mac Cleaner couldn't read this folder, so its size is unknown."
                }
                if documentPaths.contains(leftover.path) {
                    updated.safety = max(updated.safety, .review)
                    updated.note = "Contains documents saved inside the app. Make sure you don't need them."
                }
                return updated
            }
        }
        progress?(1, "Done")
        return results
    }

    /// A folder whose top level couldn't be read has an unknown size, not zero.
    static func knownUsage(_ usage: DiskUsage) -> DiskUsage? {
        usage.fileCount == 0 && usage.unreadableDirectoryCount > 0 ? nil : usage
    }

    /// Sandboxed apps keep documents saved "inside the app" in Data/Documents.
    private static func containsSavedDocuments(_ containerPath: String) -> Bool {
        guard let records = try? FileSystemScanner().children(of: containerPath + "/Data/Documents", includeHidden: false) else { return false }
        return !records.isEmpty
    }
}
