import Foundation

/// Readers for the places things can start from that the Startup Items page doesn't cover.
/// All read-only; paths are injectable for tests.
enum GuardianExtraSources {
    // MARK: Cron

    /// The current user's crontab lines as records. System crontabs need an administrator.
    static func cronRecords(_ jobs: [SecurityCronJob], now: Date) -> [GuardianStartupRecord] {
        var occurrences: [String: Int] = [:]
        return jobs.map { job in
            let tokens = job.command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            let program = tokens.first
            let count = occurrences[job.command, default: 0]
            occurrences[job.command] = count + 1
            let key = count == 0 ? job.command : job.command + "#\(count + 1)"
            var record = GuardianStartupRecord(
                source: .cronJobs, key: key, kind: .cronJob,
                name: program.map { ($0 as NSString).lastPathComponent } ?? job.command,
                identifier: job.schedule,
                programPath: program.flatMap { $0.hasPrefix("/") || $0.hasPrefix("~") ? PathUtilities.normalize($0) : nil },
                arguments: Array(tokens.dropFirst()),
                date: now
            )
            if record.programPath == nil { record.note = "Runs: \(job.command)" }
            record.trigger = cronScheduleSummary(job.schedule)
            record.isEnabled = true
            return record
        }
    }

    /// "@reboot" → "At startup", "*/5 * * * *" → "Every 5 minutes".
    static func cronScheduleSummary(_ schedule: String) -> String {
        switch schedule.lowercased() {
        case "@reboot": return "At startup"
        case "@yearly", "@annually": return "Once a year"
        case "@monthly": return "Once a month"
        case "@weekly": return "Once a week"
        case "@daily", "@midnight": return "Every day at midnight"
        case "@hourly": return "Every hour"
        default: break
        }
        let fields = schedule.split(separator: " ").map(String.init)
        guard fields.count == 5 else { return "Schedule \(schedule)" }
        if fields.allSatisfy({ $0 == "*" }) { return "Every minute" }
        if fields[0].hasPrefix("*/"), fields[1...].allSatisfy({ $0 == "*" }), let step = Int(fields[0].dropFirst(2)) {
            return "Every \(step) minutes"
        }
        if let minute = Int(fields[0]), let hour = Int(fields[1]), fields[2...].allSatisfy({ $0 == "*" }) {
            return String(format: "Every day at %02d:%02d", hour, minute)
        }
        if let minute = Int(fields[0]), fields[1...].allSatisfy({ $0 == "*" }) {
            return String(format: "Every hour at :%02d", minute)
        }
        return "Schedule \(schedule)"
    }

    // MARK: Legacy locations

    /// Folders in `/Library/StartupItems`. macOS stopped running them in OS X 10.10.
    static func legacyStartupItems(folder: String, now: Date) -> (records: [GuardianStartupRecord], status: GuardianSourceStatus) {
        switch PrivacyFileAccess.list(folder) {
        case .missing:
            return ([], GuardianSourceStatus(source: .legacyStartupItems, state: .notPresent))
        case .blocked:
            return ([], GuardianSourceStatus(source: .legacyStartupItems, state: .needsAdministrator))
        case .entries(let entries):
            let records = entries.filter { $0.type == .directory && !$0.name.hasPrefix(".") }.sorted { $0.name < $1.name }.map { entry in
                var record = GuardianStartupRecord(source: .legacyStartupItems, key: entry.path, kind: .legacyStartupItem,
                                                   name: entry.name, programPath: entry.path + "/" + entry.name, configPath: entry.path, date: now)
                record.isEnabled = false
                record.note = "macOS no longer runs legacy startup items (since OS X 10.10), so this one is probably left over."
                record.trigger = "Not run by current macOS"
                return record
            }
            return (records, GuardianSourceStatus(source: .legacyStartupItems, state: records.isEmpty ? .notPresent : .read, count: records.count))
        }
    }

