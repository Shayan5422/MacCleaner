import Foundation

/// Compares a check with the stored snapshot.
///
/// - Only sources the check covered are compared; everything else is kept as it was.
/// - The first time a source is covered, its items become the baseline: no changes are reported.
/// - Items keep their first-seen date; the last-changed date moves when a compared field changes
///   (program, arguments, on/off state or code signature).
enum GuardianStartupDiff {
    struct Result: Sendable {
        var snapshot: GuardianStartupSnapshot
        var changes: [GuardianStartupChange]
    }

    static func merge(previous: GuardianStartupSnapshot?, collection: GuardianStartupCollection) -> Result {
        let now = collection.date
        let covered = collection.covered
        guard let previous else {
            let records = dedupe(collection.records).map { record -> GuardianStartupRecord in
                var copy = record
                copy.firstSeen = now
                copy.lastChanged = now
                copy.isBaseline = true
                return copy
            }
            var snapshot = GuardianStartupSnapshot(createdAt: now, updatedAt: now, records: records.sorted(by: order), coveredSources: covered)
            for source in covered { snapshot.sourceCheckedAt[source.rawValue] = now }
            return Result(snapshot: snapshot, changes: [])
        }

        var records = previous.records.filter { !covered.contains($0.source) }
        var changes: [GuardianStartupChange] = []
        let incomingBySource = Dictionary(grouping: collection.records, by: \.source)

        for source in covered {
            let incoming = dedupe(incomingBySource[source] ?? [])
            let isFirstLook = !previous.coveredSources.contains(source)
            let old = Dictionary(previous.records(of: source).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            for var record in incoming {
                if let before = old[record.id], record.isUnreadable, !before.isUnreadable {
                    // Most likely caught while an installer was writing it: keep the last good state until it reads again.
                    records.append(before)
                    continue
                }
                if let before = old[record.id] {
                    record.firstSeen = before.firstSeen
                    record.isBaseline = before.isBaseline
                    let fields = record.differences(from: before)
                    if fields.isEmpty {
                        record.lastChanged = before.lastChanged
                        // A signature that couldn't be read this time keeps the last known one.
                        if record.signature == nil || record.signature?.isKnown == false, let known = before.signature, known.isKnown,
                           record.programPath == before.programPath {
                            record.signature = known
                        }
                    } else {
                        record.lastChanged = now
                        changes.append(GuardianStartupChange(date: now, kind: .changed, fields: fields, record: record, previous: before,
                                                             isRoutineUpdate: isRoutineUpdate(fields: fields, old: before, new: record)))
                    }
                } else {
                    record.firstSeen = now
                    record.lastChanged = now
                    record.isBaseline = isFirstLook
                    if !isFirstLook {
                        changes.append(GuardianStartupChange(date: now, kind: .added, record: record))
                    }
                }
                records.append(record)
            }

            if !isFirstLook {
                let incomingIDs = Set(incoming.map(\.id))
                for (id, before) in old where !incomingIDs.contains(id) {
                    changes.append(GuardianStartupChange(date: now, kind: .removed, record: before))
                }
            }
        }

        var snapshot = GuardianStartupSnapshot(
            createdAt: previous.createdAt,
            updatedAt: now,
            records: records.sorted(by: order),
            coveredSources: previous.coveredSources.union(covered),
            sourceCheckedAt: previous.sourceCheckedAt
        )
        for source in covered { snapshot.sourceCheckedAt[source.rawValue] = now }
        return Result(snapshot: snapshot, changes: changes.sorted(by: changeOrder))
    }

    /// A newer version of the same app: the program moved within the same app bundle (or only
    /// arguments changed) and the developer stayed the same.
    static func isRoutineUpdate(fields: [GuardianStartupChange.Field], old: GuardianStartupRecord, new: GuardianStartupRecord) -> Bool {
        guard !fields.contains(.enabled), !fields.contains(.signature) else { return false }
        guard fields.contains(.program) else { return false }
        guard let oldPath = old.programPath, let newPath = new.programPath,
              let oldApp = LaunchdProgramAnalyzer.outermostAppBundle(in: oldPath),
              let newApp = LaunchdProgramAnalyzer.outermostAppBundle(in: newPath), oldApp == newApp else { return false }
        guard let oldSignature = old.signature, let newSignature = new.signature,
              oldSignature.trustClass == newSignature.trustClass, oldSignature.teamIdentifier != nil,
              oldSignature.teamIdentifier == newSignature.teamIdentifier else { return false }
        return true
    }

    private static func dedupe(_ records: [GuardianStartupRecord]) -> [GuardianStartupRecord] {
        var seen = Set<String>()
        return records.filter { seen.insert($0.id).inserted }
    }

    private static func order(_ lhs: GuardianStartupRecord, _ rhs: GuardianStartupRecord) -> Bool {
        if lhs.source != rhs.source { return lhs.source.rawValue < rhs.source.rawValue }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func changeOrder(_ lhs: GuardianStartupChange, _ rhs: GuardianStartupChange) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.record.name.localizedStandardCompare(rhs.record.name) == .orderedAscending
    }
}

/// The stored snapshot and change timeline.
struct GuardianStartupStore: Sendable {
    static let maximumChanges = 300
    static let maximumChangeAge: TimeInterval = 180 * 24 * 60 * 60

