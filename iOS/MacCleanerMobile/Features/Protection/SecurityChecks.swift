import CFNetwork
import Foundation
import LocalAuthentication
import SafariServices

/// Whether the device has a passcode.
enum PasscodeState: Sendable, Equatable {
    case set, notSet, unknown
}

/// Face ID, Touch ID or Optic ID.
enum BiometryKind: Sendable, Equatable {
    case faceID, touchID, opticID

    var name: String {
        switch self {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        }
    }

    var symbol: String {
        switch self {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        }
    }
}

/// Whether Face ID, Touch ID or Optic ID is set up.
enum BiometricsState: Sendable, Equatable {
    case enrolled(BiometryKind)
    case notEnrolled(BiometryKind)
    /// Set up, but locked after too many failed attempts until the passcode is entered.
    case lockedOut(BiometryKind)
    /// The device has no biometric sensor (or iOS doesn't offer it).
    case unavailable
    case unknown

    var kind: BiometryKind? {
        switch self {
        case .enrolled(let kind), .notEnrolled(let kind), .lockedOut(let kind): return kind
        case .unavailable, .unknown: return nil
        }
    }
}

/// Whether traffic goes through a VPN or a proxy. Neither is bad; the person should recognize them.
enum NetworkRouteState: Sendable, Equatable {
    case direct, vpn, proxy, vpnAndProxy, unknown
}

/// Whether Mac Cleaner Protection is turned on in Safari's settings.
enum SafariExtensionState: Sendable, Equatable {
    case on, off, unknown
}

/// Reads what iOS lets an app see about the device's security.
enum SecurityChecks {
    static let contentBlockerID = "com.maccleaner.MacCleaner.mobile.ContentBlocker"

    static func passcode() -> PasscodeState {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) { return .set }
        return passcodeState(errorCode: error?.code)
    }

    /// `LAError.passcodeNotSet` means no passcode; other errors say nothing about it.
    static func passcodeState(errorCode: Int?) -> PasscodeState {
        errorCode == LAError.Code.passcodeNotSet.rawValue ? .notSet : .unknown
    }

    static func biometrics() -> BiometricsState {
        let context = LAContext()
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        let kind: BiometryKind?
        switch context.biometryType {
        case .faceID: kind = .faceID
        case .touchID: kind = .touchID
        case .opticID: kind = .opticID
        case .none: kind = nil
        @unknown default: kind = nil
        }
        return biometricsState(kind: kind, canEvaluate: canEvaluate, errorCode: error?.code)
    }

    /// No sensor means unavailable; with a sensor, iOS says whether it's enrolled or locked.
    static func biometricsState(kind: BiometryKind?, canEvaluate: Bool, errorCode: Int?) -> BiometricsState {
        guard let kind else { return errorCode == nil || errorCode == LAError.Code.biometryNotAvailable.rawValue ? .unavailable : .unknown }
        if canEvaluate { return .enrolled(kind) }
        switch errorCode {
        case LAError.Code.biometryNotEnrolled.rawValue: return .notEnrolled(kind)
        case LAError.Code.biometryLockout.rawValue: return .lockedOut(kind)
        // Biometrics can't be set up without a passcode.
        case LAError.Code.passcodeNotSet.rawValue: return .notEnrolled(kind)
        default: return .unknown
        }
    }

    static func networkRoute() -> NetworkRouteState {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return .unknown }
        return networkRoute(proxySettings: settings)
    }

    /// A tunnel interface (utun, ipsec, ppp, tun, tap) among the scoped settings means a VPN;
    /// HTTP, HTTPS or automatic proxy settings mean a proxy.
    static func networkRoute(proxySettings settings: [String: Any]) -> NetworkRouteState {
        let scoped = settings["__SCOPED__"] as? [String: Any] ?? [:]
        let tunnels = ["utun", "ipsec", "ppp", "tun", "tap"]
        let vpn = scoped.keys.contains { key in tunnels.contains { key.lowercased().contains($0) } }
        let proxy = ["HTTPEnable", "HTTPSEnable", "ProxyAutoConfigEnable"].contains { isOn(settings[$0]) }
        switch (vpn, proxy) {
        case (true, true): return .vpnAndProxy
        case (true, false): return .vpn
        case (false, true): return .proxy
        case (false, false): return .direct
        }
    }

    static func safariExtension() async -> SafariExtensionState {
        await withCheckedContinuation { continuation in
            SFContentBlockerManager.getStateOfContentBlocker(withIdentifier: contentBlockerID) { state, error in
                guard error == nil, let state else { return continuation.resume(returning: .unknown) }
                continuation.resume(returning: state.isEnabled ? .on : .off)
            }
        }
    }

    /// Asks Safari to read the rules again.
    static func reloadContentBlocker() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            SFContentBlockerManager.reloadContentBlocker(withIdentifier: contentBlockerID) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func isOn(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }
}

/// The Protection tab's summary: passcode, iOS version and Safari protection, most important first.
enum ProtectionStatusRules {
    static func status(passcode: PasscodeState?, software: SoftwareUpdateState?, safari: SafariExtensionState?,
                       systemName: String) -> ProtectionModel.Status {
        if passcode == .notSet { return .attention("Set a passcode") }
        if case .updateAvailable(let version, _)? = software { return .attention("\(systemName) \(version) is available") }
        if safari == .off { return .attention("Safari protection is off") }
        guard let passcode, let software, let safari else { return .unknown }
        if passcode == .set, software.isUpToDate == true, safari == .on { return .protected }
        if software.isUpToDate == nil { return .attention("Couldn't check for \(systemName) updates") }
        if passcode == .unknown { return .attention("Couldn't check the passcode") }
        return .attention("Couldn't check Safari protection")
    }
}
