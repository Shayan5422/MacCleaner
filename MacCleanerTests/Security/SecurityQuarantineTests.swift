import Darwin
import Foundation
import Testing
@testable import MacCleaner

struct SecurityQuarantineTests {
    @Test func parsesAFullQuarantineRecord() throws {
        let info = try #require(SecurityQuarantineInfo.parse("0281;6a2c78e7;Chrome;DE8ED0CD-4FA0-4D8F-A740-1C18A5F09AB9"))
        #expect(info.flags == 0x0281)
        #expect(info.date == Date(timeIntervalSince1970: 1_781_299_431))
        #expect(info.agent == "Chrome")
        #expect(info.eventIdentifier == "DE8ED0CD-4FA0-4D8F-A740-1C18A5F09AB9")
        #expect(!info.isUserApproved)
        #expect(info.flagsDescription == "0x0281")
    }

    @Test func approvedFlagAndMissingFields() throws {
        let approved = try #require(SecurityQuarantineInfo.parse("00c1;6abc0d95;Safari;"))
        #expect(approved.isUserApproved)
        #expect(approved.eventIdentifier == nil)

        let sparse = try #require(SecurityQuarantineInfo.parse("0083;;;"))
        #expect(sparse.date == nil)
        #expect(sparse.agent == nil)

        let flagsOnly = try #require(SecurityQuarantineInfo.parse("0001"))
        #expect(flagsOnly.flags == 1)
        #expect(flagsOnly.date == nil)

        // Trailing NUL bytes, as some writers store them.
        let padded = try #require(SecurityQuarantineInfo.parse("0081;6a95317d;Telegram;\0"))
        #expect(padded.agent == "Telegram")
    }

    @Test func rejectsValuesThatAreNotQuarantineRecords() {
        #expect(SecurityQuarantineInfo.parse("") == nil)
        #expect(SecurityQuarantineInfo.parse("hello;world") == nil)
        #expect(SecurityQuarantineInfo.parse("123456789;6a2c78e7;Chrome") == nil)
    }

    @Test func classifiesDownloads() {
        #expect(SecurityDownloadKind.classify(name: "Example.app", isDirectory: true, isExecutableMachO: false) == .application)
        #expect(SecurityDownloadKind.classify(name: "Install.PKG", isDirectory: false, isExecutableMachO: false) == .installerPackage)
        #expect(SecurityDownloadKind.classify(name: "Tool.dmg", isDirectory: false, isExecutableMachO: false) == .diskImage)
        #expect(SecurityDownloadKind.classify(name: "setup.command", isDirectory: false, isExecutableMachO: false) == .script)
        #expect(SecurityDownloadKind.classify(name: "archive.zip", isDirectory: false, isExecutableMachO: false) == .archive)
        #expect(SecurityDownloadKind.classify(name: "helper", isDirectory: false, isExecutableMachO: true) == .executable)
        #expect(SecurityDownloadKind.classify(name: "report.pdf", isDirectory: false, isExecutableMachO: false) == .other)
        #expect(SecurityDownloadKind.diskImage.isInstaller && !SecurityDownloadKind.script.isInstaller)
        #expect(SecurityDownloadKind.script.canRunCode && !SecurityDownloadKind.archive.canRunCode)
    }

