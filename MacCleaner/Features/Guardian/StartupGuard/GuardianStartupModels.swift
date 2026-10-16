import Foundation

// MARK: - Sources and kinds

/// Where Startup Guard looks for things that start automatically.
///
/// Every check says which sources it could read ("covered"). Items of sources a check didn't
/// cover are kept as they were, so a source that is temporarily unreadable never shows up as
/// a burst of removals.
enum GuardianStartupSource: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case userLaunchAgents
    case systemLaunchAgents
    case systemLaunchDaemons
    case appBackgroundItems
    case loginItems
    case reopenSetting
    /// Apps macOS opened at login for the app itself (registered with `SMAppService`), seen by the login analysis.
    case appLoginItems
    /// Every background item macOS tracks (`sfltool dumpbtm`), when the person lists them.
    case registeredItems
    case cronJobs
    case legacyStartupItems
    case periodicScripts
    case launchdConf
    case loginHooks
    case appExtensions
    case plugins

    var id: String { rawValue }

    var title: String {
        switch self {
        case .userLaunchAgents: return "Your launch agents"
        case .systemLaunchAgents: return "Launch agents for all users"
        case .systemLaunchDaemons: return "Launch daemons"
        case .appBackgroundItems: return "App background items"
        case .loginItems: return "Open at Login"
        case .reopenSetting: return "Reopen windows at login"
        case .appLoginItems: return "Apps that open themselves at login"
        case .registeredItems: return "Background items macOS tracks"
        case .cronJobs: return "Your cron jobs"
        case .legacyStartupItems: return "Legacy startup items"
        case .periodicScripts: return "Periodic scripts"
        case .launchdConf: return "launchd.conf"
        case .loginHooks: return "Login and logout hooks"
        case .appExtensions: return "Finder and background extensions"
        case .plugins: return "Spotlight and Quick Look plug-ins"
        }
    }

    /// Sources a regular check reads (the others come from the login analysis and the background-item list).
    static let regular: [GuardianStartupSource] = [
        .userLaunchAgents, .systemLaunchAgents, .systemLaunchDaemons, .appBackgroundItems, .loginItems, .reopenSetting,
        .cronJobs, .legacyStartupItems, .periodicScripts, .launchdConf, .loginHooks, .appExtensions, .plugins,
    ]
}

/// What an item is, in the person's terms.
enum GuardianStartupKind: String, Codable, Sendable, Hashable, CaseIterable {
    case loginItem
    case userAgent
    case systemAgent
    case systemDaemon
    case appBackgroundItem
    case reopenSetting
    /// The app registered itself to open at login (`SMAppService.mainApp`).
    case appLoginItem
    /// Listed by macOS's background task management (`sfltool dumpbtm`).
    case registeredItem
    case cronJob
    case legacyStartupItem
    case periodicScript
    case launchdConf
    case loginHook
    case logoutHook
    case finderSyncExtension
    case backgroundExtension
    case spotlightImporter
    case quickLookPlugin

    init(_ kind: StartupItemKind) {
        switch kind {
        case .loginItem: self = .loginItem
        case .userAgent: self = .userAgent
        case .appBackgroundItem: self = .appBackgroundItem
        case .systemAgent: self = .systemAgent
        case .systemDaemon: self = .systemDaemon
        }
    }

    var title: String {
        switch self {
        case .loginItem: return "Login item"
        case .userAgent: return "Launch agent (your account)"
        case .systemAgent: return "Launch agent (all users)"
        case .systemDaemon: return "Launch daemon (system)"
        case .appBackgroundItem: return "App background item"
        case .reopenSetting: return "macOS setting"
        case .appLoginItem: return "Opens at login (set in the app)"
        case .registeredItem: return "Background item"
        case .cronJob: return "Cron job"
        case .legacyStartupItem: return "Legacy startup item"
        case .periodicScript: return "Periodic script"
        case .launchdConf: return "launchd.conf"
        case .loginHook: return "Login hook"
        case .logoutHook: return "Logout hook"
        case .finderSyncExtension: return "Finder extension"
        case .backgroundExtension: return "App extension"
        case .spotlightImporter: return "Spotlight importer"
        case .quickLookPlugin: return "Quick Look plug-in"
        }
    }

