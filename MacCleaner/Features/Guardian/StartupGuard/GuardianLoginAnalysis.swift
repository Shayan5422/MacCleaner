import Darwin
import Foundation

// MARK: - Model

/// Why something opened automatically at login.
enum GuardianLoginCause: Codable, Sendable, Hashable {
    /// Listed under Open at Login (System Events).
    case loginItem
    /// macOS opened it because the app registered itself to open at login (`SMAppService`).
    case appLoginItem
    /// "Reopen windows when logging back in": it was open when the person logged out.
    case reopened
    /// Started by a launch agent or daemon.
    case launchAgent(label: String, plistPath: String?, isUserAgent: Bool)
    /// Started by a helper inside an app (login helper or background agent).
    case appHelper(appName: String, appPath: String)
    /// Another app opened it.
    case openedByApp(name: String?)
    case unknown

    var title: String {
        switch self {
        case .loginItem: return "Login item"
        case .appLoginItem: return "Opens at login (set in the app)"
        case .reopened: return "Reopened by macOS"
        case .launchAgent(_, _, let isUserAgent): return isUserAgent ? "Launch agent" : "Launch agent (all users)"
        case .appHelper: return "App helper"
        case .openedByApp: return "Opened by another app"
        case .unknown: return "Cause unknown"
        }
    }

    var explanation: String {
        switch self {
        case .loginItem:
            return "It's listed under Open at Login in System Settings."
        case .appLoginItem:
            return "The app asked macOS to open it at login. It may not appear in older login-item lists; change it in the app's settings or in System Settings › General › Login Items & Extensions."
        case .reopened:
            return "Reopens at login because it was open when you logged out (Reopen windows when logging back in)."
        case .launchAgent(let label, _, _):
            return "Started by the launch agent “\(label)”."
        case .appHelper(let appName, _):
            return "Part of \(appName), started in the background by the app or by macOS."
        case .openedByApp(let name):
            return name.map { "Opened by “\($0)”." } ?? "Opened by a helper that has quit since."
        case .unknown:
            return "It started within a couple of minutes after you logged in, but macOS doesn't say what opened it."
        }
    }

