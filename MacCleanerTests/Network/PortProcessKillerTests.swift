import Darwin
import Foundation
import Testing
@testable import MacCleaner

// PortProcessKiller against real processes. Every process here is a `/bin/sleep` the test starts itself in its own
// session, and the test kills its whole process group before returning.

extension PortLiveProcessTests {
    @Suite struct PortProcessKillerTests {

        /// Starts `/bin/sh -c <script>` as a session leader (pgid == pid), like a daemonized process manager. Its stdio
        /// is /dev/null and it inherits no other descriptors, so it never holds the test runner's output pipes.
        private func spawnSessionLeader(_ script: String) throws -> pid_t {
            var attributes: posix_spawnattr_t?
            guard posix_spawnattr_init(&attributes) == 0 else { throw PortTestError("posix_spawnattr_init failed") }
            defer { posix_spawnattr_destroy(&attributes) }
            #expect(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0)
            var fileActions: posix_spawn_file_actions_t?
            guard posix_spawn_file_actions_init(&fileActions) == 0 else { throw PortTestError("posix_spawn_file_actions_init failed") }
            defer { posix_spawn_file_actions_destroy(&fileActions) }
            for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
                #expect(posix_spawn_file_actions_addopen(&fileActions, descriptor, "/dev/null",
                                                                descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0) == 0)
            }
            let arguments: [String] = ["/bin/sh", "-c", script]
            let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
            defer { argv.forEach { free($0) } }
            var pid: pid_t = 0
            let status = posix_spawn(&pid, "/bin/sh", &fileActions, &attributes, argv, environ)
            guard status == 0, pid > 0 else { throw PortTestError("posix_spawn failed: \(status)") }
            return pid
        }

        private func endGroup(_ pid: pid_t) {
            kill(-pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        }

        /// Finding #9: the PM2 God Daemon is the cluster primary, and pm2 daemonizes it, so it leads a process group
        /// that also holds the cluster workers. Even a plan that names it must neither signal it nor its group.
        @Test func killerNeverSignalsAPM2DaemonOrItsProcessGroup() async throws {
            // The worker is a plain `sh -c` (not a protected process) that blocks opening a FIFO nobody writes to.
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacCleanerNetworkTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fifo = directory.appendingPathComponent("never-written").path
            #expect(mkfifo(fifo, 0o600) == 0)

            let daemonPID = try spawnSessionLeader(
                "/bin/sh -c 'read line < \"\(fifo)\"; :' & "
                    + "exec -a 'PM2 v5.4.3: God Daemon (/tmp/mac-cleaner-network-tests)' /bin/sleep 30")
            defer { endGroup(daemonPID) }
            func groupMembers() -> [PortProcessBasic] { PortSysProc.allProcesses().filter { $0.pgid == daemonPID } }   // no zombies

            var daemon: PortProcessBasic?
            for _ in 0..<60 {
                if let basic = PortSysProc.basic(pid: daemonPID), PortPM2Service.isDaemon(basic, details: PortSysProc.details(for: basic)),
                   groupMembers().count == 2 {
                    daemon = basic
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let leader = try #require(daemon, "the stand-in daemon never took its title")
            #expect(leader.pgid == leader.pid)
            let worker = try #require(groupMembers().first { $0.pid != daemonPID })
            #expect(!(PortKillPlanner.isProtected(worker, details: PortSysProc.details(for: worker))), "only the daemon itself may stop the group signal")

            let plan = PortKillPlan(root: leader, targets: [leader], summary: [], requiresAdmin: false, warnings: [])
            let result = await PortProcessKiller().stop(plan, mode: .graceful, timeout: 0.5, allowAdmin: false)
            try await Task.sleep(nanoseconds: 200_000_000)

            #expect(result.stopped == [])
            #expect(result.failures.map(\.pid) == [daemonPID])
            #expect(PortSysProc.basic(pid: daemonPID) != nil, "the daemon is still running")
            #expect(groupMembers().map(\.pid).sorted() == [daemonPID, worker.pid].sorted(), "and so is its worker")
        }

        /// Apps and macOS services are stopped with `escalate: false`: a target that ignores SIGTERM is reported as
        /// still running and never gets SIGKILL (neither it nor its process group). The default still escalates.
        @Test func gracefulStopWithoutEscalationNeverSendsSIGKILL() async throws {
            // An ignored signal stays ignored across exec, so this `sleep` shrugs off SIGTERM.
            let pid = try spawnSessionLeader("trap '' TERM; exec /bin/sleep 30")
            defer { endGroup(pid) }
            var sleeper: PortProcessBasic?
            for _ in 0..<60 {
                if let basic = PortSysProc.basic(pid: pid), basic.comm == "sleep" {
                    sleeper = basic
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let target = try #require(sleeper, "the test process never exec'd into sleep")
            let plan = PortKillPlan(root: target, targets: [target], summary: [], requiresAdmin: false, warnings: [])

            let gentle = await PortProcessKiller(killGracePeriod: 0.5)
                .stop(plan, mode: .graceful, timeout: 0.3, allowAdmin: false, escalate: false)
            #expect(!gentle.escalated)
            #expect(gentle.stopped == [])
            #expect(gentle.failures == [PortStopFailure(pid: pid, reason: "Still running — use Force Stop")])
            #expect(PortSysProc.basic(pid: pid)?.startTime == target.startTime, "still the same, running process")

            let escalating = await PortProcessKiller(killGracePeriod: 2)
                .stop(plan, mode: .graceful, timeout: 0.3, allowAdmin: false)
            #expect(escalating.escalated)
            #expect(escalating.stopped == [pid])
        }
    }
}
