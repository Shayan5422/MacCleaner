import Foundation
import Observation

@MainActor
@Observable
final class SystemJunkViewModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case results
        case failed(String)
    }

    let services: AppServices
    let selection = CandidateSelection()
    let cleanupFlow = CleanupFlow()
    /// Other providers whose findings belong on this page (for example leftovers of removed apps).
    private let extraProviders: [any SmartScanProvider]

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var progressMessage = ""
    private(set) var groups: [CandidateGroup] = []
    private(set) var lastScanDate: Date?
    private(set) var trashSize: Int64?
    var searchText = ""
    private var scanTask: Task<Void, Never>?

    init(services: AppServices, extraProviders: [any SmartScanProvider] = []) {
        self.services = services
        self.extraProviders = extraProviders
    }

    var allCandidates: [CleanupCandidate] { groups.flatMap(\.candidates) }
    var totalBytes: Int64 { groups.reduce(0) { $0 + $1.totalBytes } }
    var safeBytes: Int64 { allCandidates.filter { $0.safety == .safe }.reduce(0) { $0 + $1.usage.reclaimableBytes } }
    var selectedBytes: Int64 { selection.selectedBytes(in: allCandidates) }
    var selectedCount: Int { selection.selected(in: allCandidates).count }

    func scan() {
        scanTask?.cancel()
        phase = .scanning
        progress = 0
        progressMessage = "Preparing…"
        let preferences = services.settings.scanPreferences
        let includeContainers = services.permissions.fullDiskAccess == .granted
        let providers = extraProviders
        let started = Date()

        scanTask = Task {
            do {
                let scanner = SystemJunkScanner(includeAppContainers: includeContainers)
                let shares = Double(providers.count) * 0.15
                let junkShare = 1 - shares
                let results = try await scanner.scan(preferences: preferences) { fraction, message in
                    Task { @MainActor in
                        self.progress = fraction * junkShare
                        self.progressMessage = message
                    }
                }
                var newGroups = results.map { result in
                    CandidateGroup(
                        id: result.category.id, title: result.category.title, symbol: result.category.symbol,
                        explanation: result.category.explanation, consequence: result.category.consequence,
                        candidates: result.candidates
                    )
                }
                for (index, provider) in providers.enumerated() {
                    try Task.checkCancellation()
                    let base = junkShare + Double(index) * 0.15
                    let context = SmartScanContext(preferences: preferences) { fraction, message in
                        Task { @MainActor in
                            self.progress = base + fraction * 0.15
                            self.progressMessage = message
                        }
                    }
                    if let contribution = try? await provider.smartScan(context: context), !contribution.candidates.isEmpty {
                        newGroups.append(CandidateGroup(
                            id: "provider." + provider.area.rawValue,
                            title: provider.area == .leftovers ? "Leftovers of Removed Apps" : provider.area.title,
                            symbol: provider.area.symbolName,
                            explanation: provider.area == .leftovers
                                ? "Settings, caches and support files of apps that are no longer installed."
                                : (contribution.summary ?? ""),
                            consequence: provider.area == .leftovers
                                ? "Review each item: names are matched carefully, but only you know whether you'll reinstall an app. Items go to the Trash."
                                : "Review before removing.",
                            candidates: contribution.candidates
                        ))
                    }
                }
                try Task.checkCancellation()
                groups = newGroups
                selection.reset(to: newGroups.flatMap(\.candidates))
                lastScanDate = Date()
                phase = .results
                trashSize = await Self.measureTrash()
                services.logger.info(
                    "System Junk scan found \(allCandidates.count) items (\(ByteFormatting.string(totalBytes))) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s",
                    category: .scan
                )
            } catch is CancellationError {
                phase = groups.isEmpty ? .idle : .results
            } catch {
                phase = .failed(error.localizedDescription)
                services.logger.error("System Junk scan failed: \(error.localizedDescription)", category: .scan)
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    func cleanSelected() {
        let chosen = selection.selected(in: allCandidates)
        guard !chosen.isEmpty else { return }
        let includesPersonalFiles = chosen.contains { !$0.purpose.allowsPermanentDeletion }
        cleanupFlow.requestCleanup(
            title: "Clean System Junk",
            items: chosen.map(\.cleanupItem),
            services: services,
            regenerableData: true,
            warning: includesPersonalFiles ? "Downloads, installers and app leftovers always go to the Trash so you can restore them." : nil
        ) { [weak self] report in
            self?.applyCleanup(report)
        }
    }

    /// Removes cleaned items from the results without rescanning.
    private func applyCleanup(_ report: CleanupReport) {
        let removed = Set(report.removed.map(\.path))
        groups = groups.compactMap { group in
            var copy = group
            copy.candidates.removeAll { candidate in
                removed.contains { PathUtilities.isSameOrDescendant(candidate.path, of: $0) }
            }
            return copy.candidates.isEmpty ? nil : copy
        }
        selection.set(allCandidates.filter { removed.contains($0.path) }, selected: false)
        Task { trashSize = await Self.measureTrash() }
    }

    func exclude(_ candidate: CleanupCandidate) {
        services.settings.addExclusion(candidate.path)
        groups = groups.compactMap { group in
            var copy = group
            copy.candidates.removeAll { $0.id == candidate.id }
            return copy.candidates.isEmpty ? nil : copy
        }
    }

    func selectRecommended() {
        selection.reset(to: allCandidates)
    }

    /// Size of the Trash. Reading it requires Full Disk Access on recent macOS; nil if not readable.
    static func measureTrash() async -> Int64? {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path
        guard FileManager.default.isReadableFile(atPath: trash),
              (try? FileManager.default.contentsOfDirectory(atPath: trash)) != nil else { return nil }
        return try? await FileSystemScanner().measure(path: trash).allocatedBytes
    }
}
