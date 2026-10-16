import Foundation
import Testing
@testable import MacCleaner

struct GuardianLSAppInfoParserTests {
    /// `lsappinfo list` excerpt (format of macOS 14–27; app names are examples).
    static let sample = """
     1) "loginwindow" ASN:0x0-0x2002:
        childASNs: ASN:0x0-0x32032:
     5) "Dock" ASN:0x0-0xd00d:
        childASNs: ASN:0x0-0x54054: ASN:0x0-0x55055:
    35) "PortThing" ASN:0x0-0x2d02d:
        bundleID="eu.example.PortThing"
        bundle path="/Applications/PortThing.app"
        executable path="/Applications/PortThing.app/Contents/MacOS/PortThing"
        pid = 1039 token=[sess=100023 pid=1039 uid:501,501,501 g:20,20 pV:2716] type="UIElement" flavor=3 Version="1" fileType="APPL" creator="????" Arch=ARM64
        coalition: 1077  { 1039 1086 }
        checkin time = 2026/10/16 10:28:13 ( 6 hours, 12 minutes, 5.17199 seconds ago )
    38) "Music Player" ASN:0x0-0x31031:
        bundleID="com.example.player"
        bundle path="/Applications/Music Player.app"
        executable path="/Applications/Music Player.app/Contents/MacOS/Music Player"
        pid = 1083 token=[sess=100023 pid=1083 uid:501,501,501 g:20,20 pV:2823] type="Foreground" flavor=3 Version="1.3.5" fileType="APPL" creator="????" Arch=ARM64
        parentASN=ASN:0x0-0x2e02e:
        launch time =  2026/10/16 10:28:13 ( 6 hours, 12 minutes, 5.07998 seconds ago )
        checkin time = 2026/10/16 10:28:16 ( 6 hours, 12 minutes, 2.36092 seconds ago )
    39) "MenuMeter" ASN:0x0-0x32032:
        bundleID="pro.example.MenuMeter"
        bundle path="/Applications/MenuMeter.app"
        executable path="/Applications/MenuMeter.app/Contents/MacOS/MenuMeter"
        pid = 1116 token=[sess=100023 pid=1116 uid:501,501,501 g:20,20 pV:2829] type="UIElement" flavor=3 Version="50119" fileType="APPL" creator="????" Arch=ARM64
        parentASN="loginwindow" ASN:0x0-0x2002:
        launch time =  2026/10/16 10:28:13 ( 6 hours, 12 minutes, 5.01603 seconds ago )
    55) "Example Browser" ASN:0x0-0x54054: (in front)
        bundleID="com.example.browser"
        bundle path="/Applications/Example Browser.app"
        executable path="/Applications/Example Browser.app/Contents/MacOS/Example Browser"
        pid = 1520 token=[sess=100023 pid=1520 uid:501,501,501 g:20,20 pV:3719] type="Foreground" flavor=3 Version="8059.84" fileType="APPL" creator="rimZ" Arch=ARM64
        parentASN="Dock" ASN:0x0-0xd00d:
        launch time =  2026/10/16 10:28:23 ( 6 hours, 11 minutes, 33.3871 seconds ago )
    """

    private let utc = TimeZone(identifier: "UTC")!

    @Test func parsesAppsParentsAndLaunchTimes() {
        let apps = GuardianLSAppInfoParser.parse(Self.sample, timeZone: utc)
        #expect(apps.map(\.name) == ["loginwindow", "Dock", "PortThing", "Music Player", "MenuMeter", "Example Browser"])
        let menu = apps[4]
        #expect(menu.asn == "0x0-0x32032")
        #expect(menu.bundleIdentifier == "pro.example.MenuMeter")
        #expect(menu.bundlePath == "/Applications/MenuMeter.app")
        #expect(menu.pid == 1116)
        #expect(menu.type == "UIElement")
        #expect(menu.parentName == "loginwindow")
        #expect(menu.parentASN == "0x0-0x2002")
        #expect(menu.launchTime == ISO8601DateFormatter().date(from: "2026-10-16T10:28:13Z"))

        let player = apps[3]
        #expect(player.parentName == nil)
        #expect(player.parentASN == "0x0-0x2e02e")
        // Started by launchd directly: no parent, no launch time.
        #expect(apps[2].parentASN == nil)
        #expect(apps[2].launchTime == nil)
        #expect(apps[5].parentName == "Dock")
    }

