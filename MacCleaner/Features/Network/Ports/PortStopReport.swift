import Foundation

// What Stop, Stop All, Relaunch and Start did, and the banner that says so. Pure values and functions (no system
// calls), so the wording and the actions offered are unit tested. AppStore runs the actions and fills these in.

/// One Stop the user asked for: a group, one of its listeners, or one group of "Stop All Projects".
struct PortStopRequest: Sendable {
    let processes: [PortListenerProcess]
    let groupID: String
    let title: String
    /// Category of the row. Apps are asked to quit; apps and macOS services are never force-killed by a plain Stop
    /// and never get a Recently Stopped record (relaunching a bare helper argv would be wrong).
    let category: PortListenerCategory
    let mode: PortStopMode
    /// "Stop Only This Process": signal just the listener, never through its manager.
    let onlyThisProcess: Bool
    /// Stop & Disable Auto-Start.
    let disableAutoStart: Bool

    init(processes: [PortListenerProcess], groupID: String, title: String, category: PortListenerCategory, mode: PortStopMode,
         onlyThisProcess: Bool, disableAutoStart: Bool) {
        self.processes = processes
        self.groupID = groupID
        self.title = title
        self.category = category
        self.mode = mode
        self.onlyThisProcess = onlyThisProcess
        self.disableAutoStart = disableAutoStart
    }

    init(group: PortListenerGroup, mode: PortStopMode, disableAutoStart: Bool) {
        self.init(processes: group.processes, groupID: group.id, title: group.title, category: group.category,
                  mode: mode, onlyThisProcess: false, disableAutoStart: disableAutoStart)
    }

    var isAppOrSystem: Bool { category == .app || category == .system }
}

/// What one Stop did.
struct PortStopOutcome: Sendable {
    let groupID: String
    let title: String
    /// Ports of the listeners the user asked to stop.
    let ports: [UInt16]
    var errors: [String] = []
    /// Short facts for the success message ("pm2 api removed", "auto-start turned off for com.acme.api").
    var notes: [String] = []
    /// Servers stopped by signal, for Recently Stopped.
    var records: [PortStoppedRecord] = []
    /// The records whose command is known well enough to start them again (Undo).
    var undoRecordIDs: [UUID] = []
    /// How many things were stopped: launchd jobs, pm2 apps, containers, kill plans, apps that quit.
    var stoppedCount = 0
    /// SIGKILL had to be used.
    var escalated = false
    /// launchd jobs that were unloaded (not disabled) and start again at next login, in a folder where Disable
    /// Auto-Start can switch them off (and Startup Items back on).
    var autoStartLabels: [String] = []
    /// A GUI app was asked to quit and did.
    var quitApp = false
    /// A GUI app was asked to quit but was still open at the deadline (it may be asking to save). Never force-quit.
    var stillQuitting = false
    /// Nothing was left to stop: the listeners had exited and nothing of theirs listens on their ports any more.
    var alreadyExited = false

    init(groupID: String, title: String, ports: [UInt16]) {
        self.groupID = groupID
        self.title = title
        self.ports = ports
    }

    var succeeded: Bool { errors.isEmpty }
}

/// A relaunch, checked beyond the spawn: the new process must stay up and, when the stopped server had ports,
/// listen on one of them again.
struct PortRelaunchResult: Sendable {
    enum State: Equatable, Sendable {
        /// Running and listening on `port` again.
        case listening(pid: Int32, port: UInt16)
        /// Running; the record had no port to check.
        case running(pid: Int32)
        /// Running, but none of the record's ports opened within the wait.
        case notListening(pid: Int32)
        /// Started, then exited while Mac Cleaner waited for its port.
        case exited
        /// Couldn't start; the reason follows "Couldn't relaunch <title>: ".
        case failed(String)
    }

    let record: PortStoppedRecord
    let state: State
    /// Where its output goes (~/Library/Logs/Mac Cleaner/<title>.log).
    let logPath: String

    /// The process is up: the record can leave Recently Stopped (relaunching it again would start a second copy).
    var isRunning: Bool {
        switch state {
        case .listening, .running, .notListening: return true
        case .exited, .failed: return false
        }
    }
}

/// The pm2 commands a Stop runs. A seam so tests never reach the person's own pm2 daemon.
struct PortPM2Commands: Sendable {
    /// `pm2 stop` (a cluster-mode app as a whole).
    var stop: @Sendable (_ id: Int) async throws -> Void
    /// `pm2 delete` plus removing the app from pm2's saved list.
    var delete: @Sendable (_ id: Int, _ name: String) async throws -> PortPM2SavedListUpdate

    static func live(_ service: PortPM2Service) -> PortPM2Commands {
        PortPM2Commands(stop: { try await service.stop(id: $0) },
                        delete: { try await service.delete(id: $0, name: $1) })
    }
}

