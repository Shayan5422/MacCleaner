import Darwin
import Foundation

// MARK: - Model

/// What kind of background item macOS's Background Task Management tracks.
enum GuardianBTMKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// An app registered to open at login by itself (`SMAppService.mainApp`), or the app that owns other items.
    case app
    /// A helper app inside an app's `Contents/Library/LoginItems`.
    case loginItem
    /// `SMAppService.agent` / `.daemon`.
    case agent, daemon
    /// Property lists in `LaunchAgents` / `LaunchDaemons` folders.
    case legacyAgent, legacyDaemon
    /// Groups the items of one developer (not something that runs).
    case developer
    case backgroundTasks
    case spotlight, quickLook, dockTile
    case userItem, curated
    case unknown

    init(typeName: String, code: Int?) {
        let name = typeName.lowercased()
        if name.contains("legacy") && name.contains("daemon") { self = .legacyDaemon }
        else if name.contains("legacy") && name.contains("agent") { self = .legacyAgent }
        else if name.contains("login item") { self = .loginItem }
        else if name.contains("daemon") { self = .daemon }
        else if name.contains("agent") { self = .agent }
        else if name.contains("background task") { self = .backgroundTasks }
        else if name.contains("developer") { self = .developer }
        else if name.contains("spotlight") { self = .spotlight }
        else if name.contains("quicklook") || name.contains("quick look") { self = .quickLook }
        else if name.contains("dock tile") { self = .dockTile }
        else if name.contains("user item") { self = .userItem }
        else if name.contains("curated") { self = .curated }
        else if name == "app" || name.hasSuffix(" app") { self = .app }
        else {
            switch code.map({ $0 & 0xFFFF }) {
            case 0x2?: self = .app
            case 0x4?: self = .loginItem
            case 0x8?: self = code.map { $0 & 0x10000 != 0 } == true ? .legacyAgent : .agent
            case 0x10?: self = code.map { $0 & 0x10000 != 0 } == true ? .legacyDaemon : .daemon
            case 0x20?: self = .developer
            default: self = .unknown
            }
        }
    }

    var title: String {
        switch self {
        case .app: return "Opens at login (set in the app)"
        case .loginItem: return "Login helper"
        case .agent: return "App background agent"
        case .daemon: return "App background daemon"
        case .legacyAgent: return "Launch agent"
        case .legacyDaemon: return "Launch daemon"
        case .developer: return "Developer"
        case .backgroundTasks: return "Background tasks"
        case .spotlight: return "Spotlight importer"
        case .quickLook: return "Quick Look plug-in"
        case .dockTile: return "Dock tile plug-in"
        case .userItem: return "Login item"
        case .curated: return "Curated item"
        case .unknown: return "Background item"
        }
    }

    var symbolName: String {
        switch self {
        case .app: return "power.circle"
        case .loginItem, .userItem: return StartupItemKind.loginItem.symbolName
        case .agent, .legacyAgent: return StartupItemKind.userAgent.symbolName
        case .daemon, .legacyDaemon: return StartupItemKind.systemDaemon.symbolName
        case .developer: return "person.crop.square"
        case .backgroundTasks: return "clock.arrow.2.circlepath"
        case .spotlight: return "magnifyingglass"
        case .quickLook: return "eye"
        case .dockTile: return "dock.rectangle"
        case .curated, .unknown: return "app.badge"
        }
    }

    /// Something that runs (developer groups and curated placeholders don't).
    var isRunnable: Bool {
        switch self {
        case .developer, .curated: return false
        default: return true
        }
    }
}

/// The state macOS records for an item ("Disposition").
struct GuardianBTMDisposition: Codable, Sendable, Hashable {
    /// The app or installer turned it on.
    var enabled: Bool?
    /// The person allows it (System Settings › General › Login Items & Extensions › Allow in the Background).
    var allowed: Bool?
    /// Shown in System Settings (older macOS versions print it).
    var visible: Bool?
    /// macOS has shown its "Background item added" notification.
    var notified: Bool?
    var rawValue: Int?

