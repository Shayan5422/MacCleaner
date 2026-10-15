import Foundation
import Testing
@testable import MacCleaner

struct StartupLaunchctlParserTests {
    /// Trimmed `launchctl print gui/501/homebrew.mxcl.redis` output (macOS 15+ format).
    static let runningService = """
    gui/501/homebrew.mxcl.redis = {
    \tactive count = 1
    \tpath = /Users/test/Library/LaunchAgents/homebrew.mxcl.redis.plist
    \ttype = LaunchAgent
    \tstate = running

    \tprogram = /opt/homebrew/opt/redis/bin/redis-server
    \targuments = {
    \t\t/opt/homebrew/opt/redis/bin/redis-server
    \t\t/opt/homebrew/etc/redis.conf
    \t}

    \tworking directory = /opt/homebrew/var
    \tenvironment = {
    \t\tXPC_SERVICE_NAME => homebrew.mxcl.redis
    \t}

    \tdomain = gui/501 [100020]
    \truns = 1
    \tpid = 968
    \timmediate reason = speculative
    \tlast exit code = (never exited)

    \tresource coalition = {
    \t\tID = 1060
    \t\tstate = active
    \t}
    }
    """

    static let exitedService = """
    gui/501/com.example.updater = {
    \tactive count = 0
    \tpath = /Users/test/Library/LaunchAgents/com.example.updater.plist
    \ttype = LaunchAgent
    \tstate = not running
    \tprogram = /Users/test/Library/Application Support/Example/Updater.app/Contents/MacOS/Updater
    \truns = 117
    \tlast exit code = 78: EX_CONFIG
    \tlast terminating signal = Terminated: 15
    \trun interval = 3600 seconds
    \tjob state = exited
    }
    """

    @Test func parsesARunningService() {
        let info = LaunchctlParser.parseService(Self.runningService, label: "homebrew.mxcl.redis")
        #expect(info.state == "running")
        #expect(info.pid == 968)
        #expect(info.isRunning)
        #expect(info.runs == 1)
        #expect(info.path == "/Users/test/Library/LaunchAgents/homebrew.mxcl.redis.plist")
        #expect(info.program == "/opt/homebrew/opt/redis/bin/redis-server")
        #expect(info.type == "LaunchAgent")
        #expect(info.lastExitDescription == "(never exited)")
        #expect(info.lastExitCode == nil)
        #expect(info.lastExitSummary == "Hasn't exited since it started")
        // Nested blocks ("state = active" inside resource coalition) are ignored.
        #expect(!info.properties.contains { $0.key == "ID" })
    }

    @Test func parsesAnExitedServiceWithAnErrorCode() {
        let info = LaunchctlParser.parseService(Self.exitedService, label: "com.example.updater")
        #expect(info.state == "not running")
        #expect(info.pid == nil)
        #expect(!info.isRunning)
        #expect(info.runs == 117)
        #expect(info.lastExitCode == 78)
        #expect(info.lastExitSummary == "Last exit: error 78: EX_CONFIG")
        #expect(info.lastTerminatingSignal == "Terminated: 15")
        #expect(info.program?.hasSuffix("Updater.app/Contents/MacOS/Updater") == true)
    }

    @Test func parsesDisabledOverridesInBothFormats() {
        let output = """
        \tdisabled services = {
        \t\t"org.pqrs.service.agent.Karabiner-Menu" => enabled
        \t\t"us.zoom.updater" => disabled
        \t\t"com.example.legacy-on" => false
        \t\t"com.example.legacy-off" => true
        \t\t"com.example.weird" => maybe
        \t}
        """
        let overrides = LaunchctlParser.parseDisabled(output)
        #expect(overrides["org.pqrs.service.agent.Karabiner-Menu"] == false)
        #expect(overrides["us.zoom.updater"] == true)
        #expect(overrides["com.example.legacy-on"] == false)
        #expect(overrides["com.example.legacy-off"] == true)
        #expect(overrides["com.example.weird"] == nil)
        #expect(overrides.count == 4)
    }

    @Test func parsesTheDomainServiceTable() {
        let output = """
        gui/501 = {
        \ttype = gui
        \tservices = {
        \t\t     752      - \tcom.apple.syncdefaultsd
        \t\t       0      0 \tcom.example.updater
        \t\t       0      - \tcom.example.idle
        \t\t    1569     -9 \tcom.example.crashed
        \t\t   74446      - \tapplication.com.apple.mail.1152921500311887790.1152921500311887795
        \t}

        \tunmanaged processes = {
        \t\tcom.apple.xpc.launchd.unmanaged.loginwindow.123
        \t}
        }
        """
        let services = LaunchctlParser.parseServiceList(output)
        #expect(services.count == 5)
        #expect(services["com.apple.syncdefaultsd"]?.pid == 752)
        #expect(services["com.apple.syncdefaultsd"]?.lastExitStatus == nil)
        #expect(services["com.example.updater"]?.pid == nil)
        #expect(services["com.example.updater"]?.lastExitStatus == 0)
        #expect(services["com.example.idle"] != nil)
        #expect(services["com.example.crashed"]?.lastExitStatus == -9)
        #expect(services["com.apple.xpc.launchd.unmanaged.loginwindow.123"] == nil)
    }

    @Test func emptyOrUnexpectedOutputYieldsNothing() {
        #expect(LaunchctlParser.parseServiceList("Bad request.\nCould not find domain").isEmpty)
        #expect(LaunchctlParser.parseDisabled("").isEmpty)
        let info = LaunchctlParser.parseService("Bad request.", label: "x")
        #expect(info.state == nil && info.pid == nil)
    }

    @Test func labelValidationProtectsAppleAndRejectsPaths() {
        #expect(LaunchctlClient.isValidLabel("com.example.agent"))
        #expect(!LaunchctlClient.isValidLabel(""))
        #expect(!LaunchctlClient.isValidLabel("gui/501/com.example"))
        #expect(!LaunchctlClient.isValidLabel("com.example\nagent"))
        #expect(LaunchctlClient.isProtectedLabel("com.apple.Siri.agent"))
        #expect(LaunchctlClient.isProtectedLabel("COM.APPLE.something"))
        #expect(!LaunchctlClient.isProtectedLabel("com.applesauce.agent"))
        #expect(throws: LaunchctlError.self) { try LaunchctlClient.validateUserAgentLabel("com.apple.mdworker") }
        #expect(throws: Never.self) { try LaunchctlClient.validateUserAgentLabel("com.example.agent") }
    }

    @Test func onlyPlistsDirectlyInsideTheUserLaunchAgentsFolderAreAccepted() {
        let folder = LaunchdLocations.userAgentsFolder
        #expect(throws: Never.self) { try LaunchctlClient.validateUserAgentPlist(folder + "/com.example.agent.plist") }
        #expect(throws: LaunchctlError.self) { try LaunchctlClient.validateUserAgentPlist("/Library/LaunchAgents/com.example.agent.plist") }
        #expect(throws: LaunchctlError.self) { try LaunchctlClient.validateUserAgentPlist(folder + "/nested/com.example.agent.plist") }
        #expect(throws: LaunchctlError.self) { try LaunchctlClient.validateUserAgentPlist(folder + "/../LaunchAgents2/x.plist") }
    }

    @Test func domainTargets() {
        #expect(LaunchdDomain.gui(501).target == "gui/501")
        #expect(LaunchdDomain.gui(501).serviceTarget("com.example") == "gui/501/com.example")
        #expect(LaunchdDomain.system.serviceTarget("com.example.daemon") == "system/com.example.daemon")
    }
}
