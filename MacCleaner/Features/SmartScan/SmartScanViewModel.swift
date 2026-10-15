import Foundation
import Observation

@MainActor
@Observable
final class SmartScanViewModel {
    enum Phase: Equatable {
        case idle, scanning, results
    }

    enum AreaStatus: Equatable {
        case waiting, running, done, failed(String), unavailable
    }

    struct AreaState: Identifiable {
        var area: SmartScanArea
        var status: AreaStatus = .waiting
        var progress: Double = 0
        var message = ""
        var summary: String?
        var duration: TimeInterval?
        var id: SmartScanArea { area }
    }

    let services: AppServices
    let selection = CandidateSelection()
    let cleanupFlow = CleanupFlow()
    /// Set by the app shell so findings can link to other sections.
    var navigate: ((AppSection) -> Void)?

    private let providers: [any SmartScanProvider]
    private(set) var phase: Phase = .idle
    private(set) var areas: [AreaState]
    private(set) var candidates: [CleanupCandidate] = []
    private(set) var findings: [Finding] = []
    private(set) var duplicatesMerged = 0
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    var focusedArea: SmartScanArea?
    var searchText = ""
    private var scanTask: Task<Void, Never>?

    init(services: AppServices, providers: [any SmartScanProvider]) {
        self.services = services
        self.providers = providers
        let available = Set(providers.map(\.area))
        areas = SmartScanArea.allCases.map { AreaState(area: $0, status: available.contains($0) ? .waiting : .unavailable) }
    }

    // MARK: - Derived values

    var overallProgress: Double {
        let active = areas.filter { $0.status != .unavailable }
        guard !active.isEmpty else { return 0 }
        return active.reduce(0) { total, state in
            switch state.status {
            case .done, .failed: return total + 1
            case .running: return total + state.progress
            default: return total
            }
        } / Double(active.count)
    }

    var totalReclaimable: Int64 { SmartScanMerger.reclaimableBytes(candidates) }
    var safeReclaimable: Int64 { SmartScanMerger.reclaimableBytes(candidates.filter { $0.safety == .safe }) }
    var reviewCandidates: [CleanupCandidate] { candidates.filter { $0.safety != .safe } }
    var reviewReclaimable: Int64 { SmartScanMerger.reclaimableBytes(reviewCandidates) }
    var selectedBytes: Int64 { selection.selectedBytes(in: candidates) }
    var selectedCount: Int { selection.selected(in: candidates).count }

    func count(_ severity: FindingSeverity) -> Int {
        findings.filter { $0.severity == severity }.count
    }

    func candidates(in area: SmartScanArea) -> [CleanupCandidate] {
        let categoryAreas = areaByCategory
        return candidates.filter { categoryAreas[$0.categoryID] == area }
    }

    func findings(in area: SmartScanArea) -> [Finding] {
        findings.filter { $0.area == area }
    }

    func bytes(in area: SmartScanArea) -> Int64 {
        SmartScanMerger.reclaimableBytes(candidates(in: area))
    }

    /// Groups an area's candidates by category for the detail list.
    func groups(in area: SmartScanArea) -> [CandidateGroup] {
        Dictionary(grouping: candidates(in: area), by: \.categoryID).map { categoryID, items in
            let junk = JunkCategory.category(id: categoryID)
            return CandidateGroup(
                id: categoryID,
                title: junk?.title ?? items.first?.categoryTitle ?? area.title,
                symbol: junk?.symbol ?? area.symbolName,
                explanation: junk?.explanation ?? (areas.first { $0.area == area }?.summary ?? area.title),
                consequence: junk?.consequence ?? area.defaultConsequence,
                candidates: items
            )
        }
        .sorted { $0.totalBytes > $1.totalBytes }
    }

    private var areaByCategory: [String: SmartScanArea] = [:]

    // MARK: - Actions

