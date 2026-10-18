import Observation
import SwiftUI

/// A confirmation shown at the top of the Contacts page after a change.
struct ContactNotice: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}

/// Duplicate and incomplete contacts: access, scanning, merging, deleting, and the backups saved before every change.
@MainActor
@Observable
final class ContactCleanupModel {
    enum Phase: Equatable {
        case idle
        case scanning(read: Int)
        case scanned
    }

    private(set) var access: ContactAccess
    private(set) var phase: Phase = .idle
    /// Every contact from the last scan.
    private(set) var contacts: [ContactSnapshot] = []
    private(set) var duplicateGroups: [ContactDuplicateGroup] = []
    private(set) var incompleteContacts: [IncompleteContact] = []
    /// Newest first.
    private(set) var backups: [ContactBackup] = []
    private(set) var lastScanDate: Date?
    /// A merge, delete or restore is being saved.
    private(set) var isSaving = false
    var notice: ContactNotice?
    var errorMessage: String?
    /// "iPhone" or "iPad", for sentences.
    let deviceWord: String

    private let service: ContactStoreService

    init() {
        service = ContactStoreService(backups: .standard)
        access = ContactStoreService.currentAccess()
        deviceWord = DeviceInfo.current().deviceWord
    }

    // MARK: Summary

    /// Contacts to review after the last scan (the extra cards in duplicate groups and the incomplete contacts),
    /// or nil before the first scan.
    var issueCount: Int? {
        guard lastScanDate != nil else { return nil }
        var ids = Set(incompleteContacts.map(\.id))
        for group in duplicateGroups {
            ids.formUnion(group.contacts.dropFirst().map(\.id))
        }
        return ids.count
    }

    /// "12 duplicates and 5 incomplete contacts", or nil before the first scan.
    var summary: String? {
        guard lastScanDate != nil else { return nil }
        let duplicates = NumberFormatting.count(duplicateCount, "duplicate")
        let incomplete = NumberFormatting.count(incompleteContacts.count, "incomplete contact")
        switch (duplicateCount, incompleteContacts.count) {
        case (0, 0): return "No duplicate or incomplete contacts"
        case (_, 0): return duplicates
        case (0, _): return incomplete
        default: return "\(duplicates) and \(incomplete)"
        }
    }

    /// The cards merging every group would remove.
    var duplicateCount: Int { duplicateGroups.reduce(0) { $0 + $1.duplicateCount } }

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    func incomplete(_ issue: ContactIssue) -> [IncompleteContact] {
        incompleteContacts.filter { $0.issue == issue }
    }

    // MARK: Access

    /// Reads the authorization again, for example after the person comes back from Settings.
    func refreshAccess() {
        let previous = access
        access = ContactStoreService.currentAccess()
        guard access != previous else { return }
        if !access.canRead {
            clearResults()
        } else if lastScanDate != nil {
            // From limited to full access, for example: the old results miss contacts.
            Task { await scan() }
        }
    }

    func requestAccess() async {
        _ = try? await service.requestAccess()
        access = ContactStoreService.currentAccess()
        if access.canRead { await scan() }
    }

    // MARK: Scan

    func scan() async {
        guard access.canRead, !isScanning else { return }
        notice = nil
        phase = .scanning(read: 0)
        #if DEBUG
        await ContactSampleData.seedIfRequested()
        #endif
        let (updates, continuation) = AsyncStream.makeStream(of: Int.self, bufferingPolicy: .bufferingNewest(1))
        let progress = Task {
            for await count in updates where isScanning {
                phase = .scanning(read: count)
            }
        }
        do {
            let snapshots = try await service.fetchAll { continuation.yield($0) }
            continuation.finish()
            await progress.value
            apply(scan: snapshots, at: Date())
        } catch {
            continuation.finish()
            phase = lastScanDate == nil ? .idle : .scanned
            // A cancelled pull to refresh keeps the previous results without a message.
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    // MARK: Changes

    /// Saves a merge the person confirmed. `previewed` are the cards the plan was made from. Returns whether it was saved.
    func merge(_ plan: ContactMergePlan, previewed: [ContactSnapshot]) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            let outcome = try await service.merge(plan, previewed: previewed)
            let removed = Set(plan.removedIDs)
            var remaining = contacts.filter { !removed.contains($0.id) }
            if let index = remaining.firstIndex(where: { $0.id == plan.primaryID }) {
                remaining[index] = outcome.merged
            }
            show(remaining)
            await loadBackups()
            notice = ContactNotice(title: "Merged \(NumberFormatting.count(plan.contactCount, "contact")) into \(outcome.merged.displayName)",
                                   message: "A backup was saved first. You'll find it under Backups.")
            return true
        } catch {
            await handle(error)
            return false
        }
    }

    /// Deletes contacts the person confirmed, after saving a backup. Returns whether they were deleted.
    func delete(_ snapshots: [ContactSnapshot]) async -> Bool {
        guard !isSaving, !snapshots.isEmpty else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await service.delete(snapshots)
            let removed = Set(snapshots.map(\.id))
            show(contacts.filter { !removed.contains($0.id) })
            await loadBackups()
            notice = ContactNotice(title: "Deleted \(NumberFormatting.count(snapshots.count, "contact"))",
                                   message: "A backup was saved first, so you can restore \(snapshots.count == 1 ? "it" : "them") under Backups.")
            return true
        } catch {
            await handle(error)
            return false
        }
    }

    /// Adds a backup's contacts as new contacts. Returns whether they were added.
    func restore(_ backup: ContactBackup) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        do {
            let count = try await service.restore(backup)
            isSaving = false
            if lastScanDate != nil { await scan() }
            notice = ContactNotice(title: "Restored \(NumberFormatting.count(count, "contact"))",
                                   message: count == 1 ? "It was added as a new contact." : "They were added as new contacts.")
            return true
        } catch {
            isSaving = false
            await handle(error)
            return false
        }
    }

    func loadBackups() async {
        backups = await service.loadBackups()
    }

    /// Shows a finished scan's contacts.
    func apply(scan snapshots: [ContactSnapshot], at date: Date) {
        show(snapshots)
        lastScanDate = date
        phase = .scanned
    }

    // MARK: Helpers

    private func show(_ snapshots: [ContactSnapshot]) {
        contacts = snapshots
        duplicateGroups = ContactDuplicateFinder.groups(in: snapshots)
        incompleteContacts = ContactDuplicateFinder.incomplete(in: snapshots)
    }

    private func clearResults() {
        show([])
        lastScanDate = nil
        phase = .idle
    }

    private func handle(_ error: any Error) async {
        errorMessage = error.localizedDescription
        switch ContactCleanupError(error) {
        case .changedSinceScan:
            await scan()
        case .accessDenied:
            refreshAccess()
        default:
            break
        }
    }
}
