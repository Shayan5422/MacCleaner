import Foundation
import ServiceManagement

/// Where a startup item comes from, which also decides how it can be managed.
enum StartupItemKind: String, Sendable, Hashable, CaseIterable, Identifiable {
    /// "Open at Login" apps, read through System Events.
    case loginItem
    /// Property lists in `~/Library/LaunchAgents`.
    case userAgent
    /// Helpers embedded in an app bundle (SMAppService or SMLoginItemSetEnabled).
    case appBackgroundItem
    /// Property lists in `/Library/LaunchAgents`.
    case systemAgent
    /// Property lists in `/Library/LaunchDaemons`.
    case systemDaemon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .loginItem: return "Login item"
        case .userAgent: return "Launch agent (your account)"
        case .appBackgroundItem: return "App background item"
        case .systemAgent: return "Launch agent (all users)"
        case .systemDaemon: return "Launch daemon (system)"
        }
    }

    var symbolName: String {
        switch self {
        case .loginItem: return "person.crop.circle.badge.checkmark"
        case .userAgent: return "gearshape.2"
        case .appBackgroundItem: return "app.badge"
        case .systemAgent: return "person.2.badge.gearshape"
        case .systemDaemon: return "cpu"
        }
    }

    /// Mac Cleaner can change these directly (with confirmation).
    var isUserManageable: Bool { self == .loginItem || self == .userAgent }
}

/// Background-item approval recorded by macOS (System Settings › Login Items & Extensions).
enum StartupBackgroundApproval: String, Sendable, Hashable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound

    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notRegistered: self = .notRegistered
        case .notFound: self = .notFound
        @unknown default: self = .notFound
        }
    }

    var title: String {
        switch self {
        case .enabled: return "Allowed in the background"
        case .requiresApproval: return "Turned off in System Settings"
        case .notRegistered: return "Not registered"
        case .notFound: return "Not tracked by macOS"
        }
    }
}

/// The current state of a startup item, most important first.
enum StartupItemState: Sendable, Hashable {
    case running(pid: Int32?)
    /// Loaded by launchd and waiting for its trigger (schedule, file change, request).
    case loaded
    /// Not loaded in this session.
    case notLoaded
    /// Turned off with launchctl or the plist's `Disabled` key.
    case disabled
    /// Switched off under "Allow in the Background" in System Settings.
    case offInSettings
    /// The program or app it starts no longer exists.
    case broken
    /// The property list is damaged or defines nothing to run, so launchd ignores it.
    case invalid
    /// A login item whose app isn't running right now.
    case notRunning
    case unknown

    var title: String {
        switch self {
        case .running: return "Running"
        case .loaded: return "Waiting"
        case .notLoaded: return "Not loaded"
        case .disabled: return "Turned off"
        case .offInSettings: return "Off in Settings"
        case .broken: return "Broken"
        case .invalid: return "Invalid"
        case .notRunning: return "Not running"
        case .unknown: return "Unknown"
        }
    }

    var explanation: String {
        switch self {
        case .running(let pid): return pid.map { "Running now (process \($0))." } ?? "Running now."
        case .loaded: return "Loaded by launchd and waiting for its schedule or a request."
        case .notLoaded: return "Not loaded right now. It loads at your next login unless it's turned off."
        case .disabled: return "Turned off. It won't start until you turn it back on."
        case .offInSettings: return "Switched off under Allow in the Background in System Settings › General › Login Items & Extensions."
        case .broken: return "The program it should start no longer exists."
        case .invalid: return "The property list is damaged or doesn't define a program, so launchd ignores it."
        case .notRunning: return "Opens at login, but isn't running right now."
        case .unknown: return "The status couldn't be determined."
        }
    }