    /// Apple's own periodic scripts (`/etc/periodic`), which aren't reported.
    static let applePeriodicScripts: Set<String> = [
        "110.clean-tmps", "130.clean-msgs", "140.clean-rwho", "199.rotate-fax", "310.accounting", "400.status-disks",
        "420.status-network", "430.status-rwho", "999.local", "320.whatis", "200.accounting", "500.daily", "500.weekly", "500.monthly",
    ]

    /// Custom scripts run by `periodic` (daily, weekly, monthly), if this macOS still has it.
    static func periodicScripts(roots: [String], appleRoot: String = "/etc/periodic", localFiles: [String], now: Date) -> (records: [GuardianStartupRecord], status: GuardianSourceStatus) {
        var records: [GuardianStartupRecord] = []
        var anyFolder = false
        var blocked = false
        for root in roots {
            for interval in ["daily", "weekly", "monthly"] {
                let folder = root + "/" + interval
                switch PrivacyFileAccess.list(folder) {
                case .missing: continue
                case .blocked: blocked = true
                case .entries(let entries):
                    anyFolder = true
                    let isAppleFolder = root == appleRoot
                    for entry in entries.sorted(by: { $0.name < $1.name }) where entry.type == .regular && !entry.name.hasPrefix(".") {
                        if isAppleFolder && applePeriodicScripts.contains(entry.name) { continue }
                        records.append(periodicRecord(path: entry.path, interval: interval, now: now))
                    }
                }
            }
        }
        for file in localFiles where PrivacyFileAccess.probe(file) == .file {
            anyFolder = true
            let name = (file as NSString).lastPathComponent
            let interval = ["daily", "weekly", "monthly"].first { name.hasPrefix($0) } ?? "daily"
            records.append(periodicRecord(path: file, interval: interval, now: now))
        }
        let state: GuardianSourceStatus.State = blocked ? .needsAdministrator : (anyFolder ? .read : .notPresent)
        var status = GuardianSourceStatus(source: .periodicScripts, state: state, count: records.count)
        if !anyFolder && !blocked { status.note = "This macOS version doesn't run periodic scripts." }
        return (records, status)
    }

    private static func periodicRecord(path: String, interval: String, now: Date) -> GuardianStartupRecord {
        var record = GuardianStartupRecord(source: .periodicScripts, key: path, kind: .periodicScript,
                                           name: (path as NSString).lastPathComponent, programPath: path, configPath: path, date: now)
        record.isEnabled = FileManager.default.isExecutableFile(atPath: path) || path.hasSuffix(".local")
        record.trigger = "Runs \(interval) (periodic)"
        return record
    }

    /// `/etc/launchd.conf`: ignored since OS X 10.10, but its presence is unusual.
    static func launchdConf(path: String, now: Date) -> (records: [GuardianStartupRecord], status: GuardianSourceStatus) {
        switch PrivacyFileAccess.probe(path) {
        case .missing:
            return ([], GuardianSourceStatus(source: .launchdConf, state: .notPresent))
        case .blocked:
            return ([], GuardianSourceStatus(source: .launchdConf, state: .needsAdministrator))
        default:
            var record = GuardianStartupRecord(source: .launchdConf, key: path, kind: .launchdConf, name: "launchd.conf", configPath: path, date: now)
            record.isEnabled = false
            record.note = "macOS ignores /etc/launchd.conf since OS X 10.10. Some old malware used it; check where it came from."
            record.trigger = "Not run by current macOS"
            return ([record], GuardianSourceStatus(source: .launchdConf, state: .read, count: 1))
        }
    }

    // MARK: Login and logout hooks