    var symbolName: String {
        switch self {
        case .loginItem: return StartupItemKind.loginItem.symbolName
        case .appLoginItem: return "power.circle"
        case .reopened: return "macwindow.on.rectangle"
        case .launchAgent: return StartupItemKind.userAgent.symbolName
        case .appHelper: return StartupItemKind.appBackgroundItem.symbolName
        case .openedByApp: return "arrow.up.forward.app"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// How an app shows itself: in the Dock, only in the menu bar, or not at all.
enum GuardianAppPresentation: String, Codable, Sendable, Hashable {
    case regular, menuBar, background

    var note: String? {
        switch self {
        case .regular: return nil
        case .menuBar: return "menu bar"
        case .background: return "no window"
        }
    }
}

/// An app or background program that opened automatically at the last login.
struct GuardianOpenedAtLoginItem: Codable, Sendable, Hashable, Identifiable {
    var name: String
    var bundleIdentifier: String?
    /// The app bundle, or the program for background processes.
    var path: String
    var isApp: Bool
    var pid: Int32
    var started: Date
    var cause: GuardianLoginCause
    var signature: GuardianSignatureSummary?
    var presentation: GuardianAppPresentation = .background

    var id: String { path }
}

/// What opened automatically at one login.
struct GuardianLoginAnalysis: Codable, Sendable, Hashable {
    var loginDate: Date
    /// How the login time was found ("login record", "loginwindow process", "Dock process").
    var loginSource: String
    var analyzedAt: Date
    var window: TimeInterval
    var items: [GuardianOpenedAtLoginItem]
    /// Apps opened from the Dock, Finder or Spotlight in that window (not counted as automatic).
    var openedByYouCount: Int
    /// `false` when macOS didn't report which app launched which (causes are then less certain).
    var hasLaunchParents: Bool

    /// The analysis ran soon enough after login to see everything that opened then.
    var isComplete: Bool { analyzedAt.timeIntervalSince(loginDate) <= 15 * 60 }

    var apps: [GuardianOpenedAtLoginItem] { items.filter(\.isApp) }
    var backgroundPrograms: [GuardianOpenedAtLoginItem] { items.filter { !$0.isApp } }
}

// MARK: - Login time

/// Finds when the person logged in, from the login records and the session's first processes.
enum GuardianLoginClock {
    struct Estimate: Sendable, Hashable {
        var date: Date
        var source: String
    }

    /// The console login of the current user from the login records (`utmpx`), newest first.
    static func consoleLoginDate(user: String = NSUserName()) -> Date? {
        var newest: Date?
        setutxent()
        defer { endutxent() }
        while let entry = getutxent() {
            let record = entry.pointee
            guard Int32(record.ut_type) == USER_PROCESS else { continue }
            let name = withUnsafeBytes(of: record.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let line = withUnsafeBytes(of: record.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard name == user, line == "console" else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(record.ut_tv.tv_sec) + TimeInterval(record.ut_tv.tv_usec) / 1_000_000)
            if newest.map({ date > $0 }) ?? true { newest = date }
        }
        return newest
    }

    /// Combines the login record with the start of this user's `loginwindow` and `Dock`.
    /// The process times are precise to the second; the login record confirms they belong to this session.
    static func estimate(consoleLogin: Date?, processes: [ProcessSnapshot], uid: uid_t = getuid()) -> Estimate? {
        func start(of name: String) -> Date? {
            processes.filter { $0.uid == uid && $0.name == name }.compactMap(\.startTime).min()
        }
        let loginwindow = start(of: "loginwindow")
        let dock = start(of: "Dock")
        if let loginwindow, consoleLogin.map({ abs($0.timeIntervalSince(loginwindow)) < 10 * 60 }) ?? true {
            return Estimate(date: loginwindow, source: "loginwindow process")
        }
        if let consoleLogin { return Estimate(date: consoleLogin, source: "login record") }
        if let dock { return Estimate(date: dock, source: "Dock process") }
        return nil
    }
}

// MARK: - lsappinfo

/// One app of `lsappinfo list`: who launched it (its parent) and when.
struct GuardianLSAppInfo: Sendable, Hashable {
    var name: String
    var asn: String
    var bundleIdentifier: String?
    var bundlePath: String?
    var executablePath: String?
    var pid: Int32?
    /// "Foreground", "UIElement", "BackgroundOnly".
    var type: String?
    var parentName: String?
    var parentASN: String?
    var launchTime: Date?
}

/// Parses `lsappinfo list`. The format isn't a stable API, so every field is optional.
enum GuardianLSAppInfoParser {
    static func parse(_ output: String, timeZone: TimeZone = .current) -> [GuardianLSAppInfo] {
        var results: [GuardianLSAppInfo] = []
        var current: GuardianLSAppInfo?
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"

        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let header = header(line) {
                if let current { results.append(current) }
                current = GuardianLSAppInfo(name: header.name, asn: header.asn)
                continue
            }
            guard current != nil else { continue }
            if let value = quoted(after: "bundleID=", in: line) {
                current?.bundleIdentifier = value
            } else if let value = quoted(after: "bundle path=", in: line) {
                current?.bundlePath = value
            } else if let value = quoted(after: "executable path=", in: line) {
                current?.executablePath = value
            } else if line.hasPrefix("pid = ") {
                let number = line.dropFirst("pid = ".count).prefix { $0.isNumber }
                current?.pid = Int32(number)
                if let type = quoted(after: "type=", in: line) { current?.type = type }
            } else if line.hasPrefix("parentASN=") {
                current?.parentName = quoted(after: "parentASN=", in: line)
                if let range = line.range(of: "ASN:") {
                    current?.parentASN = asnValue(line[range.lowerBound...])
                }
            } else if line.hasPrefix("launch time =") {
                let text = line.dropFirst("launch time =".count).trimmingCharacters(in: .whitespaces)
                let stamp = String(text.prefix(19))
                current?.launchTime = formatter.date(from: stamp)
            }
        }
        if let current { results.append(current) }
        return results
    }

    /// `12) "Google Chrome" ASN:0x0-0x54054: (in front)` → ("Google Chrome", "0x0-0x54054").
    static func header(_ line: String) -> (name: String, asn: String)? {
        guard let paren = line.firstIndex(of: ")"), line[..<paren].allSatisfy(\.isNumber), !line[..<paren].isEmpty else { return nil }
        let rest = line[line.index(after: paren)...].trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("\""), let asnRange = rest.range(of: "\" ASN:", options: .backwards) else { return nil }
        let name = String(rest[rest.index(after: rest.startIndex)..<asnRange.lowerBound])
        guard let asn = asnValue(rest[rest.index(asnRange.lowerBound, offsetBy: 2)...]) else { return nil }
        return (name, asn)
    }

    /// `ASN:0x0-0x2e02e:` → "0x0-0x2e02e".
    static func asnValue(_ text: Substring) -> String? {
        guard text.hasPrefix("ASN:") else { return nil }
        let value = text.dropFirst(4).prefix { $0 != ":" && $0 != " " }
        return value.isEmpty ? nil : String(value)
    }

    /// `key="value"` → value; `key=[ NULL ]` → nil.
    static func quoted(after key: String, in line: String) -> String? {
        guard let range = line.range(of: key) else { return nil }
        let rest = line[range.upperBound...]
        guard rest.hasPrefix("\"") else { return nil }
        let body = rest.dropFirst()
        guard let end = body.firstIndex(of: "\"") else { return nil }
        let value = String(body[..<end])
        return value.isEmpty ? nil : value
    }
}

// MARK: - Analysis

/// A running app as `NSWorkspace` reports it.
struct GuardianRunningApp: Sendable, Hashable {
    var pid: Int32
    var name: String
    var bundleIdentifier: String?
    var bundlePath: String?
    var executablePath: String?
    var launchDate: Date?
    var presentation: GuardianAppPresentation = .regular
}

/// Works out what opened automatically at login, and why.
enum GuardianLoginAnalyzer {
    /// Apps of macOS that people use to open other apps: whatever they opened isn't automatic.
    static let personalLaunchers: Set<String> = ["Dock", "Finder", "Spotlight", "Siri", "Launchpad", "Apps", "Terminal", "Script Editor"]
    /// macOS processes that open apps at login.
    static let loginLaunchers: Set<String> = ["loginwindow", "talagentd"]

    struct Context: Sendable {
        var login: GuardianLoginClock.Estimate
        var window: TimeInterval = 120
        var now: Date = Date()
        var apps: [GuardianRunningApp]
        var processes: [ProcessSnapshot]
        var appInfo: [GuardianLSAppInfo]
        var launchd: GuardianStartupCollector.LaunchdState
        var records: [GuardianStartupRecord]
        var reopen: GuardianReopenState?
        var uid: uid_t = getuid()
        var ownPID: Int32 = getpid()
    }

    static func analyze(_ context: Context) -> GuardianLoginAnalysis {
        let start = context.login.date.addingTimeInterval(-10)
        let end = context.login.date.addingTimeInterval(context.window)
        let processesByPID = Dictionary(context.processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let infoByPID = Dictionary(context.appInfo.compactMap { info in info.pid.map { ($0, info) } }, uniquingKeysWith: { first, _ in first })
        let infoByASN = Dictionary(context.appInfo.map { ($0.asn, $0) }, uniquingKeysWith: { first, _ in first })
        let labelsByPID = labelsByPID(context.launchd)
        let reopenIDs = Set((context.reopen?.apps ?? []).compactMap { $0.bundleIdentifier?.lowercased() })
        let reopenPaths = Set((context.reopen?.apps ?? []).compactMap(\.path))
        let loginItemPaths = Set(context.records.filter { $0.kind == .loginItem }.compactMap(\.programPath))
        let jobRecords = context.records.filter { [.userAgent, .systemAgent, .systemDaemon, .appBackgroundItem].contains($0.kind) }
        let jobsByLabel = Dictionary(jobRecords.compactMap { record in record.identifier.map { ($0, record) } }, uniquingKeysWith: { first, _ in first })

        func startDate(pid: Int32, fallback: Date?) -> Date? {
            processesByPID[pid]?.startTime ?? fallback
        }

        var items: [GuardianOpenedAtLoginItem] = []
        var claimedBundles = Set<String>()
        /// Apps the person opened: their helpers aren't automatic either.
        var personalBundles = Set<String>()
        var openedByYou = 0

        // Apps
        for app in context.apps where app.pid != context.ownPID {
            guard let started = startDate(pid: app.pid, fallback: app.launchDate), started >= start, started <= end else { continue }
            guard processesByPID[app.pid].map({ $0.uid == context.uid }) ?? true else { continue }
            let path = app.bundlePath ?? app.executablePath ?? ""
            guard !path.isEmpty, !isApplePath(path), app.bundleIdentifier?.lowercased().hasPrefix("com.apple.") != true else { continue }
            let info = infoByPID[app.pid]
            if let parent = info?.parentName, personalLaunchers.contains(parent) {
                openedByYou += 1
                personalBundles.insert(path)
                continue
            }
            let cause = appCause(app: app, path: path, info: info, infoByASN: infoByASN, label: labelsByPID[app.pid],
                                 jobsByLabel: jobsByLabel, jobs: jobRecords, loginItemPaths: loginItemPaths,
                                 reopenIDs: reopenIDs, reopenPaths: reopenPaths)
            claimedBundles.insert(path)
            items.append(GuardianOpenedAtLoginItem(name: app.name, bundleIdentifier: app.bundleIdentifier, path: path, isApp: true,
                                                   pid: app.pid, started: started, cause: cause, presentation: app.presentation))
        }

        // Background programs launchd started for this user in the window (not apps, not part of macOS).
        let appPIDs = Set(context.apps.map(\.pid))
        var seenPrograms = Set<String>()
        for process in context.processes where process.uid == context.uid && process.parentPID == 1 && !appPIDs.contains(process.pid) && process.pid != context.ownPID {
            guard let started = process.startTime, started >= start, started <= end, let executable = process.executablePath,
                  !isApplePath(executable) else { continue }
            let bundle = LaunchdProgramAnalyzer.outermostAppBundle(in: executable)
            if let bundle, claimedBundles.contains(bundle) || personalBundles.contains(bundle) { continue }
            let key = bundle ?? executable
            guard seenPrograms.insert(key).inserted else { continue }
            if let bundle, let bundleID = ApplicationCatalog.read(path: bundle)?.bundleIdentifier, bundleID.lowercased().hasPrefix("com.apple.") { continue }
            let cause: GuardianLoginCause
            if let label = labelsByPID[process.pid], !label.hasPrefix("application.") {
                cause = jobCause(label: label, jobsByLabel: jobsByLabel)
            } else if let job = jobRecords.first(where: { record in
                record.willStartAutomatically && (record.programPath == executable
                    || bundle.map { PathUtilities.isSameOrDescendant(record.programPath ?? "", of: $0) } == true)
            }), let label = job.identifier {
                cause = jobCause(label: label, jobsByLabel: jobsByLabel)
            } else if let bundle {
                cause = .appHelper(appName: displayName(of: bundle), appPath: bundle)
            } else {
                cause = .unknown
            }
            items.append(GuardianOpenedAtLoginItem(name: bundle.map(displayName(of:)) ?? process.name, bundleIdentifier: nil, path: key,
                                                   isApp: false, pid: process.pid, started: started, cause: cause))
        }

        // Apps with windows first (the ones people notice opening), then menu bar and background apps, each by start time.
        func rank(_ item: GuardianOpenedAtLoginItem) -> Int {
            guard item.isApp else { return 3 }
            switch item.presentation {
            case .regular: return 0
            case .menuBar: return 1
            case .background: return 2
            }
        }
        items.sort { rank($0) != rank($1) ? rank($0) < rank($1) : $0.started < $1.started }
        return GuardianLoginAnalysis(loginDate: context.login.date, loginSource: context.login.source, analyzedAt: context.now,
                                     window: context.window, items: items, openedByYouCount: openedByYou,
                                     hasLaunchParents: !context.appInfo.isEmpty)
    }

    private static func appCause(
        app: GuardianRunningApp,
        path: String,
        info: GuardianLSAppInfo?,
        infoByASN: [String: GuardianLSAppInfo],
        label: String?,
        jobsByLabel: [String: GuardianStartupRecord],
        jobs: [GuardianStartupRecord],
        loginItemPaths: Set<String>,
        reopenIDs: Set<String>,
        reopenPaths: Set<String>
    ) -> GuardianLoginCause {
        let inReopenList = app.bundleIdentifier.map { reopenIDs.contains($0.lowercased()) } == true || reopenPaths.contains(path)
        // 1. A launch agent or helper job runs it directly.
        if let label, !label.hasPrefix("application.") {
            return jobCause(label: label, jobsByLabel: jobsByLabel)
        }
        // 2. Who launched it, according to LaunchServices.
        if let info {
            if let parent = info.parentName, loginLaunchers.contains(parent) {
                if inReopenList { return .reopened }
                if loginItemPaths.contains(path) { return .loginItem }
                return .appLoginItem
            }
            if let parentASN = info.parentASN {
                if let parent = infoByASN[parentASN] {
                    // Its own login helper (inside the app's bundle) opened it.
                    if let parentPath = parent.bundlePath, PathUtilities.isDescendant(parentPath, of: path) {
                        return .appHelper(appName: app.name, appPath: path)
                    }
                    return .openedByApp(name: parent.name)
                }
                // The launcher quit. Apps with a login helper are usually opened by it.
                if !LaunchdLocations.embeddedItems(inApp: path).loginItemApps.isEmpty {
                    return .appHelper(appName: app.name, appPath: path)
                }
                return .openedByApp(name: nil)
            }
        }
        // 3. No launcher recorded: match what's set up to start automatically (a program in this app's bundle).
        if let job = jobs.first(where: { $0.willStartAutomatically && PathUtilities.isSameOrDescendant($0.programPath ?? "", of: path) }),
           let label = job.identifier {
            return jobCause(label: label, jobsByLabel: jobsByLabel)
        }
        if loginItemPaths.contains(path) { return .loginItem }
        if inReopenList { return .reopened }
        if let executable = app.executablePath, let outer = LaunchdProgramAnalyzer.outermostAppBundle(in: executable), outer != path {
            return .appHelper(appName: displayName(of: outer), appPath: outer)
        }
        return .unknown
    }

    private static func jobCause(label: String, jobsByLabel: [String: GuardianStartupRecord]) -> GuardianLoginCause {
        guard let record = jobsByLabel[label] else { return .launchAgent(label: label, plistPath: nil, isUserAgent: true) }
        if record.kind == .appBackgroundItem, let owner = record.ownerPath {
            return .appHelper(appName: record.ownerName ?? displayName(of: owner), appPath: owner)
        }
        return .launchAgent(label: label, plistPath: record.configPath, isUserAgent: record.kind == .userAgent)
    }

    static func labelsByPID(_ launchd: GuardianStartupCollector.LaunchdState) -> [Int32: String] {
        var result: [Int32: String] = [:]
        for services in [launchd.gui, launchd.system].compactMap({ $0 }) {
            for (label, service) in services {
                if let pid = service.pid, result[pid] == nil || result[pid]?.hasPrefix("application.") == true { result[pid] = label }
            }
        }
        return result
    }

    static func isApplePath(_ path: String) -> Bool {
        let prefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/bin/", "/sbin/", "/Library/Apple/", "/private/var/db/",
                        "/Library/Developer/CommandLineTools/", "/Applications/Xcode.app/"]
        return prefixes.contains { path.hasPrefix($0) }
    }

    static func displayName(of bundlePath: String) -> String {
        ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// Records for apps that opened themselves at login, for the startup snapshot.
    static func appLoginRecords(_ analysis: GuardianLoginAnalysis) -> [GuardianStartupRecord] {
        analysis.items.filter { $0.cause == .appLoginItem }.map { item in
            var record = GuardianStartupRecord(source: .appLoginItems, key: item.bundleIdentifier ?? item.path, kind: .appLoginItem,
                                               name: item.name, identifier: item.bundleIdentifier, programPath: item.path,
                                               date: analysis.analyzedAt)
            record.ownerPath = item.path
            record.isEnabled = true
            record.trigger = "Seen opening at login on \(DateFormatting.day(analysis.loginDate))"
            record.signature = item.signature
            return record
        }
    }
}
