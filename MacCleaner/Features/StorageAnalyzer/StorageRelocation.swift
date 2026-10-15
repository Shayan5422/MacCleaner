import AppKit
import Darwin
import SwiftUI

/// Moves files and folders to another location.
///
/// * On the same volume the item is renamed into place (`renamex_np` with
///   `RENAME_EXCL`: atomic, never overwrites, can't cross volumes).
/// * To another volume the item is copied under a temporary hidden name,
///   the copy is verified (file count, folder count and data size must match
///   the original), renamed into place, and only then is the original moved
///   to the Trash through `CleanupEngine` — so it can be restored from History.
/// * Items `SafetyPolicy` wouldn't let the person delete as `.userFile`
///   (for example anything in ~/Library or a system folder) are refused, and
///   items containing cloud-only files aren't copied, because reading them
///   would download them.
enum StorageRelocator {
    struct Item: Identifiable, Sendable, Hashable {
        var path: String
        var name: String
        var snapshot: FileSnapshot
        var estimatedBytes: Int64
        var id: String { path }
    }

    enum Mode: Sendable, Equatable {
        /// Same volume: instant rename.
        case move
        /// Other volume: copy, verify, then move the original to the Trash.
        case copyThenTrash
    }

    struct Check: Identifiable, Sendable {
        var item: Item
        var mode: Mode?
        /// Why the item can't be relocated, or nil.
        var problem: String?
        var id: String { item.id }
    }

    struct Outcome: Identifiable, Sendable {
        enum Result: Sendable {
            case moved(to: String)
            case copied(to: String, trashedOriginal: String?)
            case copiedOriginalKept(to: String, reason: String)
            case failed(String)
        }

        var item: Item
        var result: Result
        var id: String { item.id }

        var succeeded: Bool {
            switch result {
            case .moved, .copied: return true
            case .copiedOriginalKept, .failed: return false
            }
        }
    }

    // MARK: - Checks

