import Foundation
import Testing
@testable import MacCleaner

@Suite("Developer – simctl output")
struct DeveloperSimctlParserTests {
    static let devicesJSON = #"""
    {
      "devices" : {
        "com.apple.CoreSimulator.SimRuntime.iOS-27-0" : [
          {
            "dataPath" : "\/Users\/me\/Library\/Developer\/CoreSimulator\/Devices\/CFC8633A-0850-46EC-8DD9-9F575FBA5D8B\/data",
            "dataPathSize" : 18337792,
            "logPath" : "\/Users\/me\/Library\/Logs\/CoreSimulator\/CFC8633A-0850-46EC-8DD9-9F575FBA5D8B",
            "udid" : "CFC8633A-0850-46EC-8DD9-9F575FBA5D8B",
            "lastUsedAt" : "2026-10-12T14:24:46Z",
            "isAvailable" : true,
            "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
            "state" : "Shutdown",
            "name" : "iPhone 18 Pro"
          }
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-18-1" : [
          {
            "availabilityError" : "runtime profile not found using “System” match policy",
            "dataPath" : "\/Users\/me\/Library\/Developer\/CoreSimulator\/Devices\/11111111-1111-1111-1111-111111111111\/data",
            "dataPathSize" : 523000000,
            "logPath" : "\/Users\/me\/Library\/Logs\/CoreSimulator\/11111111-1111-1111-1111-111111111111",
            "logPathSize" : 4096,
            "udid" : "11111111-1111-1111-1111-111111111111",
            "isAvailable" : false,
            "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro",
            "state" : "Shutdown",
            "name" : "iPhone 16 Pro"
          },
          {
            "availabilityError" : "runtime profile not found using “System” match policy",
            "dataPath" : "\/Users\/me\/Library\/Developer\/CoreSimulator\/Devices\/22222222-2222-2222-2222-222222222222\/data",
            "dataPathSize" : 18000000,
            "udid" : "22222222-2222-2222-2222-222222222222",
            "isAvailable" : false,
            "state" : "Shutdown",
            "name" : "iPhone 16"
          }
        ],
        "com.apple.CoreSimulator.SimRuntime.watchOS-11-4" : []
      }
    }
    """#

    static let runtimesJSON = #"""
    {
      "99937711-6DB6-4A20-945A-05BDBFDA00B5" : {
        "build" : "23D8133",
        "deletable" : true,
        "identifier" : "99937711-6DB6-4A20-945A-05BDBFDA00B5",
        "kind" : "Patchable Cryptex Disk Image",
        "lastUsedAt" : "2026-09-14T19:22:54Z",
        "platformIdentifier" : "com.apple.platform.iphonesimulator",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-26-3",
        "signatureState" : "Verified",
        "sizeBytes" : 8393503393,
        "state" : "Ready",
        "supportedArchitectures" : ["arm64"],
        "version" : "26.3.1"
      },
      "EE9C96CA-2208-4F69-90C7-57E0B6C2AD76" : {
        "build" : "24A434",
        "deletable" : true,
        "identifier" : "EE9C96CA-2208-4F69-90C7-57E0B6C2AD76",
        "kind" : "Patchable Cryptex Disk Image",
        "platformIdentifier" : "com.apple.platform.iphonesimulator",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
        "sizeBytes" : 8067000161,
        "state" : "Ready",
        "version" : "27.0"
      },
      "0F0F0F0F-0000-0000-0000-000000000000" : {
        "build" : "22T250",
        "deletable" : false,
        "identifier" : "0F0F0F0F-0000-0000-0000-000000000000",
        "platformIdentifier" : "com.apple.platform.watchsimulator",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.watchOS-11-4",
        "sizeBytes" : 4100000000,
        "state" : "Unusable",
        "version" : "11.4"
      }
    }
    """#

    @Test func parsesDevicesAndFindsUnavailableOnes() throws {
        let list = try DeveloperSimctlParser.parseDevices(Data(Self.devicesJSON.utf8))
        #expect(list.devices.count == 3)
        let unavailable = list.unavailableDevices
        #expect(unavailable.map(\.name).sorted() == ["iPhone 16", "iPhone 16 Pro"])
        #expect(unavailable.reduce(0) { $0 + ($1.dataPathSize ?? 0) } == 541_000_000)
        #expect(unavailable.first { $0.name == "iPhone 16 Pro" }?.reportedBytes == 523_004_096)
        #expect(list.availableDeviceCount(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0") == 1)
        #expect(list.availableDeviceCount(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-1") == 0)
        #expect(list.deviceCount(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-1") == 2)

        let available = try #require(list.devices.first { $0.isAvailable })
        #expect(available.runtimeIdentifier == "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        #expect(available.lastUsedAt == DeveloperSimctlParser.parseDate("2026-10-12T14:24:46Z"))
        #expect(available.lastUsedAt != nil)
    }

    @Test func acceptsOlderStringAvailabilityValues() throws {
        let json = #"""
        {"devices": {"iOS 12.4": [
          {"udid": "A", "name": "Old Phone", "state": "Shutdown", "availability": "(unavailable, runtime profile not found)"},
          {"udid": "B", "name": "Older Phone", "state": "Shutdown", "isAvailable": "YES"}
        ]}}
        """#
        let list = try DeveloperSimctlParser.parseDevices(Data(json.utf8))
        #expect(list.unavailableDevices.map(\.udid) == ["A"])
    }

    @Test func parsesRuntimesAndTellsWhichAreUnused() throws {
        let runtimes = try DeveloperSimctlParser.parseRuntimes(Data(Self.runtimesJSON.utf8))
        let devices = try DeveloperSimctlParser.parseDevices(Data(Self.devicesJSON.utf8))
        #expect(runtimes.count == 3)

        let old = try #require(runtimes.first { $0.version == "26.3.1" })
        #expect(old.displayName == "iOS 26.3.1")
        #expect(old.deletable)
        #expect(old.isReady)
        #expect(old.sizeBytes == 8_393_503_393)
        #expect(old.lastUsedAt != nil)
        #expect(devices.availableDeviceCount(runtimeIdentifier: old.runtimeIdentifier ?? "") == 0)

        let current = try #require(runtimes.first { $0.version == "27.0" })
        #expect(devices.availableDeviceCount(runtimeIdentifier: current.runtimeIdentifier ?? "") == 1)

        let watch = try #require(runtimes.first { $0.platformName == "watchOS" })
        #expect(!watch.deletable)
        #expect(!watch.isReady)
        #expect(watch.displayName == "watchOS 11.4")
    }

    @Test func rejectsMalformedOutput() {
        #expect(throws: (any Error).self) {
            try DeveloperSimctlParser.parseDevices(Data("xcrun: error: unable to find utility \"simctl\"".utf8))
        }
    }
}
