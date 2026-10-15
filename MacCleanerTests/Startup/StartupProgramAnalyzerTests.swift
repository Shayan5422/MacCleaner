import Foundation
import Testing
@testable import MacCleaner

struct StartupProgramAnalyzerTests {
    /// A fake file system containing only `existing` paths.
    private func environment(_ existing: Set<String>, apps: [String: String] = [:]) -> LaunchdProgramAnalyzer.Environment {
        LaunchdProgramAnalyzer.Environment(
            fileExists: { existing.contains($0) },
            appPathForBundleIdentifier: { apps[$0] },
            home: "/Users/test"
        )
    }

    private func job(_ arguments: [String], program: String? = nil, workingDirectory: String? = nil) -> LaunchdJobDefinition {
        var job = LaunchdJobDefinition()
        job.label = "com.example.job"
        job.programArguments = arguments
        job.program = program
        job.workingDirectory = workingDirectory
        return job
    }

    @Test func plainProgramThatExists() {
        let analysis = LaunchdProgramAnalyzer.analyze(job(["/usr/local/bin/tool", "--flag"]), environment: environment(["/usr/local/bin/tool"]))
        #expect(analysis.executable == "/usr/local/bin/tool")
        #expect(analysis.targetKind == .program)
        #expect(analysis.targetPath == "/usr/local/bin/tool")
        #expect(analysis.targetExists)
        #expect(!analysis.isBroken)
        #expect(analysis.commandLine == "/usr/local/bin/tool --flag")
    }

    @Test func missingProgramIsBroken() {
        let analysis = LaunchdProgramAnalyzer.analyze(job(["/Applications/Gone.app/Contents/MacOS/Gone"]), environment: environment([]))
        #expect(analysis.isBroken)
        #expect(analysis.enclosingAppPath == "/Applications/Gone.app")
    }

    @Test func openWithAppPath() {
        let existing: Set<String> = ["/usr/bin/open", "/Applications/ClickShare.app"]
        let analysis = LaunchdProgramAnalyzer.analyze(
            job(["/usr/bin/open", "-a", "/Applications/ClickShare.app", "--args", "--minimized"]),
            environment: environment(existing)
        )
        #expect(analysis.isOpenCommand)
        #expect(analysis.targetKind == .application)
        #expect(analysis.targetPath == "/Applications/ClickShare.app")
        #expect(analysis.targetExists)
        #expect(!analysis.isBroken)
        #expect(analysis.targetDescription == "Opens ClickShare")
    }

    @Test func openWithMissingAppIsBroken() {
        let analysis = LaunchdProgramAnalyzer.analyze(
            job(["/usr/bin/open", "-a", "/Applications/Free Download Manager.app/Contents/MacOS/fdm", "--args", "--hidden"]),
            environment: environment(["/usr/bin/open"])
        )
        #expect(analysis.targetKind == .application)
        #expect(analysis.isBroken)
    }

    @Test func openResolvesAppNamesAndBundleIdentifiers() {
        let byName = LaunchdProgramAnalyzer.analyze(
            job(["/usr/bin/open", "-g", "-a", "Safari"]),
            environment: environment(["/usr/bin/open", "/System/Applications/Safari.app"])
        )
        #expect(byName.targetPath == "/System/Applications/Safari.app")
        #expect(byName.targetExists)

        let byIdentifier = LaunchdProgramAnalyzer.analyze(
            job(["/usr/bin/open", "-b", "com.example.app"]),
            environment: environment(["/usr/bin/open"], apps: ["com.example.app": "/Applications/Example.app"])
        )
        #expect(byIdentifier.targetPath == "/Applications/Example.app")
        #expect(byIdentifier.targetExists)

        let url = LaunchdProgramAnalyzer.analyze(job(["/usr/bin/open", "https://example.com"]), environment: environment(["/usr/bin/open"]))
        #expect(url.targetKind == .url)
        #expect(!url.isBroken)
    }

    @Test func shellWithInlineCode() {
        let analysis = LaunchdProgramAnalyzer.analyze(
            job(["/bin/zsh", "-lc", "cd ~/site && npm start"]),
            environment: environment(["/bin/zsh"])
        )
        #expect(analysis.interpreter == .shell)
        #expect(analysis.inlineCode == "cd ~/site && npm start")
        #expect(analysis.targetKind == .inlineCode)
        #expect(analysis.scriptPath == nil)
        #expect(!analysis.isBroken)
    }

    @Test func shellWithOptionValueBeforeInlineCode() {
        let analysis = LaunchdProgramAnalyzer.analyze(
            job(["/bin/bash", "-o", "pipefail", "-c", "echo hi"]),
            environment: environment(["/bin/bash"])
        )
        #expect(analysis.inlineCode == "echo hi")
    }