    var directory: URL?

    var snapshotURL: URL? { directory?.appendingPathComponent("StartupSnapshot.json") }
    var changesURL: URL? { directory?.appendingPathComponent("StartupChanges.json") }
    var backgroundItemsURL: URL? { directory?.appendingPathComponent("BackgroundItems.json") }
    var loginAnalysisURL: URL? { directory?.appendingPathComponent("LoginAnalysis.json") }

    func loadSnapshot() -> GuardianStartupSnapshot? { GuardianStorage.load(GuardianStartupSnapshot.self, from: snapshotURL) }
    func loadChanges() -> [GuardianStartupChange] { GuardianStorage.load([GuardianStartupChange].self, from: changesURL) ?? [] }
    func loadBackgroundItems() -> GuardianBackgroundItemsState? { GuardianStorage.load(GuardianBackgroundItemsState.self, from: backgroundItemsURL) }
    func loadLoginAnalysis() -> GuardianLoginAnalysis? { GuardianStorage.load(GuardianLoginAnalysis.self, from: loginAnalysisURL) }

    func save(snapshot: GuardianStartupSnapshot) async { await GuardianStorage.save(snapshot, to: snapshotURL) }
    func save(changes: [GuardianStartupChange]) async { await GuardianStorage.save(changes, to: changesURL) }
    func save(backgroundItems: GuardianBackgroundItemsState) async { await GuardianStorage.save(backgroundItems, to: backgroundItemsURL) }
    func save(loginAnalysis: GuardianLoginAnalysis) async { await GuardianStorage.save(loginAnalysis, to: loginAnalysisURL) }

    /// Newest first, pruned by count and age.
    static func appending(_ new: [GuardianStartupChange], to existing: [GuardianStartupChange], now: Date = Date()) -> [GuardianStartupChange] {
        let cutoff = now.addingTimeInterval(-maximumChangeAge)
        let combined = (new + existing).filter { $0.date >= cutoff }.sorted { $0.date > $1.date }
        return Array(combined.prefix(maximumChanges))
    }
}

/// The last list of every background item, and what changed since the list before.
struct GuardianBackgroundItemsState: Codable, Sendable, Hashable {
    var dump: GuardianBTMDump
    /// Items that weren't in the previous list (empty for the first list).
    var newItemIDs: Set<String>
    /// Items of the previous list that are gone.
    var removedItems: [GuardianBTMItem]
    var previousDate: Date?

    static func make(dump: GuardianBTMDump, previous: GuardianBackgroundItemsState?) -> GuardianBackgroundItemsState {
        guard let previous else {
            return GuardianBackgroundItemsState(dump: dump, newItemIDs: [], removedItems: [], previousDate: nil)
        }
        let currentIDs = Set(dump.items.map(\.id))
        let previousIDs = Set(previous.dump.items.map(\.id))
        return GuardianBackgroundItemsState(
            dump: dump,
            newItemIDs: currentIDs.subtracting(previousIDs),
            removedItems: previous.dump.items.filter { !currentIDs.contains($0.id) && $0.kind.isRunnable },
            previousDate: previous.dump.date
        )
    }

    /// Records for the startup snapshot: runnable, active items of this account and the system, not part of macOS.
    func records(now: Date, currentUID: Int = Int(getuid())) -> [GuardianStartupRecord] {
        // An "app" entry that isn't enabled itself only owns other items: it doesn't open at login.
        dump.relevantItems(currentUID: currentUID).filter { $0.kind.isRunnable && !$0.isApple && ($0.kind != .app || $0.disposition.enabled == true) }.map { item in
            var record = GuardianStartupRecord(
                source: .registeredItems, key: item.id, kind: item.kind == .app ? .appLoginItem : .registeredItem,
                name: item.displayName, identifier: item.bundleIdentifier ?? item.identifier.map(GuardianBTMParser.strippedIdentifier),
                programPath: item.executablePath ?? item.path, configPath: item.path?.hasSuffix(".plist") == true ? item.path : nil, date: now
            )
            record.isEnabled = item.disposition.isActive
            record.startsAutomatically = true
            record.trigger = item.kind.title
            record.ownerName = item.developerName
            if let path = item.path, path.hasSuffix(".app") { record.ownerPath = path }
            if item.disposition.enabled == true && item.disposition.allowed == false {
                record.note = "Turned off under Allow in the Background in System Settings."
            }
            return record
        }
    }
}
