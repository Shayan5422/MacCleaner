import Foundation
import LocalAuthentication
import Testing
@testable import MacCleanerMobile

struct ProtectionStatusTests {
    private let upToDate = SoftwareUpdateState.upToDate(newerMajorRelease: nil)
    private let update = SoftwareUpdateState.updateAvailable(SystemVersion("27.0.2")!, postingDate: nil)

    private func status(_ passcode: PasscodeState?, _ software: SoftwareUpdateState?, _ safari: SafariExtensionState?,
                        system: String = "iOS") -> ProtectionModel.Status {
        ProtectionStatusRules.status(passcode: passcode, software: software, safari: safari, systemName: system)
    }

    @Test func protectedNeedsAPasscodeTheLatestIOSAndSafariProtection() {
        #expect(status(.set, upToDate, .on) == .protected)
        // The previous major release still gets updates from Apple, like Settings says.
        #expect(status(.set, .upToDate(newerMajorRelease: SystemVersion("27.0.1")!), .on) == .protected)
    }

    @Test func theMostImportantReasonComesFirst() {
        #expect(status(.notSet, update, .off) == .attention("Set a passcode"))
        #expect(status(.set, update, .off) == .attention("iOS 27.0.2 is available"))
        #expect(status(.set, upToDate, .off) == .attention("Safari protection is off"))
    }

    @Test func aKnownProblemShowsBeforeTheOtherChecksFinish() {
        #expect(status(.notSet, nil, nil) == .attention("Set a passcode"))
        #expect(status(nil, update, nil) == .attention("iOS 27.0.2 is available"))
        #expect(status(nil, nil, .off) == .attention("Safari protection is off"))
    }

    @Test func unknownUntilEveryCheckIsDone() {
        #expect(status(nil, nil, nil) == .unknown)
        #expect(status(.set, nil, .on) == .unknown)
        #expect(status(.set, upToDate, nil) == .unknown)
    }

    @Test func checksThatCouldntRunNeedAttention() {
        #expect(status(.set, .couldNotCheck(.offline), .on) == .attention("Couldn't check for iOS updates"))
        #expect(status(.unknown, upToDate, .on) == .attention("Couldn't check the passcode"))
        #expect(status(.set, upToDate, .unknown) == .attention("Couldn't check Safari protection"))
    }

    @Test func iPadsSayIPadOS() {
        #expect(status(.set, update, .on, system: "iPadOS") == .attention("iPadOS 27.0.2 is available"))
    }
}

struct SecurityCheckMappingTests {
    @Test func passcodeNotSetIsTheOnlyErrorThatMeansNoPasscode() {
        #expect(SecurityChecks.passcodeState(errorCode: LAError.Code.passcodeNotSet.rawValue) == .notSet)
        #expect(SecurityChecks.passcodeState(errorCode: LAError.Code.notInteractive.rawValue) == .unknown)
        #expect(SecurityChecks.passcodeState(errorCode: nil) == .unknown)
    }

