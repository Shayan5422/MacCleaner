import AppKit
import Darwin
import Foundation

enum PerformanceActionError: LocalizedError, Equatable {
    case notRunning(String)
    case changed(String)
    case notAllowed(String)
    case requestFailed(String)
    case signalFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .notRunning(let name):
            return "\(name) isn't running anymore."
        case .changed(let name):
            return "\(name) changed since the list was updated, so nothing was done. Check the list and try again."
        case .notAllowed(let name):
            return "Mac Cleaner doesn't quit or stop \(name), because it's part of macOS, belongs to another user, or is Mac Cleaner itself."
        case .requestFailed(let name):
            return "macOS couldn't send the request to \(name). It may already be quitting."
        case .signalFailed(let name, let code):
            return "Couldn't stop \(name): \(String(cString: strerror(code)))."
        }
    }
}

/// Quits apps and stops processes after re-checking that the target is still the
/// same, still allowed, and still owned by the current user.
@MainActor
enum PerformanceProcessActions {
    /// Asks an app to quit normally (it can ask to save changes).
    static func quit(_ target: PerformanceActionTarget) -> Result<String, PerformanceActionError> {
        switch runningApp(for: target) {
        case .failure(let error):
            return .failure(error)
        case .success(let app):
            guard app.terminate() else { return .failure(.requestFailed(target.name)) }
            return .success("Asked \(target.name) to quit.")
        }
    }

    /// Quits an app immediately; unsaved changes are lost. Callers must have asked twice.
    static func forceQuit(_ target: PerformanceActionTarget) -> Result<String, PerformanceActionError> {
        switch runningApp(for: target) {
        case .failure(let error):
            return .failure(error)
        case .success(let app):
            guard app.forceTerminate() else { return .failure(.requestFailed(target.name)) }
            return .success("Force quit \(target.name).")
        }
    }

    /// Sends SIGTERM to a background process of the current user.
    static func stopProcess(_ target: PerformanceActionTarget) -> Result<String, PerformanceActionError> {
        guard target.kind == .process else { return .failure(.notAllowed(target.name)) }
        guard let fresh = ProcessInspector.snapshot(pid: target.pid) else { return .failure(.notRunning(target.name)) }
        guard fresh.uid == getuid(), target.uid == getuid() else { return .failure(.notAllowed(target.name)) }
        // Same process? The start time and executable identify it; a recycled pid won't match.
        guard sameStart(fresh.startTime, target.startTime), fresh.executablePath == target.executablePath else {
            return .failure(.changed(target.name))
        }
        let process = PerformanceProcess(
            pid: fresh.pid, parentPID: fresh.parentPID, uid: fresh.uid, userName: "", name: target.name,
            executablePath: fresh.executablePath, appBundlePath: fresh.executablePath.flatMap(PerformanceProcessTracker.outermostAppBundle),
            startTime: fresh.startTime, memoryFootprint: nil, cpu: nil, recentCPU: nil, recentCPUWindow: 0,
            isCurrentUser: true, hasUsageInfo: true
        )
        guard PerformanceProcessPolicy.role(of: process, apps: .current()).canStopProcess,
              !PerformanceProcessPolicy.protectedNames.contains(fresh.name) else {
            return .failure(.notAllowed(target.name))
        }
        guard kill(target.pid, SIGTERM) == 0 else {
            let code = errno
            return .failure(code == ESRCH ? .notRunning(target.name) : .signalFailed(target.name, code))
        }
        return .success("Asked \(target.name) to stop.")
    }

    /// True while the app or process is still running (used after a quit request).
    static func isStillRunning(_ target: PerformanceActionTarget) -> Bool {
        switch target.kind {
        case .app:
            guard let app = NSRunningApplication(processIdentifier: target.pid) else { return false }
            return !app.isTerminated && app.bundleIdentifier == target.bundleIdentifier
        case .process:
            guard let fresh = ProcessInspector.snapshot(pid: target.pid) else { return false }
            return sameStart(fresh.startTime, target.startTime)
        }
    }

    // MARK: - Validation

    private static func runningApp(for target: PerformanceActionTarget) -> Result<NSRunningApplication, PerformanceActionError> {
        guard target.kind == .app else { return .failure(.notAllowed(target.name)) }
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated else {
            return .failure(.notRunning(target.name))
        }
        guard app.bundleIdentifier == target.bundleIdentifier, app.bundleURL?.path == target.bundlePath else {
            return .failure(.changed(target.name))
        }
        let ownBundle = Bundle.main.bundlePath
        let isSelf = app.processIdentifier == getpid() || app.bundleIdentifier == Bundle.main.bundleIdentifier || app.bundleURL?.path == ownBundle
        let isSessionApp = app.bundleURL?.path.hasPrefix("/System/Library/") ?? true
        let isUserFacing = app.activationPolicy == .regular || app.activationPolicy == .accessory
        let name = app.executableURL?.lastPathComponent ?? ""
        guard !isSelf, !isSessionApp, isUserFacing, !PerformanceProcessPolicy.protectedNames.contains(name) else {
            return .failure(.notAllowed(target.name))
        }
        // Only the current user's apps. macOS doesn't reveal details of other users'
        // processes, so a missing snapshot also means "not ours" (or already gone).
        guard let owner = ProcessInspector.snapshot(pid: target.pid)?.uid, owner == getuid() else {
            return .failure(.notAllowed(target.name))
        }
        return .success(app)
    }

    private static func sameStart(_ lhs: Date?, _ rhs: Date?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return abs(lhs.timeIntervalSince(rhs)) < 0.000_01
    }
}
