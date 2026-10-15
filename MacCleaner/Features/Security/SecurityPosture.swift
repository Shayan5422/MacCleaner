import Foundation

/// The state of macOS's built-in protections. `nil` means "couldn't be determined".
struct SecurityPosture: Sendable, Hashable, Codable {
    var gatekeeperEnabled: Bool?
    var sipEnabled: Bool?
    /// Extra SIP detail, such as a custom configuration with some protections off.
    var sipDetail: String?
    var fileVaultEnabled: Bool?
    /// "Encrypting (45%)", "Turns on after the next restart"...
    var fileVaultDetail: String?
    var firewallEnabled: Bool?
    var firewallBlocksAllIncoming: Bool?
    var firewallStealthEnabled: Bool?
    var xprotectVersion: String?
    var xprotectUpdated: Date?
    var automaticCheckEnabled: Bool?
    var automaticDownloadEnabled: Bool?
    /// "Install Security Responses and system files" (`CriticalUpdateInstall`).
    var securityResponsesEnabled: Bool?
    /// Background system data files such as XProtect definitions (`ConfigDataInstall`).
    var systemDataFilesEnabled: Bool?
    /// Software Update settings come from a device-management profile.
    var updateSettingsManaged = false
    /// Some Software Update values weren't stored, so macOS's defaults apply.
    var updateSettingsUseDefaults = false
    var checkedAt = Date()

    /// Security responses and system data files both install automatically.
    var automaticSecurityUpdatesEnabled: Bool? {
        switch (securityResponsesEnabled, systemDataFilesEnabled) {
        case (true?, true?): return true
        case (false?, _), (_, false?): return false
        default: return nil
        }
    }

    /// Days since XProtect's definitions were last updated.
    func xprotectAgeDays(now: Date = Date()) -> Int? {
        xprotectUpdated.map { max(0, Int(now.timeIntervalSince($0) / 86_400)) }
    }

    /// The five core protections counted in the score.
    var protections: [SecurityProtectionStatus] {
        [
            SecurityProtectionStatus(kind: .gatekeeper, isOn: gatekeeperEnabled,
                                     statusText: Self.onOff(gatekeeperEnabled), detail: nil),
            SecurityProtectionStatus(kind: .systemIntegrityProtection, isOn: sipEnabled,
                                     statusText: sipDetail != nil && sipEnabled == false ? "Partly off" : Self.onOff(sipEnabled), detail: sipDetail),
            SecurityProtectionStatus(kind: .fileVault, isOn: fileVaultEnabled,
                                     statusText: Self.onOff(fileVaultEnabled), detail: fileVaultDetail),
            SecurityProtectionStatus(kind: .firewall, isOn: firewallEnabled,
                                     statusText: Self.onOff(firewallEnabled), detail: firewallDetail),
            SecurityProtectionStatus(kind: .automaticSecurityUpdates, isOn: automaticSecurityUpdatesEnabled,
                                     statusText: Self.onOff(automaticSecurityUpdatesEnabled), detail: updatesDetail),
        ]
    }

