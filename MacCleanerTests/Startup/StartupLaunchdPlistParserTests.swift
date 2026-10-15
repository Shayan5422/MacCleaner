import Foundation
import Testing
@testable import MacCleaner

struct StartupLaunchdPlistParserTests {
    private func parse(_ dictionary: [String: Any]) throws -> LaunchdJobDefinition {
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        return try LaunchdPlistParser.parse(data: data)
    }

    @Test func programTakesPrecedenceOverProgramArguments() throws {
        let job = try parse([
            "Label": "com.example.agent",
            "Program": "/usr/local/bin/example-daemon",
            "ProgramArguments": ["example", "--serve", "--port", "8080"],
        ])
        #expect(job.label == "com.example.agent")
        #expect(job.executable == "/usr/local/bin/example-daemon")
        #expect(job.argumentVector == ["example", "--serve", "--port", "8080"])
        #expect(!job.isEmpty)
    }

    @Test func programArgumentsAloneProvideTheExecutable() throws {
        let job = try parse([
            "Label": "com.example.updater",
            "ProgramArguments": ["/Applications/Example.app/Contents/MacOS/Updater", "--check"],
            "RunAtLoad": true,
        ])
        #expect(job.program == nil)
        #expect(job.executable == "/Applications/Example.app/Contents/MacOS/Updater")
        #expect(job.argumentVector.count == 2)
        #expect(job.runAtLoad)
    }

    @Test func bundleProgramIsUsedWhenNothingElseIsSet() throws {
        let job = try parse([
            "Label": "com.example.helper",
            "BundleProgram": "Contents/MacOS/Helper",
        ])
        #expect(job.executable == "Contents/MacOS/Helper")
        #expect(job.argumentVector == ["Contents/MacOS/Helper"])
    }

    @Test func calendarIntervalAsDictionary() throws {
        let job = try parse([
            "Label": "com.example.nightly",
            "Program": "/usr/bin/true",
            "StartCalendarInterval": ["Hour": 3, "Minute": 15],
        ])
        #expect(job.startCalendarIntervals == [LaunchdCalendarInterval(minute: 15, hour: 3)])
        #expect(job.startCalendarIntervals.first?.summary == "Daily at 03:15")
        #expect(job.startsAutomatically)
    }

    @Test func calendarIntervalAsArray() throws {
        let job = try parse([
            "Label": "com.example.weekly",
            "Program": "/usr/bin/true",
            "StartCalendarInterval": [
                ["Weekday": 1, "Hour": 9, "Minute": 0],
                ["Minute": 30],
                ["Day": 1, "Hour": 0, "Minute": 0],
            ],
        ])
        #expect(job.startCalendarIntervals.count == 3)
        #expect(job.startCalendarIntervals[0].summary == "Mondays at 09:00")
        #expect(job.startCalendarIntervals[1].summary == "Hourly at :30")
        #expect(job.startCalendarIntervals[2].summary == "day 1 at 00:00")
    }

    @Test func calendarWildcardsAreDescribedHonestly() {
        #expect(LaunchdCalendarInterval().summary == "Every minute")
        #expect(LaunchdCalendarInterval(hour: 0).summary == "Daily, every minute from 00:00 to 00:59")
        #expect(LaunchdCalendarInterval(weekday: 0).summary == "Sundays, every minute")
        #expect(LaunchdCalendarInterval(minute: 5, hour: 8, weekday: 7).summary == "Sundays at 08:05")
        #expect(LaunchdCalendarInterval(minute: 0, hour: 12, day: 15, month: 3).summary == "March, day 15 at 12:00")
    }

