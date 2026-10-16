import Foundation

/// "New port opened" notifications (ported from PortPilot's Notifier), posted through Mac Cleaner's
/// `NotificationService` so a click opens the Ports & Network page.
///
/// Stateful: call `pendingNotifications(for:)` with the *full* current list of (visible) groups after every scan.
/// The first call only records a baseline (no burst of notifications at launch); afterwards a port is "new" when no
/// group had it in the previous call. At most one notification per group per `throttleInterval` (60 s), and only
/// for the categories given (projects and background services by default: apps and macOS open and close ports
/// all the time).
///
/// Thread-safe.
final class PortNewPortNotifier: @unchecked Sendable {
    /// What would be (or was) posted; exposed for tests.
    struct PortNotification: Equatable, Sendable {
        let groupID: String
        let ports: [UInt16]
        let title: String
        let body: String
    }

    private let throttleInterval: TimeInterval
    private let categories: Set<PortListenerCategory>
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    // Guarded by `lock`.
    private var knownPorts: Set<UInt16> = []
    private var hasBaseline = false
    private var lastNotified: [String: Date] = [:]

    /// - Parameters:
    ///   - categories: only groups in these categories notify.
    ///   - now: clock, injectable for tests.
    init(throttleInterval: TimeInterval = 60, categories: Set<PortListenerCategory> = [.project, .service],
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.throttleInterval = throttleInterval
        self.categories = categories
        self.now = now
    }

    /// Posts "New port opened: :5173" for every new port (throttled per group). Notifications only appear when the
    /// person allowed them for Mac Cleaner.
    func notifyNewPorts(_ groups: [PortListenerGroup], service: NotificationService) {
        let notifications = pendingNotifications(for: groups)
        guard !notifications.isEmpty else { return }
        Task.detached(priority: .utility) {
            for notification in notifications {
                // One identifier per group: a newer notification for the same group replaces the older one.
                await service.post(title: notification.title, body: notification.body,
                                   identifier: "network.new-port:\(notification.groupID)", section: .network)
            }
        }
    }

    /// Forget the baseline, e.g. when the person turns notifications back on (avoids a burst for everything that
    /// opened while they were off).
    func resetBaseline() {
        lock.withLock {
            hasBaseline = false
            knownPorts = []
        }
    }

    /// Diffs `groups` against the previous call, applies the throttle and updates state. Posts nothing.
    func pendingNotifications(for groups: [PortListenerGroup]) -> [PortNotification] {
        let relevant = groups.filter { categories.contains($0.category) }
        let currentPorts = Set(relevant.flatMap(\.ports))
        let date = now()
        return lock.withLock {
            defer {
                knownPorts = currentPorts
                hasBaseline = true
                lastNotified = lastNotified.filter { date.timeIntervalSince($0.value) < throttleInterval }
            }
            guard hasBaseline else { return [] }
            var result: [PortNotification] = []
            for group in relevant {
                let newPorts = group.ports.filter { !knownPorts.contains($0) }
                guard !newPorts.isEmpty else { continue }
                if let last = lastNotified[group.id], date.timeIntervalSince(last) < throttleInterval { continue }
                lastNotified[group.id] = date
                result.append(Self.makeNotification(for: group, ports: newPorts))
            }
            return result
        }
    }

    static func makeNotification(for group: PortListenerGroup, ports: [UInt16]) -> PortNotification {
        let portList = ports.map { ":\($0)" }.joined(separator: ", ")
        var name = group.title
        if let framework = group.frameworks.first { name += " (\(framework))" }
        let title = "New port opened: \(portList)"
        var body = name
        if let path = group.path { body += " — " + PortFormat.abbreviatePath(path) }
        return PortNotification(groupID: group.id, ports: ports, title: title, body: body)
    }
}
