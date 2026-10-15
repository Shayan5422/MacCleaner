import Foundation

/// Combines Smart Scan contributions into one result without double counting.
///
/// The same file can be reported by several areas (a cache folder is both
/// "junk" and a "developer cache"; an old download is both "junk" and a
/// "large file"). Each path is kept once — by the area that explains it best —
/// and items nested inside other items are excluded from totals.
struct SmartScanMerger {
    /// Earlier areas win when the same item appears in several areas.
    static let priority: [SmartScanArea] = [.junk, .developer, .privacy, .leftovers, .duplicates, .largeFiles, .startup, .security]

    struct Merged: Sendable {
        var candidates: [CleanupCandidate]
        var findings: [Finding]
        /// Candidate paths dropped because another area already reported them.
        var duplicatesRemoved: Int
    }

    static func merge(_ contributions: [SmartScanContribution]) -> Merged {
        let ordered = contributions.sorted { lhs, rhs in
            (priority.firstIndex(of: lhs.area) ?? priority.count) < (priority.firstIndex(of: rhs.area) ?? priority.count)
        }
        var seenPaths = Set<String>()
        var seenIdentities = Set<FileIdentity>()
        var candidates: [CleanupCandidate] = []
        var findings: [Finding] = []
        var seenFindings = Set<String>()
        var removed = 0
        for contribution in ordered {
            for candidate in contribution.candidates {
                let path = PathUtilities.normalize(candidate.path)
                if seenPaths.contains(path) {
                    removed += 1
                    continue
                }
                if let identity = candidate.snapshot?.identity, candidate.snapshot?.type == .regular, seenIdentities.contains(identity) {
                    removed += 1
                    continue
                }
                seenPaths.insert(path)
                if let identity = candidate.snapshot?.identity, candidate.snapshot?.type == .regular { seenIdentities.insert(identity) }
                candidates.append(candidate)
            }
            for finding in contribution.findings where seenFindings.insert(finding.id).inserted {
                findings.append(finding)
            }
        }
        return Merged(candidates: candidates, findings: findings.sorted { $0.severity > $1.severity }, duplicatesRemoved: removed)
    }

    /// Total reclaimable bytes of `candidates`, ignoring items nested inside other listed items.
    static func reclaimableBytes(_ candidates: [CleanupCandidate]) -> Int64 {
        let topLevel = Set(PathUtilities.removingNestedPaths(candidates.map(\.path)))
        var counted = Set<String>()
        return candidates.reduce(0) { total, candidate in
            guard topLevel.contains(candidate.path), counted.insert(candidate.path).inserted else { return total }
            return total + candidate.usage.reclaimableBytes
        }
    }
}

/// Runs all Smart Scan providers with bounded parallelism and reports per-area progress.
struct SmartScanRunner: Sendable {
    let providers: [any SmartScanProvider]
    var maxConcurrent = 3

    enum Event: Sendable {
        case started(SmartScanArea)
        case progress(SmartScanArea, Double, String)
        case finished(SmartScanArea, SmartScanContribution, TimeInterval)
        case failed(SmartScanArea, String)
    }

    func run(preferences: ScanPreferences, events: @escaping @Sendable (Event) -> Void) async -> [SmartScanContribution] {
        var contributions: [SmartScanContribution] = []
        await withTaskGroup(of: SmartScanContribution?.self) { group in
            var iterator = providers.makeIterator()
            func addNext() {
                guard let provider = iterator.next() else { return }
                group.addTask {
                    let area = provider.area
                    events(.started(area))
                    let started = Date()
                    let context = SmartScanContext(preferences: preferences) { fraction, message in
                        events(.progress(area, fraction, message))
                    }
                    do {
                        let contribution = try await provider.smartScan(context: context)
                        events(.finished(area, contribution, Date().timeIntervalSince(started)))
                        return contribution
                    } catch is CancellationError {
                        return nil
                    } catch {
                        events(.failed(area, error.localizedDescription))
                        return nil
                    }
                }
            }
            for _ in 0..<max(1, maxConcurrent) { addNext() }
            while let result = await group.next() {
                if let result { contributions.append(result) }
                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                addNext()
            }
        }
        return contributions
    }
}
