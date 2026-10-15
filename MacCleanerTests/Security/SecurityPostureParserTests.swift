import Foundation
import Testing
@testable import MacCleaner

struct SecurityPostureParserTests {
    @Test func gatekeeperStatus() {
        #expect(SecurityPostureParser.gatekeeper("assessments enabled\n") == true)
        #expect(SecurityPostureParser.gatekeeper("assessments disabled") == false)
        #expect(SecurityPostureParser.gatekeeper("spctl: unrecognized option") == nil)
    }

    @Test func systemIntegrityProtectionStatus() {
        let enabled = SecurityPostureParser.systemIntegrityProtection("System Integrity Protection status: enabled.")
        #expect(enabled.enabled == true)
        #expect(enabled.detail == nil)

        let disabled = SecurityPostureParser.systemIntegrityProtection("System Integrity Protection status: disabled.")
        #expect(disabled.enabled == false)

        let custom = SecurityPostureParser.systemIntegrityProtection("""
        System Integrity Protection status: unknown (Custom Configuration).

        Configuration:
        \tApple Internal: disabled
        \tKext Signing: enabled
        \tFilesystem Protections: disabled
        \tDebugging Restrictions: enabled
        \tDTrace Restrictions: enabled
        \tNVRAM Protections: enabled
        \tBaseSystem Verification: enabled

        This is an unsupported configuration, likely to break in the future and leave your machine in an unknown state.
        """)
        #expect(custom.enabled == false)
        #expect(custom.detail == "Custom configuration — off: Filesystem Protections")

        #expect(SecurityPostureParser.systemIntegrityProtection("csrutil: command not found").enabled == nil)
    }

    @Test func fileVaultStatus() {
        #expect(SecurityPostureParser.fileVault("FileVault is On.").enabled == true)
        #expect(SecurityPostureParser.fileVault("FileVault is Off.").enabled == false)

        let pending = SecurityPostureParser.fileVault("FileVault is Off, but will be enabled after the next restart.")
        #expect(pending.enabled == false)
        #expect(pending.detail == "Turns on after the next restart")

        let encrypting = SecurityPostureParser.fileVault("Encryption in progress: Percent completed = 45.6")
        #expect(encrypting.enabled == true)
        #expect(encrypting.detail == "Encrypting (46% done)")

        let decrypting = SecurityPostureParser.fileVault("Decryption in progress: Percent completed = 10")
        #expect(decrypting.enabled == false)
        #expect(decrypting.detail == "Decrypting (10% done)")

        #expect(SecurityPostureParser.fileVault("").enabled == nil)
    }

    @Test func firewallStates() {
        let off = SecurityPostureParser.firewall("Firewall is disabled. (State = 0)")
        #expect(off.enabled == false && off.blocksAll == false)
        let on = SecurityPostureParser.firewall("Firewall is enabled. (State = 1)")
        #expect(on.enabled == true && on.blocksAll == false)
        let blockAll = SecurityPostureParser.firewall("Firewall is blocking all non-essential incoming connections. (State = 2)")
        #expect(blockAll.enabled == true && blockAll.blocksAll == true)
        let legacy = SecurityPostureParser.firewall("Firewall is enabled.")
        #expect(legacy.enabled == true)
        #expect(SecurityPostureParser.firewall("socketfilterfw: error").enabled == nil)
    }

    @Test func stealthMode() {
        #expect(SecurityPostureParser.stealthMode("Firewall stealth mode is on") == true)
        #expect(SecurityPostureParser.stealthMode("Firewall stealth mode is off") == false)
        #expect(SecurityPostureParser.stealthMode("Stealth mode enabled") == true)
        #expect(SecurityPostureParser.stealthMode("Stealth mode disabled") == false)
        #expect(SecurityPostureParser.stealthMode("") == nil)
    }