    /// `LoginHook`/`LogoutHook` of `com.apple.loginwindow`, from the preference files this user can read.
    /// Hooks set for the root account (`sudo defaults write …`) live in root's preferences, which need an administrator.
    static func loginHooks(preferenceFiles: [String], now: Date) -> (records: [GuardianStartupRecord], status: GuardianSourceStatus) {
        var records: [GuardianStartupRecord] = []
        var seen = Set<String>()
        for file in preferenceFiles {
            guard let plist = GuardianReopenReader.readPlist(file) else { continue }
            for (key, kind) in [("LoginHook", GuardianStartupKind.loginHook), ("LogoutHook", GuardianStartupKind.logoutHook)] {
                guard let value = (plist[key] as? String)?.trimmingCharacters(in: .whitespaces), !value.isEmpty,
                      seen.insert(key + "|" + value).inserted else { continue }
                var record = GuardianStartupRecord(source: .loginHooks, key: key + "|" + file, kind: kind,
                                                   name: (value as NSString).lastPathComponent, identifier: key,
                                                   programPath: value.hasPrefix("/") ? value : nil, configPath: file, date: now)
                record.isEnabled = true
                record.trigger = kind == .loginHook ? "Runs as root when you log in" : "Runs as root when you log out"
                record.note = "Login and logout hooks are deprecated. macOS runs them with administrator rights."
                records.append(record)
            }
        }
        var status = GuardianSourceStatus(source: .loginHooks, state: .read, count: records.count)
        status.note = "Hooks set for the root account need an administrator to check."
        return (records, status)
    }

    // MARK: Plug-ins

    struct PluginFolder: Sendable, Hashable {
        var path: String
        var kind: GuardianStartupKind
        var suffix: String
    }

    static func pluginFolders(home: String) -> [PluginFolder] {
        [
            PluginFolder(path: home + "/Library/Spotlight", kind: .spotlightImporter, suffix: ".mdimporter"),
            PluginFolder(path: "/Library/Spotlight", kind: .spotlightImporter, suffix: ".mdimporter"),
            PluginFolder(path: home + "/Library/QuickLook", kind: .quickLookPlugin, suffix: ".qlgenerator"),
            PluginFolder(path: "/Library/QuickLook", kind: .quickLookPlugin, suffix: ".qlgenerator"),
        ]
    }

    /// Spotlight importers and Quick Look generators that macOS loads by itself.
    static func plugins(folders: [PluginFolder], quickLookGeneratorsSupported: Bool, now: Date) -> (records: [GuardianStartupRecord], status: GuardianSourceStatus) {
        var records: [GuardianStartupRecord] = []
        var blocked = false
        for folder in folders {
            switch PrivacyFileAccess.list(folder.path) {
            case .missing: continue
            case .blocked: blocked = true
            case .entries(let entries):
                for entry in entries.sorted(by: { $0.name < $1.name }) where entry.name.hasSuffix(folder.suffix) {
                    let name = (entry.name as NSString).deletingPathExtension
                    var record = GuardianStartupRecord(source: .plugins, key: entry.path, kind: folder.kind, name: name,
                                                       identifier: bundleIdentifier(entry.path), programPath: entry.path,
                                                       configPath: entry.path, date: now)
                    if folder.kind == .quickLookPlugin {
                        record.isEnabled = quickLookGeneratorsSupported
                        record.trigger = quickLookGeneratorsSupported ? "Loaded when Finder shows previews" : "Not loaded by this macOS version"
                        if !quickLookGeneratorsSupported { record.note = "macOS 15 and later no longer load Quick Look generators." }
                    } else {
                        record.isEnabled = true
                        record.trigger = "Loaded by Spotlight while it indexes files"
                    }
                    records.append(record)
                }
            }
        }
        let state: GuardianSourceStatus.State = records.isEmpty ? (blocked ? .needsFullDiskAccess : .notPresent) : .read
        return (records, GuardianSourceStatus(source: .plugins, state: state, count: records.count))
    }

