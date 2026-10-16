import Foundation
import Observation

/// Something Mac Cleaner's protection features noticed: a threat, a flagged download, a
/// visit to a known malware site, a new startup item, a newly opened port...
/// Shown in the menu bar's Activity feed and on the Dashboard.
struct ProtectionEvent: Identifiable, Sendable, Codable, Hashable {
    enum Kind: String, Sendable, Codable, Hashable, CaseIterable {
        case threatFound, threatQuarantined, downloadFlagged
        case maliciousSite, maliciousConnection
        case startupItemAdded, startupItemRemoved, startupItemChanged, openedAtLogin
        case portOpened, portClosed
        case definitionsUpdated, scanCompleted, appUpdateAvailable

        var symbolName: String {
            switch self {
            case .threatFound: return "ladybug.fill"
            case .threatQuarantined: return "archivebox.fill"
            case .downloadFlagged: return "arrow.down.circle.fill"
            case .maliciousSite: return "globe.badge.chevron.backward"
            case .maliciousConnection: return "network.badge.shield.half.filled"
            case .startupItemAdded: return "plus.circle.fill"
            case .startupItemRemoved: return "minus.circle.fill"
            case .startupItemChanged: return "pencil.circle.fill"
            case .openedAtLogin: return "power.circle.fill"
            case .portOpened: return "point.3.connected.trianglepath.dotted"
            case .portClosed: return "xmark.circle.fill"
            case .definitionsUpdated: return "arrow.triangle.2.circlepath.circle.fill"
            case .scanCompleted: return "checkmark.shield.fill"
            case .appUpdateAvailable: return "arrow.down.app.fill"
            }
        }
    }

    var id: UUID
    var date: Date
    var kind: Kind
    var severity: FindingSeverity
    /// One line, e.g. "Threat found in “Invoice.dmg”".
    var title: String
    /// Optional second line, e.g. the signature name or the program a startup item runs.
    var detail: String?
    /// The file, app or item the event is about (Reveal in Finder).
    var path: String?
    /// Where in the app the person can act on it.
    var section: AppSection?

    init(id: UUID = UUID(), date: Date = Date(), kind: Kind, severity: FindingSeverity, title: String,
         detail: String? = nil, path: String? = nil, section: AppSection? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.severity = severity
        self.title = title
        self.detail = detail
        self.path = path
        self.section = section
    }
}

/// Recent protection events, newest first, kept on this Mac only
/// (`~/Library/Application Support/Mac Cleaner/Activity.json`, last 30 days, at most 500 events).
///
/// Features post from the main actor: `ProtectionEventLog.shared.post(...)`. Posting doesn't notify the
/// person by itself; features decide separately whether something deserves a notification.
@MainActor
@Observable
final class ProtectionEventLog {
    static let shared = ProtectionEventLog()

    static let maximumEvents = 500
    static let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    private(set) var events: [ProtectionEvent] = []
    /// Events the person hasn't looked at yet (cleared by `markAllSeen()`), for a badge.
    private(set) var unseenCount = 0

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// - Parameter directory: where `Activity.json` lives; `nil` keeps events in memory only (tests, previews).
    init(directory: URL? = ProtectionEventLog.defaultDirectory) {
        fileURL = directory?.appendingPathComponent("Activity.json")
        load()
    }

    nonisolated static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mac Cleaner", isDirectory: true)
    }

    /// Adds an event. An identical event (same kind, title and path) within `coalescingInterval`
    /// replaces the earlier one instead of repeating it.
    func post(_ event: ProtectionEvent, coalescingInterval: TimeInterval = 60) {
        if let index = events.firstIndex(where: {
            $0.kind == event.kind && $0.title == event.title && $0.path == event.path
                && event.date.timeIntervalSince($0.date) < coalescingInterval
        }) {
            events.remove(at: index)
        } else {
            unseenCount += 1
        }
        events.insert(event, at: 0)
        prune()
        scheduleSave()
    }

    func markAllSeen() {
        unseenCount = 0
    }

    func remove(_ id: ProtectionEvent.ID) {
        events.removeAll { $0.id == id }
        scheduleSave()
    }

    func clear() {
        events = []
        unseenCount = 0
        scheduleSave()
    }

    /// Events of the given kinds, newest first.
    func events(of kinds: Set<ProtectionEvent.Kind>) -> [ProtectionEvent] {
        events.filter { kinds.contains($0.kind) }
    }

    // MARK: Persistence

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.maximumAge)
        events.removeAll { $0.date < cutoff }
        if events.count > Self.maximumEvents { events.removeLast(events.count - Self.maximumEvents) }
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([ProtectionEvent].self, from: data) else { return }
        events = stored.sorted { $0.date > $1.date }
        prune()
    }

    /// Writes at most once per second, off the main thread.
    private func scheduleSave() {
        guard let fileURL else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let snapshot = self?.events else { return }
            await BackgroundWork.run(qos: .utility) {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
}
