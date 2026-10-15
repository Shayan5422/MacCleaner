import Foundation

/// A simulator device from `xcrun simctl list devices --json`.
struct DeveloperSimulatorDevice: Sendable, Hashable, Decodable {
    var udid: String
    var name: String
    var state: String?
    var isAvailable: Bool
    var availabilityError: String?
    var dataPath: String?
    var dataPathSize: Int64?
    var logPath: String?
    var logPathSize: Int64?
    var lastUsedAt: Date?
    var deviceTypeIdentifier: String?
    /// The runtime the device belongs to (the key it was listed under).
    var runtimeIdentifier = ""

    private enum CodingKeys: String, CodingKey {
        case udid, name, state, isAvailable, availability, availabilityError
        case dataPath, dataPathSize, logPath, logPathSize, lastUsedAt, deviceTypeIdentifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        udid = try container.decode(String.self, forKey: .udid)
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? udid
        state = try? container.decodeIfPresent(String.self, forKey: .state)
        if let flag = try? container.decodeIfPresent(Bool.self, forKey: .isAvailable) {
            isAvailable = flag
        } else if let text = (try? container.decodeIfPresent(String.self, forKey: .isAvailable)) ?? (try? container.decodeIfPresent(String.self, forKey: .availability)) {
            // Older simctl versions report "YES"/"NO" or "(available)"/"(unavailable, …)".
            let lowered = text.lowercased()
            isAvailable = lowered == "yes" || lowered == "true" || lowered.hasPrefix("(available")
        } else {
            isAvailable = true
        }
        availabilityError = try? container.decodeIfPresent(String.self, forKey: .availabilityError)
        dataPath = try? container.decodeIfPresent(String.self, forKey: .dataPath)
        dataPathSize = try? container.decodeIfPresent(Int64.self, forKey: .dataPathSize)
        logPath = try? container.decodeIfPresent(String.self, forKey: .logPath)
        logPathSize = try? container.decodeIfPresent(Int64.self, forKey: .logPathSize)
        lastUsedAt = (try? container.decodeIfPresent(String.self, forKey: .lastUsedAt)).flatMap { $0 }.flatMap(DeveloperSimctlParser.parseDate)
        deviceTypeIdentifier = try? container.decodeIfPresent(String.self, forKey: .deviceTypeIdentifier)
    }

    /// Space the device's data and logs use, as reported by simctl.
    var reportedBytes: Int64 { (dataPathSize ?? 0) + (logPathSize ?? 0) }
}

/// All simulator devices, grouped by runtime.
struct DeveloperSimulatorDeviceList: Sendable, Hashable {
    var devices: [DeveloperSimulatorDevice]

    var unavailableDevices: [DeveloperSimulatorDevice] { devices.filter { !$0.isAvailable } }

    func availableDeviceCount(runtimeIdentifier: String) -> Int {
        devices.filter { $0.isAvailable && $0.runtimeIdentifier == runtimeIdentifier }.count
    }

    func deviceCount(runtimeIdentifier: String) -> Int {
        devices.filter { $0.runtimeIdentifier == runtimeIdentifier }.count
    }
}

/// A simulator runtime disk image from `xcrun simctl runtime list --json`.
struct DeveloperSimulatorRuntime: Sendable, Hashable, Decodable {
    var identifier: String
    var runtimeIdentifier: String?
    var version: String?
    var build: String?
    var state: String?
    var deletable: Bool
    var sizeBytes: Int64?
    var lastUsedAt: Date?
    var platformIdentifier: String?
    var kind: String?

    private enum CodingKeys: String, CodingKey {
        case identifier, runtimeIdentifier, version, build, state, deletable, sizeBytes, lastUsedAt, platformIdentifier, kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = (try? container.decodeIfPresent(String.self, forKey: .identifier)) ?? ""
        runtimeIdentifier = try? container.decodeIfPresent(String.self, forKey: .runtimeIdentifier)
        version = try? container.decodeIfPresent(String.self, forKey: .version)
        build = try? container.decodeIfPresent(String.self, forKey: .build)
        state = try? container.decodeIfPresent(String.self, forKey: .state)
        deletable = ((try? container.decodeIfPresent(Bool.self, forKey: .deletable)) ?? nil) ?? false
        sizeBytes = try? container.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        lastUsedAt = (try? container.decodeIfPresent(String.self, forKey: .lastUsedAt)).flatMap { $0 }.flatMap(DeveloperSimctlParser.parseDate)
        platformIdentifier = try? container.decodeIfPresent(String.self, forKey: .platformIdentifier)
        kind = try? container.decodeIfPresent(String.self, forKey: .kind)
    }

    var isReady: Bool { state?.lowercased() == "ready" }

    /// "iOS", "watchOS"…
    var platformName: String {
        switch platformIdentifier {
        case "com.apple.platform.iphonesimulator": return "iOS"
        case "com.apple.platform.appletvsimulator": return "tvOS"
        case "com.apple.platform.watchsimulator": return "watchOS"
        case "com.apple.platform.xrsimulator": return "visionOS"
        default:
            // "com.apple.CoreSimulator.SimRuntime.iOS-26-3" → "iOS"
            if let last = runtimeIdentifier?.split(separator: ".").last, let name = last.split(separator: "-").first {
                return String(name)
            }
            return "Simulator"
        }
    }

    /// "iOS 26.3.1"
    var displayName: String {
        [platformName, version].compactMap { $0 }.joined(separator: " ")
    }
}

/// Parses `simctl` JSON output.
enum DeveloperSimctlParser {
    private struct DeviceListRoot: Decodable {
        var devices: [String: [DeveloperSimulatorDevice]]
    }

    static func parseDevices(_ data: Data) throws -> DeveloperSimulatorDeviceList {
        let root = try JSONDecoder().decode(DeviceListRoot.self, from: data)
        var devices: [DeveloperSimulatorDevice] = []
        for (runtime, list) in root.devices.sorted(by: { $0.key < $1.key }) {
            for var device in list {
                device.runtimeIdentifier = runtime
                devices.append(device)
            }
        }
        return DeveloperSimulatorDeviceList(devices: devices)
    }

    static func parseRuntimes(_ data: Data) throws -> [DeveloperSimulatorRuntime] {
        let root = try JSONDecoder().decode([String: DeveloperSimulatorRuntime].self, from: data)
        return root.map { key, value in
            var runtime = value
            if runtime.identifier.isEmpty { runtime.identifier = key }
            return runtime
        }
        .sorted { ($0.platformName, $0.version ?? "") < ($1.platformName, $1.version ?? "") }
    }

    /// Parses simctl's ISO 8601 timestamps, with or without fractional seconds.
    static func parseDate(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle()) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