    /// Will run: turned on and allowed.
    var isActive: Bool { enabled == true && allowed != false }
}

/// One item of `sfltool dumpbtm`.
struct GuardianBTMItem: Codable, Sendable, Hashable, Identifiable {
    var uid: Int
    var uuid: String?
    var name: String?
    var developerName: String?
    var teamIdentifier: String?
    var typeName: String
    var typeCode: Int?
    var kind: GuardianBTMKind
    var flags: [String] = []
    var disposition: GuardianBTMDisposition
    var identifier: String?
    /// The URL field as printed.
    var url: String?
    /// The item's file (app, helper or property list) as a path, when it could be worked out.
    var path: String?
    var executablePath: String?
    var bundleIdentifier: String?
    var parentIdentifier: String?
    var embeddedIdentifiers: [String] = []
    var associatedBundleIdentifiers: [String] = []
    var generation: Int?
    var lastUse: Date?

    var id: String { "\(uid)|" + (identifier ?? uuid ?? name ?? "") }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let bundleIdentifier { return bundleIdentifier }
        if let path { return ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
        return identifier ?? "Unnamed item"
    }

    var isLegacy: Bool { flags.contains("legacy") }
    var isSandboxed: Bool { flags.contains("sandboxed") }

    /// Part of macOS (Apple's own apps register items too).
    var isApple: Bool {
        let identifiers = [bundleIdentifier, identifier.map(GuardianBTMParser.strippedIdentifier)].compactMap { $0?.lowercased() }
        if identifiers.contains(where: { $0.hasPrefix("com.apple.") }) { return true }
        return path?.hasPrefix("/System/") == true
    }

    /// Will start automatically.
    var startsAutomatically: Bool {
        guard kind.isRunnable, disposition.isActive else { return false }
        // An "app" record is only a login item when it's enabled itself (otherwise it just owns other items).
        return true
    }
}

/// Records for one user (or the system) in the dump.
struct GuardianBTMUserSection: Codable, Sendable, Hashable {
    var uid: Int
    var uuid: String?
    /// "ServiceManagement migrated", "LaunchServices registered"... as printed.
    var properties: [String: String] = [:]
    var itemCount: Int
}

/// A complete `sfltool dumpbtm` result.
struct GuardianBTMDump: Codable, Sendable, Hashable {
    var date: Date
    var sections: [GuardianBTMUserSection]
    var items: [GuardianBTMItem]
    /// Run with administrator rights (older macOS versions need them).
    var usedAdministrator: Bool

    /// Items of this account and the system (other accounts' items aren't shown).
    func relevantItems(currentUID: Int = Int(getuid())) -> [GuardianBTMItem] {
        items.filter { $0.uid == currentUID || $0.uid < 1 }
    }

    var otherAccountCount: Int {
        Set(sections.map(\.uid).filter { $0 >= 500 && $0 != Int(getuid()) }).count
    }
}

// MARK: - Parser