    var symbolName: String {
        switch self {
        case .running: return "play.circle.fill"
        case .loaded: return "clock.fill"
        case .notLoaded: return "pause.circle"
        case .disabled: return "power.circle"
        case .offInSettings: return "switch.2"
        case .broken: return "exclamationmark.triangle.fill"
        case .invalid: return "doc.badge.ellipsis"
        case .notRunning: return "moon.zzz.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var isOff: Bool { self == .disabled || self == .offInSettings }
}

/// Resource use of the processes that belong to a startup item.
struct StartupResourceUsage: Sendable, Hashable {
    enum Impact: Int, Sendable, Hashable, Comparable {
        case low, medium, high

        static func < (lhs: Impact, rhs: Impact) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .low: return "Low impact"
            case .medium: return "Medium impact"
            case .high: return "High impact"
            }
        }
    }

    var processCount: Int
    var memoryBytes: UInt64
    var cpuTimeNanoseconds: UInt64
    /// Average share of one CPU core since the processes started.
    var averageCPU: Double?
    /// Some processes belong to another user, so their usage can't be read.
    var isPartial: Bool

    var impact: Impact {
        let cpu = averageCPU ?? 0
        if memoryBytes >= 500_000_000 || cpu >= 0.05 { return .high }
        if memoryBytes >= 150_000_000 || cpu >= 0.01 { return .medium }
        return .low
    }

    var summary: String {
        var parts: [String] = []
        if memoryBytes > 0 { parts.append(ByteFormatting.string(memoryBytes) + " memory") }
        if let averageCPU { parts.append(NumberFormatting.percent(averageCPU, digits: averageCPU < 0.1 ? 1 : 0) + " CPU (average)") }
        if parts.isEmpty { return isPartial ? "Usage not available (runs as another user)" : "No measurable usage" }
        return parts.joined(separator: " · ")
    }
}

/// A reason an item may be unnecessary. Mac Cleaner never acts on these by itself.
struct StartupConcern: Sendable, Hashable, Identifiable {
    enum Kind: String, Sendable, Hashable {
        case broken, empty, unusedApp, duplicate, keepAliveRarelyUsed, leftover
    }

    var kind: Kind
    var title: String
    var explanation: String

    var id: String { kind.rawValue }
}

/// The app an item belongs to, when that can be established reliably.
struct StartupOwnerApp: Sendable, Hashable {
    var name: String
    var path: String
    var bundleIdentifier: String?
    var lastUsedDate: Date?
}

/// One thing that starts automatically, from any source.
struct StartupItem: Identifiable, Sendable, Hashable {
    var id: String
    var kind: StartupItemKind
    var name: String
    var label: String?
    /// The launchd property list (launch agents, daemons, embedded agents).
    var plistPath: String?
    /// Where a symlinked property list points.
    var plistLinkDestination: String?
    var definition: LaunchdJobDefinition?
    var parseError: String?
    var analysis: LaunchdProgramAnalysis?
    /// The app, script or program the item effectively runs.
    var targetPath: String?
    var code: SecurityCodeEvaluation?
    var owner: StartupOwnerApp?
    /// The app bundle that contains an embedded background item.
    var containingAppPath: String?
    var state: StartupItemState = .unknown
    /// From `launchctl print-disabled`, when an override exists.
    var disabledOverride: Bool?
    var backgroundApproval: StartupBackgroundApproval?
    var launchctl: LaunchctlServiceInfo?
    var usage: StartupResourceUsage?
    var concerns: [StartupConcern] = []
    /// Login items: hidden at launch.
    var opensHidden: Bool?

    /// Apple's own services; never changed.
    var isProtected: Bool { label.map(LaunchctlClient.isProtectedLabel) ?? false }

    var isPotentiallyUnnecessary: Bool { !concerns.isEmpty }

    /// `true`/`false` when known: the item is set to start automatically.
    var isEnabled: Bool? {
        switch kind {
        case .loginItem:
            return true
        case .userAgent, .systemAgent, .systemDaemon, .appBackgroundItem:
            if backgroundApproval == .requiresApproval { return false }
            if let disabledOverride { return !disabledOverride }
            if let definition { return !definition.disabled }
            return nil
        }
    }

