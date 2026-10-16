import Foundation
import Testing
@testable import MacCleaner

struct GuardianStartupDiffTests {
    private let day1 = Date(timeIntervalSince1970: 1_800_000_000)
    private var day2: Date { day1.addingTimeInterval(86_400) }
    private var day3: Date { day1.addingTimeInterval(2 * 86_400) }
    private let regular: [GuardianStartupSource] = [.userLaunchAgents, .loginItems, .cronJobs]

    private func merge(_ previous: GuardianStartupSnapshot?, _ records: [GuardianStartupRecord], covered: [GuardianStartupSource]? = nil, date: Date) -> GuardianStartupDiff.Result {
        GuardianStartupDiff.merge(previous: previous, collection: GuardianRecordFactory.collection(records, covered: covered ?? regular, date: date))
    }

    @Test func firstCheckIsTheBaseline() {
        let result = merge(nil, [GuardianRecordFactory.agent("com.example.a"), GuardianRecordFactory.agent("com.example.b")], date: day1)
        #expect(result.changes.isEmpty)
        #expect(result.snapshot.records.count == 2)
        #expect(result.snapshot.records.allSatisfy { $0.isBaseline && $0.firstSeen == day1 && $0.lastChanged == day1 })
        #expect(result.snapshot.createdAt == day1)
        #expect(result.snapshot.coveredSources == Set(regular))
        #expect(result.snapshot.checkedAt(.cronJobs) == day1)
    }

    @Test func detectsAddedRemovedAndChangedItems() {
        let a = GuardianRecordFactory.agent("com.example.a")
        let b = GuardianRecordFactory.agent("com.example.b")
        let base = merge(nil, [a, b], date: day1).snapshot

        var changedA = GuardianRecordFactory.agent("com.example.a", program: "/Users/test/.hidden/payload", category: .unsigned, team: nil)
        changedA.isRunning = true
        let c = GuardianRecordFactory.agent("com.example.c")
        let result = merge(base, [changedA, c], date: day2)

        #expect(result.changes.map(\.kind) == [.added, .changed, .removed])
        let added = result.changes[0]
        #expect(added.record.name == "com.example.c")
        #expect(added.record.firstSeen == day2)
        #expect(added.record.isBaseline == false)

        let changed = result.changes[1]
        #expect(Set(changed.fields) == [.program, .signature])
        #expect(changed.previous?.programPath == "/Applications/Example.app/Contents/MacOS/Helper")
        #expect(changed.isRoutineUpdate == false)
        #expect(changed.severity == .suspicious)
        #expect(changed.isSecurityRelevantChange)

        let removed = result.changes[2]
        #expect(removed.record.name == "com.example.b")

        let stored = result.snapshot.records.first { $0.name == "com.example.a" }
        #expect(stored?.firstSeen == day1)
        #expect(stored?.lastChanged == day2)
        #expect(stored?.isBaseline == true)
        #expect(result.snapshot.records.count == 2)
    }

    @Test func unchangedItemsKeepTheirDatesAndRunningStateDoesntCount() {
        let base = merge(nil, [GuardianRecordFactory.agent("com.example.a")], date: day1).snapshot
        var again = GuardianRecordFactory.agent("com.example.a")
        again.isRunning = true
        again.trigger = "Starts at login"
        let result = merge(base, [again], date: day2)
        #expect(result.changes.isEmpty)
        #expect(result.snapshot.records.first?.lastChanged == day1)
        #expect(result.snapshot.records.first?.isRunning == true)
        #expect(result.snapshot.updatedAt == day2)
    }

    @Test func sourcesNotReadThisTimeAreKeptAsTheyWere() {
        var login = GuardianRecordFactory.agent("Clicky", source: .loginItems)
        login.kind = .loginItem
        let base = merge(nil, [GuardianRecordFactory.agent("com.example.a"), login], date: day1).snapshot
        // Login items couldn't be read (no Automation access): no removals reported for them.
        let result = merge(base, [GuardianRecordFactory.agent("com.example.a")], covered: [.userLaunchAgents, .cronJobs], date: day2)
        #expect(result.changes.isEmpty)
        #expect(result.snapshot.records(of: .loginItems).count == 1)
        #expect(result.snapshot.checkedAt(.loginItems) == day1)
        #expect(result.snapshot.checkedAt(.userLaunchAgents) == day2)
    }

    @Test func aSourceReadForTheFirstTimeBecomesItsOwnBaseline() {
        let base = merge(nil, [GuardianRecordFactory.agent("com.example.a")], covered: [.userLaunchAgents], date: day1).snapshot
        var registered = GuardianRecordFactory.agent("Clicky", source: .registeredItems)
        registered.kind = .appLoginItem
        let first = merge(base, [registered], covered: [.registeredItems], date: day2)
        #expect(first.changes.isEmpty)
        #expect(first.snapshot.records(of: .registeredItems).first?.isBaseline == true)
        #expect(first.snapshot.records(of: .userLaunchAgents).count == 1)

        var another = GuardianRecordFactory.agent("Other", source: .registeredItems)
        another.kind = .appLoginItem
        let second = merge(first.snapshot, [registered, another], covered: [.registeredItems], date: day3)
        #expect(second.changes.map(\.kind) == [.added])
        #expect(second.changes.first?.record.name == "Other")
    }

