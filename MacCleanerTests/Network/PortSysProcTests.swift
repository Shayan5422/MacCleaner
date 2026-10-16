import Darwin
import Foundation
import Testing
@testable import MacCleaner

extension PortLiveProcessTests {
    @Suite struct PortSysProcTests {

        // MARK: - Process table

        @Test func allProcessesContainsSelfWithCorrectParent() throws {
            let processes = PortSysProc.allProcesses()
            #expect(processes.count > 10)
            #expect(!(processes.contains { $0.pid == 0 }), "kernel_task (pid 0) must be skipped")

            let me = try #require(processes.first { $0.pid == getpid() })
            #expect(me.ppid == getppid())
            #expect(me.pgid == getpgrp())
            #expect(me.uid == geteuid())
            #expect(!me.comm.isEmpty)
            #expect(me.comm.utf8.count <= 16)
            #expect(me.startDate <= Date())
            #expect(me.startDate > Date(timeIntervalSinceNow: -86_400 * 30))
        }

        @Test func basicMatchesProcessTableEntry() throws {
            let fromTable = try #require(PortSysProc.allProcesses().first { $0.pid == getpid() })
            let single = try #require(PortSysProc.basic(pid: getpid()))
            #expect(single == fromTable)
            #expect(PortSysProc.basic(pid: Int32.max) == nil, "a pid that cannot exist must be reported as gone")
            #expect(PortSysProc.basic(pid: 0) == nil)
        }

        @Test func currentUID() {
            #expect(PortSysProc.currentUID == geteuid())
        }

        // MARK: - Arguments, environment, cwd, path

        @Test func argumentsAndEnvironmentOfSelf() throws {
            let result = try #require(PortSysProc.argumentsAndEnvironment(pid: getpid()))
            #expect(result.arguments == CommandLine.arguments)
            let path = try #require(result.environment["PATH"])
            #expect(!path.isEmpty)
        }

        @Test func argumentsOfOtherUsersProcessAreUnavailable() throws {
            guard geteuid() != 0 else { return }  // root can inspect every process
            #expect(PortSysProc.argumentsAndEnvironment(pid: 1) == nil)
        }

        @Test func executablePathAndCurrentDirectoryOfSelf() throws {
            let path = try #require(PortSysProc.executablePath(pid: getpid()))
            let expected = try #require(Bundle.main.executablePath)
            #expect(resolved(path) == resolved(expected))

            let cwd = try #require(PortSysProc.currentDirectory(pid: getpid()))
            #expect(resolved(cwd) == resolved(FileManager.default.currentDirectoryPath))
        }

        @Test func detailsOfSelf() throws {
            let me = try #require(PortSysProc.basic(pid: getpid()))
            let details = try #require(PortSysProc.details(for: me))
            #expect(details.identity == me.identity)
            #expect(details.arguments == CommandLine.arguments)
            #expect(details.environment["PATH"] != nil)
            #expect(resolved(details.executablePath ?? "") == resolved(Bundle.main.executablePath ?? "-"))
            #expect(resolved(details.cwd ?? "") == resolved(FileManager.default.currentDirectoryPath))
        }

        @Test func detailsRejectsRecycledIdentity() throws {
            let me = try #require(PortSysProc.basic(pid: getpid()))
            let stale = PortProcessBasic(pid: me.pid, ppid: me.ppid, pgid: me.pgid, uid: me.uid,
                                     comm: me.comm, startTime: me.startTime &+ 1)
            #expect(PortSysProc.details(for: stale) == nil, "details must never describe a different process on the same pid")
        }

        // MARK: - KERN_PROCARGS2 parsing

        @Test func parseProcArgsLayout() throws {
            let buffer = Self.procArgsBuffer(argc: 3,
                                             execPath: "/opt/homebrew/bin/node",
                                             padding: 5,
                                             arguments: ["node", "", "server.js"],
                                             environment: ["PATH=/usr/bin", "EQ=a=b", "PATH=/shadowed", "NOEQUALS"],
                                             trailer: ["executable_path=/opt/homebrew/bin/node", "ptr_munge="])
            let parsed = try #require(buffer.withUnsafeBytes { PortSysProc.parseProcArgs($0) })
            #expect(parsed.arguments == ["node", "", "server.js"])
            #expect(parsed.environment == ["PATH": "/usr/bin", "EQ": "a=b"])
        }

