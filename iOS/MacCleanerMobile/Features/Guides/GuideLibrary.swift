import SwiftUI

/// What the guides know about the device, to suggest the ones that help now.
struct GuideContext: Sendable, Equatable {
    var storage: DeviceStorage?
    var device: DeviceInfo
    var deletedPhotos: Bool
    var deletedFiles: Bool
    var safariProtectionEnabled: Bool?
    /// False when Apple offers a newer iOS for this device (`ProtectionModel.systemUpToDate`).
    var systemUpToDate: Bool? = nil
    /// False when the device has no passcode (`ProtectionModel.passcodeSet`).
    var passcodeSet: Bool? = nil
    /// The update Apple offers, e.g. "27.0.2" (`ProtectionModel.availableSystemVersion`).
    var availableSystemVersion: String? = nil

    var isStorageLow: Bool { storage?.isLow ?? false }
    /// "iOS" or "iPadOS".
    var systemName: String { device.isPad ? "iPadOS" : "iOS" }
}

/// The library's sections.
enum GuideCategory: String, CaseIterable, Identifiable, Sendable {
    case space, security

    var id: String { rawValue }

    var title: String {
        switch self {
        case .space: return "Free up space"
        case .security: return "Privacy & security"
        }
    }

    var footer: String {
        switch self {
        case .space: return "iOS doesn't let apps clear other apps' data or system caches. These settings and tools in iOS do it instead."
        case .security: return "Apps can't see or change most of these settings, so it's worth checking them yourself."
        }
    }
}

/// The guides, by name.
enum GuideKey: String, CaseIterable, Sendable {
    case photosRecentlyDeleted = "photos-recently-deleted"
    case filesRecentlyDeleted = "files-recently-deleted"
    case optimizePhotos = "optimize-photos"
    case offloadApps = "offload-apps"
    case largestApps = "largest-apps"
    case messagesHistory = "messages-history"
    case messagesAttachments = "messages-attachments"
    case safariHistory = "safari-history"
    case safariTabs = "safari-tabs"
    case downloadedMedia = "downloaded-media"
    case chatAppMedia = "chat-app-media"
    case updateSystem = "update-ios"
    case stolenDeviceProtection = "stolen-device-protection"
    case safariProtection = "safari-protection"
    case privacyAccess = "privacy-access"
    case profiles = "vpn-device-management"
    case passcode = "passcode"
    case lockdownMode = "lockdown-mode"
}

/// A step-by-step guide for something iOS doesn't let an app do itself.
///
/// Text other than the title and summary may contain "{device}" ("iPhone" or "iPad") and
/// "{system}" ("iOS" or "iPadOS"); steps and notes use Markdown, with **bold** for what to tap.
struct Guide: Identifiable, Sendable, Hashable {
    var id: String
    var title: String
    var summary: String
    var symbol: String
    var category: GuideCategory
    var tint: Color
    /// Why it helps.
    var why: String
    /// Roughly what it saves (space guides) or protects (security guides).
    var benefit: String
    /// The steps on iOS 18 and later.
    var steps: [String]
    /// The steps on iOS 17, when they differ.
    var iOS17Steps: [String]? = nil
    /// A caveat after the steps.
    var note: String? = nil
    /// Mac Cleaner's own page in Settings helps here (its Photos and Contacts access).
    var opensAppSettings = false
    /// The feature exists on iPhone only.
    var iPhoneOnly = false

    var key: GuideKey? { GuideKey(rawValue: id) }

    var benefitTitle: String { category == .space ? "What it saves" : "What it protects" }

    func steps(forSystemMajorVersion major: Int) -> [String] {
        major >= 18 ? steps : (iOS17Steps ?? steps)
    }

    func isAvailable(on device: DeviceInfo) -> Bool {
        !iPhoneOnly || !device.isPad
    }

    /// Fills in "{device}" and "{system}".
    static func text(_ template: String, for device: DeviceInfo) -> String {
        template.replacingOccurrences(of: "{device}", with: device.deviceWord)
            .replacingOccurrences(of: "{system}", with: device.isPad ? "iPadOS" : "iOS")
    }
}

/// A sentence about the guide's subject on this device, e.g. "iOS 27.0.2 is available".
struct GuideStatusNote: Sendable, Equatable {
    var text: String
    /// Already done (green) rather than something to do (orange).
    var isGood: Bool
}

enum GuideLibrary {
    /// Every guide, in the library's order.
    static let all: [Guide] = GuideContent.space + GuideContent.security

    static func guide(_ key: GuideKey) -> Guide {
        guard let guide = all.first(where: { $0.id == key.rawValue }) else { preconditionFailure("No guide for \(key)") }
        return guide
    }

    static func guide(id: String) -> Guide? {
        all.first { $0.id == id }
    }

    static func guides(in category: GuideCategory, for device: DeviceInfo) -> [Guide] {
        all.filter { $0.category == category && $0.isAvailable(on: device) }
    }

