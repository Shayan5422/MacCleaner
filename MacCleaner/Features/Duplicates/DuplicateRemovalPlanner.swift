import Darwin
import Foundation

/// Items ready for `CleanupFlow`, plus what was left out and why.
struct DuplicateRemovalPlan: Sendable {
    var items: [CleanupItem] = []
    /// Marked files that changed or disappeared since the scan.
    var changedFiles = 0
    /// Groups left untouched because none of their kept copies is still in place.
    var groupsWithoutKeptCopy = 0

    var hasExclusions: Bool { changedFiles > 0 || groupsWithoutKeptCopy > 0 }

    /// Explanation for the confirmation sheet, or nil when nothing was left out.
    var exclusionSummary: String? {
        var parts: [String] = []
        if changedFiles > 0 {
            parts.append("\(NumberFormatting.count(changedFiles)) file\(changedFiles == 1 ? "" : "s") changed since the scan and will be left alone.")
        }
        if groupsWithoutKeptCopy > 0 {
            parts.append("\(NumberFormatting.count(groupsWithoutKeptCopy)) group\(groupsWithoutKeptCopy == 1 ? "" : "s") were skipped because the copy you're keeping was moved, changed or deleted.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ") + " Scan again to review them."
    }
}

/// Verifies a selection right before anything is moved to the Trash.
///
/// Defense in depth on top of the selection invariant:
/// * every group must still have at least one unmarked copy, and at least one of
///   those kept copies must still exist unchanged (same file, same modification
///   time), otherwise nothing in that group is removed;
/// * every marked copy must still be the file that was compared (same device,
///   inode and modification time), otherwise it is left alone;
/// * protected copies are never included.
///
/// `CleanupEngine` then re-checks identity and the `SafetyPolicy` once more
/// immediately before moving each item to the Trash.
enum DuplicateRemovalPlanner {
    static func plan(groups: [[DuplicateFile]], marked: Set<String>, category: String) -> DuplicateRemovalPlan {
        var plan = DuplicateRemovalPlan()
        var verified: [DuplicateFile] = []
        var seen = Set<String>()
        for members in groups {
            let markedMembers = members.filter { marked.contains($0.id) && $0.protectionReason == nil }
            guard !markedMembers.isEmpty else { continue }
            let keptMembers = members.filter { !marked.contains($0.id) }
            guard !keptMembers.isEmpty, keptMembers.contains(where: isUnchanged) else {
                plan.groupsWithoutKeptCopy += 1
                continue
            }
            for file in markedMembers where seen.insert(file.id).inserted {
                if isUnchanged(file) {
                    verified.append(file)
                } else {
                    plan.changedFiles += 1
                }
            }
        }
        let estimates = DuplicateSpaceEstimator.perFileEstimates(verified)
        plan.items = verified.map { file in
            CleanupItem(path: file.path, purpose: .userFile, snapshot: file.snapshot, estimatedBytes: estimates[file.id] ?? 0, category: category)
        }
        return plan
    }

    /// `true` when `file` is still the regular file seen during the scan, unmodified.
    static func isUnchanged(_ file: DuplicateFile) -> Bool {
        var info = stat()
        guard lstat(file.path, &info) == 0,
              FileObjectType(mode: info.st_mode) == .regular,
              info.st_dev == file.identity.device,
              UInt64(info.st_ino) == file.identity.inode else { return false }
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return abs(modified - file.modificationDate.timeIntervalSince1970) < 0.000_01
    }
}