    @Test func shellRunningAScript() {
        let analysis = LaunchdProgramAnalyzer.analyze(
            job(["/bin/bash", "/Users/test/bin/sync.sh", "--quiet"]),
            environment: environment(["/bin/bash", "/Users/test/bin/sync.sh"])
        )
        #expect(analysis.targetKind == .script)
        #expect(analysis.scriptPath == "/Users/test/bin/sync.sh")
        #expect(analysis.targetExists)
    }

    @Test func pythonModuleInlineAndRelativeScript() {
        let module = LaunchdProgramAnalyzer.analyze(
            job(["/Users/test/.venv/bin/python", "-m", "service.main", "run"]),
            environment: environment(["/Users/test/.venv/bin/python"])
        )
        #expect(module.interpreter == .python)
        #expect(module.moduleName == "service.main")
        #expect(module.targetKind == .program)

        let inline = LaunchdProgramAnalyzer.analyze(job(["/usr/bin/python3", "-c", "print(1)"]), environment: environment(["/usr/bin/python3"]))
        #expect(inline.inlineCode == "print(1)")

        let relative = LaunchdProgramAnalyzer.analyze(
            job(["/opt/homebrew/bin/node", "server.js"], workingDirectory: "/Users/test/app"),
            environment: environment(["/opt/homebrew/bin/node", "/Users/test/app/server.js"])
        )
        #expect(relative.interpreter == .node)
        #expect(relative.scriptPath == "/Users/test/app/server.js")
        #expect(relative.targetExists)
    }

    @Test func osascriptStatementsAreCollected() {
        let analysis = LaunchdProgramAnalyzer.analyze(
            job(["/usr/bin/osascript", "-e", "do shell script \"id\"", "-e", "return 1"]),
            environment: environment(["/usr/bin/osascript"])
        )
        #expect(analysis.interpreter == .osascript)
        #expect(analysis.inlineCode == "do shell script \"id\"\nreturn 1")
    }

    @Test func envWrapperIsSkipped() {
        let analysis = LaunchdProgramAnalyzer.analyze(
            job(["/usr/bin/env", "-i", "PATH=/usr/bin", "python3", "/Users/test/job.py"]),
            environment: environment(["/usr/bin/env", "/usr/bin/python3", "/Users/test/job.py"])
        )
        #expect(analysis.executable == "/usr/bin/python3")
        #expect(analysis.interpreter == .python)
        #expect(analysis.scriptPath == "/Users/test/job.py")
    }

    @Test func bundleProgramResolvesInsideTheApp() {
        var definition = LaunchdJobDefinition()
        definition.label = "com.example.helper"
        definition.bundleProgram = "Contents/Frameworks/Helper.framework/Helper"
        definition.programArguments = ["Contents/Frameworks/Helper.framework/Helper", "background"]
        let plist = "/Applications/Example.app/Contents/Library/LaunchAgents/com.example.helper.plist"
        let target = "/Applications/Example.app/Contents/Frameworks/Helper.framework/Helper"
        let analysis = LaunchdProgramAnalyzer.analyze(definition, plistPath: plist, environment: environment([target]))
        #expect(analysis.executable == target)
        #expect(analysis.targetExists)
        #expect(analysis.enclosingAppPath == "/Applications/Example.app")
    }

    @Test func interpreterNamesWithVersions() {
        #expect(LaunchdInterpreterKind.from(executableName: "/usr/local/bin/python3.12") == .python)
        #expect(LaunchdInterpreterKind.from(executableName: "perl5.30") == .perl)
        #expect(LaunchdInterpreterKind.from(executableName: "/bin/sh") == .shell)
        #expect(LaunchdInterpreterKind.from(executableName: "tclsh8.6") == .tcl)
        #expect(LaunchdInterpreterKind.from(executableName: "/usr/bin/ssh") == nil)
        #expect(LaunchdInterpreterKind.from(executableName: "shasum") == nil)
    }

    @Test func appBundleHelpers() {
        let path = "/Applications/Spotify.app/Contents/Library/LoginItems/StartUpHelper.app/Contents/MacOS/StartUpHelper"
        #expect(LaunchdProgramAnalyzer.outermostAppBundle(in: path) == "/Applications/Spotify.app")
        #expect(LaunchdProgramAnalyzer.innermostAppBundle(in: path) == "/Applications/Spotify.app/Contents/Library/LoginItems/StartUpHelper.app")
        #expect(LaunchdProgramAnalyzer.outermostAppBundle(in: "/usr/bin/true") == nil)
    }
}
