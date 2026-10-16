import Foundation

/// Every screen of the app. Features use it to link findings to the place where
/// the person can act on them.
enum AppSection: String, CaseIterable, Identifiable, Sendable, Codable, Hashable {
    case dashboard, smartScan, systemJunk, privacy, developer
    case storage, duplicates, cloud
    case uninstaller, updates, startup
    case performance, security
    case antivirus, network
    case automation, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .smartScan: return "Smart Scan"
        case .systemJunk: return "System Junk"
        case .privacy: return "Privacy"
        case .developer: return "Developer Tools"
        case .storage: return "Storage Analyzer"
        case .duplicates: return "Duplicate Finder"
        case .cloud: return "Cloud Storage"
        case .uninstaller: return "Uninstaller"
        case .updates: return "Updates"
        case .startup: return "Startup Items"
        case .performance: return "Performance"
        case .security: return "Security"
        case .antivirus: return "Antivirus"
        case .network: return "Ports & Network"
        case .automation: return "Automation"
        case .history: return "History"
        }
    }

    var symbolName: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .smartScan: return "sparkles"
        case .systemJunk: return "trash.circle"
        case .privacy: return "hand.raised"
        case .developer: return "hammer"
        case .storage: return "chart.pie"
        case .duplicates: return "square.on.square"
        case .cloud: return "icloud"
        case .uninstaller: return "xmark.app"
        case .updates: return "arrow.down.app"
        case .startup: return "power.circle"
        case .performance: return "waveform.path.ecg"
        case .security: return "lock.shield"
        case .antivirus: return "shield.lefthalf.filled"
        case .network: return "network"
        case .automation: return "clock.arrow.2.circlepath"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

/// How confident Mac Cleaner is that removing an item is harmless.
enum CleanupSafety: Int, Sendable, Codable, Comparable, CaseIterable, Hashable {
    /// Regenerable data; selected by default.
    case safe
    /// Probably unneeded, but the person should look first; not selected by default.
    case review
    /// Removing it may lose data or settings; never selected by default.
    case caution

    static func < (lhs: CleanupSafety, rhs: CleanupSafety) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .safe: return "Safe"
        case .review: return "Review"
        case .caution: return "Caution"
        }
    }

    var explanation: String {
        switch self {
        case .safe: return "Regenerated automatically when needed. Safe to remove."
        case .review: return "Usually not needed, but check the list before removing."
        case .caution: return "May contain data or settings you want to keep. Remove only if you're sure."
        }
    }

    var symbolName: String {
        switch self {
        case .safe: return "checkmark.shield.fill"
        case .review: return "eye.fill"
        case .caution: return "exclamationmark.triangle.fill"
        }
    }
}

/// A removable item shown in scan results.
struct CleanupCandidate: Identifiable, Sendable, Hashable {
    var id: String
    var path: String
    var title: String
    /// Secondary line, such as the owning app or file count.
    var detail: String?
    /// Groups candidates in result lists ("Application caches", "Old downloads").
    var categoryID: String
    var categoryTitle: String
    var usage: DiskUsage
    var snapshot: FileSnapshot?
    var safety: CleanupSafety
    var purpose: DeletionPurpose
    var modificationDate: Date?
    /// Bundle identifier of the app the data belongs to, for icons and running-app checks.
    var ownerBundleIdentifier: String?

    init(
        path: String,
        title: String? = nil,
        detail: String? = nil,
        categoryID: String,
        categoryTitle: String,
        usage: DiskUsage,
        snapshot: FileSnapshot? = nil,
        safety: CleanupSafety,
        purpose: DeletionPurpose,
        modificationDate: Date? = nil,
        ownerBundleIdentifier: String? = nil
    ) {
        self.id = categoryID + "|" + path
        self.path = path
        self.title = title ?? (path as NSString).lastPathComponent
        self.detail = detail
        self.categoryID = categoryID
        self.categoryTitle = categoryTitle
        self.usage = usage
        self.snapshot = snapshot ?? FileSnapshot.capture(path: path)
        self.safety = safety
        self.purpose = purpose
        self.modificationDate = modificationDate
        self.ownerBundleIdentifier = ownerBundleIdentifier
    }

    var url: URL { URL(fileURLWithPath: path) }
    var isSelectedByDefault: Bool { safety == .safe }

    var cleanupItem: CleanupItem {
        CleanupItem(path: path, purpose: purpose, snapshot: snapshot, estimatedBytes: usage.reclaimableBytes, category: categoryTitle)
    }
}

