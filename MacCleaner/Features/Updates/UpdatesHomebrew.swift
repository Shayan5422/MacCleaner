import Foundation

/// A Homebrew cask that installed an app, with its latest catalog version.
struct UpdatesHomebrewCask: Sendable, Hashable {
    /// Short token ("visual-studio-code").
    var token: String
    /// Tap-qualified token for casks from third-party taps ("user/tap/name").
    var fullToken: String
    var names: [String]
    /// Version in Homebrew's local catalog. "latest" means unversioned.
    var latestVersion: String
    /// Version Homebrew recorded at install time (apps that update themselves move ahead of it).
    var installedVersion: String?
    var autoUpdates: Bool
    /// Absolute paths where the cask installed its apps.
    var appPaths: [String]
    var homepage: URL?
    /// Listed by `brew outdated --cask --greedy`.
    var isOutdated = false

    var isUnversioned: Bool { latestVersion.lowercased() == "latest" }
    var appFileNames: [String] { appPaths.map { ($0 as NSString).lastPathComponent } }

    /// Token passed to `brew upgrade`; tap-qualified when the cask comes from another tap.
    var upgradeToken: String { fullToken.contains("/") ? fullToken : token }
    var upgradeArguments: [String] { ["upgrade", "--cask", upgradeToken] }
    var upgradeCommand: String { "brew upgrade --cask \(upgradeToken)" }

    /// Tokens only contain lowercase letters, digits and a few separators; anything else isn't run.
    var hasSafeToken: Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789@._+-/")
        return !upgradeToken.isEmpty && !upgradeToken.hasPrefix("-") && upgradeToken.allSatisfy { allowed.contains($0) }
    }
}

/// Reads Homebrew's cask information (read-only commands) and maps casks to installed apps.
enum UpdatesHomebrew {
    struct OutdatedEntry: Sendable, Hashable {
        var token: String
        var installedVersions: [String]
        var currentVersion: String
    }

    // MARK: - Parsing