    /// Validates a destination folder chosen by the person. Returns a reason when it can't be used.
    static func destinationProblem(_ destination: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String? {
        var info = stat()
        guard stat(destination, &info) == 0, FileObjectType(mode: info.st_mode) == .directory else {
            return "The destination folder doesn't exist."
        }
        guard access(destination, W_OK) == 0 else {
            return "You don't have permission to put items in this folder."
        }
        let canonical = PathUtilities.firmlinkCanonical(PathUtilities.resolvedPath(destination) ?? destination)
        let resolvedHome = PathUtilities.resolvedPath(home) ?? home
        if canonical.contains("/.Trash") {
            return "Choose a folder outside the Trash. To delete items, use Move to Trash instead."
        }
        let insideHome = PathUtilities.isSameOrDescendant(canonical, of: resolvedHome)
        let shared = PathUtilities.isSameOrDescendant(canonical, of: "/Users/Shared")
        let volume = PathUtilities.isDescendant(canonical, of: "/Volumes")
        guard insideHome || shared || volume else {
            return "Choose a folder in your home folder, in /Users/Shared or on another drive."
        }
        return nil
    }

    /// Checks every item against the destination and the safety policy.
    static func check(items: [Item], destination: String, policy: SafetyPolicy) -> [Check] {
        let destinationCanonical = PathUtilities.firmlinkCanonical(PathUtilities.resolvedPath(destination) ?? destination)
        var destinationInfo = stat()
        let destinationDevice: dev_t? = stat(destination, &destinationInfo) == 0 ? destinationInfo.st_dev : nil

        return items.map { item in
            var check = Check(item: item)
            if case .denied(let reason) = policy.evaluate(path: item.path, purpose: .userFile) {
                check.problem = reason
                return check
            }
            var info = stat()
            guard lstat(item.path, &info) == 0 else {
                check.problem = "The item no longer exists."
                return check
            }
            let current = FileSnapshot(identity: FileIdentity(device: info.st_dev, inode: UInt64(info.st_ino)), type: FileObjectType(mode: info.st_mode))
            guard current == item.snapshot else {
                check.problem = "The item changed after the scan. Scan again to review it."
                return check
            }
            let itemCanonical = PathUtilities.firmlinkCanonical(item.path)
            if PathUtilities.isSameOrDescendant(destinationCanonical, of: itemCanonical) {
                check.problem = "A folder can't be moved into itself."
                return check
            }
            if (itemCanonical as NSString).deletingLastPathComponent == destinationCanonical {
                check.problem = "The item is already in this folder."
                return check
            }
            var existing = stat()
            if lstat(PathUtilities.join(destination, item.name), &existing) == 0 {
                check.problem = "An item named “\(item.name)” already exists in the destination."
                return check
            }
            guard let destinationDevice else {
                check.problem = "The destination folder doesn't exist."
                return check
            }
            check.mode = info.st_dev == destinationDevice ? .move : .copyThenTrash
            if check.mode == .copyThenTrash, info.st_flags & FileFlags.dataless != 0 {
                check.problem = "The file is stored in the cloud and isn't downloaded. Copying it would download it first."
                check.mode = nil
            }
            return check
        }
    }

    // MARK: - Same volume

    /// Renames the item into `destination`. Fails instead of overwriting, and never crosses volumes.
    static func moveOnSameVolume(_ item: Item, to destination: String) throws -> String {
        guard FileSnapshot.capture(path: item.path) == item.snapshot else {
            throw RelocationError.changed
        }
        let target = PathUtilities.join(destination, item.name)
        guard renamex_np(item.path, target, UInt32(RENAME_EXCL)) == 0 else {
            throw RelocationError.posix(errno)
        }
        return target
    }

    // MARK: - Other volume

    /// Counts what a copy must reproduce. `._*` AppleDouble files and `.DS_Store` are ignored on
    /// both sides: some file systems create them when extended attributes are copied.
    struct Inventory: Sendable, Equatable {
        var regularFiles = 0
        var directories = 0
        var symbolicLinks = 0
        var dataBytes: Int64 = 0
        var datalessFiles = 0
    }

    static func inventory(of path: String, cancellation: StorageCancellationFlag) throws -> Inventory {
        var result = Inventory()
        var info = stat()
        guard lstat(path, &info) == 0 else { throw RelocationError.posix(errno) }
        func record(_ info: stat) -> Bool {
            switch FileObjectType(mode: info.st_mode) {
            case .regular:
                result.regularFiles += 1
                result.dataBytes += Int64(info.st_size)
                if info.st_flags & FileFlags.dataless != 0 { result.datalessFiles += 1 }
                return false
            case .directory:
                result.directories += 1
                return true
            case .symlink:
                result.symbolicLinks += 1
                return false
            case .other:
                return false
            }
        }
        guard record(info) else { return result }
        var pending = [path]
        while let directory = pending.popLast() {
            if cancellation.isCancelled { throw CancellationError() }
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: directory)
            } catch {
                throw RelocationError.unreadable(directory)
            }
            for name in names where !name.hasPrefix("._") && name != ".DS_Store" {
                let child = PathUtilities.join(directory, name)
                var childInfo = stat()
                guard lstat(child, &childInfo) == 0 else { throw RelocationError.unreadable(child) }
                if record(childInfo) { pending.append(child) }
            }
        }
        return result
    }

    /// Copies `source` to `target` (which must not exist) with `copyfile(3)`, reporting progress
    /// and stopping when cancelled. Cloud placeholders are never downloaded: materialization is
    /// disabled for the copying thread, so such a file makes the copy fail instead.
    static func copy(_ source: String, to target: String, progress: StorageCopyProgress) throws {
        // COPYFILE_EXCL doesn't stop a recursive copy from merging into an existing folder,
        // so an existing target is refused explicitly.
        var existing = stat()
        if lstat(target, &existing) == 0 { throw RelocationError.destinationExists }
        guard let state = copyfile_state_alloc() else { throw RelocationError.posix(ENOMEM) }
        defer { copyfile_state_free(state) }
        let callback: copyfile_callback_t = { what, stage, fileState, source, _, context in
            guard let context else { return COPYFILE_CONTINUE }
            let progress = Unmanaged<StorageCopyProgress>.fromOpaque(context).takeUnretainedValue()
            if progress.isCancelled { return COPYFILE_QUIT }
            if stage == COPYFILE_ERR {
                progress.recordError(path: source.map { String(cString: $0) })
                return COPYFILE_QUIT
            }
            if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS, let fileState {
                // Recursive copies pass a per-file state; its COPIED value is the current file's progress.
                var copied: off_t = 0
                if copyfile_state_get(fileState, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 {
                    progress.didCopyChunk(bytes: Int64(copied))
                }
            } else if what == COPYFILE_RECURSE_FILE, stage == COPYFILE_FINISH, let source {
                var info = stat()
                if lstat(source, &info) == 0, FileObjectType(mode: info.st_mode) == .regular {
                    progress.didFinishFile(bytes: Int64(info.st_size))
                }
            }
            return COPYFILE_CONTINUE
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(progress).toOpaque())

        let flags = StorageCopyFlags.all | StorageCopyFlags.recursive | StorageCopyFlags.exclusive | StorageCopyFlags.noFollow
        let status = StorageDatalessGuard.withoutMaterialization {
            copyfile(source, target, state, flags)
        }
        if progress.isCancelled { throw CancellationError() }
        guard status == 0 else {
            let code = errno
            throw RelocationError.copyFailed(progress.errorPath ?? source, code == 0 ? EIO : code)
        }
    }

    enum RelocationError: LocalizedError {
        /// Thrown by `copy` before anything is written.
        case destinationExists
        case changed
        case posix(Int32)
        case unreadable(String)
        case copyFailed(String, Int32)
        case verificationFailed
        case notEnoughSpace(needed: Int64, available: Int64)
        case cloudOnlyContent(Int)

        var errorDescription: String? {
            switch self {
            case .destinationExists:
                return "An item with the same name already exists in the destination."
            case .changed:
                return "The item changed after the scan, so it was left untouched."
            case .posix(let code):
                if code == EEXIST { return "An item with the same name already exists in the destination." }
                if code == EXDEV { return "The destination is on another volume." }
                if code == EPERM || code == EACCES { return "Permission denied." }
                return String(cString: strerror(code))
            case .unreadable(let path):
                return "Couldn't read \(PathUtilities.abbreviate(path))."
            case .copyFailed(let path, let code):
                return "Copying stopped at \((path as NSString).lastPathComponent): \(String(cString: strerror(code)))."
            case .verificationFailed:
                return "The copy doesn't match the original (different number of files or size), so the original was kept."
            case .notEnoughSpace(let needed, let available):
                return "Not enough space on the destination: \(ByteFormatting.string(needed)) needed, \(ByteFormatting.string(available)) available."
            case .cloudOnlyContent(let count):
                return "\(NumberFormatting.count(count)) file\(count == 1 ? " is" : "s are") stored only in the cloud. Copying would download \(count == 1 ? "it" : "them") first, so the item was skipped."
            }
        }
    }
}