    @Test func nullValuesAndHeaders() {
        let apps = GuardianLSAppInfoParser.parse("""
        [ NULL ]  ASN:0x0-0x31031:
            bundleID=[ NULL ]
         2) "QuickLookUIService (Finder)" ASN:0x0-0x17017:
            bundleID=[ NULL ]
        """)
        #expect(apps.count == 1)
        #expect(apps.first?.name == "QuickLookUIService (Finder)")
        #expect(apps.first?.bundleIdentifier == nil)
        #expect(GuardianLSAppInfoParser.header("12) \"A \\\"quoted\\\" name\" ASN:0x0-0x1:")?.asn == "0x0-0x1")
        #expect(GuardianLSAppInfoParser.header("childASNs: ASN:0x0-0x32032:") == nil)
    }
}

struct GuardianLoginClockTests {
    private let login = Date(timeIntervalSince1970: 1_792_139_286) // 10:28:06

    private func process(_ name: String, pid: Int32, uid: uid_t = 501, start: Date?) -> ProcessSnapshot {
        ProcessSnapshot(pid: pid, parentPID: 1, uid: uid, name: name, executablePath: nil, memoryFootprint: 0, cpuTimeNanoseconds: 0,
                        diskBytesRead: 0, diskBytesWritten: 0, startTime: start, idleWakeups: 0)
    }

    @Test func prefersTheLoginwindowProcessWhenTheLoginRecordAgrees() {
        let processes = [process("loginwindow", pid: 497, start: login), process("Dock", pid: 784, start: login.addingTimeInterval(2)),
                         process("loginwindow", pid: 90, uid: 0, start: login.addingTimeInterval(-400))]
        let estimate = GuardianLoginClock.estimate(consoleLogin: login.addingTimeInterval(-6), processes: processes, uid: 501)
        #expect(estimate?.date == login)
        #expect(estimate?.source == "loginwindow process")
    }

    @Test func fallsBackToTheLoginRecordThenToTheDock() {
        let restarted = [process("loginwindow", pid: 497, start: login.addingTimeInterval(3 * 3600))]
        #expect(GuardianLoginClock.estimate(consoleLogin: login, processes: restarted, uid: 501)?.source == "login record")
        let dockOnly = [process("Dock", pid: 784, start: login)]
        #expect(GuardianLoginClock.estimate(consoleLogin: nil, processes: dockOnly, uid: 501)?.source == "Dock process")
        #expect(GuardianLoginClock.estimate(consoleLogin: nil, processes: [], uid: 501) == nil)
    }

    @Test func readsThisMacsLoginRecordWithoutFailing() {
        // Read-only: the current console login of this user, if any.
        if let date = GuardianLoginClock.consoleLoginDate() {
            #expect(date <= Date())
        }
    }
}

struct GuardianLoginAnalyzerTests {
    private let login = Date(timeIntervalSince1970: 1_792_139_286)
    private let me: uid_t = 501

    private func process(_ pid: Int32, _ path: String, after seconds: TimeInterval, parent: Int32 = 1, uid: uid_t = 501) -> ProcessSnapshot {
        ProcessSnapshot(pid: pid, parentPID: parent, uid: uid, name: (path as NSString).lastPathComponent, executablePath: path,
                        memoryFootprint: 0, cpuTimeNanoseconds: 0, diskBytesRead: 0, diskBytesWritten: 0,
                        startTime: login.addingTimeInterval(seconds), idleWakeups: 0)
    }