        @Test func parseProcArgsSurvivesTruncationAndGarbage() {
            let buffer = Self.procArgsBuffer(argc: 2, execPath: "/bin/x", padding: 3,
                                             arguments: ["x", "--flag"], environment: ["A=1", "B=2"], trailer: [])
            // Every truncation point must be handled without crashing or reading past the end.
            for length in 0...buffer.count {
                let prefix = Array(buffer.prefix(length))
                let parsed = prefix.withUnsafeBytes { PortSysProc.parseProcArgs($0) }
                if length < 4 { #expect(parsed == nil) }
                if let parsed {
                    #expect(parsed.arguments.count <= 2)
                    #expect(parsed.environment.allSatisfy { ["A", "B"].contains($0.key) })
                }
            }

            for argc in [Int32.min, -1, 0, 1_000_000, Int32.max] {
                var garbage = buffer
                withUnsafeBytes(of: argc.littleEndian) { garbage.replaceSubrange(0..<4, with: $0) }
                _ = garbage.withUnsafeBytes { PortSysProc.parseProcArgs($0) }
            }
            var noise = [UInt8](repeating: 0, count: 512)
            for index in noise.indices { noise[index] = UInt8(truncatingIfNeeded: index &* 37 &+ 11) }
            _ = noise.withUnsafeBytes { PortSysProc.parseProcArgs($0) }
        }

        // MARK: - Listening sockets

        @Test func listeningTCPSocketsFindsOwnIPv4Socket() throws {
            let listener = try PortTestListener(family: AF_INET, address: "127.0.0.1")
            defer { listener.close() }

            let sockets = try #require(PortSysProc.listeningTCPSockets(pid: getpid()))
            #expect(sockets.contains(PortListeningSocket(port: listener.port, address: "127.0.0.1",
                                                           family: .ipv4, pid: getpid())), "expected 127.0.0.1:\(listener.port) in \(sockets)")
            let ours = try #require(sockets.first { $0.port == listener.port })
            #expect(ours.isLoopbackOnly)
        }

        @Test func listeningTCPSocketsFindsOwnIPv6Socket() throws {
            let listener: PortTestListener
            do {
                listener = try PortTestListener(family: AF_INET6, address: "::1")
            } catch {
                return  // IPv6 loopback unavailable on this Mac
            }
            defer { listener.close() }

            let sockets = try #require(PortSysProc.listeningTCPSockets(pid: getpid()))
            #expect(sockets.contains(PortListeningSocket(port: listener.port, address: "::1",
                                                           family: .ipv6, pid: getpid())), "expected [::1]:\(listener.port) in \(sockets)")
        }

        /// Java NIO (Gradle, Spring, Netty, JetBrains) binds "127.0.0.1" through an AF_INET6 socket as ::ffff:127.0.0.1.
        /// The kernel turns that into a plain IPv4 PCB; it must be reported as loopback IPv4, not as exposed "::127.0.0.1".
        @Test func iPv4AddressOnIPv6SocketIsReportedAsIPv4() throws {
            let listener: PortTestListener
            do {
                listener = try PortTestListener(family: AF_INET6, address: "::ffff:127.0.0.1", v6Only: false)
            } catch {
                return  // v4-mapped bind unavailable on this Mac
            }
            defer { listener.close() }

            let sockets = try #require(PortSysProc.listeningTCPSockets(pid: getpid()))
            let ours = try #require(sockets.first { $0.port == listener.port }, "\(sockets)")
            #expect(ours == PortListeningSocket(port: listener.port, address: "127.0.0.1", family: .ipv4, pid: getpid()))
            #expect(ours.isLoopbackOnly)
            #expect(!ours.isExposed)

            if let all = PortSysProc.systemTCPListeners() {
                #expect(all.contains(ours), "the kernel PCB list must agree with libproc: \(all.filter { $0.pid == getpid() })")
            }
        }

        @Test func dualStackWildcardSocketStaysIPv6() throws {
            let listener: PortTestListener
            do {
                listener = try PortTestListener(family: AF_INET6, address: "::", v6Only: false)
            } catch {
                return  // IPv6 unavailable on this Mac
            }
            defer { listener.close() }
            let sockets = try #require(PortSysProc.listeningTCPSockets(pid: getpid()))
            #expect(sockets.contains(PortListeningSocket(port: listener.port, address: "*", family: .ipv6, pid: getpid())), "\(sockets)")
        }

        @Test func closedSocketIsNoLongerReported() throws {
            let listener = try PortTestListener(family: AF_INET, address: "127.0.0.1")
            let port = listener.port
            listener.close()
            let sockets = try #require(PortSysProc.listeningTCPSockets(pid: getpid()))
            #expect(!(sockets.contains { $0.port == port }))
        }

        @Test func listeningTCPSocketsOfOtherUsersProcessIsNil() throws {
            guard geteuid() != 0 else { return }  // root can inspect every process
            #expect(PortSysProc.listeningTCPSockets(pid: 1) == nil)
            #expect(PortSysProc.listeningTCPSockets(pid: Int32.max) == nil)
        }

        @Test func systemTCPListenersIncludesOwnSocket() throws {
            let listener = try PortTestListener(family: AF_INET, address: "127.0.0.1")
            defer { listener.close() }
            guard let all = PortSysProc.systemTCPListeners() else {
                // A test runner outside an app bundle gets an empty kernel list; the app itself gets the real one.
                return
            }
            #expect(all.contains(PortListeningSocket(port: listener.port, address: "127.0.0.1",
                                                       family: .ipv4, pid: getpid())))
        }

        // MARK: - Kernel PCB list parsing

        @Test func parsePCBListDecodesListenerRecords() throws {
            var list = PortPCBListBuilder()
            list.append(port: 8080, family: AF_INET, ipv4: [127, 0, 0, 1], pid: 4242, state: 1)
            list.append(port: 443, family: AF_INET, ipv4: [10, 0, 0, 2], pid: 4243, state: 4)   // ESTABLISHED
            list.append(port: 5432, family: AF_INET6, ipv6: Array(repeating: 0, count: 15) + [1], pid: 77, state: 1)
            list.append(port: 3000, family: AF_INET6, ipv6: Array(repeating: 0, count: 16), pid: 78, state: 1)
            let bytes = list.finish()

            let sockets = try #require(bytes.withUnsafeBytes { PortSysProc.parsePCBList($0) })
            #expect(sockets == [
                PortListeningSocket(port: 8080, address: "127.0.0.1", family: .ipv4, pid: 4242),
                PortListeningSocket(port: 5432, address: "::1", family: .ipv6, pid: 77),
                PortListeningSocket(port: 3000, address: "*", family: .ipv6, pid: 78),
            ])
        }

        @Test func parsePCBListUsesVersionFlagForIPv4OnIPv6Sockets() throws {
            let in4in6Loopback = Array(repeating: UInt8(0), count: 12) + [127, 0, 0, 1]
            var list = PortPCBListBuilder()
            // AF_INET6 socket bound to ::ffff:127.0.0.1: IPv4-only PCB (vflag 1), address stored as in4in6.
            list.append(port: 60237, family: AF_INET6, ipv6: in4in6Loopback, vflag: 0x1, pid: 16913, state: 1)
            // ::ffff:0.0.0.0 → IPv4 wildcard.
            list.append(port: 60238, family: AF_INET6, ipv6: Array(repeating: 0, count: 16), vflag: 0x1, pid: 16914, state: 1)
            // Dual-stack "::" (both flags) stays IPv6.
            list.append(port: 60239, family: AF_INET6, ipv6: Array(repeating: 0, count: 16), vflag: 0x3, pid: 16915, state: 1)
            // A real v4-mapped address on a dual-stack PCB still decodes as IPv4.
            list.append(port: 60240, family: AF_INET6, ipv6: Array(repeating: 0, count: 10) + [0xff, 0xff, 10, 0, 0, 7],
                        vflag: 0x3, pid: 16916, state: 1)
            let bytes = list.finish()

            let sockets = try #require(bytes.withUnsafeBytes { PortSysProc.parsePCBList($0) })
            #expect(sockets == [
                PortListeningSocket(port: 60237, address: "127.0.0.1", family: .ipv4, pid: 16913),
                PortListeningSocket(port: 60238, address: "*", family: .ipv4, pid: 16914),
                PortListeningSocket(port: 60239, address: "*", family: .ipv6, pid: 16915),
                PortListeningSocket(port: 60240, address: "10.0.0.7", family: .ipv4, pid: 16916),
            ])
            #expect(sockets[0].isLoopbackOnly)
        }

        // MARK: - Descriptor listing

        @Test func descriptorListingUsesLastFillDuringAnFDStorm() throws {
            let entrySize = MemoryLayout<proc_fdinfo>.stride
            var buffer: [proc_fdinfo] = []
            var listCalls = 0
            var tableSize = 8
            // Every call fills the buffer completely with socket descriptors and the table keeps growing.
            let count = PortSysProc.listFileDescriptors(
                into: &buffer,
                list: { raw in
                    listCalls += 1
                    let entries = raw.bindMemory(to: proc_fdinfo.self)
                    for index in entries.indices {
                        entries[index] = proc_fdinfo(proc_fd: Int32(index), proc_fdtype: UInt32(PROX_FDTYPE_SOCKET))
                    }
                    return Int32(entries.count * entrySize)
                },
                probe: {
                    tableSize = tableSize * 3 + 100   // outgrows every regrow
                    return tableSize * entrySize
                })
            let filled = try #require(count)
            #expect(listCalls == PortSysProc.maxDescriptorListAttempts)
            #expect(filled == buffer.count, "the last fill is used as is (truncated), never a freshly grown empty buffer")
            #expect(buffer.prefix(filled).allSatisfy { $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) }, "every reported entry must hold data written by the kernel")
            #expect(buffer[filled - 1].proc_fd == Int32(filled - 1))
        }

        @Test func descriptorListingGrowsOnceAndReportsErrors() {
            let entrySize = MemoryLayout<proc_fdinfo>.stride
            var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: 4)
            var table = 10   // more descriptors than the buffer holds: one regrow, then complete
            let count = PortSysProc.listFileDescriptors(
                into: &buffer,
                list: { raw in
                    let capacity = raw.count / entrySize
                    return Int32(min(table, capacity) * entrySize)
                },
                probe: { (table + 20) * entrySize })
            #expect(count == 10)
            #expect(buffer.count > 10)

            table = 0
            #expect(PortSysProc.listFileDescriptors(into: &buffer, list: { _ in 0 }, probe: { 0 }) == 0, "no descriptors")
            #expect(PortSysProc.listFileDescriptors(into: &buffer, list: { _ in errno = ESRCH; return 0 }, probe: { nil }) == nil, "an error is 'cannot inspect', not 'no sockets'")
            var empty: [proc_fdinfo] = []
            #expect(PortSysProc.listFileDescriptors(into: &empty, list: { _ in 0 }, probe: { nil }) == nil)
        }

        @Test func parsePCBListRejectsMalformedInput() {
            #expect([UInt8]().withUnsafeBytes { PortSysProc.parsePCBList($0) } == nil)
            #expect(PortPCBListBuilder().finish().withUnsafeBytes { PortSysProc.parsePCBList($0) } == nil, "a list without PCBs is treated as unavailable")

            var list = PortPCBListBuilder()
            list.append(port: 1, family: AF_INET, ipv4: [127, 0, 0, 1], pid: 1, state: 1)
            let valid = list.finish()
            // Truncated anywhere: never crash; a cut inside a record is rejected.
            for length in 0..<valid.count {
                _ = Array(valid.prefix(length)).withUnsafeBytes { PortSysProc.parsePCBList($0) }
            }
            // Unknown record size (layout drift) must be rejected rather than misread.
            var drifted = valid
            drifted.replaceSubrange(24..<28, with: [100, 0, 0, 0])
            #expect(drifted.withUnsafeBytes { PortSysProc.parsePCBList($0) } == nil)
        }

        // MARK: - Resource usage

        @Test func resourceSampleOfSelf() throws {
            let sample = try #require(PortSysProc.resourceSample(pid: getpid()))
            #expect(sample.cpuNanos > 0)
            #expect(sample.footprintBytes > 1_000_000)
            #expect(PortSysProc.resourceSample(pid: Int32.max) == nil)
        }

        @Test func machTicksConversionIsMonotonicAndOverflowSafe() {
            #expect(PortSysProc.machTicksToNanoseconds(0) == 0)
            #expect(PortSysProc.machTicksToNanoseconds(1_000) < PortSysProc.machTicksToNanoseconds(2_000))
            _ = PortSysProc.machTicksToNanoseconds(UInt64.max)
        }

        // MARK: - netstat parsing

        @Test func parseNetstatListeners() {
            let output = """
            Active Internet connections (including servers)
            Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)          rxbytes      txbytes  rhiwat  shiwat          process:pid    state  options           gencnt    flags   flags1 usecnt rtncnt fltrs
            tcp4       0      0  192.0.2.10.52082       203.0.113.7.443        ESTABLISHED        11162          713  131072  131600 com.avast.daemon:1050   00182 00000000 000000000082295c 20000081 04000900      3      0 000004
            tcp4       0      0  127.0.0.1.51790        *.*                    LISTEN                 0            0  131072  131072 Code Helper (Plu:82075  00100 00000106 000000000081822a 00000001 00000800      1      0 000000
            tcp4       0      0  *.57621                *.*                    LISTEN                 0            0  131072  131072          Spotify:17080  00100 00000002 00000000007a9ece 00000000 00000800      1      0 000000
            tcp4       0      0  127.0.0.1.8831         *.*                    LISTEN                 0            0  131072  131072 Antigravity IDE :86033  00100 00000106 000000000079a662 00000001 00000800      1      0 000000
            tcp6       0      0  ::1.6379               *.*                    LISTEN                 0            0  131072  131072     redis-server:972    00100 00000006 0000000000001bf0 00000000 00000800      1      0 000000
            tcp46      0      0  *.3091                 *.*                    LISTEN                 0            0  131072  131072             node:1392   00100 00000006 0000000000001bf1 00000000 00000800      1      0 000000
            tcp6       0      0  *.5900                 *.*                    LISTEN                 0            0  131072  131072          launchd:1      00180 00000006 0000000000000a41 00000000 00000800      1      0 000000
            tcp4       0      0  127.0.0.1.9999         *.*                    LISTEN                 0            0  131072  131072 00100 00000006 0000000000000a41 00000000 00000800      1      0 000000
            """
            #expect(PortProcessScanner.parseNetstatListeners(output) == [
                PortListeningSocket(port: 51790, address: "127.0.0.1", family: .ipv4, pid: 82075),
                PortListeningSocket(port: 57621, address: "*", family: .ipv4, pid: 17080),
                PortListeningSocket(port: 8831, address: "127.0.0.1", family: .ipv4, pid: 86033),
                PortListeningSocket(port: 6379, address: "::1", family: .ipv6, pid: 972),
                PortListeningSocket(port: 3091, address: "*", family: .ipv6, pid: 1392),
                PortListeningSocket(port: 5900, address: "*", family: .ipv6, pid: 1),
            ])
        }

        // MARK: - PortProcessScanner

        @Test func scannerFindsOwnListenerWithoutOtherUsers() throws {
            let listener = try PortTestListener(family: AF_INET, address: "127.0.0.1")
            defer { listener.close() }

            let scanner = PortProcessScanner()
            // Other users' candidates are ignored unless they were asked for.
            let raw = scanner.scan(includeOtherUsers: false,
                                   otherUserListeners: [PortListeningSocket(port: 5900, address: "*", family: .ipv4, pid: 1)])
            #expect(raw.table[getpid()] != nil)
            #expect(raw.restrictedPIDs.isEmpty)
            let mine = try #require(raw.socketsByPID[getpid()])
            #expect(mine.contains { $0.port == listener.port && $0.address == "127.0.0.1" })
            #expect(raw.socketsByPID.values.allSatisfy { !$0.isEmpty })
        }

        @Test func scannerAddsOnlyUninspectableOtherUserListeners() throws {
            guard geteuid() != 0 else { return }  // root can inspect every process
            let listener = try PortTestListener(family: AF_INET, address: "127.0.0.1")
            defer { listener.close() }

            let fake = [
                PortListeningSocket(port: 5900, address: "*", family: .ipv4, pid: 1),
                PortListeningSocket(port: 5900, address: "*", family: .ipv4, pid: 1),          // duplicate
                PortListeningSocket(port: listener.port, address: "127.0.0.1", family: .ipv4, pid: getpid()),
                PortListeningSocket(port: 1, address: "*", family: .ipv4, pid: Int32.max),     // not in table
            ]
            let scanner = PortProcessScanner()
            let raw = scanner.scan(includeOtherUsers: true, otherUserListeners: fake)
            #expect(raw.restrictedPIDs == [1])
            #expect(raw.socketsByPID[1] == [PortListeningSocket(port: 5900, address: "*", family: .ipv4, pid: 1)])
            #expect(raw.socketsByPID[Int32.max] == nil)
            let mine = try #require(raw.socketsByPID[getpid()])
            #expect(mine.filter { $0.port == listener.port }.count == 1, "self was inspected via libproc; no duplicate")
        }

        @Test func scannerFallsBackToNetstatWhenKernelListIsUnavailable() throws {
            guard geteuid() != 0 else { return }  // root can inspect every process
            let netstat = """
            tcp4       0      0  127.0.0.1.8021         *.*                    LISTEN                 0            0  131072  131072          launchd:1      00180 00000006 0000000000000a4e 00000000 00000800      1      0 000000
            """
            // netstat's rows stand in when the kernel list is unavailable (the engine runs netstat through ProcessRunner).
            let scanner = PortProcessScanner()
            let raw = scanner.scan(includeOtherUsers: true,
                                   otherUserListeners: PortProcessScanner.parseNetstatListeners(netstat))
            #expect(raw.restrictedPIDs == [1])
            #expect(raw.socketsByPID[1]?.map(\.port) == [8021])
        }

        @Test func scannerDetailsAreCachedPerIdentity() throws {
            let scanner = PortProcessScanner()
            let raw = scanner.scan(includeOtherUsers: false)
            let me = try #require(raw.table[getpid()])
            let first = try #require(scanner.details(for: me))
            let second = try #require(scanner.details(for: me))
            #expect(first.identity == me.identity)
            #expect(first.arguments == second.arguments)
            #expect(first.cwd == second.cwd)

            let stale = PortProcessBasic(pid: me.pid, ppid: me.ppid, pgid: me.pgid, uid: me.uid,
                                     comm: me.comm, startTime: me.startTime &+ 1)
            #expect(scanner.details(for: stale) == nil)
        }

        @Test func scannerUsageIsZeroFirstThenMeasuresCPU() throws {
            let scanner = PortProcessScanner()
            let me = try #require(PortSysProc.basic(pid: getpid()))

            let first = try #require(scanner.usage(for: [me])[me.pid])
            #expect(first.cpuPercent == 0)
            #expect(first.memoryBytes > 0)

            // Burn CPU for ~400 ms so the next sample has a measurable delta.
            let deadline = Date().addingTimeInterval(0.4)
            var accumulator = 0.0
            while Date() < deadline { accumulator += sin(accumulator + 1) }
            #expect(!accumulator.isNaN)

            let second = try #require(scanner.usage(for: [me])[me.pid])
            #expect(second.cpuPercent > 5)
            #expect(second.cpuPercent < 100 * Double(ProcessInfo.processInfo.activeProcessorCount) + 1)
            #expect(scanner.usage(for: [PortProcessBasic(pid: Int32.max, ppid: 1, pgid: 1, uid: 0,
                                                          comm: "gone", startTime: 1)])[Int32.max] == nil)
        }

        // MARK: - Helpers

        private func resolved(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }

        /// Builds a KERN_PROCARGS2-shaped buffer.
        private static func procArgsBuffer(argc: Int32, execPath: String, padding: Int, arguments: [String],
                                           environment: [String], trailer: [String]) -> [UInt8] {
            var bytes: [UInt8] = []
            withUnsafeBytes(of: argc.littleEndian) { bytes.append(contentsOf: $0) }
            bytes.append(contentsOf: Array(execPath.utf8) + [0])
            bytes.append(contentsOf: [UInt8](repeating: 0, count: padding))
            for string in arguments + environment { bytes.append(contentsOf: Array(string.utf8) + [0]) }
            bytes.append(0)   // empty string ends the environment
            for string in trailer { bytes.append(contentsOf: Array(string.utf8) + [0]) }
            return bytes
        }
    }
}