/// PortBanner texts and actions for stopping, relaunching and starting. Pure.
enum PortStopReport {
    /// Where to turn off a login item Mac Cleaner can't manage.
    static let loginItemsSettings = "System Settings › General › Login Items & Extensions"

    // MARK: Stop

    /// The banner after one Stop.
    static func banner(for outcome: PortStopOutcome) -> PortBanner {
        if !outcome.succeeded {
            return PortBanner(style: .error, message: "Couldn't fully stop \(outcome.title): "
                          + outcome.errors.prefix(3).joined(separator: "; "))
        }
        if outcome.alreadyExited && outcome.stoppedCount == 0 {
            return PortBanner(style: .info, message: "\(outcome.title) had already exited")
        }
        if outcome.stillQuitting {
            return PortBanner(style: .info, message: "Asked \(outcome.title) to quit. It's still open — "
                          + "it may be waiting for you to save something.")
        }
        var message = (outcome.quitApp ? "Quit " : "Stopped ") + outcome.title + portText(outcome.ports)
        if outcome.escalated { message += " — had to force-stop" }
        if !outcome.notes.isEmpty { message += " · " + outcome.notes.joined(separator: ", ") }
        if !outcome.autoStartLabels.isEmpty {
            return PortBanner(style: .success, message: message + ". It will start again at next login.",
                          action: .disableAutoStart(groupID: outcome.groupID, launchdLabels: outcome.autoStartLabels),
                          actionTitle: "Disable Auto-Start")
        }
        if let undo = undoAction(for: outcome.undoRecordIDs) {
            return PortBanner(style: .success, message: message, action: undo, actionTitle: "Undo")
        }
        return PortBanner(style: .success, message: message)
    }

    /// One banner for "Stop All Projects": how many stopped, the first failures, and one Disable Auto-Start or Undo
    /// covering every project. nil when nothing was stopped.
    static func summary(for outcomes: [PortStopOutcome]) -> PortBanner? {
        guard let first = outcomes.first else { return nil }
        guard outcomes.count > 1 else { return banner(for: first) }
        let total = outcomes.count
        let failed = outcomes.filter { !$0.succeeded }
        if !failed.isEmpty {
            let reasons = failed.prefix(2).map { "\($0.title): \($0.errors.first ?? "failed")" }
            let more = failed.count > 2 ? "; \(failed.count - 2) more failed" : ""
            return PortBanner(style: .error, message: "Stopped \(total - failed.count) of \(total) projects — "
                          + reasons.joined(separator: "; ") + more)
        }
        let ports = Array(Set(outcomes.flatMap(\.ports))).sorted()
        var message = "Stopped \(total) projects" + portText(ports, limit: 6)
        if outcomes.contains(where: \.escalated) { message += " — had to force-stop some" }
        var labels: [String] = []
        for label in outcomes.flatMap(\.autoStartLabels) where !labels.contains(label) { labels.append(label) }
        if !labels.isEmpty {
            message += labels.count == 1 ? ". \(labels[0]) starts again at next login."
                                         : ". \(labels.count) launchd jobs start again at next login."
            return PortBanner(style: .success, message: message,
                          action: .disableAutoStart(groupID: "", launchdLabels: labels),
                          actionTitle: "Disable Auto-Start")
        }
        if let undo = undoAction(for: outcomes.flatMap(\.undoRecordIDs)) {
            return PortBanner(style: .success, message: message, action: undo, actionTitle: "Undo")
        }
        return PortBanner(style: .success, message: message)
    }

    /// Armed tooltip of "Stop All Projects": which projects the second click stops.
    static func stopAllConfirmHelp(_ groups: [PortListenerGroup]) -> String {
        let names = groups.map(\.title)
        let list = names.count <= 3 ? joinedList(names)
            : names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
        var text = "Click again to stop \(list)."
        let autoStart = groups.filter { group in
            if case .launchd(let job) = group.manager { return job.keepAlive || job.runAtLoad }
            return false
        }
        if autoStart.count == 1 {
            text += " \(autoStart[0].title) starts again at next login."
        } else if autoStart.count > 1 {
            text += " \(autoStart.count) of them start again at next login."
        }
        return text
    }

    /// Undo for the records a Stop created; nil when none can be relaunched.
    static func undoAction(for recordIDs: [UUID]) -> PortBanner.Action? {
        guard let first = recordIDs.first else { return nil }
        return .relaunch(recordID: first, moreRecordIDs: Array(recordIDs.dropFirst()))
    }

    // MARK: Relaunch

