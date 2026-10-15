import Foundation
import IOKit
import IOKit.ps

/// Reads the internal battery through IOKit power sources (`IOPSCopyPowerSourcesInfo`)
/// and adds health details from the battery's registry entry (`AppleSmartBattery`).
enum PerformanceBatteryReader {
    static func read() -> PerformancePowerReading {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PerformancePowerReading(battery: .noBattery, source: .unknown)
        }
        let source = providingSource(blob)
        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return PerformancePowerReading(battery: .noBattery, source: source)
        }
        let internalBattery = sources.lazy
            .compactMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
            .first { ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType }
        guard let description = internalBattery else { return PerformancePowerReading(battery: .noBattery, source: source) }
        let battery = PerformanceBatteryParser.parse(powerSource: description, registry: smartBatteryProperties())
        return PerformancePowerReading(battery: .present(battery), source: source)
    }

    /// "AC Power", "Battery Power" or "UPS Power", as reported by `IOPSGetProvidingPowerSourceType`.
    private static func providingSource(_ blob: CFTypeRef) -> PerformanceBattery.PowerSource {
        guard let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? else { return .unknown }
        switch type {
        case kIOPMACPowerKey: return .powerAdapter
        case kIOPMBatteryPowerKey: return .battery
        case kIOPMUPSPowerKey: return .ups
        default: return .unknown
        }
    }

    /// Properties of the `AppleSmartBattery` registry entry, if a battery is installed.
    /// Desktop Macs can have the entry with `BatteryInstalled = No`.
    private static func smartBatteryProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        if let installed = dictionary["BatteryInstalled"] as? Bool, !installed { return nil }
        return dictionary
    }
}

/// Turns power-source and registry dictionaries into `PerformanceBattery`.
/// Separate from the IOKit calls so it can be tested with sample dictionaries.
enum PerformanceBatteryParser {
    static func parse(powerSource: [String: Any], registry: [String: Any]?) -> PerformanceBattery {
        let current = int(powerSource[kIOPSCurrentCapacityKey])
        let maximum = int(powerSource[kIOPSMaxCapacityKey])
        var level: Double?
        if let current, let maximum, maximum > 0 {
            level = min(1, max(0, Double(current) / Double(maximum)))
        }

        let state = powerSource[kIOPSPowerSourceStateKey] as? String
        let powerSourceKind: PerformanceBattery.PowerSource
        switch state {
        case kIOPSACPowerValue: powerSourceKind = .powerAdapter
        case kIOPSBatteryPowerValue: powerSourceKind = .battery
        default: powerSourceKind = .unknown
        }

        let isCharging = bool(powerSource[kIOPSIsChargingKey]) ?? false
        let isCharged = bool(powerSource[kIOPSIsChargedKey]) ?? false
        // Minutes; -1 means macOS is still calculating, 0 means not applicable.
        let timeToEmpty = minutes(powerSource[kIOPSTimeToEmptyKey]).flatMap { powerSourceKind == .battery ? $0 : nil }
        let timeToFull = minutes(powerSource[kIOPSTimeToFullChargeKey]).flatMap { isCharging ? $0 : nil }

        var condition = (powerSource[kIOPSBatteryHealthConditionKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if condition == nil { condition = (powerSource[kIOPSBatteryHealthKey] as? String).flatMap { $0.isEmpty ? nil : $0 } }

        var battery = PerformanceBattery(
            level: level,
            isCharging: isCharging,
            isCharged: isCharged,
            powerSource: powerSourceKind,
            timeToEmpty: timeToEmpty,
            timeToFull: timeToFull,
            condition: condition,
            optimizedChargingEngaged: bool(powerSource["Optimized Battery Charging Engaged"])
        )

        guard let registry else { return battery }
        battery.cycleCount = positive(registry["CycleCount"])
        battery.designCapacity = positive(registry["DesignCapacity"])
        // Full-charge capacity in mAh. On Apple silicon "MaxCapacity" is a percentage,
        // so the mAh keys are preferred; "MaxCapacity" is only used when it's clearly mAh.
        if let nominal = positive(registry["NominalChargeCapacity"]) {
            battery.fullChargeCapacity = nominal
        } else if let raw = positive(registry["AppleRawMaxCapacity"]) {
            battery.fullChargeCapacity = raw
        } else if let maxCapacity = positive(registry["MaxCapacity"]), maxCapacity > 100 {
            battery.fullChargeCapacity = maxCapacity
        }
        // The registry reports the battery temperature in hundredths of a degree Celsius.
        if let raw = int(registry["Temperature"]), raw > 0, raw < 10_000 {
            battery.temperatureCelsius = Double(raw) / 100
        }
        return battery
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func positive(_ value: Any?) -> Int? {
        int(value).flatMap { $0 > 0 ? $0 : nil }
    }

    private static func bool(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }

    private static func minutes(_ value: Any?) -> TimeInterval? {
        guard let minutes = int(value), minutes > 0, minutes < 100 * 60 else { return nil }
        return TimeInterval(minutes * 60)
    }
}