/// Parses the output of `sfltool dumpbtm`.
///
/// The format isn't documented and has changed between macOS versions, so parsing is lenient:
/// every field is optional, unknown keys are ignored, `(null)` means no value, and both `file://`
/// URLs (older versions) and plain or bundle-relative paths (current versions) are understood.
/// Built from the output of macOS 27 (sfltool 2026) and the macOS 13–15 format documented by
/// security researchers; no administrator prompt was used to develop it.
enum GuardianBTMParser {
    static func parse(_ output: String, homeForUID: (Int) -> String? = GuardianBTMParser.homeDirectory(forUID:)) -> (sections: [GuardianBTMUserSection], items: [GuardianBTMItem]) {
        let text = output.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var sections: [GuardianBTMUserSection] = []
        var items: [GuardianBTMItem] = []

        var currentUID: Int?
        var currentUUID: String?
        var sectionProperties: [String: String] = [:]
        var sectionItemCount = 0
        var inItems = false
        var fields: [String: String]?
        var lists: [String: [String]] = [:]
        var activeList: String?

        func finishItem() {
            if let current = fields, let uid = currentUID {
                items.append(makeItem(uid: uid, fields: current, lists: lists))
                sectionItemCount += 1
            }
            fields = nil
            lists = [:]
            activeList = nil
        }

        func finishSection() {
            finishItem()
            if let uid = currentUID {
                sections.append(GuardianBTMUserSection(uid: uid, uuid: currentUUID, properties: sectionProperties, itemCount: sectionItemCount))
            }
            currentUID = nil
            currentUUID = nil
            sectionProperties = [:]
            sectionItemCount = 0
            inItems = false
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                activeList = nil
                continue
            }
            if trimmed.hasPrefix("====") { continue }

            if let header = sectionHeader(trimmed) {
                finishSection()
                currentUID = header.uid
                currentUUID = header.uuid
                continue
            }
            guard currentUID != nil else { continue }

            if trimmed == "Items:" {
                inItems = true
                continue
            }
            if !inItems {
                if let pair = keyValue(trimmed) { sectionProperties[pair.key] = pair.value }
                continue
            }

            // "#12:" starts an item; "#1: 16.com.example.helper" is an entry of a list field.
            if let entry = numberedEntry(trimmed) {
                if entry.value.isEmpty {
                    finishItem()
                    fields = [:]
                } else if let list = activeList {
                    lists[list, default: []].append(entry.value)
                }
                continue
            }
            guard fields != nil, let pair = keyValue(trimmed) else { continue }
            if pair.value.isEmpty {
                activeList = pair.key
                lists[pair.key] = lists[pair.key] ?? []
            } else {
                activeList = nil
                fields?[pair.key] = pair.value
            }
        }
        finishSection()