    private func app(_ pid: Int32, _ name: String, _ bundleID: String, path: String) -> GuardianRunningApp {
        GuardianRunningApp(pid: pid, name: name, bundleIdentifier: bundleID, bundlePath: path,
                           executablePath: path + "/Contents/MacOS/" + name, launchDate: nil)
    }

    private func context() -> GuardianLoginAnalyzer.Context {
        let apps = [
            app(1520, "Example Browser", "com.example.browser", path: "/Applications/Example Browser.app"),
            app(1116, "MenuMeter", "pro.example.MenuMeter", path: "/Applications/MenuMeter.app"),
            app(1083, "Music Player", "com.example.player", path: "/Applications/Music Player.app"),
            app(1039, "PortThing", "eu.example.PortThing", path: "/Applications/PortThing.app"),
            app(900, "Notes", "com.apple.Notes", path: "/System/Applications/Notes.app"),
            app(1300, "Editor", "com.example.editor", path: "/Applications/Editor.app"),
            app(1400, "Notebook", "com.example.notebook", path: "/Applications/Notebook.app"),
            app(2000, "Late", "com.example.late", path: "/Applications/Late.app"),
            app(4242, "Mac Cleaner", "com.maccleaner.MacCleaner", path: "/Applications/Mac Cleaner.app"),
            app(1148, "Content Manager", "com.example.ccx", path: "/Applications/Utilities/Example Cloud/CCX.app"),
        ]
        var processes = [
            process(1520, "/Applications/Example Browser.app/Contents/MacOS/Example Browser", after: 17),
            process(1116, "/Applications/MenuMeter.app/Contents/MacOS/MenuMeter", after: 7),
            process(1083, "/Applications/Music Player.app/Contents/MacOS/Music Player", after: 7),
            process(1039, "/Applications/PortThing.app/Contents/MacOS/PortThing", after: 7),
            process(900, "/System/Applications/Notes.app/Contents/MacOS/Notes", after: 9),
            process(1300, "/Applications/Editor.app/Contents/MacOS/Editor", after: 12),
            process(1400, "/Applications/Notebook.app/Contents/MacOS/Notebook", after: 14),
            process(2000, "/Applications/Late.app/Contents/MacOS/Late", after: 600),
            process(4242, "/Applications/Mac Cleaner.app/Contents/MacOS/Mac Cleaner", after: 5),
            // Background programs
            process(1045, "/opt/homebrew/bin/cloudflared", after: 7),
            process(1058, "/Library/Application Support/org.example/Helper.app/Contents/MacOS/Helper", after: 7),
            process(700, "/Library/PrivilegedHelperTools/com.example.daemon", after: 2, uid: 0),
            process(800, "/System/Library/CoreServices/Something", after: 3),
            process(1099, "/Applications/Music Player.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper", after: 9, parent: 1083),
            process(1110, "/usr/local/bin/late-tool", after: 900),
            // A helper of the browser you opened yourself, re-parented to launchd: not automatic either.
            process(1693, "/Applications/Example Browser.app/Contents/Frameworks/Browser Framework.framework/Helpers/crashpad_handler", after: 23),
            // The app's launcher started another program of the same bundle and quit.
            process(1148, "/Applications/Utilities/Example Cloud/CCX.app/Contents/MacOS/Content Manager.node", after: 9),
        ]
        processes.append(process(1046, "/opt/homebrew/bin/cloudflared", after: 7)) // a second instance: listed once

        let appInfo = GuardianLSAppInfoParser.parse(GuardianLSAppInfoParserTests.sample, timeZone: TimeZone(identifier: "UTC")!) + [
            GuardianLSAppInfo(name: "Editor", asn: "0x0-0x60060", bundleIdentifier: "com.example.editor", pid: 1300, parentName: "loginwindow", parentASN: "0x0-0x2002"),
            GuardianLSAppInfo(name: "Notebook", asn: "0x0-0x61061", bundleIdentifier: "com.example.notebook", pid: 1400, parentName: "loginwindow", parentASN: "0x0-0x2002"),
        ]

        var portAgent = GuardianRecordFactory.agent("eu.example.PortThing.agent", program: "/Applications/PortThing.app/Contents/MacOS/PortThing")
        portAgent.configPath = "/Users/test/Library/LaunchAgents/eu.example.PortThing.agent.plist"
        let tunnelAgent = GuardianRecordFactory.agent("com.example.cloudflared", program: "/opt/homebrew/bin/cloudflared")
        var ccxAgent = GuardianRecordFactory.agent("com.example.ccxprocess", program: "/Applications/Utilities/Example Cloud/CCX.app/Contents/MacOS/CCX",
                                                   source: .systemLaunchAgents)
        ccxAgent.kind = .systemAgent
        var notebook = GuardianStartupRecord(source: .loginItems, key: "/Applications/Notebook.app", kind: .loginItem, name: "Notebook",
                                             programPath: "/Applications/Notebook.app")
        notebook.isEnabled = true

        let launchd = GuardianStartupCollector.LaunchdState(
            gui: [
                "eu.example.PortThing.agent": LaunchctlListedService(label: "eu.example.PortThing.agent", pid: 1039, lastExitStatus: nil),
                "com.example.cloudflared": LaunchctlListedService(label: "com.example.cloudflared", pid: 1045, lastExitStatus: nil),
                "application.com.example.browser.1.2": LaunchctlListedService(label: "application.com.example.browser.1.2", pid: 1520, lastExitStatus: nil),
            ],
            system: [:], guiOverrides: [:], systemOverrides: [:]
        )
        let reopen = GuardianReopenState(savesState: true, settingSource: .macOSDefault, currentHostValue: nil, userValue: nil,
                                         apps: [GuardianReopenApp(bundleIdentifier: "com.example.editor", path: "/Applications/Editor.app", isHidden: false, backgroundState: 2)],
                                         listPath: nil, listDate: nil, ignoredOtherHostFiles: 0, isHostUncertain: false, lastLogoutReason: nil)
        return GuardianLoginAnalyzer.Context(
            login: GuardianLoginClock.Estimate(date: login, source: "loginwindow process"),
            now: login.addingTimeInterval(180),
            apps: apps, processes: processes, appInfo: appInfo, launchd: launchd,
            records: [portAgent, tunnelAgent, ccxAgent, notebook], reopen: reopen, uid: me, ownPID: 4242
        )
    }

