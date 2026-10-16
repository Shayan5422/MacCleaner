import Darwin
import Foundation
import Testing
@testable import MacCleaner

// Relaunch / Undo (findings #3 and #43). The spawn tests only start tiny processes the test owns (/bin/sh scripts
// in a temporary folder) and kill them before returning.

extension PortLiveProcessTests {
    @Suite struct PortRelauncherTests {
        private let nodeExe = "/opt/homebrew/Cellar/node/25.4.0/bin/node"
        private let project = "/Users/me/code/my-app"

        private func temporaryDirectory() throws -> URL {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("PortPilotTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }

        private func record(_ arguments: [String], executable: String?, environment: [String: String] = [:],
                            cwd: String? = nil, manager: PortProcessManager = .none) -> PortStoppedRecord {
            PortStoppedRecord(id: UUID(), date: Date(), title: "my-app · test", ports: [], cwd: cwd, arguments: arguments,
                          environment: environment, executablePath: executable, manager: manager)
        }

        // MARK: Title detection

        @Test func titleRewrittenArgv() {
            #expect(PortRelauncher.isTitleRewritten(["npm run dev", "", "", ""], executablePath: nodeExe))
            #expect(PortRelauncher.isTitleRewritten(["npm exec next start"], executablePath: nodeExe))
            #expect(PortRelauncher.isTitleRewritten(["nginx: master process /opt/homebrew/bin/nginx -c x.conf"],
                                                      executablePath: "/opt/homebrew/bin/nginx"))
            #expect(PortRelauncher.isTitleRewritten(["next-server (v16.4.0)", "", "", "", ""]))
            #expect(!(PortRelauncher.isTitleRewritten(["node", "server.js"], executablePath: nodeExe)))
            #expect(!(PortRelauncher.isTitleRewritten(["/Applications/My App.app/Contents/MacOS/My App", ""])))
            #expect(!(PortRelauncher.isTitleRewritten(["my tool", "--port", "3000"])), "real arguments follow")
            #expect(!(PortRelauncher.isTitleRewritten(["my tool"], executablePath: "/usr/local/bin/my tool")))
            #expect(!(PortRelauncher.isTitleRewritten([])))
        }

        @Test func commandFromTitle() {
            #expect(PortRelauncher.commandFromTitle("npm run dev") == ["npm", "run", "dev"])
            #expect(PortRelauncher.commandFromTitle("npm exec next start") == ["npm", "exec", "next", "start"])
            #expect(PortRelauncher.commandFromTitle(" pnpm  dev ") == ["pnpm", "dev"])
            #expect(PortRelauncher.commandFromTitle("nginx: master process /opt/homebrew/bin/nginx") == nil)
            #expect(PortRelauncher.commandFromTitle("next-server (v16.4.0)") == nil)
            #expect(PortRelauncher.commandFromTitle("PM2 v5.4.3: God Daemon (/Users/me/.pm2)") == nil)
        }

        // MARK: Picking the command for a stopped plan

        private struct Tree {
            var details: [Int32: PortProcessDetails] = [:]
            var basics: [Int32: PortProcessBasic] = [:]

            mutating func add(_ pid: Int32, ppid: Int32, args: [String], exe: String?, env: [String: String] = [:],
                              cwd: String? = nil) {
                let basic = PortProcessBasic(pid: pid, ppid: ppid, pgid: pid, uid: 501, comm: "x", startTime: UInt64(pid))
                basics[pid] = basic
                details[pid] = PortProcessDetails(identity: basic.identity, executablePath: exe, arguments: args,
                                              environment: env, cwd: cwd)
            }

            func plan(root: Int32, targets: [Int32]) -> PortKillPlan {
                PortKillPlan(root: basics[root]!, targets: targets.compactMap { basics[$0] }, summary: [], requiresAdmin: false,
                         warnings: [])
            }

            func lookup(_ basic: PortProcessBasic) -> PortProcessDetails? { details[basic.pid] }
        }

