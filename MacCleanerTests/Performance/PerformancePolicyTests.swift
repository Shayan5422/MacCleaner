import Darwin
import Foundation
import Testing
@testable import MacCleaner

@Suite("Performance process safety policy")
struct PerformanceProcessPolicyTests {
    private let me: uid_t = 501
    private let ownPID: pid_t = 4_242
    private let ownBundle = "/Applications/Mac Cleaner.app"

    private func process(_ pid: pid_t, _ name: String, path: String?, uid: uid_t = 501) -> PerformanceProcess {
        PerformanceProcess(
            pid: pid, parentPID: 1, uid: uid, userName: "me", name: name, executablePath: path,
            appBundlePath: path.flatMap(PerformanceProcessTracker.outermostAppBundle), startTime: Date(timeIntervalSince1970: 100),
            memoryFootprint: 1_000, cpu: 0.1, recentCPU: nil, recentCPUWindow: 0, isCurrentUser: uid == 501, hasUsageInfo: uid == 501
        )
    }

    private var apps: PerformanceAppDirectory {
        PerformanceAppDirectory(apps: [
            PerformanceRunningApp(pid: 100, name: "Safari", bundleIdentifier: "com.apple.Safari", bundlePath: "/Applications/Safari.app", isUserFacing: true),
            PerformanceRunningApp(pid: 200, name: "Google Chrome", bundleIdentifier: "com.google.Chrome", bundlePath: "/Applications/Google Chrome.app", isUserFacing: true),
            PerformanceRunningApp(pid: 300, name: "Finder", bundleIdentifier: "com.apple.finder", bundlePath: "/System/Library/CoreServices/Finder.app", isUserFacing: true),
            PerformanceRunningApp(pid: 400, name: "Activity Monitor", bundleIdentifier: "com.apple.ActivityMonitor", bundlePath: "/System/Applications/Utilities/Activity Monitor.app", isUserFacing: true),
            PerformanceRunningApp(pid: ownPID, name: "Mac Cleaner", bundleIdentifier: "com.maccleaner.MacCleaner", bundlePath: ownBundle, isUserFacing: true),
        ])
    }

    private func role(_ process: PerformanceProcess) -> PerformanceProcessRole {
        PerformanceProcessPolicy.role(of: process, apps: apps, currentUID: me, ownPID: ownPID, ownBundlePath: ownBundle)
    }

    @Test func userAppsCanBeQuit() {
        let safari = role(process(100, "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari"))
        #expect(safari.actionableApp?.name == "Safari")
        #expect(!safari.canStopProcess)
        let activityMonitor = role(process(400, "Activity Monitor", path: "/System/Applications/Utilities/Activity Monitor.app/Contents/MacOS/Activity Monitor"))
        #expect(activityMonitor.actionableApp?.pid == 400)
    }