    var canToggle: Bool { kind == .userAgent && !isProtected && (label?.isEmpty == false) && definition != nil }
    var canMoveToTrash: Bool { kind == .userAgent && plistPath != nil && !isProtected }
    var canRemoveLoginItem: Bool { kind == .loginItem }

    /// Signed developer, package manager or a plain description.
    var developerDescription: String {
        if parseError != nil { return "Damaged property list" }
        if definition?.isEmpty == true { return "Empty property list" }
        if let analysis, analysis.targetKind == .inlineCode {
            return "Inline \(analysis.interpreter?.title ?? "script") code"
        }
        if let developer = code?.developer { return developer }
        switch code?.category {
        case .script?: return "Script"
        case .adHoc?: return "Unidentified developer"
        case .unsigned?: return "Unsigned"
        case .missing?: return "Program missing"
        case .unknown?: return owner?.name ?? "Signature couldn't be read"
        default: return owner?.name ?? "Unknown developer"
        }
    }

    /// When the item runs, in plain words.
    var triggerSummary: String {
        if parseError != nil || definition?.isEmpty == true { return "Never starts (no program defined)" }
        switch kind {
        case .loginItem:
            return opensHidden == true ? "Opens hidden at login" : "Opens at login"
        case .appBackgroundItem where definition == nil:
            return "Starts at login when turned on in \(owner?.name ?? "its app")"
        default:
            return definition?.triggerSummary ?? "Unknown schedule"
        }
    }

    /// How the person can manage the item.
    var managementNote: String {
        switch kind {
        case .loginItem:
            return "Remove it here, or in System Settings › General › Login Items & Extensions › Open at Login."
        case .userAgent:
            if isProtected { return "Part of macOS. Mac Cleaner doesn't change Apple services." }
            return "You can turn it off (reversible) or move its property list to the Trash. The app that installed it may add it again when it runs."
        case .appBackgroundItem:
            let app = owner?.name ?? containingAppPath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? "its app"
            return "Managed by \(app). Turn it off in \(app)'s settings or in System Settings › General › Login Items & Extensions. macOS doesn't let other apps query or change another app's background items."
        case .systemAgent, .systemDaemon:
            return "Installed for all users. Changing it requires an administrator: use System Settings › General › Login Items & Extensions › Allow in the Background, or uninstall the app that installed it."
        }
    }

    /// What happens if it's turned off.
    var consequenceOfDisabling: String {
        let subject = owner?.name ?? name
        var text: String
        switch kind {
        case .loginItem:
            text = "\(subject) won't open automatically when you log in. You can still open it yourself."
        case .userAgent, .systemAgent, .systemDaemon, .appBackgroundItem:
            text = "It stops now and won't start at login."
            let lowered = [name, label ?? "", targetPath ?? ""].joined(separator: " ").lowercased()
            if lowered.contains("update") || lowered.contains("keystone") {
                text += " \(subject) may stop updating itself automatically; update it manually from time to time."
            } else if lowered.contains("sync") || lowered.contains("backup") {
                text += " Syncing or backups done by \(subject) may pause until you open it."
            } else if lowered.contains("helper") || lowered.contains("agent") || lowered.contains("daemon") {
                text += " Features of \(subject) that work in the background (menu bar icons, notifications, quick actions) may stop until you open the app."
            } else {
                text += " Anything it does in the background stops until you start it again."
            }
        }
        return text
    }

    /// Text matched by search.
    var searchableText: String {
        [name, label, plistPath, targetPath, code?.developer, owner?.name, kind.title].compactMap { $0 }.joined(separator: " ")
    }
}

/// Everything found by a startup scan.
struct StartupInventory: Sendable {
    var items: [StartupItem]
    /// `false` when login items couldn't be read (no Automation permission).
    var includesLoginItems: Bool
    var scannedAt: Date
    /// Honest notes about what couldn't be checked.
    var notes: [String]

    func items(of kind: StartupItemKind) -> [StartupItem] { items.filter { $0.kind == kind } }

    var potentiallyUnnecessary: [StartupItem] { items.filter(\.isPotentiallyUnnecessary) }
}
