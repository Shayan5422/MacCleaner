import Foundation

/// Where the Guardian features keep their state on this Mac. Nothing here ever leaves the Mac.
///
/// `~/Library/Application Support/Mac Cleaner/Guardian/`:
/// - `StartupSnapshot.json`: the last startup-item inventory, with first-seen and last-changed dates
/// - `StartupChanges.json`: the change timeline
/// - `BackgroundItems.json`: the last list of every background item (when the person asked for it)
/// - `LoginAnalysis.json`: what opened automatically at the last login
/// - `WebShield.json`: per-browser read positions (visit numbers, never addresses) and warnings (matches only)
///
/// Tests pass a temporary directory instead.
enum GuardianStorage {
    static var defaultDirectory: URL {
        ProtectionEventLog.defaultDirectory.appendingPathComponent("Guardian", isDirectory: true)
    }

    /// Short-lived working copies (history snapshots). Emptied at launch and after every read.
    static var defaultScratchDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Mac Cleaner/Guardian", isDirectory: true)
    }

    static func load<Value: Decodable>(_ type: Value.Type, from url: URL?) -> Value? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// One queue for every write, so saves land in the order they were made.
    private static let writeQueue = DispatchQueue(label: "MacCleaner.Guardian.Storage", qos: .utility)

    /// Writes atomically off the main thread, readable by this user only.
    static func save<Value: Encodable & Sendable>(_ value: Value, to url: URL?) async {
        guard let url else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writeQueue.async {
                writeNow(value, to: url)
                continuation.resume()
            }
        }
    }

    /// Blocking variant for background jobs.
    static func writeNow<Value: Encodable>(_ value: Value, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Removes leftovers of an interrupted read (a crash while a history snapshot existed).
    /// Never follows a symbolic link: a scratch folder replaced by a link is left alone.
    static func clearScratch(_ directory: URL) {
        SecureDirectory.removeContents(of: directory)
    }
}

/// `true` while running inside the unit-test host, where background loops, file watching and
/// notifications must stay off.
enum GuardianRuntime {
    static var isTestHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil {
            return true
        }
        let process = ProcessInfo.processInfo.processName.lowercased()
        if process.contains("xctest") || process.contains("swiftpm-testing-helper") || process.hasSuffix("packagetests") { return true }
        return NSClassFromString("XCTestCase") != nil
    }
}