    @Test func attributesACauseToEverythingThatOpenedByItself() {
        let analysis = GuardianLoginAnalyzer.analyze(context())
        let causes = Dictionary(analysis.items.map { ($0.name, $0.cause) }, uniquingKeysWith: { first, _ in first })

        #expect(causes["MenuMeter"] == .appLoginItem)
        #expect(causes["Music Player"] == .openedByApp(name: nil))
        #expect(causes["PortThing"] == .launchAgent(label: "eu.example.PortThing.agent",
                                                    plistPath: "/Users/test/Library/LaunchAgents/eu.example.PortThing.agent.plist", isUserAgent: true))
        #expect(causes["Editor"] == .reopened)
        #expect(causes["Notebook"] == .loginItem)
        #expect(causes["cloudflared"] == .launchAgent(label: "com.example.cloudflared",
                                                      plistPath: "/Users/test/Library/LaunchAgents/com.example.cloudflared.plist", isUserAgent: true))
        #expect(causes["Helper"] == .appHelper(appName: "Helper", appPath: "/Library/Application Support/org.example/Helper.app"))
        #expect(causes["Content Manager"] == .launchAgent(label: "com.example.ccxprocess",
                                                          plistPath: "/Users/test/Library/LaunchAgents/com.example.ccxprocess.plist", isUserAgent: false))
        #expect(analysis.items.filter { $0.name == "cloudflared" }.count == 1)
    }

    @Test func leavesOutWhatYouOpenedMacOSAndLateStarts() {
        let analysis = GuardianLoginAnalyzer.analyze(context())
        let names = Set(analysis.items.map(\.name))
        #expect(!names.contains("Example Browser")) // opened from the Dock
        #expect(!names.contains("Notes"))           // part of macOS
        #expect(!names.contains("Late"))            // ten minutes later
        #expect(!names.contains("Mac Cleaner"))     // itself
        #expect(!names.contains("late-tool"))
        #expect(!names.contains("com.example.daemon")) // another user (root)
        #expect(!names.contains("Something"))
        #expect(!names.contains("crashpad_handler"))
        #expect(!analysis.items.contains { $0.path.hasPrefix("/Applications/Example Browser.app") })
        #expect(analysis.openedByYouCount == 1)
        #expect(analysis.hasLaunchParents)
        #expect(analysis.isComplete)
        // Apps first, then background programs; each group in the order they started.
        let firstProgram = analysis.items.firstIndex { !$0.isApp } ?? analysis.items.count
        #expect(analysis.items[..<firstProgram].allSatisfy { $0.isApp })
        #expect(analysis.items[firstProgram...].allSatisfy { !$0.isApp })
        #expect(analysis.apps.map(\.started) == analysis.apps.map(\.started).sorted())
        #expect(analysis.backgroundPrograms.map(\.started) == analysis.backgroundPrograms.map(\.started).sorted())
        #expect(Set(analysis.apps.map(\.name)) == ["MenuMeter", "Music Player", "PortThing", "Editor", "Notebook", "Content Manager"])
    }

    @Test func withoutLaunchParentsCausesComeFromStartupItems() {
        var context = context()
        context.appInfo = []
        let analysis = GuardianLoginAnalyzer.analyze(context)
        let causes = Dictionary(analysis.items.map { ($0.name, $0.cause) }, uniquingKeysWith: { first, _ in first })
        #expect(!analysis.hasLaunchParents)
        #expect(causes["Editor"] == .reopened)
        #expect(causes["Notebook"] == .loginItem)
        #expect(causes["MenuMeter"] == .unknown)
        // Without launch parents, an app opened from the Dock can't be told apart and is listed as unknown.
        #expect(causes["Example Browser"] == .unknown)
    }

    @Test func appLoginItemsBecomeStartupRecords() {
        var analysis = GuardianLoginAnalyzer.analyze(context())
        analysis.items[analysis.items.firstIndex { $0.name == "MenuMeter" }!].signature = GuardianSignatureSummary(category: .developerIDNotarized, developer: "Example Dev")
        let records = GuardianLoginAnalyzer.appLoginRecords(analysis)
        #expect(records.map(\.name) == ["MenuMeter"])
        #expect(records.first?.id == "appLoginItems|pro.example.MenuMeter")
        #expect(records.first?.kind == .appLoginItem)
        #expect(records.first?.signature?.developer == "Example Dev")
    }

    @Test func appsWithWindowsComeBeforeMenuBarApps() {
        var context = context()
        if let index = context.apps.firstIndex(where: { $0.name == "MenuMeter" }) { context.apps[index].presentation = .menuBar }
        let apps = GuardianLoginAnalyzer.analyze(context).apps
        #expect(apps.last?.name == "MenuMeter")
        #expect(apps.last?.presentation == .menuBar)
    }

    @Test func lateAnalysisIsMarkedIncomplete() {
        var context = context()
        context.now = login.addingTimeInterval(3 * 3600)
        #expect(!GuardianLoginAnalyzer.analyze(context).isComplete)
    }

    @Test func causeTexts() {
        #expect(GuardianLoginCause.reopened.explanation.contains("open when you logged out"))
        #expect(GuardianLoginCause.appLoginItem.title == "Opens at login (set in the app)")
        #expect(GuardianLoginCause.openedByApp(name: "Raycast").explanation == "Opened by “Raycast”.")
    }
}
