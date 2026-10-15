import Foundation
import Security

/// Code-signing facts about an app or executable, read with the Security framework.
struct CodeSignatureInfo: Sendable, Hashable {
    enum Status: String, Sendable, Hashable {
        /// Signed and the signature verifies.
        case valid
        /// Not signed at all.
        case unsigned
        /// Signed, but the signature doesn't verify (modified or damaged code).
        case invalid
        /// The signing certificate was revoked by Apple.
        case revoked
        /// Couldn't be checked (missing file, unsupported item).
        case unknown

        var title: String {
            switch self {
            case .valid: return "Valid signature"
            case .unsigned: return "Not signed"
            case .invalid: return "Invalid signature"
            case .revoked: return "Certificate revoked"
            case .unknown: return "Unknown"
            }
        }
    }

    var status: Status = .unknown
    var identifier: String?
    var teamIdentifier: String?
    /// Common names of the certificate chain, leaf first.
    var authorities: [String] = []
    var isAppleSigned = false
    var isAppStoreSigned = false
    var isDeveloperIDSigned = false
    var isAdHocSigned = false
    var hasHardenedRuntime = false
    /// `true` when a notarization ticket was verified offline; `nil` when it couldn't be confirmed offline.
    var isNotarized: Bool?
    var errorCode: OSStatus?

    /// "Developer ID Application: Example Inc (ABCDE12345)" → "Example Inc".
    var developerName: String? {
        if isAppleSigned { return "Apple" }
        guard let leaf = authorities.first else { return nil }
        let prefixes = ["Developer ID Application: ", "Apple Distribution: ", "Apple Development: ", "Mac Developer: ", "3rd Party Mac Developer Application: "]
        var name = leaf
        for prefix in prefixes where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        if let range = name.range(of: " (", options: .backwards) { name = String(name[..<range.lowerBound]) }
        if leaf == "Apple Mac OS Application Signing" || leaf == "Apple iPhone OS Application Signing" { return "App Store" }
        return name
    }

    var trustSummary: String {
        switch status {
        case .valid:
            if isAppleSigned { return "Signed by Apple" }
            if isAppStoreSigned { return "Mac App Store" }
            if isDeveloperIDSigned { return isNotarized == true ? "Developer ID, notarized" : "Developer ID" }
            if isAdHocSigned { return "Ad-hoc signed (no identity)" }
            return "Signed"
        default:
            return status.title
        }
    }
}

enum CodeSignatureInspector {
    /// `kSecCSNoNetworkAccess` (1 << 29): never contact Apple's servers during validation.
    private static let noNetworkAccess: UInt32 = 1 << 29

    /// Inspects the code at `path`.
    ///
    /// - Parameter deep: Also verifies every resource of the bundle. This is
    ///   thorough but slow for large apps, so it's off by default.
    static func inspect(path: String, deep: Bool = false) -> CodeSignatureInfo {
        var info = CodeSignatureInfo()
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            info.errorCode = createStatus
            return info
        }

        var signingInfo: CFDictionary?
        if SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfo) == errSecSuccess,
           let dictionary = signingInfo as? [String: Any] {
            info.identifier = dictionary[kSecCodeInfoIdentifier as String] as? String
            info.teamIdentifier = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
            if let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate] {
                info.authorities = certificates.compactMap { SecCertificateCopySubjectSummary($0) as String? }
            }
            if let flags = dictionary[kSecCodeInfoFlags as String] as? UInt32 {
                info.isAdHocSigned = flags & 0x0002 != 0          // kSecCodeSignatureAdhoc
                info.hasHardenedRuntime = flags & 0x0001_0000 != 0 // kSecCodeSignatureRuntime
            }
        }

        var flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | noNetworkAccess)
        if !deep { flags.insert(SecCSFlags(rawValue: kSecCSDoNotValidateResources)) }
        var errors: Unmanaged<CFError>?
        let validity = SecStaticCodeCheckValidityWithErrors(code, flags, nil, &errors)
        errors?.release()
        switch validity {
        case errSecSuccess:
            info.status = .valid
        case errSecCSUnsigned:
            info.status = .unsigned
        case OSStatus(bitPattern: 0x8001_0C0C), errSecCSRevokedNotarization: // CSSMERR_TP_CERT_REVOKED
            info.status = .revoked
        default:
            info.status = info.identifier == nil && info.authorities.isEmpty ? .unsigned : .invalid
            info.errorCode = validity
        }

        if info.status == .valid {
            info.isAppleSigned = satisfies(code, "anchor apple")
            info.isAppStoreSigned = satisfies(code, "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists")
            info.isDeveloperIDSigned = satisfies(code, "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists")
            if info.isDeveloperIDSigned {
                info.isNotarized = satisfies(code, "notarized") ? true : nil
            } else if info.isAppleSigned || info.isAppStoreSigned {
                info.isNotarized = true
            }
        }
        return info
    }

    private static func satisfies(_ code: SecStaticCode, _ requirementText: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateResources | noNetworkAccess)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}
