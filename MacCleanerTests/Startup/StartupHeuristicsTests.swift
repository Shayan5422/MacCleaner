import Foundation
import Testing
@testable import MacCleaner

struct StartupHeuristicsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func environment(_ existing: Set<String>) -> LaunchdProgramAnalyzer.Environment {
        LaunchdProgramAnalyzer.Environment(fileExists: { existing.contains($0) }, appPathForBundleIdentifier: { _ in nil }, home: "/Users/test")
    }

    /// A user launch agent built from its program arguments, analyzed against a fake file system.
    private func agent(
        _ label: String,
        arguments: [String],
        existing: Set<String>,
        kind: StartupItemKind = .userAgent,
        keepAlive: Bool = false,
        sessions: [String] = []
    ) -> StartupItem {
        var definition = LaunchdJobDefinition()
        definition.label = label
        definition.programArguments = arguments
        definition.runAtLoad = true
        definition.keepAlive = keepAlive ? .always : .off
        definition.limitLoadToSessionTypes = sessions
        var item = StartupItem(id: "\(kind.rawValue)|\(label)", kind: kind, name: label)
        item.label = label
        item.plistPath = "/Users/test/Library/LaunchAgents/\(label).plist"
        item.definition = definition
        let analysis = LaunchdProgramAnalyzer.analyze(definition, environment: environment(existing))
        item.analysis = analysis
        item.targetPath = analysis.targetPath
        return item
    }

    private func loginItem(_ name: String, path: String?, exists: Bool = true) -> StartupItem {
        var item = StartupItem(id: "loginItem|\(name)|\(path ?? "")", kind: .loginItem, name: name)
        item.targetPath = path
        if let path {
            var code = SecurityCodeEvaluation(path: path, exists: exists, signature: CodeSignatureInfo(), category: exists ? .developerIDNotarized : .missing)
            code.packageManager = nil
            item.code = code
        }
        return item
    }

    @Test func missingProgramIsReportedAsBroken() {
        let item = agent("com.example.gone", arguments: ["/Applications/Gone.app/Contents/MacOS/Gone"], existing: [])
        let concerns = StartupHeuristics.concerns(for: item, duplicates: [], installedVendorPrefixes: [], now: now)
        #expect(concerns.map(\.kind) == [.broken])
        #expect(StartupHeuristics.isBroken(item))
    }

    @Test func emptyAndDamagedPlistsAreFlagged() {
        var empty = StartupItem(id: "userAgent|empty", kind: .userAgent, name: "empty")
        empty.definition = LaunchdJobDefinition()
        #expect(StartupHeuristics.concerns(for: empty, duplicates: [], installedVendorPrefixes: [], now: now).map(\.kind) == [.empty])

        var damaged = StartupItem(id: "userAgent|damaged", kind: .userAgent, name: "damaged")
        damaged.parseError = "The property list is damaged."
        #expect(StartupHeuristics.concerns(for: damaged, duplicates: [], installedVendorPrefixes: [], now: now).map(\.kind) == [.empty])
    }

    @Test func helperOfAnAppNotOpenedFor90DaysIsUnused() {
        let program = "/Applications/Example.app/Contents/MacOS/ExampleHelper"
        var item = agent("com.example.helper", arguments: [program], existing: [program], keepAlive: true)
        item.owner = StartupOwnerApp(name: "Example", path: "/Applications/Example.app", bundleIdentifier: "com.example.app",
                                     lastUsedDate: now.addingTimeInterval(-120 * 86_400))
        let kinds = StartupHeuristics.concerns(for: item, duplicates: [], installedVendorPrefixes: ["com.example"], now: now).map(\.kind)
        #expect(kinds.contains(.unusedApp))
        #expect(kinds.contains(.keepAliveRarelyUsed))
    }

    @Test func recentlyUsedAppsAreNotFlagged() {
        let program = "/Applications/Example.app/Contents/MacOS/ExampleHelper"
        var item = agent("com.example.helper", arguments: [program], existing: [program], keepAlive: true)
        item.owner = StartupOwnerApp(name: "Example", path: "/Applications/Example.app", bundleIdentifier: "com.example.app",
                                     lastUsedDate: now.addingTimeInterval(-3 * 86_400))
        #expect(StartupHeuristics.concerns(for: item, duplicates: [], installedVendorPrefixes: ["com.example"], now: now).isEmpty)
    }

    @Test func unknownLastUseIsNeverTreatedAsUnused() {
        let program = "/Applications/Example.app/Contents/MacOS/ExampleHelper"
        var item = agent("com.example.helper", arguments: [program], existing: [program], keepAlive: true)
        item.owner = StartupOwnerApp(name: "Example", path: "/Applications/Example.app", bundleIdentifier: "com.example.app", lastUsedDate: nil)
        #expect(StartupHeuristics.concerns(for: item, duplicates: [], installedVendorPrefixes: ["com.example"], now: now).isEmpty)
    }

    @Test func duplicateLoginItemAndOpenAgentForTheSameApp() {
        let app = "/Applications/Example.app"
        let login = loginItem("Example", path: app)
        let opener = agent("com.example.autorun", arguments: ["/usr/bin/open", "-a", app], existing: ["/usr/bin/open", app])
        let result = StartupHeuristics.applyConcerns(to: [login, opener], installedVendorPrefixes: ["com.example"], now: now)
        #expect(result.allSatisfy { $0.concerns.contains { $0.kind == .duplicate } })
    }

    @Test func sameProgramInDifferentSessionsIsNotADuplicate() {
        let program = "/Library/vnc/Contents/MacOS/agent"
        let perUser = agent("com.example.vnc.peruser", arguments: [program, "service"], existing: [program], kind: .systemAgent, sessions: ["Aqua"])
        let prelogin = agent("com.example.vnc.prelogin", arguments: [program, "service"], existing: [program], kind: .systemAgent, sessions: ["LoginWindow"])
        let result = StartupHeuristics.applyConcerns(to: [perUser, prelogin], installedVendorPrefixes: ["com.example"], now: now)
        #expect(result.allSatisfy { !$0.concerns.contains { $0.kind == .duplicate } })
    }

    @Test func differentArgumentsAreNotDuplicates() {
        let ssh = "/usr/bin/ssh"
        let first = agent("com.example.tunnel-a", arguments: [ssh, "-N", "host-a"], existing: [ssh])
        let second = agent("com.example.tunnel-b", arguments: [ssh, "-N", "host-b"], existing: [ssh])
        let result = StartupHeuristics.applyConcerns(to: [first, second], installedVendorPrefixes: [], now: now)
        #expect(result.allSatisfy { $0.concerns.isEmpty })
    }

    @Test func leftoverUpdaterOfAnUninstalledVendor() {
        let helper = "/Library/PrivilegedHelperTools/us.example.updater"
        let item = agent("us.example.updater", arguments: [helper], existing: [helper], kind: .systemDaemon)
        let concern = StartupHeuristics.leftoverConcern(for: item, installedVendorPrefixes: ["com.other"], home: "/Users/test")
        #expect(concern?.kind == .leftover)
        // Installed vendor: not left over.
        #expect(StartupHeuristics.leftoverConcern(for: item, installedVendorPrefixes: ["us.example"], home: "/Users/test") == nil)
    }

    @Test func commandLineToolsAreNeverCalledLeftovers() {
        let tool = "/Users/test/.local/share/tool/server-agent"
        let item = agent("dev.example.agent", arguments: [tool], existing: [tool])
        #expect(StartupHeuristics.leftoverConcern(for: item, installedVendorPrefixes: [], home: "/Users/test") == nil)
        let brew = agent("homebrew.mxcl.redis", arguments: ["/opt/homebrew/opt/redis/bin/redis-server"], existing: ["/opt/homebrew/opt/redis/bin/redis-server"])
        #expect(StartupHeuristics.leftoverConcern(for: brew, installedVendorPrefixes: [], home: "/Users/test") == nil)
    }

    @Test func vendorPrefixes() {
        #expect(StartupHeuristics.vendorPrefix(of: "com.Google.Keystone.Agent") == "com.google")
        #expect(StartupHeuristics.vendorPrefix(of: "postgresql") == nil)
    }

    @Test func missingLoginItemAppIsBroken() {
        let gone = loginItem("Gone", path: "/Applications/Gone.app", exists: false)
        #expect(StartupHeuristics.isBroken(gone))
        let unresolved = loginItem("Unknown", path: nil)
        #expect(StartupHeuristics.isBroken(unresolved))
    }

    @Test func stateReflectsLaunchdAndApproval() {
        let program = "/usr/local/bin/tool"
        var item = agent("com.example.tool", arguments: [program], existing: [program])
        #expect(StartupInventoryScanner.state(for: item, isRunning: true, runningPID: 42, isLoaded: true, statusKnown: true) == .running(pid: 42))
        #expect(StartupInventoryScanner.state(for: item, isRunning: false, runningPID: nil, isLoaded: true, statusKnown: true) == .loaded)
        #expect(StartupInventoryScanner.state(for: item, isRunning: false, runningPID: nil, isLoaded: false, statusKnown: true) == .notLoaded)
        #expect(StartupInventoryScanner.state(for: item, isRunning: false, runningPID: nil, isLoaded: false, statusKnown: false) == .unknown)

        item.disabledOverride = true
        #expect(item.isEnabled == false)
        #expect(StartupInventoryScanner.state(for: item, isRunning: false, runningPID: nil, isLoaded: false, statusKnown: true) == .disabled)

        item.disabledOverride = nil
        item.backgroundApproval = .requiresApproval
        #expect(StartupInventoryScanner.state(for: item, isRunning: false, runningPID: nil, isLoaded: false, statusKnown: true) == .offInSettings)

        let broken = agent("com.example.gone", arguments: ["/nope/tool"], existing: [])
        #expect(StartupInventoryScanner.state(for: broken, isRunning: false, runningPID: nil, isLoaded: true, statusKnown: true) == .broken)
    }

    @Test func resourceImpactThresholds() {
        let low = StartupResourceUsage(processCount: 1, memoryBytes: 20_000_000, cpuTimeNanoseconds: 0, averageCPU: 0.001, isPartial: false)
        let medium = StartupResourceUsage(processCount: 1, memoryBytes: 200_000_000, cpuTimeNanoseconds: 0, averageCPU: 0.001, isPartial: false)
        let high = StartupResourceUsage(processCount: 2, memoryBytes: 20_000_000, cpuTimeNanoseconds: 0, averageCPU: 0.2, isPartial: false)
        #expect(low.impact == .low)
        #expect(medium.impact == .medium)
        #expect(high.impact == .high)
    }

    @Test func protectedItemsCannotBeChanged() {
        let item = agent("com.apple.fake", arguments: ["/usr/bin/true"], existing: ["/usr/bin/true"])
        #expect(item.isProtected)
        #expect(!item.canToggle)
        #expect(!item.canMoveToTrash)
    }
}