    @Test func keepAliveBoolAndDictionary() throws {
        let always = try parse(["Label": "a", "Program": "/bin/sh", "KeepAlive": true])
        #expect(always.keepAlive == .always)
        let off = try parse(["Label": "b", "Program": "/bin/sh", "KeepAlive": false])
        #expect(off.keepAlive == .off)
        let conditional = try parse(["Label": "c", "Program": "/bin/sh", "KeepAlive": ["SuccessfulExit": false, "NetworkState": true]])
        #expect(conditional.keepAlive == .conditional(["NetworkState", "SuccessfulExit"]))
        #expect(conditional.keepAlive.isEnabled)
    }

    @Test func otherKeysAreRead() throws {
        let job = try parse([
            "Label": "com.example.watch",
            "ProgramArguments": ["/usr/bin/true"],
            "Disabled": true,
            "StartInterval": 3600,
            "WatchPaths": ["/tmp/watched"],
            "LimitLoadToSessionType": "Aqua",
            "AssociatedBundleIdentifiers": ["com.example.app"],
            "MachServices": ["com.example.xpc": true],
            "WorkingDirectory": "/var/tmp",
        ])
        #expect(job.disabled)
        #expect(job.startInterval == 3600)
        #expect(job.watchPaths == ["/tmp/watched"])
        #expect(job.limitLoadToSessionTypes == ["Aqua"])
        #expect(job.associatedBundleIdentifiers == ["com.example.app"])
        #expect(job.machServices == ["com.example.xpc"])
        #expect(job.workingDirectory == "/var/tmp")
    }

    @Test func emptyDictionaryIsAnEmptyJob() throws {
        let job = try parse([:])
        #expect(job.isEmpty)
        #expect(job.executable == nil)
        #expect(job.triggerSummary == "Starts only when asked")
    }

    @Test func malformedAndNonDictionaryPlistsThrow() throws {
        #expect(throws: LaunchdPlistError.self) {
            try LaunchdPlistParser.parse(data: Data("not a plist <<<".utf8))
        }
        let array = try PropertyListSerialization.data(fromPropertyList: ["a", "b"], format: .xml, options: 0)
        #expect(throws: LaunchdPlistError.notADictionary) {
            try LaunchdPlistParser.parse(data: array)
        }
    }

    @Test func binaryPlistFromATemporaryFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StartupPlistTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("com.example.binary.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "Label": "com.example.binary",
            "ProgramArguments": ["/bin/echo", "hello"],
            "RunAtLoad": 1,
        ], format: .binary, options: 0)
        try data.write(to: url)

        let job = try LaunchdPlistParser.parse(contentsOf: url.path)
        #expect(job.label == "com.example.binary")
        #expect(job.runAtLoad) // integer 1 is accepted as true
        #expect(job.executable == "/bin/echo")
    }

    @Test func missingFileThrowsUnreadable() {
        #expect(throws: LaunchdPlistError.self) {
            try LaunchdPlistParser.parse(contentsOf: "/nonexistent/folder/missing.plist")
        }
    }

    @Test func displayRowsFlattenNestedValues() throws {
        let job = try parse([
            "Label": "com.example.rows",
            "ProgramArguments": ["/bin/sh", "-c", "true"],
            "KeepAlive": ["SuccessfulExit": false],
        ])
        let rows = job.displayRows
        #expect(rows.contains { $0.key == "Label" && $0.value == "com.example.rows" && $0.depth == 0 })
        #expect(rows.contains { $0.key == "ProgramArguments" && $0.value == nil })
        #expect(rows.contains { $0.key == "[1]" && $0.value == "-c" && $0.depth == 1 })
        #expect(rows.contains { $0.key == "SuccessfulExit" && $0.value == "false" && $0.depth == 1 })
    }

    @Test func triggerSummaryDescribesWhenItRuns() throws {
        let job = try parse(["Label": "x", "Program": "/bin/sh", "RunAtLoad": true, "KeepAlive": true])
        #expect(job.triggerSummary == "Starts at login, kept running")
        let onDemand = try parse(["Label": "y", "Program": "/bin/sh", "MachServices": ["y.xpc": true]])
        #expect(onDemand.triggerSummary == "Starts on demand")
    }
}
