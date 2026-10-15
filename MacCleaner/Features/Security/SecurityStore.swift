import Foundation

/// Small persistent state of the Security feature, in `UserDefaults`:
/// findings the person chose to ignore and a summary of the last scan.
/// Thread-safe (UserDefaults is), so headless scans can use it.
enum SecurityStore {
    static let ignoredFindingsKey = "security.ignoredFindingIDs"
    static let lastScanSummaryKey = "security.lastScanSummary"

    // MARK: - Ignored findings

    static func ignoredFindingIDs(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: ignoredFindingsKey) ?? [])
    }

    static func setIgnored(_ ignored: Bool, findingID: String, defaults: UserDefaults = .standard) {
        var current = ignoredFindingIDs(defaults: defaults)
        if ignored { current.insert(findingID) } else { current.remove(findingID) }
        defaults.set(current.sorted(), forKey: ignoredFindingsKey)
    }

    static func clearIgnored(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: ignoredFindingsKey)
    }

    // MARK: - Last scan

    /// Summary of the most recent completed scan (manual or scheduled).
    static func lastScanSummary(defaults: UserDefaults = .standard) -> SecurityScanSummary? {
        guard let data = defaults.data(forKey: lastScanSummaryKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SecurityScanSummary.self, from: data)
    }

    static func saveLastScanSummary(_ summary: SecurityScanSummary, defaults: UserDefaults = .standard) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(summary) { defaults.set(data, forKey: lastScanSummaryKey) }
    }
}
