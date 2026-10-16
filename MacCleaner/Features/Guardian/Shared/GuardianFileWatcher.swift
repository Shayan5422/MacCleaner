import CoreServices
import Foundation

/// Watches folders with FSEvents and reports changed paths in batches.
///
/// FSEvents coalesces changes for `latency` seconds before calling back, so a burst of writes
/// (an installer dropping several property lists) costs one wake-up. Folders that don't exist or
/// can't be read are skipped. Callbacks arrive on a private serial queue.
final class GuardianFileWatcher: @unchecked Sendable {
    let paths: [String]
    let latency: TimeInterval
    private let handler: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "MacCleaner.Guardian.FileWatcher", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    init(paths: [String], latency: TimeInterval = 3, handler: @escaping @Sendable ([String]) -> Void) {
        self.paths = paths
        self.latency = latency
        self.handler = handler
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        stop()
    }

    var isRunning: Bool { lock.withLock { stream != nil } }

    /// Starts watching the folders that exist. Returns the folders actually watched.
    @discardableResult
    func start() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return paths }
        let existing = paths.filter { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        guard !existing.isEmpty else { return [] }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<GuardianFileWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let array = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
            watcher.deliver(Array(array.prefix(count)))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return [] }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return []
        }
        stream = created
        return existing
    }

    func stop() {
        lock.lock()
        let current = stream
        stream = nil
        lock.unlock()
        guard let current else { return }
        FSEventStreamStop(current)
        FSEventStreamInvalidate(current)
        // Wait for a callback that may be running right now, so none outlives this object.
        if DispatchQueue.getSpecific(key: queueKey) != true { queue.sync {} }
        FSEventStreamRelease(current)
    }

    private func deliver(_ changed: [String]) {
        guard isRunning, !changed.isEmpty else { return }
        handler(changed)
    }
}
