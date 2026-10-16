import Foundation
import Testing
@testable import MacCleaner

/// End-to-end tests drive real features against real macOS services with throwaway fixtures:
/// a test app in `~/Applications` with leftovers in `~/Library`, launch agents loaded with
/// `launchctl`, and items moved to the real Trash and back.
///
/// They change real (but test-only) state in the signed-in account, so they only run when asked:
///
///     TEST_RUNNER_MACCLEANER_E2E=1 xcodebuild -project MacCleaner.xcodeproj -scheme MacCleaner test
///
/// (xcodebuild passes `TEST_RUNNER_`-prefixed variables to the tests without the prefix.) CI sets it,
/// because its machines are discarded after every run. Every fixture is named
/// `com.maccleaner.e2e.<random>` and removed afterwards, also when a test fails.
enum EndToEnd {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["MACCLEANER_E2E"] == "1" }

    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// A unique, lower-case identifier for one test's fixtures.
    static func makeIdentifier() -> String {
        "com.maccleaner.e2e." + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(10)
    }

    /// App services whose history, log and settings live in a temporary folder.
    @MainActor
    static func makeServices(confirmBeforeCleaning: Bool = true) throws -> (services: AppServices, support: URL) {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("MacCleanerE2E-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: "MacCleanerE2E-\(UUID().uuidString)"))
        let settings = SettingsManager(defaults: defaults)
        settings.confirmBeforeCleaning = confirmBeforeCleaning
        let services = AppServices(
            settings: settings,
            permissions: PermissionManager(),
            history: HistoryStore(directory: support),
            logger: ActivityLogger(directory: support)
        )
        return (services, support)
    }

    /// Polls `condition` on the main actor until it holds or `seconds` pass.
    @MainActor
    static func waitUntil(_ description: String, seconds: Double = 60, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline {
                Issue.record("Timed out after \(Int(seconds)) s waiting until \(description)")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Files

    static func writeFile(_ path: String, _ contents: String = "Mac Cleaner end-to-end test fixture\n") throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
    }

    static func writePlist(_ path: String, _ dictionary: [String: Any]) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path))
    }

    static func exists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    }

    /// Removes fixtures (test files this suite created), wherever they ended up.
    static func removeFixtures(_ paths: [String]) {
        for path in paths where exists(path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Paths the cleanups recorded in `history` moved to the Trash (to clean up after a failed test).
    static func trashedPaths(in history: HistoryStore) async -> [String] {
        await history.allEntries().flatMap { entry in entry.items.compactMap(\.trashedPath) }
    }
}

/// Reads launchd's state for the current user's GUI domain.
enum LaunchAgentProbe {
    static var domain: String { "gui/\(getuid())" }

    @discardableResult
    static func run(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// The job is loaded in the user's GUI domain.
    static func isLoaded(_ label: String) -> Bool {
        run(["print", "\(domain)/\(label)"]).status == 0
    }

    /// launchd has a "disabled" override for the job.
    static func isDisabled(_ label: String) -> Bool {
        let output = run(["print-disabled", domain]).output
        return output.split(separator: "\n").contains { line in
            line.contains("\"\(label)\"") && (line.contains("=> disabled") || line.contains("=> true"))
        }
    }

    static func bootstrap(plist: String) -> Bool {
        run(["bootstrap", domain, plist]).status == 0
    }

    static func bootout(_ label: String) {
        run(["bootout", "\(domain)/\(label)"])
    }

    /// A user launch agent that runs `/bin/sleep`, so loading it starts a real, harmless process.
    static func makeAgent(label: String, plist: String) throws {
        try EndToEnd.writePlist(plist, [
            "Label": label,
            "ProgramArguments": ["/bin/sleep", "3600"],
            "RunAtLoad": true,
            "ProcessType": "Background",
        ])
    }
}