/// Flags for `copyfile(3)`, declared locally because the composite C macros don't import into Swift.
private enum StorageCopyFlags {
    static let acl: copyfile_flags_t = 1 << 0
    static let stat: copyfile_flags_t = 1 << 1
    static let xattr: copyfile_flags_t = 1 << 2
    static let data: copyfile_flags_t = 1 << 3
    static let all: copyfile_flags_t = acl | stat | xattr | data
    static let recursive: copyfile_flags_t = 1 << 15
    static let exclusive: copyfile_flags_t = 1 << 17
    static let noFollow: copyfile_flags_t = (1 << 18) | (1 << 19)
}

/// Turns off on-demand downloading of cloud placeholders for the current thread
/// while `body` runs, so reading a dataless file fails instead of downloading it.
enum StorageDatalessGuard {
    static func withoutMaterialization<T>(_ body: () throws -> T) rethrows -> T {
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer {
            if previous >= 0 { setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous) }
        }
        return try body()
    }
}

/// Progress of one `copyfile` operation, written from the copy thread and polled by the UI.
final class StorageCopyProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var completed: Int64 = 0
    private var current: Int64 = 0
    private var cancelled = false
    private var failedPath: String?

    var bytesCopied: Int64 { lock.withLock { completed + current } }
    var isCancelled: Bool { lock.withLock { cancelled } }
    var errorPath: String? { lock.withLock { failedPath } }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    fileprivate func didCopyChunk(bytes: Int64) {
        lock.withLock { current = bytes }
    }

    fileprivate func didFinishFile(bytes: Int64) {
        lock.withLock {
            completed += bytes
            current = 0
        }
    }

    fileprivate func recordError(path: String?) {
        lock.withLock { if failedPath == nil { failedPath = path } }
    }
}

// MARK: - Controller

/// Drives the "Move to…" sheet: destination choice, checks, progress and results.
@MainActor
@Observable
final class StorageRelocationController {
    enum Phase: Equatable {
        case review, running, finished
    }

    struct Request: Identifiable {
        let id = UUID()
        var items: [StorageRelocator.Item]
    }