    @Test func turningOffIsAChangeButUnknownStateIsNot() {
        let base = merge(nil, [GuardianRecordFactory.agent("com.example.a", enabled: true)], date: day1).snapshot
        let off = merge(base, [GuardianRecordFactory.agent("com.example.a", enabled: false)], date: day2)
        #expect(off.changes.first?.fields == [.enabled])
        #expect(off.changes.first?.summary == "Turned off")
        #expect(off.changes.first?.isSecurityRelevantChange == false)

        let unknown = merge(base, [GuardianRecordFactory.agent("com.example.a", enabled: nil)], date: day2)
        #expect(unknown.changes.isEmpty)
    }

    @Test func notarizationTicketAloneIsNotASignatureChange() {
        let base = merge(nil, [GuardianRecordFactory.agent("com.example.a", category: .developerIDNotarized)], date: day1).snapshot
        #expect(merge(base, [GuardianRecordFactory.agent("com.example.a", category: .developerID)], date: day2).changes.isEmpty)
        let otherTeam = merge(base, [GuardianRecordFactory.agent("com.example.a", category: .developerIDNotarized, team: "ZZZZZ99999")], date: day2)
        #expect(otherTeam.changes.first?.fields == [.signature])
    }

    @Test func signatureThatCouldntBeReadKeepsTheLastKnownOne() {
        let base = merge(nil, [GuardianRecordFactory.agent("com.example.a")], date: day1).snapshot
        var unreadable = GuardianRecordFactory.agent("com.example.a")
        unreadable.signature = nil
        let result = merge(base, [unreadable], date: day2)
        #expect(result.changes.isEmpty)
        #expect(result.snapshot.records.first?.signature?.category == .developerIDNotarized)
    }

    @Test func updateWithinTheSameAppIsRoutine() {
        let old = GuardianRecordFactory.agent("com.example.updater", program: "/Applications/Example.app/Contents/Frameworks/Updater.framework/Versions/1.0/Updater")
        let new = GuardianRecordFactory.agent("com.example.updater", program: "/Applications/Example.app/Contents/Frameworks/Updater.framework/Versions/2.0/Updater")
        let base = merge(nil, [old], date: day1).snapshot
        let change = merge(base, [new], date: day2).changes.first
        #expect(change?.isRoutineUpdate == true)
        #expect(change?.summary == "Updated by its app")
        #expect(change?.severity == .info)
        #expect(change?.isSecurityRelevantChange == false)

        // Moving to another app, or losing the developer, is not routine.
        let moved = GuardianRecordFactory.agent("com.example.updater", program: "/Applications/Other.app/Contents/MacOS/Updater")
        #expect(merge(base, [moved], date: day2).changes.first?.isRoutineUpdate == false)
    }

    @Test func addedUnsignedItemIsSuspiciousAndScanVerdictsRaiseSeverity() {
        let base = merge(nil, [], date: day1).snapshot
        let unsigned = GuardianRecordFactory.agent("com.example.x", program: "/Users/test/Library/x", category: .adHoc, team: nil)
        var change = merge(base, [unsigned], date: day2).changes.first
        #expect(change?.severity == .suspicious)
        change?.verdict = GuardianScanVerdict(detections: ["Osx.Trojan.Example"])
        #expect(change?.severity == .threat)
    }

    @Test func aPropertyListCaughtMidWriteKeepsItsLastGoodState() {
        let base = merge(nil, [GuardianRecordFactory.agent("com.example.a")], date: day1).snapshot
        var unreadable = GuardianRecordFactory.agent("com.example.a", program: "")
        unreadable.programPath = nil
        unreadable.isUnreadable = true
        let result = merge(base, [unreadable], date: day2)
        #expect(result.changes.isEmpty)
        #expect(result.snapshot.records.first?.programPath == "/Applications/Example.app/Contents/MacOS/Helper")
        // Readable again: nothing changed.
        #expect(merge(result.snapshot, [GuardianRecordFactory.agent("com.example.a")], date: day3).changes.isEmpty)
    }

    @Test func duplicateIDsInACollectionAreIgnored() {
        let a = GuardianRecordFactory.agent("com.example.a")
        let result = merge(nil, [a, a], date: day1)
        #expect(result.snapshot.records.count == 1)
        let second = merge(result.snapshot, [a, a], date: day2)
        #expect(second.changes.isEmpty)
        #expect(second.snapshot.records.count == 1)
    }
}