    private var firewallDetail: String? {
        guard firewallEnabled == true else { return nil }
        var parts: [String] = []
        if firewallBlocksAllIncoming == true { parts.append("Blocks all incoming connections") }
        if let stealth = firewallStealthEnabled { parts.append(stealth ? "Stealth mode on" : "Stealth mode off") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var updatesDetail: String? {
        var parts: [String] = []
        if securityResponsesEnabled == false { parts.append("Security Responses and system files are off") }
        if systemDataFilesEnabled == false { parts.append("System data files (XProtect definitions) are off") }
        if automaticCheckEnabled == false { parts.append("Automatic checking is off") }
        if updateSettingsManaged { parts.append("Managed by your organization") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var enabledCount: Int { protections.filter { $0.isOn == true }.count }
    var undeterminedCount: Int { protections.filter { $0.isOn == nil }.count }
    var totalCount: Int { protections.count }

    /// Share of core protections that are on (0...1).
    var score: Double { Double(enabledCount) / Double(max(1, totalCount)) }

    /// "4 of 5 protections on" (+ how many couldn't be checked).
    var summary: String {
        var text = "\(enabledCount) of \(totalCount) protections on"
        if undeterminedCount > 0 { text += " (\(undeterminedCount) couldn't be checked)" }
        return text
    }

    /// `true` when every protection that could be checked is on.
    var allDeterminedProtectionsOn: Bool { protections.allSatisfy { $0.isOn != false } }

    private static func onOff(_ value: Bool?) -> String {
        switch value {
        case true?: return "On"
        case false?: return "Off"
        case nil: return "Couldn't be checked"
        }
    }

    /// Recommendations for protections that are off (and stale XProtect definitions).
    func recommendations(now: Date = Date()) -> [SecurityFinding] {
        var findings: [SecurityFinding] = []
        for protection in protections where protection.isOn == false {
            var finding = SecurityFinding(
                id: "posture|" + protection.kind.rawValue,
                severity: .recommendation,
                category: .protection,
                title: "Turn on \(protection.kind.title)",
                summary: protection.kind.explanation,
                reasons: [protection.detail].compactMap { $0 },
                recommendation: protection.kind.howToTurnOn,
                remediation: protection.kind.settingsPane.map(SecurityRemediation.settings) ?? .none
            )
            if protection.kind == .systemIntegrityProtection, sipDetail != nil {
                finding.title = "System Integrity Protection is partly off"
            }
            findings.append(finding)
        }
        if let age = xprotectAgeDays(now: now), age > 60 {
            findings.append(SecurityFinding(
                id: "posture|xprotect-age",
                severity: .recommendation,
                category: .protection,
                title: "XProtect definitions are \(age) days old",
                summary: "macOS normally updates XProtect's malware definitions every few weeks in the background.",
                reasons: xprotectVersion.map { ["Installed version: \($0)"] } ?? [],
                recommendation: "Make sure \"Install Security Responses and system files\" is on in Software Update's Automatic Updates options, and that this Mac is connected to the internet.",
                remediation: .settings(.softwareUpdate)
            ))
        }
        return findings
    }
}

/// One core protection, for posture cards and the Dashboard.
struct SecurityProtectionStatus: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable, Hashable, CaseIterable {
        case gatekeeper, systemIntegrityProtection, fileVault, firewall, automaticSecurityUpdates

        var title: String {
            switch self {
            case .gatekeeper: return "Gatekeeper"
            case .systemIntegrityProtection: return "System Integrity Protection"
            case .fileVault: return "FileVault"
            case .firewall: return "Firewall"
            case .automaticSecurityUpdates: return "Automatic security updates"
            }
        }

        var shortTitle: String {
            switch self {
            case .systemIntegrityProtection: return "SIP"
            case .automaticSecurityUpdates: return "Security updates"
            default: return title
            }
        }

        var symbolName: String {
            switch self {
            case .gatekeeper: return "checkmark.shield"
            case .systemIntegrityProtection: return "lock.shield"
            case .fileVault: return "lock.doc"
            case .firewall: return "flame"
            case .automaticSecurityUpdates: return "arrow.triangle.2.circlepath.circle"
            }
        }

        var explanation: String {
            switch self {
            case .gatekeeper: return "Checks that apps come from the App Store or identified developers and were notarized by Apple before they open."
            case .systemIntegrityProtection: return "Prevents any software, even with administrator rights, from modifying macOS itself."
            case .fileVault: return "Encrypts your startup disk so your data can't be read without your password if the Mac is lost or stolen."
            case .firewall: return "Blocks unwanted incoming network connections to apps and services on this Mac."
            case .automaticSecurityUpdates: return "Installs security responses and XProtect malware definitions automatically in the background."
            }
        }

        var settingsPane: SystemSettingsPane? {
            switch self {
            case .gatekeeper: return .privacySecurity
            case .systemIntegrityProtection: return nil
            case .fileVault: return .fileVault
            case .firewall: return .firewall
            case .automaticSecurityUpdates: return .softwareUpdate
            }
        }

        var howToTurnOn: String {
            switch self {
            case .gatekeeper:
                return "In System Settings › Privacy & Security, set \"Allow applications from\" to App Store & Known Developers. If that option is missing, Gatekeeper was turned off in Terminal; run `sudo spctl --global-enable` (or `sudo spctl --master-enable` on older macOS) to turn it back on."
            case .systemIntegrityProtection:
                return "SIP can only be turned on from macOS Recovery: shut down, start up in Recovery, open Terminal from the Utilities menu, run `csrutil enable`, then restart."
            case .fileVault:
                return "Open System Settings › Privacy & Security › FileVault and click Turn On. Keep the recovery key somewhere safe."
            case .firewall:
                return "Open System Settings › Network › Firewall and turn it on."
            case .automaticSecurityUpdates:
                return "Open System Settings › General › Software Update, click the info button next to Automatic Updates, and turn on \"Install Security Responses and system files\"."
            }
        }
    }

    var kind: Kind
    var isOn: Bool?
    var statusText: String
    var detail: String?

    var id: Kind { kind }
}

// MARK: - Parsing

/// Parses the output of macOS's command-line security tools. Each parser returns nil
/// (or a nil field) when the output isn't recognized, never a guess.
enum SecurityPostureParser {
    /// `spctl --status`: "assessments enabled" / "assessments disabled".
    static func gatekeeper(_ output: String) -> Bool? {
        let text = output.lowercased()
        if text.contains("assessments enabled") { return true }
        if text.contains("assessments disabled") { return false }
        return nil
    }

    /// `csrutil status`.
    static func systemIntegrityProtection(_ output: String) -> (enabled: Bool?, detail: String?) {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let statusLine = lines.first(where: { $0.lowercased().contains("system integrity protection status:") }) else {
            return (nil, nil)
        }
        let status = statusLine.lowercased()
        // Custom configurations list each protection; report the ones that are off.
        let disabled = lines.compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[1].lowercased() == "disabled" else { return nil }
            return parts[0]
        }.filter { $0.lowercased() != "apple internal" }
        if status.contains("custom configuration") || !disabled.isEmpty {
            if disabled.isEmpty { return (status.contains(": enabled") ? true : nil, "Custom configuration") }
            return (false, "Custom configuration — off: " + disabled.joined(separator: ", "))
        }
        if status.contains(": enabled") { return (true, nil) }
        if status.contains(": disabled") { return (false, nil) }
        return (nil, nil)
    }

    /// `fdesetup status`.
    static func fileVault(_ output: String) -> (enabled: Bool?, detail: String?) {
        let text = output.lowercased()
        if text.contains("encryption in progress") {
            return (true, percent(in: output).map { "Encrypting (\($0)% done)" } ?? "Encryption in progress")
        }
        if text.contains("decryption in progress") {
            return (false, percent(in: output).map { "Decrypting (\($0)% done)" } ?? "Decryption in progress")
        }
        if text.contains("filevault is on") { return (true, nil) }
        if text.contains("filevault is off") {
            if text.contains("will be enabled after the next restart") || text.contains("after the next restart") {
                return (false, "Turns on after the next restart")
            }
            return (false, nil)
        }
        return (nil, nil)
    }

    /// `socketfilterfw --getglobalstate`: "Firewall is enabled. (State = 1)".
    static func firewall(_ output: String) -> (enabled: Bool?, blocksAll: Bool?) {
        if let range = output.range(of: #"State\s*=\s*(\d)"#, options: .regularExpression),
           let digit = output[range].last.flatMap({ Int(String($0)) }) {
            switch digit {
            case 0: return (false, false)
            case 1: return (true, false)
            case 2: return (true, true)
            default: break
            }
        }
        let text = output.lowercased()
        if text.contains("is disabled") || text.contains("firewall is off") { return (false, false) }
        if text.contains("block all") || text.contains("blocking all") { return (true, true) }
        if text.contains("is enabled") || text.contains("firewall is on") { return (true, false) }
        return (nil, nil)
    }

    /// `socketfilterfw --getstealthmode`: "Firewall stealth mode is on" (older: "Stealth mode enabled").
    static func stealthMode(_ output: String) -> Bool? {
        let text = output.lowercased()
        if text.contains("stealth mode is on") || text.contains("stealth mode enabled") { return true }
        if text.contains("stealth mode is off") || text.contains("stealth mode disabled") { return false }
        return nil
    }

    /// `xprotect version` (macOS 15+): "Version: 5367 Installed: 2026-10-14 10:52:34 +0000".
    static func xprotectVersion(_ output: String) -> (version: String?, installed: Date?) {
        var version: String?
        var installed: Date?
        if let range = output.range(of: #"Version:\s*[0-9A-Za-z.\-]+"#, options: .regularExpression) {
            version = output[range].split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
        }
        if let range = output.range(of: #"Installed:\s*\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}"#, options: .regularExpression) {
            let text = output[range].dropFirst("Installed:".count).trimmingCharacters(in: .whitespaces)
            installed = installedDateFormatter.date(from: text)
        }
        return (version, installed)
    }

    private static let installedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter
    }()

    /// Values from `com.apple.SoftwareUpdate` preferences. Missing keys mean macOS's defaults (on).
    struct SoftwareUpdateSettings: Sendable, Hashable {
        var automaticCheck: Bool?
        var automaticDownload: Bool?
        var securityResponses: Bool?
        var systemDataFiles: Bool?
        var isManaged = false
        var usesDefaults = false
    }

    static func softwareUpdate(preferences: [String: Any]?, managed: [String: Any]?) -> SoftwareUpdateSettings {
        guard preferences != nil || managed != nil else { return SoftwareUpdateSettings() }
        var usesDefaults = false
        func value(_ key: String) -> Bool {
            if let raw = managed?[key], let bool = LaunchdPlistValue(propertyListValue: raw).boolValue { return bool }
            if let raw = preferences?[key], let bool = LaunchdPlistValue(propertyListValue: raw).boolValue { return bool }
            usesDefaults = true
            return true
        }
        let automaticCheck = value("AutomaticCheckEnabled")
        let automaticDownload = value("AutomaticDownload")
        let securityResponses = value("CriticalUpdateInstall")
        let systemDataFiles = value("ConfigDataInstall")
        return SoftwareUpdateSettings(
            automaticCheck: automaticCheck,
            automaticDownload: automaticDownload,
            securityResponses: securityResponses,
            systemDataFiles: systemDataFiles,
            isManaged: managed?.isEmpty == false,
            usesDefaults: usesDefaults
        )
    }

    private static func percent(in output: String) -> Int? {
        guard let range = output.range(of: #"=\s*\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        let number = output[range].dropFirst().trimmingCharacters(in: .whitespaces)
        return Double(number).map { Int($0.rounded()) }
    }
}

// MARK: - Checking

/// Reads the state of macOS's protections with read-only system tools. Headless:
/// used by the Security page, the Dashboard and scheduled scans.
enum SecurityPostureChecker {
    static let spctl = "/usr/sbin/spctl"
    static let csrutil = "/usr/bin/csrutil"
    static let fdesetup = "/usr/bin/fdesetup"
    static let socketfilterfw = "/usr/libexec/ApplicationFirewall/socketfilterfw"
    static let xprotect = "/usr/bin/xprotect"
    static let xprotectBundle = "/Library/Apple/System/Library/CoreServices/XProtect.bundle"
    static let softwareUpdatePreferences = "/Library/Preferences/com.apple.SoftwareUpdate.plist"
    static let managedSoftwareUpdatePreferences = "/Library/Managed Preferences/com.apple.SoftwareUpdate.plist"

    static func check() async -> SecurityPosture {
        async let gatekeeperOutput = output(of: spctl, ["--status"])
        async let sipOutput = output(of: csrutil, ["status"])
        async let fileVaultOutput = output(of: fdesetup, ["status"])
        async let firewallOutput = output(of: socketfilterfw, ["--getglobalstate"])
        async let stealthOutput = output(of: socketfilterfw, ["--getstealthmode"])
        async let xprotectOutput = output(of: xprotect, ["version"])
        let files = await BackgroundWork.run(qos: .userInitiated) { readFiles() }

        var posture = SecurityPosture()
        posture.gatekeeperEnabled = await gatekeeperOutput.flatMap(SecurityPostureParser.gatekeeper)
        if let text = await sipOutput {
            let sip = SecurityPostureParser.systemIntegrityProtection(text)
            posture.sipEnabled = sip.enabled
            posture.sipDetail = sip.detail
        }
        if let text = await fileVaultOutput {
            let fileVault = SecurityPostureParser.fileVault(text)
            posture.fileVaultEnabled = fileVault.enabled
            posture.fileVaultDetail = fileVault.detail
        }
        if let text = await firewallOutput {
            let firewall = SecurityPostureParser.firewall(text)
            posture.firewallEnabled = firewall.enabled
            posture.firewallBlocksAllIncoming = firewall.blocksAll
        }
        posture.firewallStealthEnabled = await stealthOutput.flatMap(SecurityPostureParser.stealthMode)

        if let text = await xprotectOutput {
            let parsed = SecurityPostureParser.xprotectVersion(text)
            posture.xprotectVersion = parsed.version
            posture.xprotectUpdated = parsed.installed
        }
        if posture.xprotectVersion == nil { posture.xprotectVersion = files.xprotectVersion }
        if posture.xprotectUpdated == nil { posture.xprotectUpdated = files.xprotectModified }

        let updates = SecurityPostureParser.softwareUpdate(preferences: files.preferences?.dictionary, managed: files.managed?.dictionary)
        posture.automaticCheckEnabled = updates.automaticCheck
        posture.automaticDownloadEnabled = updates.automaticDownload
        posture.securityResponsesEnabled = updates.securityResponses
        posture.systemDataFilesEnabled = updates.systemDataFiles
        posture.updateSettingsManaged = updates.isManaged
        posture.updateSettingsUseDefaults = updates.usesDefaults
        posture.checkedAt = Date()
        return posture
    }

    /// Output of a read-only tool, or nil if it's missing, failed to launch or timed out.
    /// Non-zero exit codes are fine: `spctl --status` exits 1 when assessments are disabled.
    private static func output(of tool: String, _ arguments: [String]) async -> String? {
        guard FileManager.default.isExecutableFile(atPath: tool),
              let result = try? await ProcessRunner.run(tool, arguments: arguments, timeout: 15),
              !result.timedOut else { return nil }
        let text = result.combinedOutput
        return text.isEmpty ? nil : text
    }

    /// A property-list dictionary wrapped for crossing concurrency domains (values are immutable plist types).
    struct PlistBox: @unchecked Sendable {
        let dictionary: [String: Any]
    }

    private struct Files: Sendable {
        var preferences: PlistBox?
        var managed: PlistBox?
        var xprotectVersion: String?
        var xprotectModified: Date?
    }

    private static func readFiles() -> Files {
        func dictionary(_ path: String) -> PlistBox? {
            guard let data = FileManager.default.contents(atPath: path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
            return PlistBox(dictionary: plist)
        }
        var files = Files(preferences: dictionary(softwareUpdatePreferences), managed: dictionary(managedSoftwareUpdatePreferences))
        let info = xprotectBundle + "/Contents/Info.plist"
        let version = xprotectBundle + "/Contents/version.plist"
        files.xprotectVersion = (dictionary(info)?.dictionary["CFBundleShortVersionString"] as? String)
            ?? (dictionary(version)?.dictionary["CFBundleShortVersionString"] as? String)
        files.xprotectModified = (try? FileManager.default.attributesOfItem(atPath: info))?[.modificationDate] as? Date
        return files
    }
}