    static func bundleIdentifier(_ bundlePath: String) -> String? {
        GuardianReopenReader.readPlist(bundlePath + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String
    }
}

// MARK: - App extensions (pluginkit)

/// One line of `pluginkit -m -v`.
struct GuardianPluginKitEntry: Sendable, Hashable {
    /// "+" elected to use, "-" ignored, "!" debug, "=" superseded, "?" unknown, nil when no election was made.
    var election: Character?
    var identifier: String
    var version: String?
    var uuid: String?
    var registered: Date?
    var path: String?
}

/// Parses `pluginkit -m -v` (one plug-in per line: election mark, `identifier(version)`, UUID,
/// registration time and path, separated by tabs).
enum GuardianPluginKitParser {
    static func parse(_ output: String) -> [GuardianPluginKitEntry] {
        output.split(separator: "\n").compactMap { raw in
            let line = String(raw)
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            var election: Character?
            if let first = line.first, "+-!=?".contains(first) { election = first }
            let body = (election == nil ? line : String(line.dropFirst())).trimmingCharacters(in: .whitespaces)
            guard !body.hasPrefix("(") else { return nil } // "(518 plug-ins)", "(no matches)"
            let fields = body.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = fields.first, !first.isEmpty else { return nil }
            var identifier = first
            var version: String?
            if first.hasSuffix(")"), let open = first.lastIndex(of: "(") {
                identifier = String(first[..<open])
                version = String(first[first.index(after: open)..<first.index(before: first.endIndex)])
            }
            guard !identifier.isEmpty, !identifier.contains(" ") else { return nil }
            return GuardianPluginKitEntry(
                election: election,
                identifier: identifier,
                version: version,
                uuid: fields.count > 1 ? fields[1] : nil,
                registered: fields.count > 2 ? parseDate(fields[2]) : nil,
                path: fields.count > 3 && fields[3].hasPrefix("/") ? fields[3] : nil
            )
        }
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: text)
    }
}

/// Which extension points run by themselves, without the person using the extension.
enum GuardianExtensionPoints {
    struct Classification: Sendable, Hashable {
        var kind: GuardianStartupKind
        var title: String
        /// Finder Sync extensions run only when switched on ("+").
        var requiresElection: Bool
    }

    static func classify(_ point: String) -> Classification? {
        switch point {
        case "com.apple.FinderSync":
            return Classification(kind: .finderSyncExtension, title: "Runs whenever Finder is open", requiresElection: true)
        case "com.apple.fileprovider-nonui":
            return Classification(kind: .backgroundExtension, title: "Syncs files in the background (File Provider)", requiresElection: false)
        case "com.apple.spotlight.import":
            return Classification(kind: .spotlightImporter, title: "Loaded by Spotlight while it indexes files", requiresElection: false)
        default:
            return nil
        }
    }

    /// `NSExtensionPointIdentifier` (or ExtensionKit's `EXExtensionPointIdentifier`) of an extension bundle.
    static func extensionPoint(ofBundle path: String) -> String? {
        guard let plist = GuardianReopenReader.readPlist(path + "/Contents/Info.plist") else { return nil }
        if let point = (plist["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String { return point }
        return (plist["EXAppExtensionAttributes"] as? [String: Any])?["EXExtensionPointIdentifier"] as? String
    }

    static func isApple(_ entry: GuardianPluginKitEntry) -> Bool {
        entry.identifier.lowercased().hasPrefix("com.apple.") || entry.path?.hasPrefix("/System/") == true
            || entry.path?.hasPrefix("/Library/Apple/") == true
    }

    /// Records for third-party extensions that run by themselves; the count of the rest.
    static func records(
        from entries: [GuardianPluginKitEntry],
        extensionPoint: (String) -> String? = GuardianExtensionPoints.extensionPoint(ofBundle:),
        now: Date
    ) -> (records: [GuardianStartupRecord], onDemand: Int) {
        var records: [GuardianStartupRecord] = []
        var onDemand = 0
        var seen = Set<String>()
        for entry in entries where !isApple(entry) {
            guard seen.insert(entry.identifier).inserted else { continue }
            guard let path = entry.path, let point = extensionPoint(path), let classification = classify(point) else {
                onDemand += 1
                continue
            }
            let owner = LaunchdProgramAnalyzer.outermostAppBundle(in: path)
            var record = GuardianStartupRecord(source: .appExtensions, key: entry.identifier, kind: classification.kind,
                                               name: ((path as NSString).lastPathComponent as NSString).deletingPathExtension,
                                               identifier: entry.identifier, programPath: path, date: now)
            record.ownerPath = owner
            record.ownerName = owner.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
            record.isEnabled = classification.requiresElection ? entry.election == "+" : entry.election != "-"
            record.trigger = classification.title
            records.append(record)
        }
        return (records, onDemand)
    }
}