        // Bundle-relative URLs ("Contents/Library/LoginItems/Helper.app") belong to the parent app.
        let pathsByIdentifier = Dictionary(items.compactMap { item in item.identifier.flatMap { id in item.path.map { (id + "|\(item.uid)", $0) } } },
                                           uniquingKeysWith: { first, _ in first })
        items = items.map { item in
            var resolved = item
            if let url = item.url, item.path == nil, !url.hasPrefix("/"), !url.contains("://"),
               let parent = item.parentIdentifier, let parentPath = pathsByIdentifier[parent + "|\(item.uid)"] {
                resolved.path = parentPath + "/" + url
            }
            if let path = resolved.path { resolved.path = mapHome(path, uid: item.uid, homeForUID: homeForUID) }
            if let executable = resolved.executablePath { resolved.executablePath = mapHome(executable, uid: item.uid, homeForUID: homeForUID) }
            return resolved
        }
        return (sections, items)
    }

    /// "Records for UID 501 : 3C47867B-…" → (501, "3C47867B-…").
    static func sectionHeader(_ line: String) -> (uid: Int, uuid: String?)? {
        guard line.hasPrefix("Records for UID") else { return nil }
        let rest = line.dropFirst("Records for UID".count).trimmingCharacters(in: .whitespaces)
        let parts = rest.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first, let uid = Int(first) else { return nil }
        return (uid, parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil)
    }

    /// "#3:" or "#1: value".
    static func numberedEntry(_ line: String) -> (number: Int, value: String)? {
        guard line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { return nil }
        guard let number = Int(line[line.index(after: line.startIndex)..<colon]) else { return nil }
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return (number, value)
    }

    /// "Developer Name: Docker Inc" → ("Developer Name", "Docker Inc"). Splits at the first ": ".
    static func keyValue(_ line: String) -> (key: String, value: String)? {
        if line.hasSuffix(":"), !line.contains(": ") {
            let key = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : (key, "")
        }
        guard let range = line.range(of: ": ") else { return nil }
        let key = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.first?.isLetter == true else { return nil }
        let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    private static func makeItem(uid: Int, fields: [String: String], lists: [String: [String]]) -> GuardianBTMItem {
        func value(_ key: String) -> String? {
            guard let raw = fields[key] else { return nil }
            return raw == "(null)" || raw.isEmpty ? nil : raw
        }
        let type = parseCoded(value("Type") ?? "")
        let flags = parseCoded(value("Flags") ?? "")
        let disposition = parseDisposition(value("Disposition") ?? "")
        let url = value("URL")
        var associated = lists["Assoc. Bundle IDs"] ?? []
        if let inline = value("Assoc. Bundle IDs") { associated += bracketList(inline) }
        return GuardianBTMItem(
            uid: uid,
            uuid: value("UUID"),
            name: value("Name"),
            developerName: value("Developer Name"),
            teamIdentifier: value("Team Identifier"),
            typeName: type.text,
            typeCode: type.code,
            kind: GuardianBTMKind(typeName: type.text, code: type.code),
            flags: bracketList(flags.text),
            disposition: disposition,
            identifier: value("Identifier"),
            url: url,
            path: url.flatMap(pathFromURL),
            executablePath: value("Executable Path").flatMap(pathFromURL),
            bundleIdentifier: value("Bundle Identifier"),
            parentIdentifier: value("Parent Identifier"),
            embeddedIdentifiers: lists["Embedded Item Identifiers"] ?? [],
            associatedBundleIdentifiers: associated,
            generation: value("Generation").flatMap { Int($0) },
            lastUse: value("Last Use").flatMap(parseDate)
        )
    }

    /// "legacy agent (0x10008)" → ("legacy agent", 0x10008).
    static func parseCoded(_ text: String) -> (text: String, code: Int?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else { return (trimmed, nil) }
        let number = trimmed[trimmed.index(after: open)...].dropLast().trimmingCharacters(in: .whitespaces)
        guard let code = parseInteger(number) else { return (trimmed, nil) }
        return (trimmed[..<open].trimmingCharacters(in: .whitespaces), code)
    }

    static func parseInteger(_ text: String) -> Int? {
        let lowered = text.lowercased()
        if lowered.hasPrefix("0x") { return UInt64(lowered.dropFirst(2), radix: 16).map { Int(truncatingIfNeeded: $0) } }
        return Int(lowered)
    }

    /// "[enabled, allowed, visible, notified] (0xb)" → flags; "not notified"/"disallowed" are negatives.
    static func parseDisposition(_ text: String) -> GuardianBTMDisposition {
        let coded = parseCoded(text)
        var result = GuardianBTMDisposition(rawValue: coded.code)
        for token in bracketList(coded.text).map({ $0.lowercased() }) {
            switch token {
            case "enabled": result.enabled = true
            case "disabled": result.enabled = false
            case "allowed": result.allowed = true
            case "disallowed", "not allowed": result.allowed = false
            case "visible": result.visible = true
            case "invisible", "hidden", "not visible": result.visible = false
            case "notified": result.notified = true
            case "not notified": result.notified = false
            default: break
            }
        }
        // Older output without words: fall back to the bits (enabled 0x1, allowed 0x2, visible 0x4, notified 0x8).
        if result.enabled == nil, result.allowed == nil, let raw = coded.code {
            result.enabled = raw & 0x1 != 0
            result.allowed = raw & 0x2 != 0
            result.notified = raw & 0x8 != 0
        }
        return result
    }

    /// "[ legacy, curated ]" → ["legacy", "curated"]; also "[ com.a com.b ]".
    static func bracketList(_ text: String) -> [String] {
        var body = text.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("[") { body.removeFirst() }
        if body.hasSuffix("]") { body.removeLast() }
        return body.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            // "not notified" is split into two words above; rejoin negations.
            .reduce(into: [String]()) { result, word in
                if let last = result.last, last == "not" { result[result.count - 1] = "not " + word } else { result.append(word) }
            }
    }

    /// `file:///Applications/Docker.app/`, `/Library/LaunchDaemons/x.plist`, or a bundle-relative path (returned as is).
    static func pathFromURL(_ text: String) -> String? {
        if text.hasPrefix("file://") {
            guard let url = URL(string: text) else { return nil }
            let path = url.path
            return path.isEmpty ? nil : path
        }
        guard text.hasPrefix("/") else { return nil }
        return text.count > 1 && text.hasSuffix("/") ? String(text.dropLast()) : text
    }

    /// macOS prints home folders as `/Users/<uid>/…`; map them to the real home folder.
    static func mapHome(_ path: String, uid: Int, homeForUID: (Int) -> String?) -> String {
        let prefix = "/Users/\(uid)"
        guard uid >= 0, PathUtilities.isSameOrDescendant(path, of: prefix), let home = homeForUID(uid) else { return path }
        return home + path.dropFirst(prefix.count)
    }

    static func homeDirectory(forUID uid: Int) -> String? {
        guard uid >= 0, let entry = getpwuid(uid_t(uid)), let directory = entry.pointee.pw_dir else { return nil }
        return String(cString: directory)
    }

    /// "2026-10-16 14:36:26+02:00".
    static func parseDate(_ text: String) -> Date? {
        for format in ["yyyy-MM-dd HH:mm:ssXXXXX", "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ssZ"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// "16.com.example.helper" → "com.example.helper" (the number is the item type).
    static func strippedIdentifier(_ identifier: String) -> String {
        guard let dot = identifier.firstIndex(of: "."), Int(identifier[..<dot]) != nil else { return identifier }
        return String(identifier[identifier.index(after: dot)...])
    }
}

// MARK: - Running the dump

enum GuardianBTMError: LocalizedError, Equatable {
    case cancelled
    case unreadableOutput
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Cancelled. Nothing was listed."
        case .unreadableOutput: return "macOS returned a list Mac Cleaner couldn't read."
        case .failed(let reason): return "macOS couldn't list background items: \(reason)"
        }
    }
}

