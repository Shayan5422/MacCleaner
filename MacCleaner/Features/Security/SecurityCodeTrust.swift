import Darwin
import Foundation
import Security

/// How much a piece of code can be attributed to an identified developer.
enum SecurityTrustCategory: String, Sendable, Hashable, CaseIterable, Codable {
    case apple
    case appStore
    case developerIDNotarized
    /// Developer ID signed; a notarization ticket couldn't be confirmed offline.
    case developerID
    /// Signed with an Apple-issued development certificate (test builds).
    case appleDevelopment
    /// Ad-hoc signed or unsigned build installed by Homebrew, MacPorts or Nix.
    case packageManager
    /// A script; scripts can't carry a code signature.
    case script
    case adHoc
    /// Signed with a certificate that doesn't chain to Apple (self-signed or third-party).
    case untrustedCertificate
    case unsigned
    case invalid
    case revoked
    case missing
    case unknown

    var title: String {
        switch self {
        case .apple: return "Apple"
        case .appStore: return "App Store"
        case .developerIDNotarized: return "Developer ID, notarized"
        case .developerID: return "Developer ID"
        case .appleDevelopment: return "Development signature"
        case .packageManager: return "Package manager build"
        case .script: return "Script"
        case .adHoc: return "Ad-hoc signed"
        case .untrustedCertificate: return "Untrusted certificate"
        case .unsigned: return "Not signed"
        case .invalid: return "Invalid signature"
        case .revoked: return "Certificate revoked"
        case .missing: return "Missing"
        case .unknown: return "Unknown"
        }
    }

    /// Signed by Apple, the App Store or an identified (Developer ID) developer.
    var isIdentifiedDeveloper: Bool {
        switch self {
        case .apple, .appStore, .developerIDNotarized, .developerID: return true
        default: return false
        }
    }

    /// No identified developer stands behind the code. (`unknown` — couldn't be read — is not counted.)
    var isUnknownDeveloper: Bool {
        switch self {
        case .adHoc, .unsigned, .untrustedCertificate, .invalid, .revoked, .script: return true
        default: return false
        }
    }

    /// The signature is broken, revoked or not trusted by macOS.
    var isSignatureProblem: Bool {
        self == .invalid || self == .revoked || self == .untrustedCertificate
    }

    /// Not signed by any identity (unsigned or ad-hoc).
    var lacksIdentity: Bool { self == .unsigned || self == .adHoc }

    /// Developer ID signed without a verified notarization ticket, or not signed by an identified developer.
    var isNotarizationUnconfirmed: Bool {
        switch self {
        case .developerID, .adHoc, .unsigned, .untrustedCertificate, .appleDevelopment, .invalid, .revoked: return true
        default: return false
        }
    }