    var request: Request?
    private(set) var destination: String?
    private(set) var destinationProblem: String?
    private(set) var destinationFreeSpace: Int64?
    private(set) var checks: [StorageRelocator.Check] = []
    private(set) var phase: Phase = .review
    private(set) var bytesDone: Int64 = 0
    private(set) var bytesTotal: Int64 = 0
    private(set) var currentItemName = ""
    private(set) var outcomes: [StorageRelocator.Outcome] = []
    /// Extra caution shown before moving (for example, items in cloud-synced folders).
    private(set) var note: String?

    private var task: Task<Void, Never>?
    private var activeCopy: StorageCopyProgress?
    private var cancellation = StorageCancellationFlag()
    private var onFinish: (([StorageRelocator.Outcome]) -> Void)?

    init() {}

    var validChecks: [StorageRelocator.Check] { checks.filter { $0.problem == nil && $0.mode != nil } }
    var needsCopy: Bool { validChecks.contains { $0.mode == .copyThenTrash } }
    var plannedBytes: Int64 { validChecks.reduce(0) { $0 + $1.item.estimatedBytes } }

    func begin(items: [StorageRelocator.Item], note: String? = nil, onFinish: @escaping ([StorageRelocator.Outcome]) -> Void) {
        guard !items.isEmpty else { return }
        self.onFinish = onFinish
        self.note = note
        destination = nil
        destinationProblem = nil
        destinationFreeSpace = nil
        checks = items.map { StorageRelocator.Check(item: $0) }
        outcomes = []
        phase = .review
        bytesDone = 0
        bytesTotal = 0
        request = Request(items: items)
    }

