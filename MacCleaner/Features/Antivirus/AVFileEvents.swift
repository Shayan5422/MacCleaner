import CoreServices
import Darwin
import Foundation

/// One file-system change reported by FSEvents.
struct AVFileEvent: Sendable, Hashable {
    var path: String
    var flags: UInt32

    init(path: String, flags: UInt32) {
        self.path = path
        self.flags = flags
    }

    private func has(_ flag: Int) -> Bool { flags & UInt32(flag) != 0 }

    var isFile: Bool { has(kFSEventStreamEventFlagItemIsFile) }
    var isDirectory: Bool { has(kFSEventStreamEventFlagItemIsDir) }
    var isRemoved: Bool { has(kFSEventStreamEventFlagItemRemoved) }
    var isRenamed: Bool { has(kFSEventStreamEventFlagItemRenamed) }
    /// FSEvents dropped events for this folder.
    var mustRescan: Bool { has(kFSEventStreamEventFlagMustScanSubDirs) }

    static let created = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
    static let modified = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
    static let renamed = UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile)
    static let removed = UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)
}

/// Delivers file events for folders. `AVFSEventSource` is the real one; tests push events.
protocol AVFileEventSource: AnyObject, Sendable {
    /// Starts watching; returns false when the stream couldn't start.
    func start(paths: [String], handler: @escaping @Sendable ([AVFileEvent]) -> Void) -> Bool
    func stop()
}

/// An FSEvents stream with file-level events, delivered on a private utility queue.
final class AVFSEventSource: AVFileEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "MacCleaner.Antivirus.FSEvents", qos: .utility)
    private var stream: FSEventStreamRef?
    private var handler: (@Sendable ([AVFileEvent]) -> Void)?
    var latency: TimeInterval = 0.5

    init() {}

    deinit { stop() }

    func start(paths: [String], handler: @escaping @Sendable ([AVFileEvent]) -> Void) -> Bool {
        stop()
        lock.withLock { self.handler = handler }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let source = Unmanaged<AVFSEventSource>.fromOpaque(info).takeUnretainedValue()
            let paths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var events: [AVFileEvent] = []
            events.reserveCapacity(count)
            for index in 0..<count { events.append(AVFileEvent(path: String(cString: paths[index]), flags: flags[index])) }
            source.deliver(events)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            return false
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        lock.withLock { stream = created }
        return true
    }

    func stop() {
        let current = lock.withLock { () -> FSEventStreamRef? in
            defer { stream = nil; handler = nil }
            return stream
        }
        guard let current else { return }
        FSEventStreamStop(current)
        FSEventStreamInvalidate(current)
        FSEventStreamRelease(current)
    }

    private func deliver(_ events: [AVFileEvent]) {
        let handler = lock.withLock { self.handler }
        handler?(events)
    }
}

/// What the tracker needs to know about a file.
struct AVFileProbe: Sendable, Equatable {
    var size: Int64
    var modified: TimeInterval
    var isRegular: Bool
    var isDataless: Bool

    static func live(_ path: String) -> AVFileProbe? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return AVFileProbe(size: Int64(info.st_size),
                           modified: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9,
                           isRegular: (info.st_mode & S_IFMT) == S_IFREG,
                           isDataless: info.st_flags & FileFlags.dataless != 0)
    }
}

/// Waits until a changed file has stopped changing (same size and date for `settleInterval`)
/// before it is scanned, and ignores downloads in progress until they get their final name.
final class AVFileSettleTracker: @unchecked Sendable {
    /// Extensions browsers use while a download is in progress.
    static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial"]

    private struct Candidate {
        var lastEvent: Date
        var lastChange: Date
        var lastProbe: AVFileProbe?
    }

    private let lock = NSLock()
    private let settleInterval: TimeInterval
    private let maxPending: Int
    private let probe: @Sendable (String) -> AVFileProbe?
    private let now: @Sendable () -> Date
    private var candidates: [String: Candidate] = [:]
    private(set) var droppedCount = 0

    init(settleInterval: TimeInterval = 1.5, maxPending: Int = 5_000,
         probe: @escaping @Sendable (String) -> AVFileProbe? = AVFileProbe.live,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.settleInterval = settleInterval
        self.maxPending = maxPending
        self.probe = probe
        self.now = now
    }

    var pendingCount: Int { lock.withLock { candidates.count } }

    /// True for `name.crdownload` and anything inside Safari's `name.download` bundle.
    static func isPartialDownload(_ path: String) -> Bool {
        for component in path.split(separator: "/") {
            guard let dot = component.lastIndex(of: "."), dot != component.startIndex else { continue }
            if partialExtensions.contains(component[component.index(after: dot)...].lowercased()) { return true }
        }
        return false
    }

    func record(_ events: [AVFileEvent]) {
        let time = now()
        lock.withLock {
            for event in events {
                if event.isDirectory && !event.isFile { continue }
                if Self.isPartialDownload(event.path) { continue }
                if event.isRemoved && probe(event.path) == nil {
                    candidates[event.path] = nil
                    continue
                }
                if var existing = candidates[event.path] {
                    existing.lastEvent = time
                    candidates[event.path] = existing
                } else if candidates.count < maxPending {
                    candidates[event.path] = Candidate(lastEvent: time, lastChange: time, lastProbe: nil)
                } else {
                    droppedCount += 1
                }
            }
        }
    }

    /// Paths that are ready to scan; they are removed from the tracker.
    func poll() -> [String] {
        let time = now()
        return lock.withLock {
            var ready: [String] = []
            for (path, var candidate) in candidates {
                guard let current = probe(path), current.isRegular, !current.isDataless else {
                    candidates[path] = nil
                    continue
                }
                if current != candidate.lastProbe {
                    candidate.lastProbe = current
                    candidate.lastChange = time
                    candidates[path] = candidate
                    continue
                }
                if time.timeIntervalSince(candidate.lastChange) >= settleInterval && time.timeIntervalSince(candidate.lastEvent) >= settleInterval {
                    ready.append(path)
                    candidates[path] = nil
                }
            }
            return ready.sorted()
        }
    }
}
