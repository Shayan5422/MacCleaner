import Foundation
import Observation

/// What happens when the File Shield finds potentially unwanted software.
enum AVPUAAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case notify
    case quarantine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notify: return "Notify me"
        case .quarantine: return "Move to the Virus Chest"
        }
    }
}

/// A file the person chose to always allow ("not a threat").
struct AVAllowedHash: Codable, Sendable, Hashable, Identifiable {
    var sha256: String
    /// File name when it was allowed, for display.
    var name: String?
    var path: String?
    var signatureName: String?
    var addedAt: Date

    var id: String { sha256 }

    static func isValidSHA256(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }
    }
}

/// Which optional definition sources are downloaded.
struct AVSourceSelection: Codable, Sendable, Hashable {
    var malwareBazaarRecent = true
    var malwareBazaarFull = false
    var urlhaus = true
    var threatFox = true
}

/// Every antivirus preference as a value, readable from any thread (background agent,
/// Smart Scan, shields). Reads the same `UserDefaults` keys as `AntivirusSettings`.
struct AVSettingsSnapshot: Sendable, Hashable {
    /// nil until the person decides; then real-time protection follows whether definitions are installed.
    var realTimeProtectionChoice: Bool?
    var downloadShield = true
    var autoQuarantineMalware = true
    var puaAction: AVPUAAction = .notify
    var detectPUA = true
    var detectNonMacThreats = true
    var scanArchives = true
    var maxFileSizeMB = 200
    var automaticUpdates = true
    var useFreshclam = true
    var sources = AVSourceSelection()
    var exclusions = ExclusionList()
    var allowedHashes: [AVAllowedHash] = []
    var includeExternalVolumesInFullScan = false

    init() {}

    init(defaults: UserDefaults) {
        typealias Key = AntivirusSettings.Key
        realTimeProtectionChoice = defaults.object(forKey: Key.realTimeProtection) as? Bool
        downloadShield = defaults.object(forKey: Key.downloadShield) as? Bool ?? true
        autoQuarantineMalware = defaults.object(forKey: Key.autoQuarantineMalware) as? Bool ?? true
        puaAction = defaults.string(forKey: Key.puaAction).flatMap(AVPUAAction.init(rawValue:)) ?? .notify
        detectPUA = defaults.object(forKey: Key.detectPUA) as? Bool ?? true
        detectNonMacThreats = defaults.object(forKey: Key.detectNonMacThreats) as? Bool ?? true
        scanArchives = defaults.object(forKey: Key.scanArchives) as? Bool ?? true
        maxFileSizeMB = defaults.object(forKey: Key.maxFileSizeMB) as? Int ?? 200
        automaticUpdates = defaults.object(forKey: Key.automaticUpdates) as? Bool ?? true
        useFreshclam = defaults.object(forKey: Key.useFreshclam) as? Bool ?? true
        includeExternalVolumesInFullScan = defaults.bool(forKey: Key.includeExternalVolumes)
        var sources = AVSourceSelection()
        sources.malwareBazaarRecent = defaults.object(forKey: Key.sourceMalwareBazaarRecent) as? Bool ?? true
        sources.malwareBazaarFull = defaults.bool(forKey: Key.sourceMalwareBazaarFull)
        sources.urlhaus = defaults.object(forKey: Key.sourceURLhaus) as? Bool ?? true
        sources.threatFox = defaults.object(forKey: Key.sourceThreatFox) as? Bool ?? true
        self.sources = sources
        if let data = defaults.data(forKey: Key.exclusions), let list = try? JSONDecoder().decode(ExclusionList.self, from: data) {
            exclusions = list
        }
        if let data = defaults.data(forKey: Key.allowedHashes) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            allowedHashes = (try? decoder.decode([AVAllowedHash].self, from: data)) ?? []
        }
    }

    /// Real-time protection is on by default once definitions are installed.
    func isRealTimeProtectionOn(definitionsInstalled: Bool) -> Bool {
        realTimeProtectionChoice ?? definitionsInstalled
    }

    var allowedHashSet: Set<String> { Set(allowedHashes.map { $0.sha256.lowercased() }) }

    /// Engine options for these preferences.
    var scanOptions: AVScanOptions {
        var options = AVScanOptions()
        options.maxFileSize = Int64(max(1, maxFileSizeMB)) * 1_000_000
        options.scanArchives = scanArchives
        options.detectPUA = detectPUA
        options.detectNonMacThreats = detectNonMacThreats
        return options
    }
}

