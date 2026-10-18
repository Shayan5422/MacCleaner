import Foundation

/// A system version compared number by number, missing parts counting as zero:
/// "27.0.10" > "27.0.9" and "27.0" == "27.0.0".
struct SystemVersion: Comparable, Hashable, Sendable, Codable, CustomStringConvertible {
    var components: [Int]

    init(_ components: [Int]) {
        self.components = components.isEmpty ? [0] : components
    }

    /// "27.0.1"; nil when a part isn't a number.
    init?(_ string: String) {
        let parts = string.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard !parts.isEmpty, numbers.count == parts.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        self.init(numbers)
    }

    var major: Int { components.first ?? 0 }

    /// "27.0.1", "27.0" (a zero patch number is left out, like Settings does).
    var description: String {
        var parts = components
        while parts.count > 2, parts.last == 0 { parts.removeLast() }
        if parts.count == 1 { parts.append(0) }
        return parts.map(String.init).joined(separator: ".")
    }

    static func < (lhs: SystemVersion, rhs: SystemVersion) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: SystemVersion, rhs: SystemVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    func hash(into hasher: inout Hasher) {
        var parts = components
        while parts.count > 1, parts.last == 0 { parts.removeLast() }
        hasher.combine(parts)
    }
}

/// A release Apple offers for a device in its public software update catalog.
struct SoftwareRelease: Sendable, Equatable, Codable {
    var version: SystemVersion
    var postingDate: Date?
}

/// Apple's public software update catalog (gdmf.apple.com/v2/pmv): the versions offered to each
/// device model. `PublicAssetSets` has what Software Update offers; `AssetSets` adds versions kept
/// for managed devices.
enum SoftwareCatalog {
    static let url = URL(string: "https://gdmf.apple.com/v2/pmv")!

    /// The releases offered to `model` ("iPhone18,3"), newest first, one per version.
    static func releases(in data: Data, model: String) throws -> [SoftwareRelease] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["PublicAssetSets"] != nil || root["AssetSets"] != nil else {
            throw ThreatFeedError(message: "Apple's update catalog couldn't be read.")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        var byVersion: [SystemVersion: SoftwareRelease] = [:]
        for setName in ["PublicAssetSets", "AssetSets"] {
            let entries = (root[setName] as? [String: Any])?["iOS"] as? [[String: Any]] ?? []
            for entry in entries {
                guard let devices = entry["SupportedDevices"] as? [String],
                      devices.contains(where: { $0.caseInsensitiveCompare(model) == .orderedSame }),
                      let text = entry["ProductVersion"] as? String, let version = SystemVersion(text) else { continue }
                let posted = (entry["PostingDate"] as? String).flatMap(formatter.date(from:))
                if let existing = byVersion[version], let date = existing.postingDate, date <= (posted ?? date) { continue }
                byVersion[version] = SoftwareRelease(version: version, postingDate: posted)
            }
        }
        return byVersion.values.sorted { $0.version > $1.version }
    }
}

/// Why the iOS check couldn't finish.
enum SoftwareCheckProblem: Sendable, Equatable {
    case offline
    case unreadable
    /// The catalog doesn't list this model (for example a very new one).
    case unknownModel
    case server(Int)
}

/// What the iOS check found.
enum SoftwareUpdateState: Sendable, Equatable {
    /// The newest version of the running major release (another major release may be available as well).
    case upToDate(newerMajorRelease: SystemVersion?)
    case updateAvailable(SystemVersion, postingDate: Date?)
    case couldNotCheck(SoftwareCheckProblem)

    var isUpToDate: Bool? {
        switch self {
        case .upToDate: return true
        case .updateAvailable: return false
        case .couldNotCheck: return nil
        }
    }

    /// Like Software Update in Settings: the newest version of the running major release counts as
    /// up to date while Apple still offers it (people may stay on the previous major version).
    /// When Apple no longer offers that line, the newest version for the device is the update.
    static func evaluate(running: SystemVersion, releases: [SoftwareRelease]) -> SoftwareUpdateState {
        guard let newest = releases.max(by: { $0.version < $1.version }) else { return .couldNotCheck(.unknownModel) }
        if let line = releases.filter({ $0.version.major == running.major }).max(by: { $0.version < $1.version }) {
            if line.version > running { return .updateAvailable(line.version, postingDate: line.postingDate) }
            return .upToDate(newerMajorRelease: newest.version > running ? newest.version : nil)
        }
        if newest.version > running { return .updateAvailable(newest.version, postingDate: newest.postingDate) }
        return .upToDate(newerMajorRelease: nil)
    }
}

/// The catalog's releases for this device, kept for 12 hours.
struct SoftwareCatalogCache: Codable, Sendable, Equatable {
    static let lifetime: TimeInterval = 12 * 3600

    var fetchedAt: Date
    var model: String
    var releases: [SoftwareRelease]

    func isFresh(for model: String, at date: Date) -> Bool {
        self.model == model && date.timeIntervalSince(fetchedAt) < Self.lifetime && date >= fetchedAt
    }
}
