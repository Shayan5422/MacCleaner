import Foundation

// MARK: - Property list values

/// A property-list value converted into a `Sendable` tree, so job definitions can
/// travel between background work and the UI and be shown key by key.
indirect enum LaunchdPlistValue: Sendable, Hashable {
    case string(String)
    case integer(Int64)
    case real(Double)
    case bool(Bool)
    case date(Date)
    case data(Int)
    case array([LaunchdPlistValue])
    case dictionary([LaunchdPlistEntry])

    /// Converts a value produced by `PropertyListSerialization`.
    init(propertyListValue value: Any) {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .real(number.doubleValue)
            } else {
                self = .integer(number.int64Value)
            }
        } else if let string = value as? String {
            self = .string(string)
        } else if let date = value as? Date {
            self = .date(date)
        } else if let data = value as? Data {
            self = .data(data.count)
        } else if let array = value as? [Any] {
            self = .array(array.map(LaunchdPlistValue.init(propertyListValue:)))
        } else if let dictionary = value as? [String: Any] {
            self = .dictionary(dictionary.keys.sorted().map { LaunchdPlistEntry(key: $0, value: LaunchdPlistValue(propertyListValue: dictionary[$0] as Any)) })
        } else {
            self = .string(String(describing: value))
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .integer(let value): return value != 0
        case .string(let value):
            switch value.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .integer(let value): return Int(clamping: value)
        case .real(let value) where value.isFinite: return Int(value)
        case .string(let value): return Int(value.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    var arrayValue: [LaunchdPlistValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    var dictionaryValue: [LaunchdPlistEntry]? {
        if case .dictionary(let entries) = self { return entries }
        return nil
    }

    /// Strings of an array value, or the value itself when it is a single string.
    var stringList: [String] {
        switch self {
        case .string(let value): return [value]
        case .array(let values): return values.compactMap(\.stringValue)
        default: return []
        }
    }

    subscript(key: String) -> LaunchdPlistValue? {
        dictionaryValue?.first { $0.key == key }?.value
    }

    /// Short, human-readable rendering of a leaf value.
    var displayString: String {
        switch self {
        case .string(let value): return value
        case .integer(let value): return String(value)
        case .real(let value): return value.formatted(.number.precision(.fractionLength(0...4)))
        case .bool(let value): return value ? "true" : "false"
        case .date(let value): return DateFormatting.short(value)
        case .data(let count): return "<\(ByteFormatting.string(Int64(count)))>"
        case .array(let values): return values.isEmpty ? "(empty list)" : "\(values.count) item\(values.count == 1 ? "" : "s")"
        case .dictionary(let entries): return entries.isEmpty ? "(empty)" : "\(entries.count) key\(entries.count == 1 ? "" : "s")"
        }
    }
}

struct LaunchdPlistEntry: Sendable, Hashable {
    var key: String
    var value: LaunchdPlistValue
}

/// One line of a flattened property list, for display with indentation.
struct LaunchdPlistRow: Identifiable, Sendable, Hashable {
    var id: Int
    var depth: Int
    var key: String
    /// nil for container rows (dictionaries and arrays) that have children.
    var value: String?
}

extension Array where Element == LaunchdPlistEntry {
    /// Flattens nested dictionaries and arrays into indented rows (capped to keep huge plists readable).
    func flattenedRows(limit: Int = 500) -> [LaunchdPlistRow] {
        var rows: [LaunchdPlistRow] = []
        func visit(_ key: String, _ value: LaunchdPlistValue, depth: Int) {
            guard rows.count < limit else { return }
            switch value {
            case .dictionary(let entries) where !entries.isEmpty:
                rows.append(LaunchdPlistRow(id: rows.count, depth: depth, key: key, value: nil))
                for entry in entries { visit(entry.key, entry.value, depth: depth + 1) }
            case .array(let values) where !values.isEmpty:
                rows.append(LaunchdPlistRow(id: rows.count, depth: depth, key: key, value: nil))
                for (index, element) in values.enumerated() { visit("[\(index)]", element, depth: depth + 1) }
            default:
                rows.append(LaunchdPlistRow(id: rows.count, depth: depth, key: key, value: value.displayString))
            }
        }
        for entry in self { visit(entry.key, entry.value, depth: 0) }
        return rows
    }
}

// MARK: - Job definition

/// How launchd keeps a job alive.
enum LaunchdKeepAlive: Sendable, Hashable {
    case off
    case always
    /// Kept alive only while conditions hold (for example `SuccessfulExit` or `NetworkState`).
    case conditional([String])

    var isEnabled: Bool { self != .off }

    var summary: String {
        switch self {
        case .off: return "Not kept running"
        case .always: return "Restarted whenever it quits"
        case .conditional(let conditions):
            let names = conditions.map(Self.conditionTitle).joined(separator: ", ")
            return names.isEmpty ? "Restarted under some conditions" : "Restarted when: \(names)"
        }
    }

    private static func conditionTitle(_ key: String) -> String {
        switch key {
        case "SuccessfulExit": return "it exits"
        case "Crashed": return "it crashes"
        case "NetworkState": return "the network is up"
        case "PathState": return "a file exists"
        case "OtherJobEnabled", "OtherJobActive": return "another job runs"
        case "AfterInitialDemand": return "after first use"
        default: return key
        }
    }
}

/// One entry of `StartCalendarInterval`. Missing fields are wildcards, as in cron.
struct LaunchdCalendarInterval: Sendable, Hashable {
    var minute: Int?
    var hour: Int?
    var day: Int?
    var weekday: Int?
    var month: Int?

    init(minute: Int? = nil, hour: Int? = nil, day: Int? = nil, weekday: Int? = nil, month: Int? = nil) {
        self.minute = minute
        self.hour = hour
        self.day = day
        self.weekday = weekday
        self.month = month
    }

    init(entries: [LaunchdPlistEntry]) {
        func value(_ key: String) -> Int? { entries.first { $0.key == key }?.value.intValue }
        self.init(minute: value("Minute"), hour: value("Hour"), day: value("Day"), weekday: value("Weekday"), month: value("Month"))
    }

    /// "Daily at 03:15", "Mondays at 09:00", "Hourly at :30", "Every minute".
    var summary: String {
        let time: String?
        switch (hour, minute) {
        case let (hour?, minute?): time = String(format: "%02d:%02d", hour, minute)
        case let (hour?, nil): time = String(format: "every minute from %02d:00 to %02d:59", hour, hour)
        default: time = nil
        }

        // The rest of the interface is English, so names are too (independent of the region setting).
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        var qualifiers: [String] = []
        if let month, (1...12).contains(month) {
            qualifiers.append(calendar.monthSymbols[month - 1])
        }
        if let day { qualifiers.append("day \(day)") }
        if let weekday {
            let index = ((weekday % 7) + 7) % 7 // 0 and 7 are both Sunday
            qualifiers.append(calendar.weekdaySymbols[index] + "s")
        }

        if qualifiers.isEmpty {
            if let time { return hour != nil && minute != nil ? "Daily at \(time)" : "Daily, \(time)" }
            if let minute { return String(format: "Hourly at :%02d", minute) }
            return "Every minute"
        }
        let when = qualifiers.joined(separator: ", ")
        if let time { return hour != nil && minute != nil ? "\(when) at \(time)" : "\(when), \(time)" }
        if let minute { return "\(when), hourly at :" + String(format: "%02d", minute) }
        return "\(when), every minute"
    }
}

/// The parts of a launchd property list that matter for reviewing a startup item.
struct LaunchdJobDefinition: Sendable, Hashable {
    var label: String?
    var program: String?
    var programArguments: [String] = []
    /// SMAppService-style executable path relative to the containing app bundle.
    var bundleProgram: String?
    var runAtLoad = false
    var keepAlive: LaunchdKeepAlive = .off
    var startInterval: Int?
    var startCalendarIntervals: [LaunchdCalendarInterval] = []
    var disabled = false
    var watchPaths: [String] = []
    var queueDirectories: [String] = []
    var startOnMount = false
    var limitLoadToSessionTypes: [String] = []
    var associatedBundleIdentifiers: [String] = []
    var userName: String?
    var workingDirectory: String?
    var processType: String?
    var machServices: [String] = []
    var hasSockets = false
    var hasLaunchEvents = false
    /// Every top-level key, for the detail view.
    var entries: [LaunchdPlistEntry] = []

    /// The executable launchd starts: `Program`, else the first `ProgramArguments` entry, else `BundleProgram`.
    var executable: String? {
        if let program, !program.isEmpty { return program }
        if let first = programArguments.first, !first.isEmpty { return first }
        if let bundleProgram, !bundleProgram.isEmpty { return bundleProgram }
        return nil
    }

    /// The full argument vector launchd passes (`argv[0]` first).
    var argumentVector: [String] {
        if !programArguments.isEmpty { return programArguments }
        if let executable { return [executable] }
        return []
    }

    /// `true` when the plist defines no label or nothing to run, so launchd ignores it.
    var isEmpty: Bool { (label ?? "").isEmpty || executable == nil }

    /// Starts on its own, without another process asking for it.
    var startsAutomatically: Bool {
        runAtLoad || keepAlive == .always || startInterval != nil || !startCalendarIntervals.isEmpty
            || !watchPaths.isEmpty || !queueDirectories.isEmpty || startOnMount
    }

    /// Plain-language description of when the job runs.
    var triggerSummary: String {
        var parts: [String] = []
        if runAtLoad { parts.append("Starts at login") }
        switch keepAlive {
        case .always: parts.append("kept running")
        case .conditional: parts.append("restarted when needed")
        case .off: break
        }
        if let startInterval, startInterval > 0 {
            parts.append("every \(DateFormatting.duration(TimeInterval(startInterval)))")
        }
        if let first = startCalendarIntervals.first {
            parts.append(startCalendarIntervals.count == 1 ? first.summary : "\(first.summary) (+\(startCalendarIntervals.count - 1) more)")
        }
        if !watchPaths.isEmpty || !queueDirectories.isEmpty { parts.append("when files change") }
        if startOnMount { parts.append("when a disk is mounted") }
        if parts.isEmpty {
            if !machServices.isEmpty || hasSockets || hasLaunchEvents { return "Starts on demand" }
            return "Starts only when asked"
        }
        var text = parts.joined(separator: ", ")
        text = text.prefix(1).uppercased() + text.dropFirst()
        return text
    }

    /// Flattened plist contents for display.
    var displayRows: [LaunchdPlistRow] { entries.flattenedRows() }
}

enum LaunchdPlistError: LocalizedError, Sendable, Equatable {
    case unreadable(String)
    case notADictionary
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let reason): return "The property list couldn't be read: \(reason)"
        case .notADictionary: return "The property list doesn't contain a launchd job."
        case .malformed(let reason): return "The property list is damaged: \(reason)"
        }
    }
}