        @Test func npmPlanRelaunchesTheScriptShellWithNpmsEnvironment() throws {
            var tree = Tree()
            let npmEnv = ["PATH": "\(project)/node_modules/.bin:/opt/homebrew/bin:/usr/bin:/bin", "npm_lifecycle_event": "dev"]
            tree.add(10, ppid: 1, args: ["npm run dev", "", "", ""], exe: nodeExe, cwd: project)   // env lost with argv
            tree.add(11, ppid: 10, args: ["sh", "-c", "vite --port 5173"], exe: "/bin/sh", env: npmEnv, cwd: project)
            tree.add(12, ppid: 11, args: ["node", "\(project)/node_modules/.bin/vite", "--port", "5173"], exe: nodeExe,
                     env: npmEnv, cwd: project)
            tree.add(13, ppid: 12, args: ["\(project)/node_modules/@esbuild/darwin-arm64/bin/esbuild", "--ping"],
                     exe: "\(project)/node_modules/@esbuild/darwin-arm64/bin/esbuild", env: npmEnv, cwd: project)

            let command = try #require(PortRelauncher.relaunchCommand(for: tree.plan(root: 10, targets: [13, 12, 11, 10]),
                                                                   details: tree.lookup))
            #expect(command == PortRelaunchCommand(arguments: ["sh", "-c", "vite --port 5173"], environment: npmEnv,
                                                    executablePath: "/bin/sh", cwd: project))

            // macOS returns no environment for Apple's /bin/sh (seen on a real npm tree): the dev server below it
            // still carries npm's environment, so that one is used.
            var platformShell = tree
            platformShell.add(11, ppid: 10, args: ["sh", "-c", "vite --port 5173"], exe: "/bin/bash", env: [:], cwd: project)
            let fromServer = try #require(PortRelauncher.relaunchCommand(for: platformShell.plan(root: 10, targets: [13, 12, 11, 10]),
                                                                      details: platformShell.lookup))
            #expect(fromServer.arguments == ["sh", "-c", "vite --port 5173"])
            #expect(fromServer.environment == npmEnv)
        }

        @Test func intactRootIsKeptAsIs() throws {
            var tree = Tree()
            tree.add(20, ppid: 1, args: ["node", "/opt/homebrew/bin/npm", "run", "dev"], exe: nodeExe, env: ["A": "1"],
                     cwd: project)
            tree.add(21, ppid: 20, args: ["sh", "-c", "vite"], exe: "/bin/sh", cwd: project)
            let command = try #require(PortRelauncher.relaunchCommand(for: tree.plan(root: 20, targets: [21, 20]),
                                                                   details: tree.lookup))
            #expect(command.arguments == ["node", "/opt/homebrew/bin/npm", "run", "dev"])
            #expect(command.executablePath == nodeExe)
            #expect(command.environment == ["A": "1"])

            // Apple's /usr/bin/make shows no environment: the server below it still has the project's.
            var make = Tree()
            make.add(25, ppid: 1, args: ["make", "dev"], exe: "/usr/bin/make", cwd: project)
            make.add(26, ppid: 25, args: ["/bin/sh", "-c", "node server.js"], exe: "/bin/bash", cwd: project)
            make.add(27, ppid: 26, args: ["node", "server.js"], exe: nodeExe, env: ["PORT": "4000"], cwd: project)
            let fromMake = try #require(PortRelauncher.relaunchCommand(for: make.plan(root: 25, targets: [27, 26, 25]),
                                                                    details: make.lookup))
            #expect(fromMake == PortRelaunchCommand(arguments: ["make", "dev"], environment: ["PORT": "4000"],
                                                     executablePath: "/usr/bin/make", cwd: project))
        }

        @Test func severalChildrenFallBackToTheRebuiltTitle() throws {
            var tree = Tree()
            let env = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"]
            tree.add(30, ppid: 1, args: ["npm run dev", "", ""], exe: nodeExe, cwd: project)
            tree.add(31, ppid: 30, args: ["node", "web.js"], exe: nodeExe, env: env, cwd: project)
            tree.add(32, ppid: 30, args: ["node", "api.js"], exe: nodeExe, env: env, cwd: project)
            let command = try #require(PortRelauncher.relaunchCommand(for: tree.plan(root: 30, targets: [32, 31, 30]),
                                                                   details: tree.lookup))
            #expect(command == PortRelaunchCommand(arguments: ["npm", "run", "dev"], environment: env, executablePath: nil,
                                                    cwd: project))
        }

        @Test func unknownTitleWithoutAnIntactChildIsNotRelaunchable() {
            var tree = Tree()
            tree.add(40, ppid: 1, args: ["nginx: master process /opt/homebrew/bin/nginx -c /x/nginx.conf"],
                     exe: "/opt/homebrew/bin/nginx")
            tree.add(41, ppid: 40, args: ["nginx: worker process", ""], exe: "/opt/homebrew/bin/nginx")
            #expect(PortRelauncher.relaunchCommand(for: tree.plan(root: 40, targets: [41, 40]), details: tree.lookup) == nil)
        }

        // MARK: relaunch()

        @Test func relaunchRefusesATitleItCannotRebuild() throws {
            let logs = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: logs) }
            let titled = record(["nginx: master process /opt/homebrew/bin/nginx -c /x/nginx.conf"],
                                executable: "/opt/homebrew/bin/nginx", cwd: "/tmp")
            do {
                _ = try PortRelauncher.relaunch(titled, logDirectory: logs, settleTime: 0)
                Issue.record("a title it can't rebuild must not be relaunched")
            } catch {
                #expect(error.localizedDescription.contains("renamed itself"), "\(error.localizedDescription)")
            }
        }

        @Test func relaunchRebuildsNpmTitleAndFindsTheToolOnTheRecordsPATH() throws {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            // A stand-in "npm" that records its arguments and stays up like a dev server.
            let bin = directory.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let marker = directory.appendingPathComponent("args.txt")
            let npm = bin.appendingPathComponent("npm")
            try "#!/bin/sh\necho \"$@\" > '\(marker.path)'\nexec /bin/sleep 30\n".write(to: npm, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: npm.path)

            let titled = record(["npm run dev", "", "", ""], executable: nodeExe,
                                environment: ["PATH": bin.path + ":/usr/bin:/bin", "HOME": NSHomeDirectory()],
                                cwd: directory.path)
            let pid = try PortRelauncher.relaunch(titled, logDirectory: directory, settleTime: 0.5)
            defer { kill(pid, SIGKILL) }
            #expect(pid > 0)
            #expect(try String(contentsOf: marker, encoding: .utf8) == "run dev\n")
            let log = try String(contentsOf: PortRelauncher.logFileURL(forTitle: titled.title, in: directory), encoding: .utf8)
            #expect(log.contains("$ npm run dev\n"), "\(log)")
        }

        @Test func relaunchReportsAProcessThatExitsRightAway() throws {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let failing = record(["/bin/sh", "-c", "echo boom; exit 3"], executable: "/bin/sh",
                                 environment: ["PATH": "/usr/bin:/bin"], cwd: directory.path)
            do {
                _ = try PortRelauncher.relaunch(failing, logDirectory: directory, settleTime: 3)
                Issue.record("a process that exits right away must be reported")
            } catch {
                #expect(error.localizedDescription.contains("exited right after starting (exit code 3)"), "\(error.localizedDescription)")
            }
            let log = try String(contentsOf: PortRelauncher.logFileURL(forTitle: failing.title, in: directory), encoding: .utf8)
            #expect(log.contains("boom"), "the output is in the log the error points to")

            // A record whose environment could not be read still gets a usable PATH (not launchd's minimal one).
            let noEnvironment = record(["sh", "-c", "exec sleep 30"], executable: nil, cwd: directory.path)
            let pid = try PortRelauncher.relaunch(noEnvironment, logDirectory: directory, settleTime: 0.3)
            kill(pid, SIGKILL)
            #expect(PortRelauncher.fallbackEnvironment()["PATH"]?.contains("/usr/bin") == true)
            #expect(PortRelauncher.fallbackEnvironment()["XPC_SERVICE_NAME"] == nil)
        }

        @Test func childExitDecoding() {
            #expect(PortChildExit(waitStatus: 0) == .exited(code: 0))
            #expect(PortChildExit(waitStatus: 3 << 8) == .exited(code: 3))
            #expect(PortChildExit(waitStatus: SIGTERM) == .signaled(SIGTERM))
            #expect(PortChildExit(waitStatus: SIGKILL | 0x80) == .signaled(SIGKILL), "core-dump flag ignored")
            #expect(PortChildExit.exited(code: 1).description == "exit code 1")
        }
    }
}
