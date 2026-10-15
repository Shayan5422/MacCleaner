import Darwin
import Foundation

/// A launchd domain: the current user's GUI session or the system.
enum LaunchdDomain: Sendable, Hashable {
    case gui(uid_t)
    case system

    static var currentUser: LaunchdDomain { .gui(getuid()) }

    var target: String {
        switch self {
        case .gui(let uid): return "gui/\(uid)"
        case .system: return "system"
        }
    }

    func serviceTarget(_ label: String) -> String { target + "/" + label }
}

enum LaunchctlError: LocalizedError, Sendable {
    case protectedLabel(String)
    case invalidLabel
    case notAUserAgent
    case failed(operation: String, detail: String)
    case partiallyApplied(String)

    var errorDescription: String? {
        switch self {
        case .protectedLabel(let label):
            return "“\(label)” belongs to macOS. Mac Cleaner never changes system services."
        case .invalidLabel:
            return "This item has no valid launchd label, so it can't be changed with launchctl."
        case .notAUserAgent:
            return "Only launch agents in your own Library folder can be changed. System-wide items need an administrator."
        case .failed(let operation, let detail):
            return detail.isEmpty ? "\(operation) failed." : "\(operation) failed: \(detail)"
        case .partiallyApplied(let message):
            return message
        }
    }
}

/// Runs `/bin/launchctl` with argument arrays. Read-only queries work for any
/// domain; state changes are limited to the current user's own launch agents and
/// always refuse Apple's labels.
struct LaunchctlClient: Sendable {
    static let executable = "/bin/launchctl"
    /// `launchctl print` exit status when a service isn't loaded in the domain.
    static let serviceNotFoundStatus: Int32 = 113

    init() {}

    // MARK: - Queries

    /// Details of a loaded service, or nil when it isn't loaded in `domain`.
    func serviceInfo(label: String, domain: LaunchdDomain) async -> LaunchctlServiceInfo? {
        guard Self.isValidLabel(label),
              let result = try? await ProcessRunner.run(Self.executable, arguments: ["print", domain.serviceTarget(label)], timeout: 10),
              result.succeeded else { return nil }
        return LaunchctlParser.parseService(result.standardOutput, label: label)
    }

    /// Labels that were turned on or off with `launchctl enable/disable` (label → disabled).
    func disabledOverrides(domain: LaunchdDomain) async -> [String: Bool] {
        guard let result = try? await ProcessRunner.run(Self.executable, arguments: ["print-disabled", domain.target], timeout: 15),
              result.succeeded else { return [:] }
        return LaunchctlParser.parseDisabled(result.standardOutput)
    }

    /// Every service currently loaded in `domain`, with its PID and last exit status.
    func loadedServices(domain: LaunchdDomain) async -> [String: LaunchctlListedService]? {
        guard let result = try? await ProcessRunner.run(Self.executable, arguments: ["print", domain.target], timeout: 20),
              result.succeeded else { return nil }
        return LaunchctlParser.parseServiceList(result.standardOutput)
    }

    // MARK: - Changes (current user's agents only)

    /// Turns an agent off for future logins (`launchctl disable`) and stops it now (`launchctl bootout`).
    func disableUserAgent(label: String) async throws {
        try Self.validateUserAgentLabel(label)
        let domain = LaunchdDomain.currentUser
        let disable = try await ProcessRunner.run(Self.executable, arguments: ["disable", domain.serviceTarget(label)], timeout: 15)
        guard disable.succeeded else {
            throw LaunchctlError.failed(operation: "Turning off “\(label)”", detail: Self.detail(disable))
        }
        try await bootout(label: label, alreadyDisabled: true)
    }

    /// Stops an agent now without changing whether it starts at the next login.
    func bootoutUserAgent(label: String) async throws {
        try Self.validateUserAgentLabel(label)
        try await bootout(label: label, alreadyDisabled: false)
    }

    /// Turns an agent back on (`launchctl enable`) and loads it now (`launchctl bootstrap`).
    func enableUserAgent(label: String, plistPath: String) async throws {
        try Self.validateUserAgentLabel(label)
        try Self.validateUserAgentPlist(plistPath)
        let domain = LaunchdDomain.currentUser
        let enable = try await ProcessRunner.run(Self.executable, arguments: ["enable", domain.serviceTarget(label)], timeout: 15)
        guard enable.succeeded else {
            throw LaunchctlError.failed(operation: "Turning on “\(label)”", detail: Self.detail(enable))
        }
        if await serviceInfo(label: label, domain: domain) != nil { return } // already loaded
        let bootstrap = try await ProcessRunner.run(Self.executable, arguments: ["bootstrap", domain.target, plistPath], timeout: 20)
        if bootstrap.succeeded { return }
        // "Operation already in progress" or a load that raced with launchd: check what actually happened.
        if await serviceInfo(label: label, domain: domain) != nil { return }
        throw LaunchctlError.partiallyApplied(
            "“\(label)” is turned on and will start at your next login, but it couldn't be started now: \(Self.detail(bootstrap)). "
                + "If it's switched off under Allow in the Background in System Settings › General › Login Items & Extensions, turn it on there."
        )
    }

    private func bootout(label: String, alreadyDisabled: Bool) async throws {
        let domain = LaunchdDomain.currentUser
        guard await serviceInfo(label: label, domain: domain) != nil else { return } // not loaded: nothing to stop
        let bootout = try await ProcessRunner.run(Self.executable, arguments: ["bootout", domain.serviceTarget(label)], timeout: 30)
        if bootout.succeeded { return }
        // launchd may already have unloaded it while we asked.
        if await serviceInfo(label: label, domain: domain) == nil { return }
        let prefix = alreadyDisabled ? "“\(label)” won't start at your next login, but it couldn't be stopped now" : "“\(label)” couldn't be stopped"
        throw LaunchctlError.partiallyApplied("\(prefix): \(Self.detail(bootout)).")
    }

    // MARK: - Validation

    static func isValidLabel(_ label: String) -> Bool {
        !label.isEmpty && label.count <= 512 && !label.contains("/")
            && !label.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }
    }

    static func isProtectedLabel(_ label: String) -> Bool {
        label.lowercased().hasPrefix("com.apple.")
    }

    static func validateUserAgentLabel(_ label: String) throws {
        guard isValidLabel(label) else { throw LaunchctlError.invalidLabel }
        guard !isProtectedLabel(label) else { throw LaunchctlError.protectedLabel(label) }
    }

    /// The plist must be a direct child of `~/Library/LaunchAgents`.
    static func validateUserAgentPlist(_ path: String) throws {
        let folder = LaunchdLocations.userAgentsFolder
        let normalized = PathUtilities.normalize(path)
        guard (normalized as NSString).deletingLastPathComponent == folder, normalized.hasSuffix(".plist") else {
            throw LaunchctlError.notAUserAgent
        }
    }

    private static func detail(_ result: CommandResult) -> String {
        if result.timedOut { return "launchctl didn't respond in time" }
        let text = result.combinedOutput.split(separator: "\n").suffix(2).joined(separator: " ")
        return text.isEmpty ? "exit code \(result.exitCode)" : text
    }
}