    /// Parses `brew info --cask --installed --json=v2`.
    static func parseInfo(_ data: Data, homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) throws -> [UpdatesHomebrewCask] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdatesCheckError.invalidFeed("Homebrew's cask information isn't in the expected format.")
        }
        let casks = root["casks"] as? [[String: Any]] ?? []
        return casks.compactMap { cask in
            guard let token = cask["token"] as? String, !token.isEmpty else { return nil }
            let version = (cask["version"] as? String) ?? "latest"
            return UpdatesHomebrewCask(
                token: token,
                fullToken: (cask["full_token"] as? String) ?? token,
                names: cask["name"] as? [String] ?? [],
                latestVersion: version,
                installedVersion: cask["installed"] as? String,
                autoUpdates: cask["auto_updates"] as? Bool ?? false,
                appPaths: appPaths(from: cask["artifacts"] as? [Any] ?? [], homeDirectory: homeDirectory),
                homepage: (cask["homepage"] as? String).flatMap(URL.init(string:)),
                isOutdated: cask["outdated"] as? Bool ?? false
            )
        }
    }

    /// Parses `brew outdated --cask --greedy --json=v2`.
    static func parseOutdated(_ data: Data) throws -> [OutdatedEntry] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdatesCheckError.invalidFeed("Homebrew's list of outdated casks isn't in the expected format.")
        }
        let casks = root["casks"] as? [[String: Any]] ?? []
        return casks.compactMap { cask in
            guard let token = cask["name"] as? String ?? cask["token"] as? String,
                  let current = cask["current_version"] as? String else { return nil }
            return OutdatedEntry(token: token, installedVersions: cask["installed_versions"] as? [String] ?? [], currentVersion: current)
        }
    }

    /// Marks casks that `brew outdated` reported, using its current version when it differs.
    static func merge(_ casks: [UpdatesHomebrewCask], outdated: [OutdatedEntry]) -> [UpdatesHomebrewCask] {
        let byToken = Dictionary(outdated.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
        return casks.map { cask in
            var merged = cask
            if let entry = byToken[cask.token] ?? byToken[cask.fullToken] {
                merged.isOutdated = true
                merged.latestVersion = entry.currentVersion
            } else {
                merged.isOutdated = false
            }
            return merged
        }
    }

    /// Where each `app` artifact was installed.
    ///
    /// Recent Homebrew versions add the absolute `target`; older ones only list the
    /// app name and an optional `{"target": ...}` rename, relative to `/Applications`.
    static func appPaths(from artifacts: [Any], homeDirectory: String) -> [String] {
        var paths: [String] = []
        for case let artifact as [String: Any] in artifacts {
            guard let app = artifact["app"] as? [Any], let source = app.first as? String else { continue }
            var path: String
            if let absolute = artifact["target"] as? String, absolute.hasPrefix("/") || absolute.hasPrefix("~") {
                path = absolute
            } else if let rename = app.dropFirst().compactMap({ ($0 as? [String: Any])?["target"] as? String }).first {
                path = rename.hasPrefix("/") || rename.hasPrefix("~") ? rename : "/Applications/" + rename
            } else {
                path = "/Applications/" + (source as NSString).lastPathComponent
            }
            if path.hasPrefix("~") { path = homeDirectory + path.dropFirst() }
            paths.append(PathUtilities.normalize(path))
        }
        return paths
    }

    // MARK: - Matching and evaluation

    /// Maps installed apps (by path) to the cask that installed them.
    static func match(casks: [UpdatesHomebrewCask], appPaths: [String]) -> [String: UpdatesHomebrewCask] {
        var result: [String: UpdatesHomebrewCask] = [:]
        let installed = Set(appPaths.map(PathUtilities.normalize))
        var byFileName: [String: [String]] = [:]
        for path in installed { byFileName[(path as NSString).lastPathComponent.lowercased(), default: []].append(path) }

        for cask in casks {
            for target in cask.appPaths {
                if installed.contains(target) {
                    result[target] = result[target] ?? cask
                } else if !FileManager.default.fileExists(atPath: target),
                          let candidates = byFileName[(target as NSString).lastPathComponent.lowercased()],
                          candidates.count == 1, let only = candidates.first, result[only] == nil {
                    // Installed with a custom --appdir: match by name when it's unambiguous.
                    result[only] = cask
                }
            }
        }
        return result
    }

    /// Casks Homebrew lists as installed whose apps are no longer where Homebrew put them.
    static func casksWithMissingApps(_ casks: [UpdatesHomebrewCask], matched: [String: UpdatesHomebrewCask]) -> [UpdatesHomebrewCask] {
        let matchedTokens = Set(matched.values.map(\.token))
        return casks.filter { !$0.appPaths.isEmpty && !matchedTokens.contains($0.token) && !$0.appPaths.contains { FileManager.default.fileExists(atPath: $0) } }
    }

    /// Decides whether the installed app is behind the cask's latest version.
    static func evaluate(cask: UpdatesHomebrewCask, installedShortVersion: String?, installedBuildVersion: String?) -> (status: UpdatesStatus, latest: String?, detail: String) {
        if cask.isUnversioned {
            return (.unknown, nil, "Homebrew tracks this app as “latest” without version numbers, so it can't tell whether a newer build exists.")
        }
        let latest = UpdatesVersionComparator.homebrewDisplayVersion(cask.latestVersion)
        let comparable = strippingRevision(latest)
        let installedCandidates = [installedShortVersion, installedBuildVersion].compactMap { $0 }.filter { !$0.isEmpty }
        let installedIsCurrent = installedCandidates.contains { !UpdatesVersionComparator.isNewer(comparable, than: $0) }

        if !cask.isOutdated {
            return (.upToDate, latest, "Matches the latest version in Homebrew's local catalog (\(latest)).")
        }
        if installedIsCurrent {
            let note = cask.autoUpdates ? " The app updated itself, so Homebrew's own record is older." : ""
            return (.upToDate, latest, "The installed version already matches Homebrew's catalog (\(latest)).\(note)")
        }
        return (.updateAvailable, latest, "Version \(latest) is available through Homebrew.")
    }

    /// "11.0_1" → "11.0": Homebrew revision suffixes don't change the app itself.
    static func strippingRevision(_ version: String) -> String {
        guard let underscore = version.lastIndex(of: "_"),
              version[version.index(after: underscore)...].allSatisfy(\.isNumber) else { return version }
        return String(version[..<underscore])
    }

    // MARK: - Commands

    /// Environment for Homebrew: no auto-update (no network), no analytics, no hints.
    static func environment() -> [String: String] {
        var environment = ToolLocator.shared.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        return environment
    }

    static func locateBrew() -> String? {
        ToolLocator.shared.locate("brew")
    }

    /// Reads installed casks and the outdated list with read-only commands.
    /// Uses Homebrew's local catalog; it doesn't update the catalog or contact the network.
    static func installedCasks(brew: String) async throws -> [UpdatesHomebrewCask] {
        let environment = environment()
        let info = try await ProcessRunner.run(brew, arguments: ["info", "--cask", "--installed", "--json=v2"], environment: environment, timeout: 120)
        guard info.succeeded else { throw CommandError.failed(command: "brew info --cask --installed", result: info) }
        let casks = try parseInfo(Data(info.standardOutput.utf8))
        guard !casks.isEmpty else { return [] }
        let outdated = try await ProcessRunner.run(brew, arguments: ["outdated", "--cask", "--greedy", "--json=v2"], environment: environment, timeout: 120)
        // `brew outdated` exits with 1 when something is outdated; the JSON is still valid.
        if !outdated.timedOut, let entries = try? parseOutdated(Data(outdated.standardOutput.utf8)) {
            return merge(casks, outdated: entries)
        }
        return markingOutdatedByRecord(casks)
    }

    /// Fallback when `brew outdated` can't be read: a cask whose recorded install
    /// version differs from the catalog version is treated as outdated (what `--greedy` does).
    static func markingOutdatedByRecord(_ casks: [UpdatesHomebrewCask]) -> [UpdatesHomebrewCask] {
        casks.map { cask in
            var marked = cask
            if let installed = cask.installedVersion, !cask.isUnversioned {
                marked.isOutdated = installed != cask.latestVersion
            }
            return marked
        }
    }
}