    var symbolName: String {
        switch self {
        case .loginItem: return StartupItemKind.loginItem.symbolName
        case .userAgent: return StartupItemKind.userAgent.symbolName
        case .systemAgent: return StartupItemKind.systemAgent.symbolName
        case .systemDaemon: return StartupItemKind.systemDaemon.symbolName
        case .appBackgroundItem: return StartupItemKind.appBackgroundItem.symbolName
        case .reopenSetting: return "macwindow.on.rectangle"
        case .appLoginItem: return "power.circle"
        case .registeredItem: return "list.bullet.rectangle"
        case .cronJob: return "calendar.badge.clock"
        case .legacyStartupItem: return "clock.badge.questionmark"
        case .periodicScript: return "calendar"
        case .launchdConf: return "doc.text"
        case .loginHook, .logoutHook: return "arrow.right.to.line"
        case .finderSyncExtension: return "folder.badge.gearshape"
        case .backgroundExtension: return "puzzlepiece.extension"
        case .spotlightImporter: return "magnifyingglass"
        case .quickLookPlugin: return "eye"
        }
    }

    /// Mac Cleaner can turn these off itself (with confirmation).
    var canTurnOff: Bool { self == .userAgent }
}

/// Something that limits how completely a source could be read.
enum GuardianAccessRequirement: String, Codable, Sendable, Hashable {
    case fullDiskAccess
    case administrator
    case automation

    var title: String {
        switch self {
        case .fullDiskAccess: return "Needs Full Disk Access"
        case .administrator: return "Needs an administrator"
        case .automation: return "Needs Automation access"
        }
    }
}

// MARK: - Code signature

/// The parts of a code signature Startup Guard compares and shows.
struct GuardianSignatureSummary: Codable, Sendable, Hashable {
    var category: SecurityTrustCategory
    var developer: String?
    var teamIdentifier: String?
    var summary: String

    init(category: SecurityTrustCategory, developer: String? = nil, teamIdentifier: String? = nil, summary: String? = nil) {
        self.category = category
        self.developer = developer
        self.teamIdentifier = teamIdentifier
        self.summary = summary ?? SecurityCodeTrust.summary(category: category, packageManager: nil)
    }

    init(_ evaluation: SecurityCodeEvaluation) {
        self.init(category: evaluation.category, developer: evaluation.developer,
                  teamIdentifier: evaluation.signature.teamIdentifier, summary: evaluation.summary)
    }

    /// Developer ID with and without a confirmed notarization ticket count as the same trust,
    /// so an update that ships without a stapled ticket isn't reported as a signature change.
    var trustClass: String {
        switch category {
        case .developerID, .developerIDNotarized: return "developerID"
        default: return category.rawValue
        }
    }

    /// Couldn't be checked: never compared.
    var isKnown: Bool { category != .unknown }

    /// "signed by Google LLC", "unsigned", "not signed by an identified developer".
    var notificationPhrase: String {
        switch category {
        case .apple: return "signed by Apple"
        case .appStore: return "from the App Store"
        case .developerIDNotarized, .developerID, .appleDevelopment:
            return developer.map { "signed by \($0)" } ?? "signed by an identified developer"
        case .packageManager: return "built by \(developer ?? "a package manager")"
        case .script: return "a script (scripts aren't signed)"
        case .adHoc: return "not signed by an identified developer"
        case .untrustedCertificate: return "signed with a certificate not issued by Apple"
        case .unsigned: return "unsigned"
        case .invalid: return "with an invalid signature"
        case .revoked: return "with a revoked signature"
        case .missing: return "its program is missing"
        case .unknown: return "signature not checked"
        }
    }

    /// Worth pointing out: no identified developer stands behind it.
    var isConcerning: Bool { category.isUnknownDeveloper && category != .script }
}

// MARK: - Records

/// One thing that starts automatically, as Startup Guard records it.
struct GuardianStartupRecord: Codable, Sendable, Hashable, Identifiable {
    /// `source|key`: stable across checks.
    var id: String
    var source: GuardianStartupSource
    var kind: GuardianStartupKind
    var name: String
    /// Label, bundle identifier, extension identifier or schedule.
    var identifier: String?
    /// The program, script or app it starts (a file or an `.app` bundle).
    var programPath: String?
    /// Arguments after the program.
    var arguments: [String] = []
    /// The property list, crontab or plug-in that defines it.
    var configPath: String?
    /// The app it belongs to, for its icon and name.
    var ownerName: String?
    var ownerPath: String?
    var signature: GuardianSignatureSummary?
    /// `nil` when unknown.
    var isEnabled: Bool?
    /// Starts at login, on a schedule or kept running (rather than only when another program asks).
    var startsAutomatically: Bool = true
    var isRunning: Bool?
    /// When it runs, in plain words.
    var trigger: String?
    var access: GuardianAccessRequirement?
    /// Extra explanation ("macOS no longer runs these").
    var note: String?
    var firstSeen: Date
    var lastChanged: Date
    /// Already there when Startup Guard first looked at its source.
    var isBaseline: Bool = false
    /// Its definition couldn't be read this time (a damaged property list, or one caught while being written).
    var isUnreadable: Bool = false

