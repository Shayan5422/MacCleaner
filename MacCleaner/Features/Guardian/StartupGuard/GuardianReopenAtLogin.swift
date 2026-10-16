import Foundation
import IOKit

/// An app macOS reopened at login because it was open when the person logged out
/// ("Reopen windows when logging back in").
struct GuardianReopenApp: Codable, Sendable, Hashable, Identifiable {
    var bundleIdentifier: String?
    var path: String?
    /// Reopened hidden.
    var isHidden: Bool
    var backgroundState: Int?

    var id: String { bundleIdentifier ?? path ?? "?" }

    var name: String {
        guard let path else { return bundleIdentifier ?? "Unknown app" }
        return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    var isAppleApp: Bool {
        bundleIdentifier?.lowercased().hasPrefix("com.apple.") == true || path?.hasPrefix("/System/") == true
    }
}

/// The "Reopen windows when logging back in" setting and the apps macOS reopened at the last login.
///
/// macOS (loginwindow) writes the list of open apps at logout into
/// `~/Library/Preferences/ByHost/com.apple.loginwindow.<HardwareUUID>.plist` (`TALAppsToRelaunchAtLogin`)
/// and reopens them at the next login. The checkbox in the logout dialog is stored as
/// `TALLogoutSavesState`; on current macOS versions loginwindow keeps it in the user's
/// `com.apple.loginwindow` domain, older versions in the per-host domain.
struct GuardianReopenState: Codable, Sendable, Hashable {
    enum SettingSource: String, Codable, Sendable {
        case currentHost, user, macOSDefault
    }

    /// Effective value: macOS saves open apps at logout and reopens them (its default when nothing is set).
    var savesState: Bool
    var settingSource: SettingSource
    var currentHostValue: Bool?
    var userValue: Bool?
    /// Apps saved at the last logout, for this Mac. Apps reopened at the last login.
    var apps: [GuardianReopenApp]
    /// The per-host file the list was read from.
    var listPath: String?
    /// Modification date of that file (about when the person last logged out).
    var listDate: Date?
    /// Per-host files of other Macs (migrated from an older Mac). They're never used, so they're ignored.
    var ignoredOtherHostFiles: Int
    /// The hardware UUID couldn't be read, so the newest per-host file was used.
    var isHostUncertain: Bool
    /// "Shut Down", "Restart" or "Log Out", when macOS recorded it.
    var lastLogoutReason: String?

    /// Third-party apps only (Finder and System Settings reopen too, but they're part of macOS).
    var thirdPartyApps: [GuardianReopenApp] { apps.filter { !$0.isAppleApp } }
}

/// Reads the reopen-at-login state from the preference files, read-only.
enum GuardianReopenReader {
    static let domain = "com.apple.loginwindow"
    static let appsKey = "TALAppsToRelaunchAtLogin"
    static let savesStateKey = "TALLogoutSavesState"
    static let logoutReasonKey = "TALLogoutReason"

    static var liveByHostFolder: String { LaunchdLocations.home + "/Library/Preferences/ByHost" }
    static var liveUserPreferencesFile: String { LaunchdLocations.home + "/Library/Preferences/com.apple.loginwindow.plist" }

    /// - Returns: nil when the ByHost folder can't be read at all.
    static func read(byHostFolder: String, userPreferencesFile: String, hardwareUUID: String?) -> GuardianReopenState? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: byHostFolder) else { return nil }
        let candidates = names.filter { $0.hasPrefix(domain + ".") && $0.hasSuffix(".plist") }.sorted()

        var chosen: String?
        var uncertain = false
        if let uuid = hardwareUUID?.uppercased() {
            chosen = candidates.first { $0.uppercased() == (domain + "." + uuid + ".plist").uppercased() }
        } else {
            // Without the hardware UUID, the most recently written file is the best guess.
            uncertain = !candidates.isEmpty
            chosen = candidates.max { lhs, rhs in
                modificationDate(byHostFolder + "/" + lhs) ?? .distantPast < modificationDate(byHostFolder + "/" + rhs) ?? .distantPast
            }
        }