    @Test func biometricsFollowWhatIOSSays() {
        #expect(SecurityChecks.biometricsState(kind: .faceID, canEvaluate: true, errorCode: nil) == .enrolled(.faceID))
        #expect(SecurityChecks.biometricsState(kind: .touchID, canEvaluate: false, errorCode: LAError.Code.biometryNotEnrolled.rawValue)
            == .notEnrolled(.touchID))
        #expect(SecurityChecks.biometricsState(kind: .faceID, canEvaluate: false, errorCode: LAError.Code.passcodeNotSet.rawValue)
            == .notEnrolled(.faceID))
        #expect(SecurityChecks.biometricsState(kind: .opticID, canEvaluate: false, errorCode: LAError.Code.biometryLockout.rawValue)
            == .lockedOut(.opticID))
        #expect(SecurityChecks.biometricsState(kind: .faceID, canEvaluate: false, errorCode: LAError.Code.biometryNotAvailable.rawValue)
            == .unknown)
        #expect(SecurityChecks.biometricsState(kind: nil, canEvaluate: false, errorCode: LAError.Code.biometryNotAvailable.rawValue)
            == .unavailable)
    }

    @Test func tunnelInterfacesMeanAVPN() {
        let vpn: [String: Any] = ["__SCOPED__": ["en0": [String: Any](), "utun4": [String: Any]()], "HTTPEnable": 0]
        #expect(SecurityChecks.networkRoute(proxySettings: vpn) == .vpn)
        for interface in ["ipsec0", "ppp0", "tun1", "tap0"] {
            #expect(SecurityChecks.networkRoute(proxySettings: ["__SCOPED__": [interface: [String: Any]()]]) == .vpn)
        }
    }

    @Test func proxySettingsMeanAProxy() {
        #expect(SecurityChecks.networkRoute(proxySettings: ["HTTPEnable": 1, "HTTPProxy": "proxy.example.com"]) == .proxy)
        #expect(SecurityChecks.networkRoute(proxySettings: ["HTTPSEnable": NSNumber(value: true)]) == .proxy)
        #expect(SecurityChecks.networkRoute(proxySettings: ["ProxyAutoConfigEnable": 1, "__SCOPED__": ["utun0": [String: Any]()]])
            == .vpnAndProxy)
    }

    @Test func plainWiFiOrCellularIsDirect() {
        let direct: [String: Any] = ["__SCOPED__": ["en0": [String: Any](), "pdp_ip0": [String: Any]()], "HTTPEnable": 0,
                                     "ExceptionsList": ["*.local", "169.254/16"]]
        #expect(SecurityChecks.networkRoute(proxySettings: direct) == .direct)
        #expect(SecurityChecks.networkRoute(proxySettings: [:]) == .direct)
    }
}

struct FeedUpdatePolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func file(checkedHoursAgo hours: Double?, failures: Int = 0, attemptMinutesAgo minutes: Double? = nil) -> FeedFileState {
        var file = FeedFileState()
        file.lastChecked = hours.map { now.addingTimeInterval(-$0 * 3600) }
        file.failures = failures
        file.lastAttempt = minutes.map { now.addingTimeInterval(-$0 * 60) }
        return file
    }

    @Test func automaticChecksWaitTwelveHours() {
        #expect(!FeedUpdatePolicy.isDue(file(checkedHoursAgo: 11.9), hasData: true, now: now, manual: false))
        #expect(FeedUpdatePolicy.isDue(file(checkedHoursAgo: 12), hasData: true, now: now, manual: false))
    }

    @Test func missingListsAreAlwaysDue() {
        #expect(FeedUpdatePolicy.isDue(file(checkedHoursAgo: 1), hasData: false, now: now, manual: false))
        #expect(FeedUpdatePolicy.isDue(file(checkedHoursAgo: nil), hasData: true, now: now, manual: false))
    }

    @Test func updateNowWaitsOnlyAMinute() {
        #expect(!FeedUpdatePolicy.isDue(file(checkedHoursAgo: 0.01), hasData: true, now: now, manual: true))
        #expect(FeedUpdatePolicy.isDue(file(checkedHoursAgo: 0.02), hasData: true, now: now, manual: true))
    }

    @Test func failuresBackOff() {
        #expect(!FeedUpdatePolicy.isDue(file(checkedHoursAgo: 20, failures: 1, attemptMinutesAgo: 5), hasData: true, now: now, manual: false))
        #expect(FeedUpdatePolicy.isDue(file(checkedHoursAgo: 20, failures: 1, attemptMinutesAgo: 11), hasData: true, now: now, manual: false))
        #expect(!FeedUpdatePolicy.isDue(file(checkedHoursAgo: 20, failures: 3, attemptMinutesAgo: 30), hasData: true, now: now, manual: false))
        // "Update Now" doesn't wait for the backoff.
        #expect(FeedUpdatePolicy.isDue(file(checkedHoursAgo: 20, failures: 3, attemptMinutesAgo: 1), hasData: true, now: now, manual: true))
        #expect(FeedUpdatePolicy.retryDelay(failures: 1) == 600)
        #expect(FeedUpdatePolicy.retryDelay(failures: 2) == 1_200)
        #expect(FeedUpdatePolicy.retryDelay(failures: 50) == 12 * 3600)
    }

    @Test func aClockSetBackDoesntBlockUpdates() {
        var future = FeedFileState()
        future.lastChecked = now.addingTimeInterval(3600)
        #expect(FeedUpdatePolicy.isDue(future, hasData: true, now: now, manual: false))
    }
}