    /// Guides whose title, summary, explanation or steps contain every word of `query`.
    static func search(_ query: String, for device: DeviceInfo) -> [Guide] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return all.filter { guide in
            guard guide.isAvailable(on: device) else { return false }
            let text = ([guide.title, guide.summary, guide.why, guide.benefit, guide.note ?? ""]
                + guide.steps(forSystemMajorVersion: device.systemMajorVersion))
                .joined(separator: " ").lowercased().replacingOccurrences(of: "*", with: "")
            return words.allSatisfy { text.contains($0) }
        }
    }

    // MARK: Suggestions

    /// The guides that help most now, best first, leaving out the ones marked as done on this device.
    @MainActor
    static func suggestions(for context: GuideContext) -> [Guide] {
        suggestions(for: context, completed: GuideProgress.shared.completed, sessionStart: GuideProgress.shared.sessionStart)
    }

    /// The guides that help most now, best first.
    ///
    /// - Items deleted with Mac Cleaner come first: the space returns once Recently Deleted is
    ///   emptied (unless that guide was marked as done since the app started).
    /// - Then what the Protection tab found: no passcode, an iOS update, Safari protection off.
    ///   These states are checked, so a "done" mark doesn't hide them.
    /// - When storage is almost full, the guides that free the most space.
    /// - Then a default order of what helps most people.
    ///
    /// `completed` holds the date each guide was marked as done.
    static func suggestions(for context: GuideContext, completed: [String: Date], sessionStart: Date) -> [Guide] {
        var keys: [GuideKey] = []
        func add(_ key: GuideKey) {
            if !keys.contains(key) { keys.append(key) }
        }
        func isDone(_ key: GuideKey) -> Bool { completed[key.rawValue] != nil }
        func isDoneThisSession(_ key: GuideKey) -> Bool {
            guard let date = completed[key.rawValue] else { return false }
            return date >= sessionStart
        }

        if context.deletedPhotos, !isDoneThisSession(.photosRecentlyDeleted) { add(.photosRecentlyDeleted) }
        if context.deletedFiles, !isDoneThisSession(.filesRecentlyDeleted) { add(.filesRecentlyDeleted) }
        if context.passcodeSet == false { add(.passcode) }
        if context.systemUpToDate == false { add(.updateSystem) }
        if context.safariProtectionEnabled == false { add(.safariProtection) }
        if context.isStorageLow {
            for key in spaceOrder where !isDone(key) { add(key) }
        }
        for key in defaultOrder where !isDone(key) {
            // Safari protection only while its state is unknown; when it's off it's already above.
            if key == .safariProtection && context.safariProtectionEnabled != nil { continue }
            add(key)
        }
        return keys.map(guide).filter { $0.isAvailable(on: context.device) }
    }

    /// The space guides, most space first.
    static let spaceOrder: [GuideKey] = [
        .photosRecentlyDeleted, .optimizePhotos, .offloadApps, .largestApps, .messagesAttachments, .messagesHistory,
        .downloadedMedia, .chatAppMedia, .filesRecentlyDeleted, .safariHistory, .safariTabs,
    ]

    /// What helps most people, when nothing more urgent shows up. Passcode and iOS update guides
    /// appear only when the checkup finds a problem, and Lockdown Mode is never pushed.
    static let defaultOrder: [GuideKey] = [
        .stolenDeviceProtection, .safariProtection, .offloadApps, .optimizePhotos, .messagesHistory, .largestApps,
        .privacyAccess, .profiles, .safariTabs, .messagesAttachments, .downloadedMedia, .chatAppMedia, .safariHistory,
        .photosRecentlyDeleted, .filesRecentlyDeleted,
    ]

    /// Why a guide is suggested now, e.g. "Photos you deleted still use space".
    static func reason(for guide: Guide, in context: GuideContext) -> String? {
        guard let key = guide.key else { return nil }
        switch key {
        case .photosRecentlyDeleted where context.deletedPhotos:
            return "Photos you deleted still use space"
        case .filesRecentlyDeleted where context.deletedFiles:
            return "Files you deleted still use space"
        case .passcode where context.passcodeSet == false:
            return "Your \(context.device.deviceWord) has no passcode"
        case .updateSystem where context.systemUpToDate == false:
            return context.availableSystemVersion.map { "\(context.systemName) \($0) is available" } ?? "An update is available"
        case .safariProtection where context.safariProtectionEnabled == false:
            return "Safari protection is off"
        default:
            if guide.category == .space && context.isStorageLow { return "Your \(context.device.deviceWord) is almost full" }
            return nil
        }
    }

    /// What the app knows about the guide's subject on this device, shown at the top of the guide.
    static func statusNote(for guide: Guide, in context: GuideContext) -> GuideStatusNote? {
        let device = context.device.deviceWord
        switch guide.key {
        case .updateSystem?:
            switch context.systemUpToDate {
            case false?:
                let update = context.availableSystemVersion.map { "\(context.systemName) \($0)" } ?? "An update"
                return GuideStatusNote(text: "\(update) is available for your \(device).", isGood: false)
            case true?:
                return GuideStatusNote(text: "Your \(device) is up to date (\(context.systemName) \(context.device.systemVersionString)).", isGood: true)
            case nil:
                return nil
            }
        case .passcode?:
            return context.passcodeSet.map {
                $0 ? GuideStatusNote(text: "Your \(device) has a passcode.", isGood: true)
                   : GuideStatusNote(text: "Your \(device) doesn't have a passcode.", isGood: false)
            }
        case .safariProtection?:
            return context.safariProtectionEnabled.map {
                $0 ? GuideStatusNote(text: "Safari protection is on.", isGood: true)
                   : GuideStatusNote(text: "Safari protection is off.", isGood: false)
            }
        case .photosRecentlyDeleted? where context.deletedPhotos:
            return GuideStatusNote(text: "You deleted photos with Mac Cleaner. They're in Recently Deleted now.", isGood: false)
        case .filesRecentlyDeleted? where context.deletedFiles:
            return GuideStatusNote(text: "You deleted files with Mac Cleaner. They're in Recently Deleted now.", isGood: false)
        default:
            guard guide.category == .space, context.isStorageLow, let storage = context.storage else { return nil }
            return GuideStatusNote(text: "Your \(device) is almost full: \(ByteFormatting.string(storage.available)) available.", isGood: false)
        }
    }
}