struct GuardianStartupStoreTests {
    @Test func changesArePrunedByAgeAndCountNewestFirst() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let record = GuardianRecordFactory.agent("com.example.a")
        let old = GuardianStartupChange(date: now.addingTimeInterval(-200 * 86_400), kind: .added, record: record)
        let recent = (0..<350).map { GuardianStartupChange(date: now.addingTimeInterval(-Double($0) * 60), kind: .changed, record: record) }
        let combined = GuardianStartupStore.appending(Array(recent.prefix(10)), to: [old] + Array(recent.dropFirst(10)), now: now)
        #expect(combined.count == GuardianStartupStore.maximumChanges)
        #expect(!combined.contains { $0.id == old.id })
        #expect(combined.first?.date == now)
        #expect(zip(combined, combined.dropFirst()).allSatisfy { $0.date >= $1.date })
    }

    @Test func snapshotAndChangesRoundTripInATemporaryFolder() async throws {
        let directory = try GuardianTestDirectory()
        let store = GuardianStartupStore(directory: directory.url)
        let result = GuardianStartupDiff.merge(previous: nil, collection: GuardianRecordFactory.collection([GuardianRecordFactory.agent("com.example.a")],
                                                                                                            covered: [.userLaunchAgents], date: Date(timeIntervalSince1970: 1_800_000_000)))
        await store.save(snapshot: result.snapshot)
        let change = GuardianStartupChange(date: Date(timeIntervalSince1970: 1_800_000_100), kind: .added, record: result.snapshot.records[0])
        await store.save(changes: [change])

        let loaded = try #require(store.loadSnapshot())
        #expect(loaded.records == result.snapshot.records)
        #expect(loaded.coveredSources == [.userLaunchAgents])
        #expect(store.loadChanges() == [change])
        // Readable by this user only.
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path("StartupSnapshot.json"))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func missingFilesLoadAsEmpty() {
        let store = GuardianStartupStore(directory: nil)
        #expect(store.loadSnapshot() == nil)
        #expect(store.loadChanges().isEmpty)
        #expect(store.loadBackgroundItems() == nil)
    }
}

struct GuardianRecordTests {
    @Test func commandLineAndAutomaticStart() {
        var record = GuardianRecordFactory.agent("com.example.a", program: "/Applications/My App.app/Contents/MacOS/My App", arguments: ["--background", ""])
        #expect(record.commandLine == "\"/Applications/My App.app/Contents/MacOS/My App\" --background \"\"")
        #expect(record.willStartAutomatically)
        record.isEnabled = false
        #expect(!record.willStartAutomatically)
        record.isEnabled = true
        record.startsAutomatically = false
        #expect(!record.willStartAutomatically)
    }

    @Test func iconPathPrefersTheOwningApp() {
        var record = GuardianRecordFactory.agent("com.example.a", program: "/Applications/Example.app/Contents/Library/LaunchServices/helper")
        #expect(record.iconPath == "/Applications/Example.app")
        record.ownerPath = "/Applications/Owner.app"
        #expect(record.iconPath == "/Applications/Owner.app")
        record.ownerPath = nil
        record.programPath = "/opt/homebrew/bin/redis-server"
        #expect(record.iconPath == nil)
    }

    @Test func displayNamesUseTheOwningApp() {
        var record = GuardianRecordFactory.agent("com.philandro.anydesk.service")
        #expect(record.displayName == "com.philandro.anydesk.service")
        record.ownerName = "AnyDesk"
        #expect(record.displayName == "AnyDesk (service)")
        record.name = "com.example.portpilot"
        record.ownerName = "PortPilot"
        #expect(record.displayName == "PortPilot")
        record.name = "Avast One"
        record.ownerName = "Avast One"
        #expect(record.displayName == "Avast One")
        record.name = "StartUpHelper"
        record.ownerName = "Spotify"
        #expect(record.displayName == "Spotify (StartUpHelper)")
    }

    @Test func compactTimes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(GuardianTimeText.compactText(now.addingTimeInterval(-20), now: now) == "now")
        #expect(GuardianTimeText.compactText(now.addingTimeInterval(-300), now: now) == "5 min")
        #expect(GuardianTimeText.compactText(now.addingTimeInterval(-7_200), now: now) == "2 h")
        #expect(GuardianTimeText.compactText(now.addingTimeInterval(-3 * 86_400), now: now) == "3 d")
    }

    @Test func signaturePhrases() {
        #expect(GuardianSignatureSummary(category: .developerIDNotarized, developer: "Google LLC").notificationPhrase == "signed by Google LLC")
        #expect(GuardianSignatureSummary(category: .unsigned).notificationPhrase == "unsigned")
        #expect(GuardianSignatureSummary(category: .adHoc).notificationPhrase == "not signed by an identified developer")
        #expect(GuardianSignatureSummary(category: .apple).notificationPhrase == "signed by Apple")
        #expect(GuardianSignatureSummary(category: .adHoc).isConcerning)
        #expect(!GuardianSignatureSummary(category: .script).isConcerning)
        #expect(!GuardianSignatureSummary(category: .developerID).isConcerning)
    }
}
