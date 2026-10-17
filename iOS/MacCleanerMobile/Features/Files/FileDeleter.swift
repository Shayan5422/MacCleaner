import Foundation

/// Moves files to Recently Deleted, or deletes them permanently when the person asks, and reports what failed.
struct FileDeleter: Sendable {
    struct Failure: Sendable, Hashable {
        var url: URL
        var reason: String
        /// The location has no Recently Deleted (for example a folder inside an app), so only permanent deletion is possible.
        var trashUnsupported: Bool
    }

    struct Outcome: Sendable {
        var deleted: [URL] = []
        var failures: [Failure] = []
    }

    /// Moves an item to the trash of its location: Recently Deleted in Files for On My iPhone and iCloud Drive.
    var moveToTrash: @Sendable (URL) throws -> Void
    var removePermanently: @Sendable (URL) throws -> Void

    static let standard = FileDeleter(
        moveToTrash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        removePermanently: { try FileManager.default.removeItem(at: $0) }
    )

    @concurrent
    func trash(_ urls: [URL]) async -> Outcome {
        perform(moveToTrash, on: urls)
    }

    @concurrent
    func deletePermanently(_ urls: [URL]) async -> Outcome {
        perform(removePermanently, on: urls)
    }

    private func perform(_ operation: (URL) throws -> Void, on urls: [URL]) -> Outcome {
        var outcome = Outcome()
        for url in urls {
            do {
                try operation(url)
                outcome.deleted.append(url)
            } catch {
                outcome.failures.append(Failure(url: url, reason: Self.reason(for: error), trashUnsupported: Self.isTrashUnsupported(error)))
            }
        }
        return outcome
    }

    static func isTrashUnsupported(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSFeatureUnsupportedError
    }

    static func reason(for error: any Error) -> String {
        if isTrashUnsupported(error) { return "This location doesn't have Recently Deleted." }
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return "It isn't there anymore."
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return "Mac Cleaner isn't allowed to change it."
            default: break
            }
        }
        return error.localizedDescription
    }
}