/// How serious a finding is. Security findings use all levels; other areas
/// mostly produce information and recommendations.
enum FindingSeverity: Int, Sendable, Codable, Comparable, CaseIterable, Hashable {
    case info
    case recommendation
    /// Unusual and worth checking, but not proven harmful.
    case suspicious
    /// Matches a reliable rule for known malware or adware.
    case threat

    static func < (lhs: FindingSeverity, rhs: FindingSeverity) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .info: return "Information"
        case .recommendation: return "Recommendation"
        case .suspicious: return "Suspicious"
        case .threat: return "Threat"
        }
    }

    var symbolName: String {
        switch self {
        case .info: return "info.circle.fill"
        case .recommendation: return "lightbulb.fill"
        case .suspicious: return "exclamationmark.triangle.fill"
        case .threat: return "xmark.octagon.fill"
        }
    }
}

/// Areas covered by Smart Scan.
enum SmartScanArea: String, CaseIterable, Sendable, Codable, Identifiable, Hashable {
    case junk, leftovers, largeFiles, duplicates, startup, security, malware, privacy, developer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .junk: return "System Junk"
        case .leftovers: return "App Leftovers"
        case .largeFiles: return "Large & Old Files"
        case .duplicates: return "Duplicates"
        case .startup: return "Startup Items"
        case .security: return "Security"
        case .malware: return "Virus Scan"
        case .privacy: return "Privacy"
        case .developer: return "Developer Caches"
        }
    }

    var symbolName: String {
        switch self {
        case .junk: return "trash.circle.fill"
        case .leftovers: return "shippingbox.fill"
        case .largeFiles: return "doc.richtext.fill"
        case .duplicates: return "square.on.square.fill"
        case .startup: return "power.circle.fill"
        case .security: return "lock.shield.fill"
        case .malware: return "ladybug.fill"
        case .privacy: return "hand.raised.fill"
        case .developer: return "hammer.fill"
        }
    }

    var section: AppSection {
        switch self {
        case .junk: return .systemJunk
        case .leftovers: return .uninstaller
        case .largeFiles: return .storage
        case .duplicates: return .duplicates
        case .startup: return .startup
        case .security: return .security
        case .malware: return .antivirus
        case .privacy: return .privacy
        case .developer: return .developer
        }
    }
}

/// An observation or recommendation that isn't a file to remove.
struct Finding: Identifiable, Sendable, Hashable {
    var id: String
    var area: SmartScanArea
    var severity: FindingSeverity
    var title: String
    var detail: String
    var path: String?
    var recommendation: String?
    /// Where in the app the person can act on it.
    var destination: AppSection?

    init(
        id: String? = nil,
        area: SmartScanArea,
        severity: FindingSeverity,
        title: String,
        detail: String,
        path: String? = nil,
        recommendation: String? = nil,
        destination: AppSection? = nil
    ) {
        self.id = id ?? "\(area.rawValue)|\(title)|\(path ?? "")"
        self.area = area
        self.severity = severity
        self.title = title
        self.detail = detail
        self.path = path
        self.recommendation = recommendation
        self.destination = destination ?? area.section
    }
}

/// What one area contributed to a Smart Scan.
struct SmartScanContribution: Sendable {
    var area: SmartScanArea
    var candidates: [CleanupCandidate] = []
    var findings: [Finding] = []
    /// Short description such as "4 apps left files behind".
    var summary: String?
}

/// Settings that influence scans, captured as a value so background work never
/// reads mutable UI state.
struct ScanPreferences: Sendable, Codable, Hashable {
    var exclusions = ExclusionList()
    var largeFileThresholdBytes: Int64 = 500 * 1_000_000
    var oldFileAgeDays = 180
    var oldDownloadAgeDays = 90
    var logAgeDays = 7
    var includeHiddenFiles = false
}

/// Context handed to each Smart Scan provider.
struct SmartScanContext: Sendable {
    var preferences: ScanPreferences
    /// Reports progress within the provider's own area (0...1) with a short status message.
    var reportProgress: @Sendable (_ fraction: Double, _ message: String) -> Void
}

/// A feature that can contribute to Smart Scan.
protocol SmartScanProvider: Sendable {
    var area: SmartScanArea { get }
    func smartScan(context: SmartScanContext) async throws -> SmartScanContribution
}