        var apps: [GuardianReopenApp] = []
        var currentHostValue: Bool?
        var listPath: String?
        var listDate: Date?
        if let chosen {
            let path = byHostFolder + "/" + chosen
            let plist = readPlist(path)
            apps = parseApps(plist?[appsKey])
            currentHostValue = boolValue(plist?[savesStateKey])
            listPath = path
            listDate = modificationDate(path)
        }

        let userPlist = readPlist(userPreferencesFile)
        let userValue = boolValue(userPlist?[savesStateKey])
        let source: GuardianReopenState.SettingSource = currentHostValue != nil ? .currentHost : userValue != nil ? .user : .macOSDefault
        return GuardianReopenState(
            savesState: currentHostValue ?? userValue ?? true,
            settingSource: source,
            currentHostValue: currentHostValue,
            userValue: userValue,
            apps: apps,
            listPath: listPath,
            listDate: listDate,
            ignoredOtherHostFiles: candidates.count - (chosen == nil ? 0 : 1),
            isHostUncertain: uncertain,
            lastLogoutReason: userPlist?[logoutReasonKey] as? String
        )
    }

    /// Parses the `TALAppsToRelaunchAtLogin` array.
    static func parseApps(_ value: Any?) -> [GuardianReopenApp] {
        guard let entries = value as? [Any] else { return [] }
        return entries.compactMap { entry in
            guard let dictionary = entry as? [String: Any] else { return nil }
            let bundleID = (dictionary["BundleID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let path = (dictionary["Path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard bundleID != nil || path != nil else { return nil }
            return GuardianReopenApp(
                bundleIdentifier: bundleID,
                path: path,
                isHidden: boolValue(dictionary["Hide"]) ?? false,
                backgroundState: (dictionary["BackgroundState"] as? NSNumber)?.intValue
            )
        }
    }

    static func boolValue(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: return nil
            }
        }
        return nil
    }

    static func readPlist(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        return object as? [String: Any]
    }

    private static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// This Mac's hardware UUID (the per-host preference files are named after it).
    static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? String
    }

    static func readLive() -> GuardianReopenState? {
        read(byHostFolder: liveByHostFolder, userPreferencesFile: liveUserPreferencesFile, hardwareUUID: hardwareUUID())
    }
}

/// Runs a command-line tool; injectable so tests verify commands without changing this Mac.
typealias GuardianCommandRunner = @Sendable (_ executable: String, _ arguments: [String]) async throws -> CommandResult

enum GuardianCommands {
    static let live: GuardianCommandRunner = { executable, arguments in
        try await ProcessRunner.run(executable, arguments: arguments, timeout: 20)
    }
}

/// Builds and applies the `defaults` commands behind "Don't Reopen Apps at Login".
///
/// The value is written where macOS keeps it: the user's `com.apple.loginwindow` domain (where the
/// logout dialog stores its checkbox on current macOS). A per-host value (`-currentHost`) is updated
/// too when one exists, because it takes precedence; none is created otherwise, so the logout
/// dialog keeps working as usual.
enum GuardianReopenCommands {
    static let defaultsTool = "/usr/bin/defaults"

    static func turnOff(_ state: GuardianReopenState) -> [[String]] {
        commands(savesState: false, state: state)
    }

    static func turnOn(_ state: GuardianReopenState) -> [[String]] {
        commands(savesState: true, state: state)
    }

    private static func commands(savesState: Bool, state: GuardianReopenState) -> [[String]] {
        let value = savesState ? "true" : "false"
        var result: [[String]] = [[defaultsTool, "write", GuardianReopenReader.domain, GuardianReopenReader.savesStateKey, "-bool", value]]
        if state.currentHostValue != nil {
            result.append([defaultsTool, "-currentHost", "write", GuardianReopenReader.domain, GuardianReopenReader.savesStateKey, "-bool", value])
        }
        return result
    }

    /// Runs the commands in order; stops at the first failure.
    static func apply(_ commands: [[String]], runner: GuardianCommandRunner) async throws {
        for command in commands {
            guard let executable = command.first else { continue }
            let result = try await runner(executable, Array(command.dropFirst()))
            guard result.succeeded else {
                throw CommandError.failed(command: command.joined(separator: " "), result: result)
            }
        }
    }
}