    @Test func parsesPackageSignatures() throws {
        let signed = try #require(SecurityPackageSignature.parse("""
        Package "Example.pkg":
           Status: signed by a developer certificate issued by Apple for distribution
           Notarization: trusted by the Apple notary service
           Signed with a trusted timestamp on: 2026-05-01 10:00:00 +0000
           Certificate Chain:
            1. Developer ID Installer: Example Inc (ABCDE12345)
               Expires: 2031-01-01 00:00:00 +0000
            2. Developer ID Certification Authority
            3. Apple Root CA
        """))
        #expect(signed.isSigned && signed.isAppleIssued)
        #expect(signed.isNotarized == true)
        #expect(signed.signer == "Developer ID Installer: Example Inc (ABCDE12345)")

        let unsigned = try #require(SecurityPackageSignature.parse("Package \"Thing.pkg\":\n   Status: no signature\n"))
        #expect(!unsigned.isSigned)
        #expect(!unsigned.isAppleIssued)

        #expect(SecurityPackageSignature.parse("pkgutil: error") == nil)
    }

    /// Writes real quarantine attributes on files in a temporary folder (never on the person's files).
    @Test func scansAFolderForQuarantinedCode() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SecurityQuarantineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        func write(_ relative: String, quarantine: String?) throws {
            let url = folder.appendingPathComponent(relative)
            try Data("#!/bin/sh\necho test\n".utf8).write(to: url)
            if let quarantine {
                let result = quarantine.withCString { value in
                    setxattr(url.path, "com.apple.quarantine", value, strlen(value), 0, XATTR_NOFOLLOW)
                }
                #expect(result == 0)
            }
        }
        try write("Installer.dmg", quarantine: "0083;6a2c78e7;Safari;")
        try write("run.sh", quarantine: "00c1;6a2c78e7;Chrome;")
        try write("notes.pdf", quarantine: "0081;6a2c78e7;Chrome;")
        try write("plain.dmg", quarantine: nil)
        try write("Nested/inner.pkg", quarantine: "0081;6a2c78e7;Mail;")

        let files = SecurityQuarantineScanner.scan(folder: folder.path)
        let names = Set(files.map(\.name))
        #expect(names == ["Installer.dmg", "run.sh", "inner.pkg"])
        let dmg = try #require(files.first { $0.name == "Installer.dmg" })
        #expect(dmg.kind == .diskImage)
        #expect(dmg.quarantine.agent == "Safari")
        #expect(dmg.snapshot != nil)
        #expect(dmg.cleanupItem.purpose == .userFile)
        let script = try #require(files.first { $0.name == "run.sh" })
        #expect(script.quarantine.isUserApproved)
        #expect(!script.neverOpened)
    }

    @Test func oldNeverOpenedInstallersBecomeOneInformationFinding() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func file(_ name: String, kind: SecurityDownloadKind, daysAgo: Double, flags: UInt32) -> SecurityQuarantinedFile {
            let quarantine = SecurityQuarantineInfo(flags: flags, date: now.addingTimeInterval(-daysAgo * 86_400), agent: "Safari", eventIdentifier: nil, rawValue: "")
            return SecurityQuarantinedFile(path: "/Users/test/Downloads/" + name, kind: kind, quarantine: quarantine, sizeBytes: 1_000_000)
        }
        let files = [
            file("Old.dmg", kind: .diskImage, daysAgo: 45, flags: 0x0081),
            file("Old.pkg", kind: .installerPackage, daysAgo: 400, flags: 0x0081),
            file("Opened.dmg", kind: .diskImage, daysAgo: 60, flags: 0x00C1),
            file("Recent.dmg", kind: .diskImage, daysAgo: 3, flags: 0x0081),
            file("Old.sh", kind: .script, daysAgo: 90, flags: 0x0081),
        ]
        let findings = SecurityScanner.downloadFindings(files, now: now)
        #expect(findings.count == 1)
        let finding = findings[0]
        #expect(finding.severity == .info)
        #expect(finding.title == "2 old installers in Downloads were never opened")
        #expect(finding.remediation == .quarantinedFiles(paths: ["/Users/test/Downloads/Old.dmg", "/Users/test/Downloads/Old.pkg"]))
    }

    @Test func unsignedDownloadedAppsAreSuspiciousUntilApproved() {
        func app(flags: UInt32, category: SecurityTrustCategory) -> SecurityQuarantinedFile {
            var file = SecurityQuarantinedFile(
                path: "/Users/test/Downloads/Tool.app", kind: .application,
                quarantine: SecurityQuarantineInfo(flags: flags, date: Date(), agent: "Chrome", eventIdentifier: nil, rawValue: ""),
                sizeBytes: 10
            )
            file.evaluation = SecurityCodeEvaluation(path: file.path, exists: true, signature: CodeSignatureInfo(), category: category)
            return file
        }
        #expect(SecurityScanner.downloadFindings([app(flags: 0x0081, category: .unsigned)]).first?.severity == .suspicious)
        #expect(SecurityScanner.downloadFindings([app(flags: 0x00C1, category: .adHoc)]).first?.severity == .info)
        #expect(SecurityScanner.downloadFindings([app(flags: 0x00C1, category: .revoked)]).first?.severity == .suspicious)
        #expect(SecurityScanner.downloadFindings([app(flags: 0x0081, category: .developerIDNotarized)]).isEmpty)
    }
}