/// Antivirus preferences, persisted in `UserDefaults` under `antivirus.` keys.
/// Background work reads `snapshot` (a value), never this object.
@MainActor
@Observable
final class AntivirusSettings {
    enum Key {
        static let realTimeProtection = "antivirus.realTimeProtection"
        static let downloadShield = "antivirus.downloadShield"
        static let autoQuarantineMalware = "antivirus.autoQuarantineMalware"
        static let puaAction = "antivirus.puaAction"
        static let detectPUA = "antivirus.detectPUA"
        static let detectNonMacThreats = "antivirus.detectNonMacThreats"
        static let scanArchives = "antivirus.scanArchives"
        static let maxFileSizeMB = "antivirus.maxFileSizeMB"
        static let automaticUpdates = "antivirus.automaticUpdates"
        static let useFreshclam = "antivirus.useFreshclam"
        static let sourceMalwareBazaarRecent = "antivirus.source.malwareBazaarRecent"
        static let sourceMalwareBazaarFull = "antivirus.source.malwareBazaarFull"
        static let sourceURLhaus = "antivirus.source.urlhaus"
        static let sourceThreatFox = "antivirus.source.threatFox"
        static let exclusions = "antivirus.exclusions"
        static let allowedHashes = "antivirus.allowedHashes"
        static let includeExternalVolumes = "antivirus.includeExternalVolumesInFullScan"
    }

    static let maxFileSizeChoices = [25, 50, 100, 200, 500, 1000, 2000]

    @ObservationIgnored private let defaults: UserDefaults

    var realTimeProtectionChoice: Bool? {
        didSet {
            if let realTimeProtectionChoice { defaults.set(realTimeProtectionChoice, forKey: Key.realTimeProtection) } else { defaults.removeObject(forKey: Key.realTimeProtection) }
        }
    }
    var downloadShield: Bool { didSet { defaults.set(downloadShield, forKey: Key.downloadShield) } }
    var autoQuarantineMalware: Bool { didSet { defaults.set(autoQuarantineMalware, forKey: Key.autoQuarantineMalware) } }
    var puaAction: AVPUAAction { didSet { defaults.set(puaAction.rawValue, forKey: Key.puaAction) } }
    var detectPUA: Bool { didSet { defaults.set(detectPUA, forKey: Key.detectPUA) } }
    var detectNonMacThreats: Bool { didSet { defaults.set(detectNonMacThreats, forKey: Key.detectNonMacThreats) } }
    var scanArchives: Bool { didSet { defaults.set(scanArchives, forKey: Key.scanArchives) } }
    var maxFileSizeMB: Int { didSet { defaults.set(maxFileSizeMB, forKey: Key.maxFileSizeMB) } }
    var automaticUpdates: Bool { didSet { defaults.set(automaticUpdates, forKey: Key.automaticUpdates) } }
    var useFreshclam: Bool { didSet { defaults.set(useFreshclam, forKey: Key.useFreshclam) } }
    var includeExternalVolumesInFullScan: Bool { didSet { defaults.set(includeExternalVolumesInFullScan, forKey: Key.includeExternalVolumes) } }
    var sources: AVSourceSelection {
        didSet {
            defaults.set(sources.malwareBazaarRecent, forKey: Key.sourceMalwareBazaarRecent)
            defaults.set(sources.malwareBazaarFull, forKey: Key.sourceMalwareBazaarFull)
            defaults.set(sources.urlhaus, forKey: Key.sourceURLhaus)
            defaults.set(sources.threatFox, forKey: Key.sourceThreatFox)
        }
    }
    private(set) var exclusions: ExclusionList { didSet { saveExclusions() } }
    private(set) var allowedHashes: [AVAllowedHash] { didSet { saveAllowedHashes() } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let snapshot = AVSettingsSnapshot(defaults: defaults)
        realTimeProtectionChoice = snapshot.realTimeProtectionChoice
        downloadShield = snapshot.downloadShield
        autoQuarantineMalware = snapshot.autoQuarantineMalware
        puaAction = snapshot.puaAction
        detectPUA = snapshot.detectPUA
        detectNonMacThreats = snapshot.detectNonMacThreats
        scanArchives = snapshot.scanArchives
        maxFileSizeMB = snapshot.maxFileSizeMB
        automaticUpdates = snapshot.automaticUpdates
        useFreshclam = snapshot.useFreshclam
        includeExternalVolumesInFullScan = snapshot.includeExternalVolumesInFullScan
        sources = snapshot.sources
        exclusions = snapshot.exclusions
        allowedHashes = snapshot.allowedHashes
    }

