import AppKit
import Darwin
import Foundation

/// Which developer tools are installed and where they keep their data.
struct DeveloperEnvironment: Sendable {
    var home: String
    /// `xcode-select -p`, when it points to an existing folder.
    var developerDirectory: String?
    /// The per-user temporary folder (`$TMPDIR`), resolved.
    var temporaryDirectory: String?
    /// Executables found for each tool name ("brew", "npm"...).
    var executables: [String: String]

    /// Full Xcode (not only the Command Line Tools) is selected.
    var hasXcode: Bool {
        developerDirectory?.contains(".app/Contents/Developer") == true
    }

    /// "/Applications/Xcode.app" for the selected Xcode.
    var xcodeApplicationPath: String? {
        guard let developerDirectory, let range = developerDirectory.range(of: ".app/Contents/Developer") else { return nil }
        return String(developerDirectory[..<range.lowerBound]) + ".app"
    }

    func executable(_ name: String) -> String? { executables[name] }

    static let toolNames = ["brew", "npm", "pnpm", "yarn", "bun", "pip3", "pip", "uv", "go", "cargo", "docker", "gradle", "mvn", "pod", "carthage"]

    /// Finds installed tools without starting any of them (only `xcode-select -p` runs).
    static func detect(home: String) async -> DeveloperEnvironment {
        var developerDirectory: String?
        if let result = try? await ProcessRunner.run("/usr/bin/xcode-select", arguments: ["-p"], timeout: 10), result.succeeded {
            let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.fileExists(atPath: path) { developerDirectory = path }
        }
        var executables: [String: String] = [:]
        for name in toolNames {
            guard let path = ToolLocator.shared.locate(name) else { continue }
            // Without developer tools, the stubs in /usr/bin open the "install
            // command line developer tools" dialog instead of running.
            if path.hasPrefix("/usr/bin/"), developerDirectory == nil { continue }
            executables[name] = path
        }
        if developerDirectory != nil, FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") {
            executables["xcrun"] = "/usr/bin/xcrun"
        }
        return DeveloperEnvironment(
            home: home,
            developerDirectory: developerDirectory,
            temporaryDirectory: userTemporaryDirectory(),
            executables: executables
        )
    }

    /// `$TMPDIR` as reported by the system, with symbolic links resolved (matches `SafetyPolicy`).
    static func userTemporaryDirectory() -> String? {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 0 else { return nil }
        let path = String(nulTerminated: buffer)
        return PathUtilities.resolvedPath(path).map(PathUtilities.normalize) ?? PathUtilities.normalize(path)
    }

    static func isXcodeRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").filter { !$0.isTerminated }.isEmpty
    }
}

/// Runs read-only queries such as `npm config get cache`.
enum DeveloperCLI {
    /// Environment for every developer command: the standard tool environment
    /// plus settings that keep tools from updating or downloading on their own.
    static func environment(adding extra: [String: String] = [:]) -> [String: String] {
        var environment = ToolLocator.shared.environment
        environment["HOMEBREW_NO_AUTOREMOVE"] = "1"
        environment["COREPACK_ENABLE_NETWORK"] = "0"
        environment["COREPACK_ENABLE_DOWNLOAD_PROMPT"] = "0"
        environment["NPM_CONFIG_UPDATE_NOTIFIER"] = "false"
        environment["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
        environment["DOCKER_CLI_HINTS"] = "false"
        for (key, value) in extra { environment[key] = value }
        return environment
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30, home: String) async -> CommandResult? {
        try? await ProcessRunner.run(executable, arguments: arguments, environment: environment(), currentDirectory: home, timeout: timeout)
    }

    /// First non-empty line of a successful command's output.
    static func firstLine(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30, home: String) async -> String? {
        guard let result = await run(executable, arguments, timeout: timeout, home: home), result.succeeded else { return nil }
        return result.standardOutput.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// An absolute path printed by a tool, if it exists.
    static func existingPath(_ executable: String, _ arguments: [String], home: String) async -> String? {
        guard let line = await firstLine(executable, arguments, home: home), line.hasPrefix("/") else { return nil }
        let path = PathUtilities.resolvedPath(line) ?? line
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}

/// Measures every direct child of a folder in one walk, so folders with
/// thousands of entries (package caches) are measured quickly.
enum DeveloperFolderMeasurer {
    private final class Accumulators: @unchecked Sendable {
        private let lock = NSLock()
        private var byPath: [String: UsageAccumulator] = [:]

        func accumulator(for path: String) -> UsageAccumulator {
            lock.withLock {
                if let existing = byPath[path] { return existing }
                let created = UsageAccumulator()
                byPath[path] = created
                return created
            }
        }

        var results: [String: DiskUsage] {
            lock.withLock { byPath.mapValues(\.current) }
        }
    }

    static func measureChildren(of folder: String, options: WalkOptions = WalkOptions()) async throws -> [String: DiskUsage] {
        let accumulators = Accumulators()
        let walker = ParallelDirectoryWalker<String?>(options: options, progress: WalkProgress(), handlers: WalkHandlers(
            didRead: { job, entries in
                if let owner = job.context {
                    accumulators.accumulator(for: owner).add(entries.filter { $0.type != .directory })
                } else {
                    for entry in entries where entry.type != .directory {
                        accumulators.accumulator(for: PathUtilities.join(job.path, entry.name)).add(entry)
                    }
                }
            },
            descend: { entry, parent in
                let owner = parent.context ?? PathUtilities.join(parent.path, entry.name)
                accumulators.accumulator(for: owner).addDirectory()
                return .some(owner)
            },
            didFail: { job, _ in
                if let owner = job.context { accumulators.accumulator(for: owner).addUnreadableDirectory() }
            }
        ))
        _ = try await walker.walk(rootPath: folder, rootContext: nil)
        return accumulators.results
    }
}