/// Reads launchd job property lists (XML or binary).
enum LaunchdPlistParser {
    static func parse(contentsOf path: String) throws -> LaunchdJobDefinition {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        } catch {
            let nsError = error as NSError
            let posix = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError)?.code
            if nsError.code == NSFileReadNoPermissionError || posix == Int(EACCES) || posix == Int(EPERM) {
                throw LaunchdPlistError.unreadable("permission denied")
            }
            throw LaunchdPlistError.unreadable(nsError.localizedDescription)
        }
        return try parse(data: data)
    }

    static func parse(data: Data) throws -> LaunchdJobDefinition {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw LaunchdPlistError.malformed((error as NSError).localizedDescription)
        }
        guard let dictionary = object as? [String: Any] else { throw LaunchdPlistError.notADictionary }
        return parse(dictionary: dictionary)
    }

    static func parse(dictionary: [String: Any]) -> LaunchdJobDefinition {
        let entries = dictionary.keys.sorted().map {
            LaunchdPlistEntry(key: $0, value: LaunchdPlistValue(propertyListValue: dictionary[$0] as Any))
        }
        return parse(entries: entries)
    }

    static func parse(entries: [LaunchdPlistEntry]) -> LaunchdJobDefinition {
        func value(_ key: String) -> LaunchdPlistValue? { entries.first { $0.key == key }?.value }

        var job = LaunchdJobDefinition()
        job.entries = entries
        job.label = value("Label")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        job.program = value("Program")?.stringValue
        job.programArguments = value("ProgramArguments")?.arrayValue?.compactMap(\.stringValue) ?? []
        job.bundleProgram = value("BundleProgram")?.stringValue
        job.runAtLoad = value("RunAtLoad")?.boolValue ?? false
        job.disabled = value("Disabled")?.boolValue ?? false
        job.startOnMount = value("StartOnMount")?.boolValue ?? false
        job.userName = value("UserName")?.stringValue
        job.workingDirectory = value("WorkingDirectory")?.stringValue
        job.processType = value("ProcessType")?.stringValue
        job.watchPaths = value("WatchPaths")?.stringList ?? []
        job.queueDirectories = value("QueueDirectories")?.stringList ?? []
        job.limitLoadToSessionTypes = value("LimitLoadToSessionType")?.stringList ?? []
        job.associatedBundleIdentifiers = value("AssociatedBundleIdentifiers")?.stringList ?? []
        job.machServices = value("MachServices")?.dictionaryValue?.map(\.key) ?? []
        job.hasSockets = value("Sockets") != nil
        job.hasLaunchEvents = value("LaunchEvents") != nil

        if let interval = value("StartInterval")?.intValue, interval > 0 {
            job.startInterval = interval
        }

        switch value("StartCalendarInterval") {
        case .dictionary(let entries)?:
            job.startCalendarIntervals = [LaunchdCalendarInterval(entries: entries)]
        case .array(let values)?:
            job.startCalendarIntervals = values.compactMap { $0.dictionaryValue.map(LaunchdCalendarInterval.init(entries:)) }
        default:
            break
        }

        switch value("KeepAlive") {
        case .dictionary(let conditions)?:
            job.keepAlive = conditions.isEmpty ? .off : .conditional(conditions.map(\.key))
        case let other?:
            job.keepAlive = other.boolValue == true ? .always : .off
        case nil:
            job.keepAlive = .off
        }
        return job
    }
}