    /// True when Relaunch can start the record again: a plain server whose argv is a real command line, or a
    /// package-manager title Mac Cleaner rebuilds ("npm run dev"). False for other titles (nginx's "master process …").
    static func canRelaunch(_ record: PortStoppedRecord) -> Bool {
        guard record.canRelaunch, let first = record.arguments.first else { return false }
        return !PortRelauncher.isTitleRewritten(record.arguments, executablePath: record.executablePath)
            || PortRelauncher.commandFromTitle(first) != nil
    }

    /// The banner after Relaunch / Undo. nil when nothing was relaunched.
    static func relaunchBanner(for results: [PortRelaunchResult]) -> PortBanner? {
        guard let first = results.first else { return nil }
        guard results.count > 1 else { return relaunchBanner(for: first) }
        let total = results.count
        let failed = results.filter { !$0.isRunning }
        if !failed.isEmpty {
            let reasons = failed.prefix(2).map { "\($0.record.title): \(failureReason($0))" }
            return PortBanner(style: .error, message: "Relaunched \(total - failed.count) of \(total) — "
                          + reasons.joined(separator: "; "))
        }
        let quiet = results.filter { if case .notListening = $0.state { return true } else { return false } }
        if !quiet.isEmpty {
            let names = joinedList(quiet.map(\.record.title))
            return PortBanner(style: .warning, message: "Relaunched \(total) servers, but \(names) "
                          + (quiet.count == 1 ? "isn't" : "aren't") + " listening yet. Logs are in "
                          + PortFormat.abbreviatePath(PortRelauncher.logDirectory.path) + ".")
        }
        let ports = results.compactMap { result -> UInt16? in
            if case .listening(_, let port) = result.state { return port }
            return nil
        }
        return PortBanner(style: .success, message: "Relaunched \(total) servers" + portText(ports.sorted(), limit: 6))
    }

    private static func relaunchBanner(for result: PortRelaunchResult) -> PortBanner {
        let title = result.record.title
        let log = PortFormat.abbreviatePath(result.logPath)
        switch result.state {
        case .listening(_, let port):
            return PortBanner(style: .success, message: "Relaunched \(title) — listening on :\(port) again")
        case .running(let pid):
            return PortBanner(style: .success, message: "Relaunched \(title) (pid \(pid)) — its output is in \(log)")
        case .notListening(let pid):
            let ports = result.record.ports.map { ":\($0)" }.joined(separator: ", ")
            return PortBanner(style: .warning, message: "Started \(title) (pid \(pid)), but \(ports) "
                          + (result.record.ports.count == 1 ? "isn't" : "aren't") + " open yet. Its output is in \(log).")
        case .exited, .failed:
            return PortBanner(style: .error, message: "Couldn't relaunch \(title): \(failureReason(result))")
        }
    }

    private static func failureReason(_ result: PortRelaunchResult) -> String {
        switch result.state {
        case .failed(let reason): return reason
        case .exited:
            return "it exited soon after starting. Its output is in \(PortFormat.abbreviatePath(result.logPath))"
        case .listening, .running, .notListening: return "it is running"
        }
    }

    // MARK: Auto-start and Startup Items

    /// The banner after "Disable Auto-Start" for jobs a Stop already unloaded.
    /// - Parameters:
    ///   - disabled: labels whose auto-start was turned off.
    ///   - manual: labels Mac Cleaner can't turn off (no plist in a LaunchAgents folder, e.g. an app's helper).
    static func autoStartBanner(disabled: [String], manual: [String], errors: [String]) -> PortBanner {
        if !errors.isEmpty {
            return PortBanner(style: .error, message: "Couldn't turn off auto-start: " + errors.prefix(2).joined(separator: "; "))
        }
        if !manual.isEmpty {
            let done = disabled.isEmpty ? "" : "Turned off auto-start for \(joinedList(disabled)). "
            return PortBanner(style: .warning, message: done + "Mac Cleaner can't turn off auto-start for \(joinedList(manual)). "
                          + "Turn it off in \(loginItemsSettings).")
        }
        if disabled.count == 1 {
            return PortBanner(style: .success, message: "\(disabled[0]) won't start at login anymore. "
                          + "Turn it back on under Startup Items.")
        }
        return PortBanner(style: .success, message: "\(disabled.count) launchd jobs won't start at login anymore. "
                      + "Turn them back on under Startup Items.")
    }

    // MARK: Helpers

    /// " (:3000, :5173)", capped at `limit` ports ("… +3"); "" for none.
    static func portText(_ ports: [UInt16], limit: Int = .max) -> String {
        guard !ports.isEmpty else { return "" }
        let shown = ports.prefix(max(1, limit)).map { ":\($0)" }.joined(separator: ", ")
        let more = ports.count > limit ? " +\(ports.count - limit)" : ""
        return " (" + shown + more + ")"
    }

    /// "a", "a and b", "a, b and c".
    static func joinedList(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}