/// Asks macOS for every background item with `sfltool dumpbtm`. Only ever runs when the person
/// clicks the button. It first runs without privileges (current macOS versions allow that, so no
/// password is needed); if macOS refuses, it asks for an administrator password through the
/// standard macOS prompt. Read-only: nothing is changed.
enum GuardianBTMService {
    static let sfltool = "/usr/bin/sfltool"
    static let osascript = "/usr/bin/osascript"

    /// AppleScript that runs the dump with administrator privileges. "without altering line endings"
    /// keeps line feeds (AppleScript would turn them into carriage returns).
    static let administratorScript = "do shell script \"/usr/bin/sfltool dumpbtm\" with administrator privileges without altering line endings"

    static func dump(runner: GuardianCommandRunner = GuardianBTMService.liveRunner, allowAdministratorPrompt: Bool = true) async throws -> GuardianBTMDump {
        if let output = try? await runner(sfltool, ["dumpbtm"]), output.succeeded, looksLikeDump(output.standardOutput) {
            return try makeDump(output.standardOutput, usedAdministrator: false)
        }
        guard allowAdministratorPrompt else { throw GuardianBTMError.failed("administrator rights are needed on this macOS version") }
        let result = try await runner(osascript, ["-e", administratorScript])
        if !result.succeeded {
            let text = result.combinedOutput
            if text.contains("-128") || text.lowercased().contains("user canceled") { throw GuardianBTMError.cancelled }
            throw GuardianBTMError.failed(text.split(separator: "\n").last.map(String.init) ?? "exit code \(result.exitCode)")
        }
        return try makeDump(result.standardOutput, usedAdministrator: true)
    }

    static let liveRunner: GuardianCommandRunner = { executable, arguments in
        // The dump can take half a minute while macOS gathers the information.
        try await ProcessRunner.run(executable, arguments: arguments, timeout: 180, maxOutputBytes: 32 * 1024 * 1024)
    }

    static func looksLikeDump(_ output: String) -> Bool {
        output.contains("Records for UID")
    }

    static func makeDump(_ output: String, usedAdministrator: Bool, date: Date = Date()) throws -> GuardianBTMDump {
        guard looksLikeDump(output) else { throw GuardianBTMError.unreadableOutput }
        let parsed = GuardianBTMParser.parse(output)
        return GuardianBTMDump(date: date, sections: parsed.sections, items: parsed.items, usedAdministrator: usedAdministrator)
    }
}