    func start() {
        scanTask?.cancel()
        phase = .scanning
        startedAt = Date()
        finishedAt = nil
        candidates = []
        findings = []
        areaByCategory = [:]
        focusedArea = nil
        for index in areas.indices where areas[index].status != .unavailable {
            areas[index].status = .waiting
            areas[index].progress = 0
            areas[index].message = ""
            areas[index].summary = nil
            areas[index].duration = nil
        }
        let preferences = services.settings.scanPreferences
        let runner = SmartScanRunner(providers: providers)

        scanTask = Task {
            let contributions = await runner.run(preferences: preferences) { event in
                Task { @MainActor in self.apply(event) }
            }
            guard !Task.isCancelled else {
                phase = candidates.isEmpty && findings.isEmpty ? .idle : .results
                return
            }
            var mapping: [String: SmartScanArea] = [:]
            for contribution in contributions {
                for candidate in contribution.candidates where mapping[candidate.categoryID] == nil {
                    mapping[candidate.categoryID] = contribution.area
                }
            }
            let merged = SmartScanMerger.merge(contributions)
            areaByCategory = mapping
            candidates = merged.candidates
            findings = merged.findings
            duplicatesMerged = merged.duplicatesRemoved
            selection.reset(to: merged.candidates)
            finishedAt = Date()
            phase = .results
            services.settings.lastSmartScanDate = finishedAt
            services.settings.lastSmartScanReclaimable = totalReclaimable
            let seconds = String(format: "%.0f", finishedAt!.timeIntervalSince(startedAt ?? finishedAt!))
            services.logger.info(
                "Smart Scan: \(merged.candidates.count) items (\(ByteFormatting.string(totalReclaimable))), \(merged.findings.count) findings, \(merged.duplicatesRemoved) overlaps merged, \(seconds)s",
                category: .scan
            )
        }
    }

    func cancel() {
        scanTask?.cancel()
        for index in areas.indices where areas[index].status == .running || areas[index].status == .waiting {
            areas[index].status = .failed("Cancelled")
        }
    }

    private func apply(_ event: SmartScanRunner.Event) {
        guard phase == .scanning else { return }
        func update(_ area: SmartScanArea, _ change: (inout AreaState) -> Void) {
            if let index = areas.firstIndex(where: { $0.area == area }) { change(&areas[index]) }
        }
        switch event {
        case .started(let area):
            update(area) { $0.status = .running }
        case .progress(let area, let fraction, let message):
            update(area) {
                $0.progress = max($0.progress, min(1, fraction))
                $0.message = message
            }
        case .finished(let area, let contribution, let duration):
            update(area) {
                $0.status = .done
                $0.progress = 1
                $0.summary = contribution.summary
                $0.duration = duration
            }
        case .failed(let area, let message):
            update(area) { $0.status = .failed(message) }
        }
    }

    func cleanSelected() {
        let chosen = selection.selected(in: candidates)
        guard !chosen.isEmpty else { return }
        let personal = chosen.contains { !$0.purpose.allowsPermanentDeletion }
        cleanupFlow.requestCleanup(
            title: "Clean Smart Scan Results",
            items: chosen.map(\.cleanupItem),
            services: services,
            regenerableData: true,
            source: .smartScan,
            warning: personal ? "Personal files, apps and app settings in your selection always go to the Trash so you can restore them." : nil
        ) { [weak self] report in
            self?.applyCleanup(report)
        }
    }

    private func applyCleanup(_ report: CleanupReport) {
        let removed = report.removed.map(\.path)
        candidates.removeAll { candidate in removed.contains { PathUtilities.isSameOrDescendant(candidate.path, of: $0) } }
        services.settings.lastSmartScanReclaimable = totalReclaimable
    }

    func exclude(_ candidate: CleanupCandidate) {
        services.settings.addExclusion(candidate.path)
        candidates.removeAll { $0.id == candidate.id }
    }

    func selectRecommended() {
        selection.reset(to: candidates)
    }
}

extension SmartScanArea {
    var defaultConsequence: String {
        switch self {
        case .junk: return "Regenerated automatically by apps and macOS."
        case .leftovers: return "Belongs to apps that are no longer installed. Review each item; they go to the Trash."
        case .largeFiles: return "These are your files. Only remove what you no longer need; they go to the Trash."
        case .duplicates: return "One copy of every file is always kept. Removed copies go to the Trash."
        case .privacy: return "Browsers rebuild caches automatically."
        case .developer: return "Rebuilt or re-downloaded by your developer tools when needed."
        case .startup, .security: return "Review the recommendation before acting."
        }
    }
}
