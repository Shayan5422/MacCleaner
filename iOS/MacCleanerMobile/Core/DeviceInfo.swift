import Foundation
import UIKit

/// The device's storage, as Settings › General › iPhone Storage shows it.
struct DeviceStorage: Sendable, Equatable {
    var total: Int64
    /// Space available for important work (what iOS can make free for the person, including purgeable data).
    var available: Int64

    var used: Int64 { max(0, total - available) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    /// Less than 10% or 5 GB left: iOS starts removing caches and offloading on its own.
    var isLow: Bool { total > 0 && (Double(available) / Double(total) < 0.10 || available < 5_000_000_000) }

    static func current() -> DeviceStorage? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity, total > 0 else { return nil }
        return DeviceStorage(total: Int64(total), available: values.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}

/// The device model and system version.
struct DeviceInfo: Sendable, Equatable {
    /// "iPhone17,1" (on the simulator, the simulated model).
    var modelIdentifier: String
    /// The system version, e.g. [27, 0, 1].
    var systemVersion: [Int]
    var isPad: Bool

    var systemMajorVersion: Int { systemVersion.first ?? 0 }

    var systemVersionString: String {
        let parts = systemVersion.count == 3 && systemVersion[2] == 0 ? Array(systemVersion.prefix(2)) : systemVersion
        return parts.map(String.init).joined(separator: ".")
    }

    /// "iPhone" or "iPad", for sentences.
    var deviceWord: String { isPad ? "iPad" : "iPhone" }

    @MainActor
    static func current() -> DeviceInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return DeviceInfo(modelIdentifier: modelIdentifier(), systemVersion: [version.majorVersion, version.minorVersion, version.patchVersion],
                          isPad: UIDevice.current.userInterfaceIdiom == .pad)
    }

    static func modelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