    init(
        source: GuardianStartupSource,
        key: String,
        kind: GuardianStartupKind,
        name: String,
        identifier: String? = nil,
        programPath: String? = nil,
        arguments: [String] = [],
        configPath: String? = nil,
        date: Date = Date()
    ) {
        self.id = source.rawValue + "|" + key
        self.source = source
        self.kind = kind
        self.name = name
        self.identifier = identifier
        self.programPath = programPath
        self.arguments = arguments
        self.configPath = configPath
        self.firstSeen = date
        self.lastChanged = date
    }

    /// Will start without the person doing anything.
    var willStartAutomatically: Bool { isEnabled != false && startsAutomatically }

    /// A name people recognize: "AnyDesk (service)" for the label "com.philandro.anydesk.service"
    /// of an item that belongs to AnyDesk; the plain name otherwise.
    var displayName: String {
        guard let owner = ownerName?.trimmingCharacters(in: .whitespaces), !owner.isEmpty else { return name }
        let isLabel = name.contains(".") && !name.contains(" ")
        if !isLabel && name.localizedCaseInsensitiveContains(owner) { return name }
        let detail = isLabel ? String(name.split(separator: ".").last ?? Substring(name)) : name
        if detail.isEmpty || detail.caseInsensitiveCompare(owner) == .orderedSame { return owner }
        return "\(owner) (\(detail))"
    }

    /// The command line, arguments quoted when they contain spaces.
    var commandLine: String? {
        guard let programPath else { return nil }
        let parts = [programPath] + arguments
        return parts.map { $0.contains(" ") || $0.isEmpty ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }

    /// File to reveal in Finder.
    var revealPath: String? { configPath ?? programPath }

    /// Path whose icon represents the item best.
    var iconPath: String? {
        if let ownerPath { return ownerPath }
        if let programPath, programPath.hasSuffix(".app") || programPath.hasSuffix(".appex") { return programPath }
        if let programPath, let app = LaunchdProgramAnalyzer.outermostAppBundle(in: programPath) { return app }
        return nil
    }

    /// Fields compared between checks; everything else (running state, names) may change freely.
    func differences(from other: GuardianStartupRecord) -> [GuardianStartupChange.Field] {
        var fields: [GuardianStartupChange.Field] = []
        if programPath.map(PathUtilities.normalize) != other.programPath.map(PathUtilities.normalize) { fields.append(.program) }
        if arguments != other.arguments { fields.append(.arguments) }
        if let enabled = isEnabled, let previous = other.isEnabled, enabled != previous { fields.append(.enabled) }
        if let signature, let previous = other.signature, signature.isKnown, previous.isKnown,
           signature.trustClass != previous.trustClass || (signature.teamIdentifier ?? "") != (previous.teamIdentifier ?? "") {
            fields.append(.signature)
        }
        return fields
    }
}

/// How complete one source was in a check.
struct GuardianSourceStatus: Codable, Sendable, Hashable, Identifiable {
    enum State: String, Codable, Sendable {
        case read
        /// Nothing there (or the mechanism doesn't exist on this macOS version).
        case notPresent
        /// macOS privacy protection blocked it.
        case needsFullDiskAccess
        case needsAdministrator
        case needsAutomation
        /// Not read in this check (rate-limited or not requested).
        case notChecked
        case failed
    }

    var source: GuardianStartupSource
    var state: State
    var count: Int = 0
    var note: String?

    var id: String { source.rawValue }

    var isCovered: Bool { state == .read || state == .notPresent }
}

/// Everything one check found.
struct GuardianStartupCollection: Sendable {
    var date: Date
    var records: [GuardianStartupRecord]
    var statuses: [GuardianSourceStatus]
    var reopen: GuardianReopenState?
    /// App extensions that only run when used (not startup items), counted for the inventory note.
    var onDemandExtensionCount: Int = 0

    var covered: Set<GuardianStartupSource> {
        Set(statuses.filter(\.isCovered).map(\.source))
    }
}

/// The stored inventory.
struct GuardianStartupSnapshot: Codable, Sendable {
    var version = 1
    /// When Startup Guard started watching.
    var createdAt: Date
    var updatedAt: Date
    var records: [GuardianStartupRecord]
    /// Sources read at least once (their items have a baseline).
    var coveredSources: Set<GuardianStartupSource>
    /// Last successful read per source (`GuardianStartupSource.rawValue` → date).
    var sourceCheckedAt: [String: Date] = [:]

