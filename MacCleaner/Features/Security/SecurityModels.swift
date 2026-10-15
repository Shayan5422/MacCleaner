import Foundation

/// What a security finding is about.
enum SecurityFindingCategory: String, Sendable, Hashable, CaseIterable, Codable {
    case protection
    case adware
    case persistence
    case codeSignature
    case download
    case shellStartup
    case scheduledTask
    case authorizationPlugin
    case configurationProfile
    case systemExtension

    var title: String {
        switch self {
        case .protection: return "macOS protection"
        case .adware: return "Adware or unwanted software"
        case .persistence: return "Startup item"
        case .codeSignature: return "App signature"
        case .download: return "Download"
        case .shellStartup: return "Shell startup file"
        case .scheduledTask: return "Scheduled task"
        case .authorizationPlugin: return "Login plug-in"
        case .configurationProfile: return "Configuration profile"
        case .systemExtension: return "System extension"
        }
    }

    var symbolName: String {
        switch self {
        case .protection: return "lock.shield"
        case .adware: return "ladybug"
        case .persistence: return "power.circle"
        case .codeSignature: return "signature"
        case .download: return "arrow.down.circle"
        case .shellStartup: return "terminal"
        case .scheduledTask: return "calendar.badge.clock"
        case .authorizationPlugin: return "person.badge.key"
        case .configurationProfile: return "gearshape.2"
        case .systemExtension: return "puzzlepiece.extension"
        }
    }
}

/// One fact supporting a finding, shown in the detail view.
struct SecurityEvidence: Sendable, Hashable, Identifiable {
    var label: String
    var value: String
    /// Shown with Reveal in Finder.
    var isPath = false

    var id: String { label + "|" + value }
}

/// What the person can do about a finding. Mac Cleaner only changes what macOS
/// lets a regular user change, and always asks first.
enum SecurityRemediation: Sendable, Hashable {
    case none
    /// A launch agent in `~/Library/LaunchAgents`: turn off (launchctl) or move the plist to the Trash.
    case userLaunchAgent(label: String?, plistPath: String)
    /// A system-wide launch agent or daemon: instructions and Reveal in Finder only.
    case systemLaunchItem(plistPath: String)
    /// A helper inside an app bundle, managed by that app.
    case appBackgroundItem(appPath: String)
    case loginItem(name: String, path: String?)
    case application(path: String)
    /// Downloads that can be moved to the Trash.
    case quarantinedFiles(paths: [String])
    case shellStartupFile(path: String)
    case cronJobs
    case settings(SystemSettingsPane)
    case deviceManagement
    case authorizationPlugin(path: String)
    /// Support files in a Library folder (for example a known adware folder) that can go to the Trash.
    case libraryItem(path: String)
    /// Apps without an identified developer: review them in the Applications list.
    case reviewApplications
}

/// Stable, process-independent hashing for finding identifiers (Swift's `Hasher` is seeded per launch).
enum SecurityHash {
    static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}

/// A security finding with its evidence. Converts to the app-wide `Finding`.
struct SecurityFinding: Identifiable, Sendable, Hashable {
    var id: String
    var severity: FindingSeverity
    var category: SecurityFindingCategory
    var title: String
    /// One line for lists.
    var summary: String
    /// Every reason the item was flagged.
    var reasons: [String] = []
    var path: String?
    var evidence: [SecurityEvidence] = []
    var recommendation: String?
    var remediation: SecurityRemediation = .none
    /// "Known adware/PUP rule match: Genieo" for rule-based threats.
    var ruleName: String?
    /// Hidden by the person ("Ignore"); excluded from counts.
    var isIgnored = false

    /// The finding in the shape Smart Scan and the Dashboard use.
    var finding: Finding {
        let detail = reasons.isEmpty ? summary : ([summary] + reasons.map { "• " + $0 }).joined(separator: "\n")
        return Finding(id: "security|" + id, area: .security, severity: severity, title: title, detail: detail,
                       path: path, recommendation: recommendation, destination: .security)
    }
}

/// An inventory entry of everything that starts automatically or hooks into the system.
struct SecurityPersistenceItem: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable, Hashable, CaseIterable {
        case loginItem, userLaunchAgent, systemLaunchAgent, systemLaunchDaemon, appBackgroundItem
        case cronJob, shellStartupFile, authorizationPlugin, systemExtension, configurationProfile

        var title: String {
            switch self {
            case .loginItem: return "Login item"
            case .userLaunchAgent: return "Launch agent (your account)"
            case .systemLaunchAgent: return "Launch agent (all users)"
            case .systemLaunchDaemon: return "Launch daemon"
            case .appBackgroundItem: return "App background item"
            case .cronJob: return "Cron job"
            case .shellStartupFile: return "Shell startup file"
            case .authorizationPlugin: return "Authorization plug-in"
            case .systemExtension: return "System extension"
            case .configurationProfile: return "Configuration profile"
            }
        }

        /// Lower-case name used inside finding titles ("Suspicious launch agent: …").
        var shortTitle: String {
            switch self {
            case .loginItem: return "login item"
            case .userLaunchAgent: return "launch agent"
            case .systemLaunchAgent: return "system launch agent"
            case .systemLaunchDaemon: return "launch daemon"
            case .appBackgroundItem: return "app background item"
            case .cronJob: return "cron job"
            case .shellStartupFile: return "shell startup file"
            case .authorizationPlugin: return "authorization plug-in"
            case .systemExtension: return "system extension"
            case .configurationProfile: return "configuration profile"
            }
        }

