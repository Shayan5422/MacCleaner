import Darwin
import Foundation

/// The `com.apple.quarantine` extended attribute: "flags;timestamp;agent;event-id".
/// Mac Cleaner only reads it; it never changes or removes quarantine information.
struct SecurityQuarantineInfo: Sendable, Hashable {
    /// Bit set once the person approved opening the item through Gatekeeper.
    static let userApprovedFlag: UInt32 = 0x0040

    var flags: UInt32
    var date: Date?
    /// The app that downloaded the file ("Safari", "Google Chrome", "Mail"...).
    var agent: String?
    var eventIdentifier: String?
    var rawValue: String

    var isUserApproved: Bool { flags & Self.userApprovedFlag != 0 }
    var flagsDescription: String { String(format: "0x%04X", flags) }

    /// Parses the attribute value. Returns nil when it isn't a quarantine record.
    static func parse(_ rawValue: String) -> SecurityQuarantineInfo? {
        let value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
        let fields = value.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard let first = fields.first, !first.isEmpty, first.count <= 8, let flags = UInt32(first, radix: 16) else { return nil }
        var date: Date?
        if fields.count > 1, let seconds = UInt64(fields[1], radix: 16), seconds > 0 {
            date = Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        let agent = fields.count > 2 && !fields[2].isEmpty ? fields[2] : nil
        let event = fields.count > 3 && !fields[3].isEmpty ? fields[3] : nil
        return SecurityQuarantineInfo(flags: flags, date: date, agent: agent, eventIdentifier: event, rawValue: value)
    }

    /// Reads the attribute without following symbolic links.
    static func read(path: String) -> SecurityQuarantineInfo? {
        let name = "com.apple.quarantine"
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0, size < 4096 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let count = getxattr(path, name, &buffer, size, 0, XATTR_NOFOLLOW)
        guard count > 0 else { return nil }
        return parse(String(decoding: buffer.prefix(count), as: UTF8.self))
    }
}

/// What kind of download a quarantined item is.
enum SecurityDownloadKind: String, Sendable, Hashable, CaseIterable {
    case application, installerPackage, diskImage, script, executable, archive, other

    var title: String {
        switch self {
        case .application: return "App"
        case .installerPackage: return "Installer package"
        case .diskImage: return "Disk image"
        case .script: return "Script"
        case .executable: return "Executable"
        case .archive: return "Archive"
        case .other: return "Document"
        }
    }

    var pluralTitle: String {
        switch self {
        case .application: return "Apps"
        case .installerPackage: return "Installer packages"
        case .diskImage: return "Disk images"
        case .script: return "Scripts"
        case .executable: return "Executables"
        case .archive: return "Archives"
        case .other: return "Other files"
        }
    }

    var symbolName: String {
        switch self {
        case .application: return "app.dashed"
        case .installerPackage: return "shippingbox"
        case .diskImage: return "opticaldiscdrive"
        case .script: return "scroll"
        case .executable: return "terminal"
        case .archive: return "doc.zipper"
        case .other: return "doc"
        }
    }

    /// Types that can run code or install software.
    var canRunCode: Bool {
        switch self {
        case .application, .installerPackage, .diskImage, .script, .executable: return true
        case .archive, .other: return false
        }
    }

    /// Apps, installer packages and disk images: things people download to install software.
    var isInstaller: Bool { self == .application || self == .installerPackage || self == .diskImage }

    static func classify(name: String, isDirectory: Bool, isExecutableMachO: Bool) -> SecurityDownloadKind {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "app": return .application
        case "pkg", "mpkg": return .installerPackage
        case "dmg", "iso", "img", "sparseimage", "sparsebundle", "cdr": return .diskImage
        case "sh", "command", "tool", "bash", "zsh", "py", "pl", "rb", "scpt", "scptd", "applescript", "workflow", "terminal": return .script
        case "jar": return .executable
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "cpgz", "zst": return .archive
        default:
            if !isDirectory && isExecutableMachO { return .executable }
            return .other
        }
    }
}

/// Signature of an installer package, from `pkgutil --check-signature`.
struct SecurityPackageSignature: Sendable, Hashable {
    var statusText: String
    var isSigned: Bool
    /// Signed with an Apple-issued (Developer ID Installer or Apple) certificate.
    var isAppleIssued: Bool
    /// `true` when pkgutil confirmed notarization; nil when it didn't say.
    var isNotarized: Bool?
    var signer: String?