    @Test func helpersActOnTheirApp() {
        let helper = role(process(201, "Google Chrome Helper (Renderer)", path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"))
        #expect(helper == .appHelper(apps.byPID[200]!))
        #expect(!helper.canStopProcess)
    }

    @Test func protectedSessionProcessesHaveNoActions() {
        for name in ["WindowServer", "loginwindow", "Dock", "SystemUIServer", "kernel_task", "launchd"] {
            let result = role(process(900, name, path: "/System/Library/CoreServices/\(name)"))
            #expect(result.actionableApp == nil, "\(name)")
            #expect(!result.canStopProcess, "\(name)")
        }
        #expect(role(process(300, "Finder", path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder")) == .protectedSystem)
        #expect(role(process(1, "launchd", path: "/sbin/launchd")) == .protectedSystem)
    }

    @Test func otherUsersAndRootProcessesHaveNoActions() {
        #expect(role(process(77, "mds_stores", path: "/System/Library/Frameworks/CoreServices.framework/mds_stores", uid: 0)) == .otherUser)
        #expect(role(process(78, "node", path: "/usr/local/bin/node", uid: 502)) == .otherUser)
    }

    @Test func macCleanerNeverActsOnItself() {
        #expect(role(process(ownPID, "Mac Cleaner", path: ownBundle + "/Contents/MacOS/Mac Cleaner")) == .thisApp)
        #expect(role(process(4_300, "Mac Cleaner Helper", path: ownBundle + "/Contents/Library/LoginItems/Helper.app/Contents/MacOS/Helper")) == .thisApp)
    }

    @Test func macOSComponentsOfTheUserAreLeftAlone() {
        #expect(role(process(500, "photoanalysisd", path: "/System/Library/PrivateFrameworks/PhotoAnalysis.framework/Versions/A/Support/photoanalysisd")) == .macOSComponent)
        #expect(role(process(501, "zsh", path: "/bin/zsh")) == .macOSComponent)
        #expect(role(process(502, "com.apple.WebKit.WebContent", path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent")) == .webContent)
        #expect(role(process(503, "mystery", path: nil)) == .unknown)
    }

    @Test func onlyTheUsersOwnBackgroundProcessesCanBeStopped() {
        #expect(role(process(600, "node", path: "/usr/local/bin/node")).canStopProcess)
        #expect(role(process(601, "language-server", path: "/Users/me/.vscode/extensions/server")).canStopProcess)
        #expect(role(process(602, "Updater", path: "/Applications/Some Tool.app/Contents/MacOS/Updater")).canStopProcess)
    }

    @Test func outermostAppBundleResolvesHelpers() {
        #expect(PerformanceProcessTracker.outermostAppBundle(of: "/Applications/A.app/Contents/Frameworks/B.app/Contents/MacOS/B") == "/Applications/A.app")
        #expect(PerformanceProcessTracker.outermostAppBundle(of: "/usr/bin/top") == nil)
    }
}

@Suite("Performance recommendations")
struct PerformanceAdvisorTests {
    private func sample(pressure: MemoryPressureLevel = .normal, swap: UInt64 = 0) -> PerformanceSample {
        let memory = PerformanceMemoryBreakdown(total: 16_000_000_000, app: 8_000_000_000, wired: 2_000_000_000, compressed: 1_000_000_000, cachedFiles: 3_000_000_000)
        return PerformanceSample(
            date: Date(), window: 2, cpuUsage: 0.3, cpuUserUsage: 0.2, cpuSystemUsage: 0.1, perCoreUsage: [0.3], loadAverage: nil,
            memoryUsed: memory.used, memoryTotal: memory.total, memory: memory, memoryPressure: pressure, swapUsed: swap, swapTotal: swap,
            swapInPerSecond: 0, swapOutPerSecond: 0, networkInPerSecond: 0, networkOutPerSecond: 0, diskReadPerSecond: 0, diskWritePerSecond: 0,
            thermalState: .nominal
        )
    }

    private func process(_ pid: pid_t, _ name: String, path: String, memory: UInt64, recentCPU: Double? = nil) -> PerformanceProcess {
        PerformanceProcess(
            pid: pid, parentPID: 1, uid: getuid(), userName: "me", name: name, executablePath: path,
            appBundlePath: PerformanceProcessTracker.outermostAppBundle(of: path), startTime: Date(timeIntervalSince1970: 100),
            memoryFootprint: memory, cpu: recentCPU, recentCPU: recentCPU, recentCPUWindow: recentCPU == nil ? 0 : 30,
            isCurrentUser: true, hasUsageInfo: true
        )
    }

    private let apps = PerformanceAppDirectory(apps: [
        PerformanceRunningApp(pid: 200, name: "Google Chrome", bundleIdentifier: "com.google.Chrome", bundlePath: "/Applications/Google Chrome.app", isUserFacing: true),
    ])

    @Test func groupsHelpersWithTheirAppForMemory() throws {
        let processes = [
            process(200, "Google Chrome", path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", memory: 600 << 20),
            process(201, "Google Chrome Helper (Renderer)", path: "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)", memory: 900 << 20),
            process(300, "small-tool", path: "/usr/local/bin/small-tool", memory: 2 << 30),
        ]
        let heavy = PerformanceAdvisor.memoryHeavyApps(processes: processes, apps: apps, totalMemory: 16 << 30)
        let chrome = try #require(heavy.first)
        #expect(heavy.count == 1) // background tools aren't apps; they're covered by recommendations
        #expect(chrome.app.name == "Google Chrome")
        #expect(chrome.bytes == 1_500 << 20)
        #expect(chrome.processCount == 2)
        #expect(abs(chrome.fractionOfMemory - 1_500.0 / 16_384.0) < 1e-9)
        #expect(chrome.target.kind == .app)
        #expect(chrome.target.pid == 200)

        let smallApps = PerformanceAdvisor.memoryHeavyApps(processes: [processes[0]], apps: apps, totalMemory: 16 << 30, minimumBytes: 1 << 30)
        #expect(smallApps.isEmpty)
    }

    @Test func largeBackgroundProcessesAreMentionedWithStopAction() throws {
        let processes = [process(300, "small-tool", path: "/usr/local/bin/small-tool", memory: 2 << 30)]
        let result = PerformanceAdvisor.recommendations(for: PerformanceAdvisorInput(sample: sample(), processes: processes, apps: apps, logicalCoreCount: 8, startup: nil, bootDate: nil))
        let background = try #require(result.first { $0.category == .background })
        #expect(background.actions == [.stopProcess])
        #expect(background.severity == .info) // memory only, pressure normal
        #expect(background.metrics == ["2 GB"])
    }

    @Test func flagsSustainedCPUAndOffersStopOnlyForBackgroundProcesses() throws {
        let processes = [
            process(700, "runaway-script", path: "/Users/me/bin/runaway-script", memory: 50_000_000, recentCPU: 0.97),
            process(701, "photoanalysisd", path: "/System/Library/PrivateFrameworks/PhotoAnalysis.framework/Versions/A/Support/photoanalysisd", memory: 50_000_000, recentCPU: 0.9),
        ]
        let result = PerformanceAdvisor.recommendations(for: PerformanceAdvisorInput(sample: sample(), processes: processes, apps: apps, logicalCoreCount: 8, startup: nil, bootDate: nil))
        let script = try #require(result.first { $0.id == "cpu|700" })
        #expect(script.actions == [.stopProcess])
        #expect(script.target?.kind == .process)
        let system = try #require(result.first { $0.id == "cpu|701" })
        #expect(system.actions.isEmpty)
        #expect(system.detail.contains("Photos"))
    }

    @Test func suggestsRestartOnlyAfterLongUptimeWithSwap() {
        let longAgo = Date().addingTimeInterval(-20 * 86_400)
        let withSwap = PerformanceAdvisor.recommendations(for: PerformanceAdvisorInput(sample: sample(swap: 3 << 30), processes: [], apps: apps, logicalCoreCount: 8, startup: nil, bootDate: longAgo))
        #expect(withSwap.contains { $0.category == .restart })
        let noSwap = PerformanceAdvisor.recommendations(for: PerformanceAdvisorInput(sample: sample(), processes: [], apps: apps, logicalCoreCount: 8, startup: nil, bootDate: longAgo))
        #expect(!noSwap.contains { $0.category == .restart })
    }

    @Test func manyLaunchAgentsLinkToStartupItems() {
        let many = PerformanceStartupSummary(userLaunchAgents: 14, sharedLaunchAgents: 3, launchDaemons: 5)
        let result = PerformanceAdvisor.recommendations(for: PerformanceAdvisorInput(sample: sample(), processes: [], apps: apps, logicalCoreCount: 8, startup: many, bootDate: nil))
        #expect(result.first { $0.category == .startup }?.actions == [.openStartupItems])
        let few = PerformanceStartupSummary(userLaunchAgents: 2, sharedLaunchAgents: 3, launchDaemons: 5)
        #expect(!PerformanceAdvisor.recommendations(for: PerformanceAdvisorInput(sample: sample(), processes: [], apps: apps, logicalCoreCount: 8, startup: few, bootDate: nil)).contains { $0.category == .startup })
    }

    @Test func memoryInterpretationMatchesPressure() {
        #expect(PerformanceMemoryInterpretation.message(for: sample(pressure: .critical)).level == .critical)
        #expect(PerformanceMemoryInterpretation.message(for: sample(swap: 2 << 30)).detail.contains("left over"))
    }
}

@Suite("Performance battery parsing")
struct PerformanceBatteryParserTests {
    @Test func appleSiliconStyleValues() {
        let source: [String: Any] = [
            "Type": "InternalBattery", "Current Capacity": 80, "Max Capacity": 100, "Is Charging": true,
            "Power Source State": "AC Power", "Time to Full Charge": 35, "Time to Empty": 0, "BatteryHealth": "Good",
        ]
        let registry: [String: Any] = [
            "CycleCount": 123, "DesignCapacity": 5_000, "NominalChargeCapacity": 4_500, "AppleRawMaxCapacity": 4_400,
            "MaxCapacity": 100, "Temperature": 3_050, "BatteryInstalled": true,
        ]
        let battery = PerformanceBatteryParser.parse(powerSource: source, registry: registry)
        #expect(battery.level == 0.8)
        #expect(battery.isCharging)
        #expect(battery.powerSource == .powerAdapter)
        #expect(battery.timeToFull == TimeInterval(35 * 60))
        #expect(battery.timeToEmpty == nil)
        #expect(battery.cycleCount == 123)
        #expect(battery.fullChargeCapacity == 4_500)
        #expect(battery.healthFraction == 0.9)
        #expect(battery.temperatureCelsius == 30.5)
        #expect(battery.condition == "Good")
    }

    @Test func intelStyleCapacityInMilliampHours() {
        let source: [String: Any] = ["Current Capacity": 50, "Max Capacity": 100, "Power Source State": "Battery Power", "Time to Empty": -1]
        let registry: [String: Any] = ["DesignCapacity": 6_000, "MaxCapacity": 5_400]
        let battery = PerformanceBatteryParser.parse(powerSource: source, registry: registry)
        #expect(battery.powerSource == .battery)
        #expect(battery.timeToEmpty == nil) // still calculating
        #expect(battery.fullChargeCapacity == 5_400)
        #expect(battery.healthFraction == 0.9)
    }

    @Test func missingRegistryLeavesHealthUnknown() {
        let battery = PerformanceBatteryParser.parse(powerSource: ["Current Capacity": 20, "Max Capacity": 100, "Power Source State": "Battery Power", "Time to Empty": 95], registry: nil)
        #expect(battery.timeToEmpty == TimeInterval(95 * 60))
        #expect(battery.healthFraction == nil)
        #expect(battery.temperatureCelsius == nil)
    }
}

@Suite("Performance CPU topology")
struct PerformanceTopologyTests {
    @Test func labelsCoresByKindOnlyWhenVerified() {
        let verified = PerformanceCPUTopology(logicalCoreCount: 6, performanceCoreCount: 4, efficiencyCoreCount: 2, coreKinds: [.efficiency, .efficiency, .performance, .performance, .performance, .performance])
        #expect((0..<6).map(verified.label(forCore:)) == ["E1", "E2", "P1", "P2", "P3", "P4"])
        #expect(verified.summary == "4 performance + 2 efficiency cores")

        let unverified = PerformanceCPUTopology(logicalCoreCount: 6, performanceCoreCount: 4, efficiencyCoreCount: 2, coreKinds: nil)
        #expect(unverified.label(forCore: 2) == "Core 3")
        #expect(unverified.kind(ofCore: 2) == nil)

        let intel = PerformanceCPUTopology(logicalCoreCount: 8, performanceCoreCount: nil, efficiencyCoreCount: nil, coreKinds: nil)
        #expect(intel.summary == "8 cores")
    }

    @Test func thisMacTopologyIsConsistent() {
        let topology = PerformanceCPUTopologyReader.read()
        #expect(topology.logicalCoreCount >= 1)
        if let kinds = topology.coreKinds {
            #expect(kinds.count == topology.logicalCoreCount)
            #expect(kinds.filter { $0 == .performance }.count == topology.performanceCoreCount)
        }
    }
}