        var symbolName: String {
            switch self {
            case .loginItem: return "person.crop.circle.badge.checkmark"
            case .userLaunchAgent: return "gearshape.2"
            case .systemLaunchAgent: return "person.2.badge.gearshape"
            case .systemLaunchDaemon: return "cpu"
            case .appBackgroundItem: return "app.badge"
            case .cronJob: return "calendar.badge.clock"
            case .shellStartupFile: return "terminal"
            case .authorizationPlugin: return "person.badge.key"
            case .systemExtension: return "puzzlepiece.extension"
            case .configurationProfile: return "gearshape.2"
            }
        }

        init(_ kind: StartupItemKind) {
            switch kind {
            case .loginItem: self = .loginItem
            case .userAgent: self = .userLaunchAgent
            case .systemAgent: self = .systemLaunchAgent
            case .systemDaemon: self = .systemLaunchDaemon
            case .appBackgroundItem: self = .appBackgroundItem
            }
        }
    }

    var id: String
    var kind: Kind
    var name: String
    /// The plist, file or bundle that defines the item.
    var location: String?
    /// The program it runs.
    var target: String?
    var detail: String?
    var trust: SecurityTrustCategory?
    var trustSummary: String?
    var developer: String?
    var isRunning: Bool?
    /// Highest severity among findings about this item, if any.
    var severity: FindingSeverity?
    var findingID: String?
}

/// Code-signing review of an installed app.
struct SecurityAppRecord: Identifiable, Sendable, Hashable {
    var path: String
    var name: String
    var bundleIdentifier: String?
    var version: String
    var evaluation: SecurityCodeEvaluation

    var id: String { path }
}

/// An installed system extension, from `systemextensionsctl list`.
struct SecuritySystemExtension: Identifiable, Sendable, Hashable {
    var category: String
    var isEnabled: Bool
    var isActive: Bool
    var teamIdentifier: String
    var bundleIdentifier: String
    var version: String
    var name: String
    var state: String

    var id: String { category + "|" + teamIdentifier + "|" + bundleIdentifier }

    var categoryTitle: String {
        switch category {
        case "com.apple.system_extension.network_extension": return "Network extension"
        case "com.apple.system_extension.endpoint_security": return "Endpoint security extension"
        case "com.apple.system_extension.driver_extension": return "Driver extension"
        case "com.apple.system_extension.cmio": return "Camera extension"
        default: return "System extension"
        }
    }
}

/// A line of the current user's crontab.
struct SecurityCronJob: Sendable, Hashable {
    var schedule: String
    var command: String
    var lineNumber: Int
}

/// Configuration profiles and device management, as far as a regular user can see.
struct SecurityProfilesStatus: Sendable, Hashable {
    /// Profiles installed for the whole Mac (count only without administrator rights).
    var systemProfileCount: Int?
    /// Identifiers of profiles installed for this user.
    var userProfileIdentifiers: [String] = []
    var isMDMEnrolled: Bool?
    var isDEPEnrolled: Bool?
}

/// The result of a security scan.
struct SecurityReport: Sendable {
    var startedAt: Date
    var finishedAt: Date
    var posture: SecurityPosture
    /// Every finding, including ones the person chose to ignore (marked `isIgnored`).
    var findings: [SecurityFinding]
    var persistenceItems: [SecurityPersistenceItem]
    var applications: [SecurityAppRecord]
    var quarantinedFiles: [SecurityQuarantinedFile]
    var systemExtensions: [SecuritySystemExtension]
    /// What couldn't be checked, in plain words.
    var limitations: [String]
    var wasCancelled: Bool

    var activeFindings: [SecurityFinding] { findings.filter { !$0.isIgnored } }
    var ignoredFindings: [SecurityFinding] { findings.filter(\.isIgnored) }

    func count(_ severity: FindingSeverity) -> Int { activeFindings.filter { $0.severity == severity }.count }

    var threatCount: Int { count(.threat) }
    var suspiciousCount: Int { count(.suspicious) }
    var recommendationCount: Int { count(.recommendation) }
    var informationCount: Int { count(.info) }

    /// Counts by severity (ignored findings excluded).
    var countsBySeverity: [FindingSeverity: Int] {
        Dictionary(uniqueKeysWithValues: FindingSeverity.allCases.map { ($0, count($0)) })
    }

    /// One line, e.g. "No known threats · 2 suspicious items to review".
    var summary: String {
        SecurityReport.summaryLine(threats: threatCount, suspicious: suspiciousCount, recommendations: recommendationCount)
    }

    static func summaryLine(threats: Int, suspicious: Int, recommendations: Int) -> String {
        func plural(_ count: Int, _ singular: String, _ pluralForm: String) -> String {
            "\(count) \(count == 1 ? singular : pluralForm)"
        }
        if threats > 0 {
            var text = plural(threats, "known threat", "known threats") + " found"
            if suspicious > 0 { text += " · " + plural(suspicious, "suspicious item", "suspicious items") }
            return text
        }
        if suspicious > 0 {
            return "No known threats · " + plural(suspicious, "suspicious item", "suspicious items") + " to review"
        }
        if recommendations > 0 {
            return "No threats or suspicious items · " + plural(recommendations, "recommendation", "recommendations")
        }
        return "No threats or suspicious items found"
    }

    /// Compact, storable summary (for the Dashboard, History and Automation).
    var scanSummary: SecurityScanSummary {
        SecurityScanSummary(
            date: finishedAt,
            threats: threatCount,
            suspicious: suspiciousCount,
            recommendations: recommendationCount,
            information: informationCount,
            protectionsOn: posture.enabledCount,
            protectionsTotal: posture.totalCount,
            summary: summary
        )
    }
}

/// A storable summary of the last security scan.
struct SecurityScanSummary: Codable, Sendable, Hashable {
    var date: Date
    var threats: Int
    var suspicious: Int
    var recommendations: Int
    var information: Int
    var protectionsOn: Int
    var protectionsTotal: Int
    var summary: String
}