    func chooseDestination(policy: SafetyPolicy) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose where to move the selected items. Another drive works too: items are copied, checked, then the originals go to the Trash."
        panel.prompt = "Move Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setDestination(url.path, policy: policy)
    }

    func setDestination(_ path: String, policy: SafetyPolicy) {
        let normalized = PathUtilities.normalize(path)
        destination = normalized
        destinationProblem = StorageRelocator.destinationProblem(normalized)
        destinationFreeSpace = VolumeService.volume(containing: normalized)?.availableCapacity
        guard let request else { return }
        if destinationProblem == nil {
            checks = StorageRelocator.check(items: request.items, destination: normalized, policy: policy)
        } else {
            checks = request.items.map { StorageRelocator.Check(item: $0) }
        }
    }

    func start(services: AppServices) {
        guard phase == .review, let destination, destinationProblem == nil else { return }
        let planned = validChecks
        guard !planned.isEmpty else { return }
        phase = .running
        bytesTotal = planned.filter { $0.mode == .copyThenTrash }.reduce(0) { $0 + $1.item.estimatedBytes }
        bytesDone = 0
        cancellation = StorageCancellationFlag()
        let engine = services.cleanupEngine
        let options = services.cleanupOptions(title: "Move to “\((destination as NSString).lastPathComponent)”", regenerableData: false)
        let logger = services.logger

        task = Task {
            var results: [StorageRelocator.Outcome] = []
            for check in planned {
                if cancellation.isCancelled { break }
                currentItemName = check.item.name
                let outcome: StorageRelocator.Outcome
                switch check.mode {
                case .move:
                    outcome = await moveItem(check.item, to: destination)
                case .copyThenTrash:
                    outcome = await copyItem(check.item, to: destination, engine: engine, options: options)
                case nil:
                    continue
                }
                results.append(outcome)
                outcomes = results
            }
            let succeeded = results.filter(\.succeeded)
            logger.info("Relocated \(succeeded.count) of \(planned.count) items (\(ByteFormatting.string(succeeded.reduce(0) { $0 + $1.item.estimatedBytes })))", category: .storage)
            phase = .finished
            currentItemName = ""
            activeCopy = nil
            onFinish?(results)
        }
    }

    func cancel() {
        cancellation.cancel()
        activeCopy?.cancel()
    }

    func dismiss() {
        guard phase != .running else { return }
        request = nil
        task = nil
    }

    private func moveItem(_ item: StorageRelocator.Item, to destination: String) async -> StorageRelocator.Outcome {
        do {
            let target = try await BackgroundWork.run { try StorageRelocator.moveOnSameVolume(item, to: destination) }
            return .init(item: item, result: .moved(to: target))
        } catch {
            return .init(item: item, result: .failed(error.localizedDescription))
        }
    }

    private func copyItem(_ item: StorageRelocator.Item, to destination: String, engine: CleanupEngine, options: CleanupOptions) async -> StorageRelocator.Outcome {
        let flag = cancellation
        let baseline = bytesDone
        do {
            let source = try await BackgroundWork.run { try StorageRelocator.inventory(of: item.path, cancellation: flag) }
            if source.datalessFiles > 0 { throw StorageRelocator.RelocationError.cloudOnlyContent(source.datalessFiles) }
            if let available = VolumeService.volume(containing: destination)?.availableCapacity,
               available < source.dataBytes + 50_000_000 {
                throw StorageRelocator.RelocationError.notEnoughSpace(needed: source.dataBytes, available: available)
            }
            guard FileSnapshot.capture(path: item.path) == item.snapshot else { throw StorageRelocator.RelocationError.changed }

            let temporary = PathUtilities.join(destination, ".\(item.name).maccleaner-partial-\(UUID().uuidString.prefix(8))")
            var existing = stat()
            guard lstat(temporary, &existing) != 0 else { throw StorageRelocator.RelocationError.posix(EEXIST) }
            let progress = StorageCopyProgress()
            activeCopy = progress
            let poller = Task { [weak self] in
                while !Task.isCancelled {
                    self?.bytesDone = baseline + progress.bytesCopied
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            defer { poller.cancel() }

            do {
                try await BackgroundWork.run { try StorageRelocator.copy(item.path, to: temporary, progress: progress) }
                let copied = try await BackgroundWork.run { try StorageRelocator.inventory(of: temporary, cancellation: flag) }
                guard copied.regularFiles == source.regularFiles, copied.directories == source.directories,
                      copied.symbolicLinks == source.symbolicLinks, copied.dataBytes == source.dataBytes else {
                    throw StorageRelocator.RelocationError.verificationFailed
                }
                let target = PathUtilities.join(destination, item.name)
                let renamed = await BackgroundWork.run { renamex_np(temporary, target, UInt32(RENAME_EXCL)) == 0 ? 0 : errno }
                guard renamed == 0 else { throw StorageRelocator.RelocationError.posix(renamed) }
                bytesDone = baseline + item.estimatedBytes

                let cleanupItem = CleanupItem(path: item.path, purpose: .userFile, snapshot: item.snapshot, estimatedBytes: item.estimatedBytes, category: "Moved to another drive")
                let report = await engine.clean([cleanupItem], options: options)
                if let removed = report.removed.first {
                    return .init(item: item, result: .copied(to: target, trashedOriginal: removed.trashedPath))
                }
                let reason = report.skipped.first?.reason ?? report.failed.first?.message ?? "The original couldn't be moved to the Trash."
                return .init(item: item, result: .copiedOriginalKept(to: target, reason: reason))
            } catch {
                // Only a temporary copy this operation created is cleaned up; `destinationExists`
                // means copying never started, so whatever is at that path isn't ours.
                if case StorageRelocator.RelocationError.destinationExists = error {} else {
                    await removeIncompleteCopy(at: temporary, engine: engine)
                }
                throw error
            }
        } catch is CancellationError {
            return .init(item: item, result: .failed("Cancelled. The original wasn't changed."))
        } catch {
            return .init(item: item, result: .failed(error.localizedDescription))
        }
    }

    /// Removes a partial copy Mac Cleaner created itself (never the original), through the cleanup engine.
    private func removeIncompleteCopy(at path: String, engine: CleanupEngine) async {
        guard let snapshot = FileSnapshot.capture(path: path) else { return }
        var options = CleanupOptions(title: "Remove incomplete copy", method: .deletePermanently)
        options.recordHistory = false
        options.skipItemsInUse = false
        let item = CleanupItem(path: path, purpose: .userFile, snapshot: snapshot, estimatedBytes: 0, category: "Incomplete copy")
        _ = await engine.clean([item], options: options)
    }
}

// MARK: - Sheet

struct StorageRelocationSheet: View {
    @Bindable var controller: StorageRelocationController
    let services: AppServices
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "folder.badge.arrow.forward")
                    .font(.system(size: 26))
                    .foregroundStyle(AppSection.storage.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Move to Another Location").font(.title3.weight(.semibold))
                    Text("\(NumberFormatting.count(controller.checks.count)) item\(controller.checks.count == 1 ? "" : "s") · \(ByteFormatting.string(controller.checks.reduce(0) { $0 + $1.item.estimatedBytes }))")
                        .foregroundStyle(.secondary)
                }
            }

            switch controller.phase {
            case .review: reviewContent
            case .running: runningContent
            case .finished: finishedContent
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled(controller.phase == .running)
    }

    @ViewBuilder
    private var reviewContent: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            if let destination = controller.destination {
                PathText(path: destination, font: .callout)
            } else {
                Text("No destination chosen").foregroundStyle(.secondary)
            }
            Spacer()
            Button(controller.destination == nil ? "Choose Destination…" : "Change…") {
                controller.chooseDestination(policy: services.policy)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

        if let note = controller.note {
            InfoCallout(style: .warning, message: note)
        }
        if let problem = controller.destinationProblem {
            InfoCallout(style: .warning, message: problem)
        } else if controller.destination != nil {
            if controller.needsCopy {
                InfoCallout(style: .info, title: "Copy, check, then move to the Trash",
                            message: "The destination is on another volume. Items are copied, the copy is checked against the original, and only then are the originals moved to the Trash. Space is freed when you empty the Trash.")
                if let free = controller.destinationFreeSpace {
                    Text("\(ByteFormatting.string(free)) available on the destination.")
                        .font(.caption)
                        .foregroundStyle(free < controller.plannedBytes ? .red : .secondary)
                }
            } else if !controller.validChecks.isEmpty {
                InfoCallout(style: .info, message: "The destination is on the same volume, so items are moved instantly. This doesn't free space on the volume.")
            }
        }

        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(controller.checks) { check in
                    HStack(spacing: 8) {
                        FileIcon(path: check.item.path, size: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(check.item.name).lineLimit(1)
                            if let problem = check.problem {
                                Text(problem).font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        SizeText(bytes: check.item.estimatedBytes, font: .callout).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
        }
        .frame(maxHeight: 200)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

        HStack {
            Spacer()
            Button("Cancel", role: .cancel) {
                controller.dismiss()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button(controller.needsCopy ? "Copy and Move" : "Move") {
                controller.start(services: services)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(controller.destination == nil || controller.destinationProblem != nil || controller.validChecks.isEmpty)
        }
    }

    @ViewBuilder
    private var runningContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.bytesTotal > 0 {
                ProgressView(value: Double(min(controller.bytesDone, controller.bytesTotal)), total: Double(max(controller.bytesTotal, 1)))
                Text("\(ByteFormatting.string(controller.bytesDone)) of \(ByteFormatting.string(controller.bytesTotal)) copied")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(controller.currentItemName.isEmpty ? "Preparing…" : "Moving “\(controller.currentItemName)”…")
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        HStack {
            Spacer()
            Button("Stop", role: .cancel) { controller.cancel() }
                .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private var finishedContent: some View {
        let succeeded = controller.outcomes.filter(\.succeeded)
        InfoCallout(
            style: succeeded.count == controller.outcomes.count && !succeeded.isEmpty ? .success : .warning,
            message: summary
        )
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(controller.outcomes) { outcome in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(outcome.succeeded ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(outcome.item.name).lineLimit(1)
                            Text(detail(for: outcome)).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if let path = newPath(for: outcome) {
                            Button("Show") { FinderActions.reveal(path) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .padding(10)
        }
        .frame(maxHeight: 220)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        HStack {
            Spacer()
            Button("Done") {
                controller.dismiss()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
    }

    private var summary: String {
        let succeeded = controller.outcomes.filter(\.succeeded)
        let bytes = succeeded.reduce(0) { $0 + $1.item.estimatedBytes }
        var text = "Moved \(succeeded.count) of \(controller.outcomes.count) item\(controller.outcomes.count == 1 ? "" : "s") (\(ByteFormatting.string(bytes)))."
        if succeeded.contains(where: { if case .copied = $0.result { return true } else { return false } }) {
            text += " Originals copied to another drive are in the Trash; empty it to free their space."
        }
        return text
    }

    private func detail(for outcome: StorageRelocator.Outcome) -> String {
        switch outcome.result {
        case .moved(let path): return "Moved to \(PathUtilities.abbreviate(path))."
        case .copied(let path, _): return "Copied to \(PathUtilities.abbreviate(path)) and checked. The original is in the Trash."
        case .copiedOriginalKept(let path, let reason): return "Copied to \(PathUtilities.abbreviate(path)), but the original was kept: \(reason)"
        case .failed(let reason): return reason
        }
    }

    private func newPath(for outcome: StorageRelocator.Outcome) -> String? {
        switch outcome.result {
        case .moved(let path), .copied(let path, _), .copiedOriginalKept(let path, _): return path
        case .failed: return nil
        }
    }
}
