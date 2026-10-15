import AppKit
import CoreServices
import Foundation

/// One "Open at Login" item as reported by System Events.
struct StartupLoginItemRecord: Sendable, Hashable {
    var name: String
    var path: String?
    var hidden: Bool
}

/// Whether Mac Cleaner may ask System Events for login items (Privacy & Security › Automation).
enum StartupAutomationAccess: Sendable, Equatable {
    case granted
    /// Asking would show the macOS permission prompt.
    case notDetermined
    case denied
    case unavailable(String)

    var isGranted: Bool { self == .granted }
}

enum StartupLoginItemsError: LocalizedError, Sendable {
    case notAuthorized
    case scriptFailed(code: Int, message: String)
    case unexpectedResult
    case itemChanged

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Mac Cleaner isn't allowed to control System Events. Allow it in System Settings › Privacy & Security › Automation."
        case .scriptFailed(let code, let message):
            return message.isEmpty ? "System Events reported error \(code)." : "\(message) (\(code))"
        case .unexpectedResult:
            return "System Events returned an unexpected answer."
        case .itemChanged:
            return "The login item changed since it was listed. Refresh and try again."
        }
    }
}

/// Reads and removes "Open at Login" items through System Events (AppleScript).
/// AppleScript runs on the main actor; permission checks run in the background and
/// never prompt unless the person asked for access.
enum StartupLoginItemsService {
    static let systemEventsBundleIdentifier = "com.apple.systemevents"
    static let systemEventsPath = "/System/Library/CoreServices/System Events.app"

    /// AppleEvent error codes.
    static let notPermittedError = -1743      // errAEEventNotPermitted
    static let wouldRequireConsentError = -1744 // errAEEventWouldRequireUserConsent
    static let processNotFoundError = -600    // procNotFound

    // MARK: - Permission

    /// Checks Automation permission for System Events. With `promptIfNeeded`, macOS shows its
    /// permission prompt when the person hasn't decided yet.
    static func automationAccess(promptIfNeeded: Bool) async -> StartupAutomationAccess {
        if !isSystemEventsRunning() {
            do {
                try await launchSystemEvents()
            } catch {
                return .unavailable("System Events couldn't be started: \(error.localizedDescription)")
            }
        }
        let status = await BackgroundWork.run(qos: .userInitiated) { () -> OSStatus in
            let target = NSAppleEventDescriptor(bundleIdentifier: systemEventsBundleIdentifier)
            return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, promptIfNeeded)
        }
        switch Int(status) {
        case Int(noErr): return .granted
        case notPermittedError: return .denied
        case wouldRequireConsentError: return .notDetermined
        case processNotFoundError: return .unavailable("System Events isn't running.")
        default: return .unavailable("macOS reported error \(status) while checking Automation access.")
        }
    }

    /// Reads login items only when access was already granted. Never shows a prompt.
    static func recordsIfAuthorized() async -> [StartupLoginItemRecord]? {
        guard await automationAccess(promptIfNeeded: false) == .granted else { return nil }
        return await MainActor.run { try? readLoginItems() }
    }

    static func isSystemEventsRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: systemEventsBundleIdentifier).isEmpty
    }

    /// Starts System Events in the background (it has no windows) so permission can be checked.
    static func launchSystemEvents() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: systemEventsPath), configuration: configuration)
        for _ in 0..<30 where !isSystemEventsRunning() {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - AppleScript (main actor)

    @MainActor
    static func readLoginItems() throws -> [StartupLoginItemRecord] {
        let descriptor = try run("tell application \"System Events\" to get {name, path, hidden} of every login item")
        guard let records = parse(descriptor) else { throw StartupLoginItemsError.unexpectedResult }
        return records
    }

    /// Removes the login item called `name`, after checking it still points at `expectedPath`.
    @MainActor
    static func deleteLoginItem(named name: String, expectedPath: String?) throws {
        let current = try readLoginItems()
        guard current.contains(where: { $0.name == name && $0.path == expectedPath }) else {
            throw StartupLoginItemsError.itemChanged
        }
        _ = try run("tell application \"System Events\" to delete login item \"\(appleScriptEscaped(name))\"")
    }

    @MainActor
    private static func run(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else { throw StartupLoginItemsError.unexpectedResult }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            if code == notPermittedError || code == wouldRequireConsentError { throw StartupLoginItemsError.notAuthorized }
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? ""
            throw StartupLoginItemsError.scriptFailed(code: code, message: message)
        }
        return result
    }

    // MARK: - Parsing

    /// Parses the `{names, paths, hidden flags}` list returned by System Events.
    static func parse(_ descriptor: NSAppleEventDescriptor) -> [StartupLoginItemRecord]? {
        guard descriptor.descriptorType == typeAEList, descriptor.numberOfItems == 3,
              let names = descriptor.atIndex(1), let paths = descriptor.atIndex(2), let hidden = descriptor.atIndex(3) else {
            return nil
        }
        let count = names.numberOfItems
        guard count > 0 else { return [] }
        var records: [StartupLoginItemRecord] = []
        for index in 1...count {
            guard let name = names.atIndex(index)?.stringValue, !name.isEmpty else { continue }
            var path: String?
            if let pathDescriptor = paths.atIndex(index), pathDescriptor.descriptorType != typeType,
               pathDescriptor.descriptorType != typeNull, let value = pathDescriptor.stringValue, value.hasPrefix("/") {
                path = value.count > 1 && value.hasSuffix("/") ? String(value.dropLast()) : value
            }
            let isHidden = hidden.atIndex(index)?.booleanValue ?? false
            records.append(StartupLoginItemRecord(name: name, path: path, hidden: isHidden))
        }
        return records
    }

    /// Escapes text for an AppleScript string literal.
    static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