    static func parse(_ output: String) -> SecurityPackageSignature? {
        var status: String?
        var notarized: Bool?
        var signer: String?
        for line in output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("Status:") {
                status = line.dropFirst("Status:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Notarization:") {
                notarized = line.lowercased().contains("trusted by the apple notary service")
            } else if signer == nil, line.hasPrefix("1. ") {
                signer = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let status else { return nil }
        let lowered = status.lowercased()
        let signed = !lowered.contains("no signature")
        return SecurityPackageSignature(
            statusText: status,
            isSigned: signed,
            isAppleIssued: signed && (lowered.contains("issued by apple") || lowered.contains("signed apple software")),
            isNotarized: notarized,
            signer: signer
        )
    }
}

/// A file in Downloads that still carries quarantine information.
struct SecurityQuarantinedFile: Identifiable, Sendable, Hashable {
    var path: String
    var kind: SecurityDownloadKind
    var quarantine: SecurityQuarantineInfo
    var sizeBytes: Int64
    var lastOpened: Date?
    var bundleIdentifier: String?
    /// Code signature, for apps and executables.
    var evaluation: SecurityCodeEvaluation?
    var packageSignature: SecurityPackageSignature?
    var snapshot: FileSnapshot?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var downloadedDate: Date? { quarantine.date }

    /// Not approved through Gatekeeper and never opened according to Spotlight.
    var neverOpened: Bool { !quarantine.isUserApproved && lastOpened == nil }

    func ageDays(now: Date = Date()) -> Int? {
        downloadedDate.map { max(0, Int(now.timeIntervalSince($0) / 86_400)) }
    }

    /// What Gatekeeper is likely to do, from offline signature facts.
    var gatekeeperNote: String {
        switch kind {
        case .application, .executable:
            guard let evaluation else { return "The signature couldn't be checked." }
            switch evaluation.category {
            case .apple, .appStore: return "Signed by Apple. Gatekeeper allows it."
            case .developerIDNotarized: return "Developer ID signed and notarized. Gatekeeper allows it."
            case .developerID: return "Developer ID signed. Notarization couldn't be confirmed offline; Gatekeeper checks it online the first time it opens."
            case .appleDevelopment: return "Signed with a development certificate. Gatekeeper will block it."
            case .adHoc, .unsigned, .packageManager: return "Not signed by an identified developer. Gatekeeper will block it."
            case .untrustedCertificate: return "Signed with a certificate not issued by Apple. Gatekeeper will block it."
            case .invalid: return "The signature is broken (damaged or modified after signing). Gatekeeper will block it."
            case .revoked: return "Apple revoked the developer's certificate. Gatekeeper will block it."
            case .script: return "Scripts aren't code-signed. Only run scripts you trust."
            case .missing, .unknown: return "The signature couldn't be checked."
            }
        case .installerPackage:
            guard let signature = packageSignature else { return "The package signature couldn't be checked." }
            if !signature.isSigned { return "The package isn't signed. Gatekeeper will block it." }
            if !signature.isAppleIssued { return "Signed with a certificate not issued by Apple (\(signature.statusText))." }
            if signature.isNotarized == true { return "Signed by \(signature.signer ?? "an identified developer") and notarized." }
            return "Signed by \(signature.signer ?? "an identified developer"). Notarization wasn't confirmed."
        case .diskImage:
            return "Gatekeeper checks the apps inside when you open them."
        case .script:
            return "Scripts aren't code-signed. Only run scripts you trust."
        case .archive, .other:
            return "Opens in its default app; macOS warns before anything inside runs."
        }
    }

    var cleanupItem: CleanupItem {
        CleanupItem(path: path, purpose: .userFile, snapshot: snapshot, estimatedBytes: sizeBytes, category: "Quarantined downloads")
    }
}

/// Finds quarantined items in a downloads folder (read-only).
enum SecurityQuarantineScanner {
    /// Lists quarantined items in `folder` and one level of subfolders (bundles aren't entered).
    static func scan(folder: String, maxDepth: Int = 2, maxEntries: Int = 20_000) -> [SecurityQuarantinedFile] {
        var results: [SecurityQuarantinedFile] = []
        var visited = 0
        let manager = FileManager.default

        func visit(_ directory: String, depth: Int) {
            guard depth <= maxDepth, visited < maxEntries,
                  let names = try? manager.contentsOfDirectory(atPath: directory) else { return }
            for name in names.sorted() {
                guard visited < maxEntries else { return }
                visited += 1
                if name == ".DS_Store" || name.hasPrefix("._") { continue }
                let path = directory + "/" + name
                var info = stat()
                guard lstat(path, &info) == 0 else { continue }
                let fileType = info.st_mode & S_IFMT
                if fileType == S_IFLNK { continue }
                let isDirectory = fileType == S_IFDIR
                let isPackage = isDirectory && PackageDetector.isPackage(name: name)

                if let quarantine = SecurityQuarantineInfo.read(path: path) {
                    let isExecutable = fileType == S_IFREG && (info.st_mode & 0o111) != 0 && SecurityCodeTrust.isMachOFile(path: path)
                    let kind = SecurityDownloadKind.classify(name: name, isDirectory: isDirectory, isExecutableMachO: isExecutable)
                    // Documents open in their own apps and can't run code; only code and archives are reviewed.
                    if kind != .other {
                        results.append(SecurityQuarantinedFile(
                            path: path,
                            kind: kind,
                            quarantine: quarantine,
                            sizeBytes: isDirectory ? directorySize(path) : Int64(info.st_blocks) * 512,
                            snapshot: FileSnapshot.capture(path: path)
                        ))
                    }
                }
                if isDirectory && !isPackage && !name.hasPrefix(".") {
                    visit(path, depth: depth + 1)
                }
            }
        }
        visit(folder, depth: 1)
        return results
    }

    /// Allocated size of a bundle (bounded, for the Trash estimate).
    static func directorySize(_ path: String, limit: Int = 50_000) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        var count = 0
        while let url = enumerator.nextObject() as? URL, count < limit {
            count += 1
            if let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]), values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