    var symbolName: String {
        switch self {
        case .apple: return "apple.logo"
        case .appStore: return "bag.fill"
        case .developerIDNotarized: return "checkmark.seal.fill"
        case .developerID: return "checkmark.seal"
        case .appleDevelopment: return "hammer.fill"
        case .packageManager: return "shippingbox.fill"
        case .script: return "scroll.fill"
        case .adHoc: return "signature"
        case .untrustedCertificate: return "exclamationmark.shield.fill"
        case .unsigned: return "questionmark.diamond.fill"
        case .invalid: return "xmark.seal.fill"
        case .revoked: return "xmark.octagon.fill"
        case .missing: return "questionmark.folder.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// A code-signing check of one file, with a trust classification and display text.
struct SecurityCodeEvaluation: Sendable, Hashable {
    var path: String
    var exists: Bool
    var signature: CodeSignatureInfo
    var category: SecurityTrustCategory
    /// "Homebrew", "MacPorts" or "Nix" when the code was installed by a package manager.
    var packageManager: String?

    /// Who signed the code, in plain words.
    var developer: String? {
        SecurityCodeTrust.developerName(signature, category: category, packageManager: packageManager)
    }

    /// One-line trust summary ("Developer ID, notarized", "Ad-hoc signed (no developer identity)").
    var summary: String {
        SecurityCodeTrust.summary(category: category, packageManager: packageManager)
    }

    /// Notarization in plain words.
    var notarization: String {
        switch category {
        case .apple, .appStore: return "Not required (distributed by Apple)"
        case .developerIDNotarized: return "Notarized (ticket verified on this Mac)"
        case .developerID: return "Not confirmed offline (no stapled ticket)"
        case .packageManager, .script: return "Not applicable"
        case .missing, .unknown: return "Unknown"
        default: return "Not notarized"
        }
    }
}

/// Classifies code signatures for review. Uses only the public Security framework
/// and never contacts Apple's servers.
enum SecurityCodeTrust {
    /// Inspects and classifies the code at `path` (blocking; run off the main thread).
    static func evaluate(path: String, deep: Bool = false) -> SecurityCodeEvaluation {
        // A path this user can't read is "unknown", never "missing".
        let exists = LaunchdPathProbe.mightExist(path)
        let signature = exists ? CodeSignatureInspector.inspect(path: path, deep: deep) : CodeSignatureInfo()
        let script = exists && signature.status != .valid && isScriptFile(path: path)
        let manager = packageManager(forPath: path, resolvedPath: PathUtilities.resolvedPath(path))
        let category = classify(signature, exists: exists, isScript: script, packageManager: manager) {
            isAnchoredToApple(path: path)
        }
        return SecurityCodeEvaluation(path: path, exists: exists, signature: signature, category: category, packageManager: manager)
    }

    /// Pure classification, separated from the file system for tests.
    static func classify(
        _ info: CodeSignatureInfo,
        exists: Bool,
        isScript: Bool,
        packageManager: String?,
        anchoredToApple: () -> Bool
    ) -> SecurityTrustCategory {
        guard exists else { return .missing }
        switch info.status {
        case .revoked:
            return .revoked
        case .invalid:
            return .invalid
        case .unsigned:
            if isScript { return .script }
            return packageManager != nil ? .packageManager : .unsigned
        case .unknown:
            return isScript ? .script : .unknown
        case .valid:
            if info.isAppleSigned { return .apple }
            if info.isAppStoreSigned { return .appStore }
            if info.isDeveloperIDSigned { return info.isNotarized == true ? .developerIDNotarized : .developerID }
            if info.isAdHocSigned { return packageManager != nil ? .packageManager : .adHoc }
            if anchoredToApple() {
                // iPhone and iPad apps from the App Store carry Apple's iOS distribution signature.
                return info.authorities.first?.contains("iPhone OS Application Signing") == true ? .appStore : .appleDevelopment
            }
            return .untrustedCertificate
        }
    }

    static func developerName(_ info: CodeSignatureInfo, category: SecurityTrustCategory, packageManager: String?) -> String? {
        switch category {
        case .apple:
            return "Apple"
        case .appStore:
            return "App Store"
        case .developerIDNotarized, .developerID:
            return info.developerName
        case .appleDevelopment:
            return info.developerName.map { "\($0) (development)" }
        case .packageManager:
            return packageManager
        case .untrustedCertificate:
            return info.authorities.first.map { "“\($0)” (not issued by Apple)" }
        case .adHoc, .script, .unsigned, .missing, .unknown:
            return nil
        case .invalid, .revoked:
            return info.isAdHocSigned ? nil : info.developerName
        }
    }

    static func summary(category: SecurityTrustCategory, packageManager: String?) -> String {
        switch category {
        case .apple: return "Signed by Apple"
        case .appStore: return "Distributed through the App Store"
        case .developerIDNotarized: return "Developer ID, notarized"
        case .developerID: return "Developer ID (notarization not confirmed offline)"
        case .appleDevelopment: return "Development signature (not for distribution)"
        case .packageManager: return "Built by \(packageManager ?? "a package manager") (ad-hoc signature)"
        case .script: return "Script (scripts aren't code-signed)"
        case .adHoc: return "Ad-hoc signed (no developer identity)"
        case .untrustedCertificate: return "Signed with a certificate not issued by Apple"
        case .unsigned: return "Not signed"
        case .invalid: return "Invalid signature (modified or damaged)"
        case .revoked: return "Signing certificate revoked by Apple"
        case .missing: return "File missing"
        case .unknown: return "Couldn't be checked"
        }
    }

    // MARK: - Helpers

    /// Package-manager install locations whose builds are normally ad-hoc signed.
    static func packageManager(forPath path: String, resolvedPath: String?) -> String? {
        for candidate in [path, resolvedPath].compactMap({ $0 }) {
            if candidate.hasPrefix("/opt/homebrew/Cellar/") || candidate.hasPrefix("/usr/local/Cellar/")
                || candidate.hasPrefix("/opt/homebrew/Caskroom/") || candidate.hasPrefix("/usr/local/Caskroom/") {
                return "Homebrew"
            }
            if candidate.hasPrefix("/opt/local/") { return "MacPorts" }
            if candidate.hasPrefix("/nix/store/") { return "Nix" }
        }
        return nil
    }

    /// `true` when the code's certificate chain ends at an Apple root (any Apple-issued certificate).
    static func isAnchoredToApple(path: String) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        let noNetworkAccess: UInt32 = 1 << 29
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateResources | noNetworkAccess)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    private static let scriptExtensions: Set<String> = [
        "sh", "bash", "zsh", "command", "tool", "py", "pyw", "pl", "rb", "js", "mjs", "php", "scpt", "applescript", "tcl", "ps1",
    ]

    /// A regular file that is a script (has a `#!` line or a script extension) rather than a Mach-O binary.
    static func isScriptFile(path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return scriptExtensions.contains((path as NSString).pathExtension.lowercased()) }
        defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: 4)
        let count = read(fd, &bytes, 4)
        if count >= 4 {
            let magic = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            if machOMagics.contains(magic) { return false }
        }
        if count >= 2, bytes[0] == UInt8(ascii: "#"), bytes[1] == UInt8(ascii: "!") { return true }
        return scriptExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Mach-O and universal binary magic numbers, read big-endian from the first four bytes.
    static let machOMagics: Set<UInt32> = [
        0xFEED_FACE, 0xCEFA_EDFE, 0xFEED_FACF, 0xCFFA_EDFE, 0xCAFE_BABE, 0xBEBA_FECA, 0xCAFE_BABF, 0xBFBA_FECA,
    ]

    /// `true` when the file starts with a Mach-O or universal binary header.
    static func isMachOFile(path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: 4)
        guard read(fd, &bytes, 4) == 4 else { return false }
        let magic = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        return machOMagics.contains(magic)
    }
}
