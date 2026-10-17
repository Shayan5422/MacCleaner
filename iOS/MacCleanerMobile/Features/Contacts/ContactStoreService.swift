import Contacts
import Foundation

/// Whether the app may read contacts.
enum ContactAccess: Sendable, Equatable {
    case notDetermined
    case full
    /// iOS 18 and later: only the contacts the person chose to share.
    case limited
    case denied
    /// Screen Time or a device profile doesn't allow it; the person can't change it here.
    case restricted

    var canRead: Bool { self == .full || self == .limited }
}

/// Why reading or changing contacts failed, in words for the person.
enum ContactCleanupError: LocalizedError, Equatable {
    /// A contact was edited, merged or deleted elsewhere after the scan.
    case changedSinceScan
    case accessDenied
    /// The account the contact is in (for example Exchange or a company directory) doesn't allow changes.
    case readOnlyAccount
    case backupFailed(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .changedSinceScan:
            return "Some of these contacts changed since the scan, so nothing was changed. Check the new results and try again."
        case .accessDenied:
            return "Mac Cleaner can't use your contacts anymore. Allow access in Settings and try again."
        case .readOnlyAccount:
            return "One of these contacts is in an account that doesn't allow changes, so nothing was changed."
        case .backupFailed(let reason):
            return "The backup couldn't be saved, so nothing was changed. \(reason)"
        case .failed(let reason):
            return reason
        }
    }

    init(_ error: any Error) {
        if let error = error as? ContactCleanupError {
            self = error
            return
        }
        switch (error as? CNError)?.code {
        case .authorizationDenied?: self = .accessDenied
        case .recordDoesNotExist?: self = .changedSinceScan
        case .policyViolation?: self = .readOnlyAccount
        default: self = .failed(error.localizedDescription)
        }
    }
}

/// A merge that was saved.
struct ContactMergeOutcome: Sendable {
    var backup: ContactBackup
    /// The kept card as saved.
    var merged: ContactSnapshot
}

/// Reads and changes the contact store, always off the main actor. Every change re-reads the contacts first,
/// refuses if they changed since the person saw them, and saves a backup before anything is written.
struct ContactStoreService: Sendable {
    var backups: ContactBackupStore

    static func currentAccess() -> ContactAccess {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .full
        default:
            if #available(iOS 18, *), status == .limited { return .limited }
            return .denied
        }
    }

    /// Shows the system prompt. Returns whether the app may read contacts now.
    func requestAccess() async throws -> Bool {
        try await CNContactStore().requestAccess(for: .contacts)
    }

    /// Every contact the app may see, in the store's own order. `progress` gets the number read so far.
    @concurrent
    func fetchAll(progress: @escaping @Sendable (Int) -> Void) async throws -> [ContactSnapshot] {
        let store = CNContactStore()
        let request = CNContactFetchRequest(keysToFetch: ContactSnapshot.keysToFetch)
        request.sortOrder = .none
        var snapshots: [ContactSnapshot] = []
        do {
            try store.enumerateContacts(with: request) { contact, stop in
                snapshots.append(ContactSnapshot(contact, order: snapshots.count))
                if snapshots.count.isMultiple(of: 200) {
                    progress(snapshots.count)
                    if Task.isCancelled { stop.pointee = true }
                }
            }
        } catch {
            throw ContactCleanupError(error)
        }
        try Task.checkCancellation()
        return snapshots
    }

    /// Saves the plan: a backup of every card in it, then one save request that updates the kept card and deletes the others.
    /// `previewed` are the snapshots the plan was made from; if the store's contacts no longer give the same plan, nothing changes.
    @concurrent
    func merge(_ plan: ContactMergePlan, previewed: [ContactSnapshot]) async throws -> ContactMergeOutcome {
        do {
            let store = CNContactStore()
            let ids = plan.allIDs
            let found = try contacts(withIdentifiers: ids, keys: ContactSnapshot.keysToFetch + ContactBackupStore.keysToFetch, in: store)
            let orders = Dictionary(previewed.map { ($0.id, $0.order) }, uniquingKeysWith: { first, _ in first })
            let current = ids.compactMap { id in found[id].map { ContactSnapshot($0, order: orders[id] ?? .max) } }
            guard current.count == ids.count, ContactMergePlanner.plan(merging: current) == plan,
                  let primary = found[plan.primaryID]?.mutableCopy() as? CNMutableContact else {
                throw ContactCleanupError.changedSinceScan
            }

            let backup = try saveBackup(of: ids.compactMap { found[$0] }, kind: .merge)
            ContactMergePlanner.apply(plan, to: primary, photo: plan.photoSourceID.flatMap { found[$0]?.imageData })
            let request = CNSaveRequest()
            if plan.changesPrimary { request.update(primary) }
            for id in plan.removedIDs {
                if let duplicate = found[id]?.mutableCopy() as? CNMutableContact { request.delete(duplicate) }
            }
            try store.execute(request)

            let saved = try? contacts(withIdentifiers: [plan.primaryID], keys: ContactSnapshot.keysToFetch, in: store)[plan.primaryID]
            let merged = saved.map { ContactSnapshot($0, order: plan.merged.order) } ?? plan.merged
            return ContactMergeOutcome(backup: backup, merged: merged)
        } catch {
            throw ContactCleanupError(error)
        }
    }

    /// Deletes the contacts after saving a backup of them. If any of them changed since the scan, nothing is deleted.
    @concurrent
    func delete(_ snapshots: [ContactSnapshot]) async throws -> ContactBackup {
        do {
            let store = CNContactStore()
            let found = try contacts(withIdentifiers: snapshots.map(\.id), keys: ContactSnapshot.keysToFetch + ContactBackupStore.keysToFetch, in: store)
            let originals = try snapshots.map { snapshot in
                guard let contact = found[snapshot.id], ContactSnapshot(contact, order: snapshot.order) == snapshot else {
                    throw ContactCleanupError.changedSinceScan
                }
                return contact
            }
            let backup = try saveBackup(of: originals, kind: .delete)
            let request = CNSaveRequest()
            for contact in originals {
                if let mutable = contact.mutableCopy() as? CNMutableContact { request.delete(mutable) }
            }
            try store.execute(request)
            return backup
        } catch {
            throw ContactCleanupError(error)
        }
    }

    /// Adds the backup's contacts to the default account as new contacts; existing contacts aren't touched.
    /// Returns how many were added.
    @concurrent
    func restore(_ backup: ContactBackup) async throws -> Int {
        do {
            let contacts = try backups.contacts(in: backup)
            guard !contacts.isEmpty else { return 0 }
            let request = CNSaveRequest()
            for contact in contacts {
                if let mutable = contact.mutableCopy() as? CNMutableContact { request.add(mutable, toContainerWithIdentifier: nil) }
            }
            try CNContactStore().execute(request)
            return contacts.count
        } catch {
            throw ContactCleanupError(error)
        }
    }

    @concurrent
    func loadBackups() async -> [ContactBackup] {
        backups.backups()
    }

    // MARK: Helpers

    private func contacts(withIdentifiers ids: [String], keys: [CNKeyDescriptor], in store: CNContactStore) throws -> [String: CNContact] {
        let found = try store.unifiedContacts(matching: CNContact.predicateForContacts(withIdentifiers: ids), keysToFetch: keys)
        return Dictionary(found.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func saveBackup(of contacts: [CNContact], kind: ContactBackupKind) throws -> ContactBackup {
        do {
            return try backups.save(contacts, kind: kind)
        } catch {
            throw ContactCleanupError.backupFailed(error.localizedDescription)
        }
    }
}