    @Test func xprotectVersionLine() throws {
        let parsed = SecurityPostureParser.xprotectVersion("Version: 5367 Installed: 2026-10-14 10:52:34 +0000\n")
        #expect(parsed.version == "5367")
        let installed = try #require(parsed.installed)
        #expect(installed == Date(timeIntervalSince1970: 1_791_975_154))
        let none = SecurityPostureParser.xprotectVersion("xprotect: unknown command")
        #expect(none.version == nil && none.installed == nil)
    }

    @Test func softwareUpdateSettings() {
        let explicit = SecurityPostureParser.softwareUpdate(
            preferences: ["AutomaticCheckEnabled": true, "AutomaticDownload": false, "CriticalUpdateInstall": false, "ConfigDataInstall": true],
            managed: nil
        )
        #expect(explicit.automaticCheck == true)
        #expect(explicit.automaticDownload == false)
        #expect(explicit.securityResponses == false)
        #expect(explicit.systemDataFiles == true)
        #expect(!explicit.usesDefaults && !explicit.isManaged)

        // Missing keys mean macOS's defaults (on).
        let defaults = SecurityPostureParser.softwareUpdate(preferences: ["LastSuccessfulDate": Date()], managed: nil)
        #expect(defaults.securityResponses == true && defaults.systemDataFiles == true)
        #expect(defaults.usesDefaults)

        // Managed (MDM) values win over local ones.
        let managed = SecurityPostureParser.softwareUpdate(preferences: ["CriticalUpdateInstall": true], managed: ["CriticalUpdateInstall": false])
        #expect(managed.securityResponses == false)
        #expect(managed.isManaged)

        // Unreadable: unknown, never guessed.
        let unknown = SecurityPostureParser.softwareUpdate(preferences: nil, managed: nil)
        #expect(unknown.securityResponses == nil && unknown.automaticCheck == nil)
    }

    @Test func postureScoreAndSummary() {
        var posture = SecurityPosture()
        posture.gatekeeperEnabled = true
        posture.sipEnabled = true
        posture.fileVaultEnabled = true
        posture.firewallEnabled = false
        posture.securityResponsesEnabled = true
        posture.systemDataFilesEnabled = true
        #expect(posture.enabledCount == 4)
        #expect(posture.totalCount == 5)
        #expect(posture.summary == "4 of 5 protections on")
        #expect(abs(posture.score - 0.8) < 0.0001)
        #expect(!posture.allDeterminedProtectionsOn)

        let recommendations = posture.recommendations(now: Date())
        #expect(recommendations.map(\.id) == ["posture|firewall"])
        #expect(recommendations.first?.severity == .recommendation)
        #expect(recommendations.first?.remediation == .settings(.firewall))

        posture.fileVaultEnabled = nil
        #expect(posture.summary == "3 of 5 protections on (1 couldn't be checked)")
    }

    @Test func automaticSecurityUpdatesNeedBothSettings() {
        var posture = SecurityPosture()
        posture.securityResponsesEnabled = true
        posture.systemDataFilesEnabled = false
        #expect(posture.automaticSecurityUpdatesEnabled == false)
        posture.systemDataFilesEnabled = nil
        #expect(posture.automaticSecurityUpdatesEnabled == nil)
        posture.systemDataFilesEnabled = true
        #expect(posture.automaticSecurityUpdatesEnabled == true)
    }

    @Test func staleXProtectIsRecommended() {
        var posture = SecurityPosture()
        posture.gatekeeperEnabled = true
        posture.xprotectVersion = "5000"
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        posture.xprotectUpdated = now.addingTimeInterval(-90 * 86_400)
        #expect(posture.xprotectAgeDays(now: now) == 90)
        #expect(posture.recommendations(now: now).contains { $0.id == "posture|xprotect-age" })
        posture.xprotectUpdated = now.addingTimeInterval(-5 * 86_400)
        #expect(!posture.recommendations(now: now).contains { $0.id == "posture|xprotect-age" })
    }
}