    /// A value copy for background work.
    var snapshot: AVSettingsSnapshot {
        var value = AVSettingsSnapshot()
        value.realTimeProtectionChoice = realTimeProtectionChoice
        value.downloadShield = downloadShield
        value.autoQuarantineMalware = autoQuarantineMalware
        value.puaAction = puaAction
        value.detectPUA = detectPUA
        value.detectNonMacThreats = detectNonMacThreats
        value.scanArchives = scanArchives
        value.maxFileSizeMB = maxFileSizeMB
        value.automaticUpdates = automaticUpdates
        value.useFreshclam = useFreshclam
        value.sources = sources
        value.exclusions = exclusions
        value.allowedHashes = allowedHashes
        value.includeExternalVolumesInFullScan = includeExternalVolumesInFullScan
        return value
    }

    func isRealTimeProtectionOn(definitionsInstalled: Bool) -> Bool {
        realTimeProtectionChoice ?? definitionsInstalled
    }

    // MARK: Exclusions

    func addExclusion(_ path: String) { exclusions.add(path) }
    func removeExclusion(_ path: String) { exclusions.remove(path) }

    // MARK: Always allow

    func isAllowed(sha256: String) -> Bool {
        allowedHashes.contains { $0.sha256.caseInsensitiveCompare(sha256) == .orderedSame }
    }

    /// Adds a hash to the allow list. Returns false when it isn't a valid SHA-256.
    @discardableResult
    func allow(sha256 raw: String, name: String? = nil, path: String? = nil, signatureName: String? = nil) -> Bool {
        let sha256 = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard AVAllowedHash.isValidSHA256(sha256) else { return false }
        guard !isAllowed(sha256: sha256) else { return true }
        allowedHashes.append(AVAllowedHash(sha256: sha256, name: name, path: path, signatureName: signatureName, addedAt: Date()))
        return true
    }

    func removeAllowed(sha256: String) {
        allowedHashes.removeAll { $0.sha256.caseInsensitiveCompare(sha256) == .orderedSame }
    }

    private func saveExclusions() {
        if let data = try? JSONEncoder().encode(exclusions) { defaults.set(data, forKey: Key.exclusions) }
    }

    private func saveAllowedHashes() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(allowedHashes) { defaults.set(data, forKey: Key.allowedHashes) }
    }

    /// Whether Mac Cleaner should keep running after its window closes, so real-time protection
    /// continues in the menu bar. For the app delegate (reads `UserDefaults` directly).
    nonisolated static func keepsRunningForProtection(defaults: UserDefaults = .standard, definitionsInstalled: Bool) -> Bool {
        AVSettingsSnapshot(defaults: defaults).isRealTimeProtectionOn(definitionsInstalled: definitionsInstalled)
    }
}