    func records(of source: GuardianStartupSource) -> [GuardianStartupRecord] {
        records.filter { $0.source == source }
    }

    func checkedAt(_ source: GuardianStartupSource) -> Date? {
        sourceCheckedAt[source.rawValue]
    }
}

// MARK: - Changes

/// The antivirus verdict for a new startup item's program, provided by the coordinator's engine.
struct GuardianScanVerdict: Codable, Sendable, Hashable {
    /// Signature names that matched; empty when nothing was found.
    var detections: [String]
    var scannedAt: Date
    /// Who checked, e.g. "ClamAV signatures".
    var engine: String?

    init(detections: [String], scannedAt: Date = Date(), engine: String? = nil) {
        self.detections = detections
        self.scannedAt = scannedAt
        self.engine = engine
    }

    var isClean: Bool { detections.isEmpty }
}

/// Scans the program of a new or changed startup item. `programPath` is a file or an `.app`
/// bundle. Return nil when nothing could be scanned (engine or definitions unavailable): that's
/// shown as "not scanned", never as clean.
typealias GuardianStartupScanHook = @Sendable (_ programPath: String) async -> GuardianScanVerdict?

/// One entry of the change timeline.
struct GuardianStartupChange: Codable, Sendable, Hashable, Identifiable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case added, removed, changed

        var title: String {
            switch self {
            case .added: return "Added"
            case .removed: return "Removed"
            case .changed: return "Changed"
            }
        }

        var symbolName: String {
            switch self {
            case .added: return "plus.circle.fill"
            case .removed: return "minus.circle.fill"
            case .changed: return "pencil.circle.fill"
            }
        }
    }

    enum Field: String, Codable, Sendable, Hashable {
        case program, arguments, enabled, signature
    }

    var id: UUID
    var date: Date
    var kind: Kind
    var fields: [Field]
    /// The item as it is now (as it last was, for removals).
    var record: GuardianStartupRecord
    /// The item before the change.
    var previous: GuardianStartupRecord?
    /// A new version of the same app: same bundle and developer.
    var isRoutineUpdate: Bool
    var verdict: GuardianScanVerdict?
    /// Scanning was requested and is running.
    var isScanning: Bool = false

    init(id: UUID = UUID(), date: Date, kind: Kind, fields: [Field] = [], record: GuardianStartupRecord,
         previous: GuardianStartupRecord? = nil, isRoutineUpdate: Bool = false) {
        self.id = id
        self.date = date
        self.kind = kind
        self.fields = fields
        self.record = record
        self.previous = previous
        self.isRoutineUpdate = isRoutineUpdate
    }

    /// One line describing what happened.
    var summary: String {
        switch kind {
        case .added:
            if record.isEnabled == false { return "Added, turned off" }
            return record.startsAutomatically ? "Will start automatically" : "Starts when another program asks for it"
        case .removed:
            return "No longer starts automatically"
        case .changed:
            if isRoutineUpdate { return "Updated by its app" }
            var parts: [String] = []
            if fields.contains(.enabled) { parts.append(record.isEnabled == true ? "Turned on" : "Turned off") }
            if fields.contains(.program) {
                // The new program is shown next to the summary; name the old one.
                parts.append("Program changed, was \(previous?.programPath.map(PathUtilities.abbreviate) ?? "none")")
            } else if fields.contains(.arguments) {
                parts.append("Arguments changed")
            }
            if fields.contains(.signature), let old = previous?.signature, let new = record.signature {
                parts.append("Signature: \(old.category.title) → \(new.category.title)")
            }
            return parts.isEmpty ? "Changed" : parts.joined(separator: " · ")
        }
    }

    /// Severity for the activity feed.
    var severity: FindingSeverity {
        if let verdict, !verdict.isClean { return .threat }
        switch kind {
        case .removed:
            return .info
        case .added:
            return record.signature?.isConcerning == true && record.isEnabled != false ? .suspicious : .info
        case .changed:
            if isRoutineUpdate { return .info }
            if fields.contains(.signature) || fields.contains(.program), record.signature?.isConcerning == true { return .suspicious }
            return .info
        }
    }

    /// Program or signature changes deserve the same attention as new items.
    var isSecurityRelevantChange: Bool {
        kind == .changed && !isRoutineUpdate && (fields.contains(.program) || fields.contains(.signature))
    }
}
