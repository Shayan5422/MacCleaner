import SwiftUI

/// Drives the shared "confirm → clean → report" sequence used by every feature
/// that removes files, so confirmation, progress and recovery look and behave
/// the same everywhere.
@MainActor
@Observable
final class CleanupFlow {
    struct Request: Identifiable {
        let id = UUID()
        var title: String
        var items: [CleanupItem]
        /// Offer "Delete Immediately" in addition to "Move to Trash".
        var allowsPermanentDeletion: Bool
        var method: CleanupMethod
        var source: CleanupHistoryEntry.Source
        var warning: String?
        var onComplete: @MainActor (CleanupReport) -> Void
    }

    var request: Request?
    private(set) var isCleaning = false
    private(set) var progress: CleanupProgress?
    var report: CleanupReport?
    var restoreMessage: String?
    private var task: Task<Void, Never>?

    init() {}

    /// Asks for confirmation before removing `items`.
    func requestCleanup(
        title: String,
        items: [CleanupItem],
        services: AppServices,
        regenerableData: Bool,
        source: CleanupHistoryEntry.Source = .manual,
        warning: String? = nil,
        onComplete: @escaping @MainActor (CleanupReport) -> Void = { _ in }
    ) {
        guard !items.isEmpty else { return }
        let method = regenerableData ? services.settings.junkCleanupMethod : .moveToTrash
        let pending = Request(title: title, items: items, allowsPermanentDeletion: regenerableData, method: method, source: source, warning: warning, onComplete: onComplete)
        if services.settings.confirmBeforeCleaning || !regenerableData {
            request = pending
        } else {
            start(pending, services: services)
        }
    }

    func confirm(services: AppServices) {
        guard let pending = request else { return }
        request = nil
        start(pending, services: services)
    }

    func cancelRequest() {
        request = nil
    }

    func cancelCleaning() {
        task?.cancel()
    }

    private func start(_ pending: Request, services: AppServices) {
        isCleaning = true
        progress = CleanupProgress(completed: 0, total: pending.items.count, currentPath: "", bytesProcessed: 0)
        var options = services.cleanupOptions(title: pending.title, regenerableData: pending.allowsPermanentDeletion, source: pending.source)
        options.method = pending.method
        let engine = services.cleanupEngine
        task = Task {
            let report = await engine.clean(pending.items, options: options) { progress in
                Task { @MainActor in self.progress = progress }
            }
            isCleaning = false
            progress = nil
            self.report = report
            pending.onComplete(report)
        }
    }

    func restoreAll(services: AppServices) async {
        guard let id = report?.historyEntryID else { return }
        let result = await services.history.restore(entryID: id)
        if result.failed.isEmpty {
            restoreMessage = "Restored \(result.restored.count) item\(result.restored.count == 1 ? "" : "s") to their original locations."
        } else {
            restoreMessage = "Restored \(result.restored.count); \(result.failed.count) couldn't be restored: \(result.failed.first?.reason ?? "")"
        }
        services.logger.info("Restored \(result.restored.count) items from the Trash, \(result.failed.count) failed", category: .cleanup)
    }
}

extension View {
    /// Presents the confirmation sheet, progress overlay and result report of a `CleanupFlow`.
    func cleanupFlow(_ flow: CleanupFlow, services: AppServices) -> some View {
        modifier(CleanupFlowModifier(flow: flow, services: services))
    }
}

private struct CleanupFlowModifier: ViewModifier {
    @Bindable var flow: CleanupFlow
    let services: AppServices

    func body(content: Content) -> some View {
        content
            .sheet(item: $flow.request) { request in
                CleanupConfirmationSheet(flow: flow, request: request, services: services)
            }
            .sheet(isPresented: Binding(get: { flow.report != nil }, set: { if !$0 { flow.report = nil; flow.restoreMessage = nil } })) {
                if let report = flow.report {
                    CleanupReportSheet(flow: flow, report: report, services: services)
                }
            }
            .overlay {
                if flow.isCleaning {
                    CleaningOverlay(progress: flow.progress) { flow.cancelCleaning() }
                }
            }
    }
}

private struct CleaningOverlay: View {
    var progress: CleanupProgress?
    var onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView(value: progress?.fraction ?? 0)
                    .frame(width: 280)
                Text("Cleaning…").font(.headline)
                if let path = progress?.currentPath, !path.isEmpty {
                    PathText(path: path)
                        .frame(maxWidth: 320)
                }
                Button("Stop", role: .cancel, action: onCancel)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(radius: 20)
        }
        .transition(.opacity)
    }
}

struct CleanupConfirmationSheet: View {
    @Bindable var flow: CleanupFlow
    let request: CleanupFlow.Request
    let services: AppServices
    @State private var method: CleanupMethod = .moveToTrash
    @Environment(\.dismiss) private var dismiss

    private var totalBytes: Int64 { request.items.reduce(0) { $0 + $1.estimatedBytes } }

    private var categories: [(title: String, count: Int, bytes: Int64)] {
        Dictionary(grouping: request.items, by: \.category)
            .map { (title: $0.key, count: $0.value.count, bytes: $0.value.reduce(0) { $0 + $1.estimatedBytes }) }
            .sorted { $0.bytes > $1.bytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: method == .moveToTrash ? "trash" : "trash.slash")
                    .font(.system(size: 26))
                    .foregroundStyle(method == .moveToTrash ? Color.accentColor : .red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.title).font(.title3.weight(.semibold))
                    Text("\(NumberFormatting.count(request.items.count)) item\(request.items.count == 1 ? "" : "s") · about \(ByteFormatting.string(totalBytes))")
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(categories, id: \.title) { category in
                        HStack {
                            Text(category.title)
                            Spacer()
                            Text("\(category.count)").foregroundStyle(.secondary).monospacedDigit()
                            SizeText(bytes: category.bytes).frame(minWidth: 80, alignment: .trailing)
                        }
                        .font(.callout)
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 180)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

            if request.allowsPermanentDeletion {
                Picker("Removal method", selection: $method) {
                    Text("Move to Trash (recoverable)").tag(CleanupMethod.moveToTrash)
                    Text("Delete immediately (frees space now)").tag(CleanupMethod.deletePermanently)
                }
                .pickerStyle(.radioGroup)
            }

            if method == .deletePermanently {
                InfoCallout(style: .warning, message: "Deleted items can't be recovered. Only caches and other data that apps recreate automatically are offered for immediate deletion.")
            } else {
                InfoCallout(style: .info, message: "Items are moved to the Trash. You can restore them from History or Finder until you empty the Trash. Space is freed when the Trash is emptied.")
            }
            if let warning = request.warning {
                InfoCallout(style: .warning, message: warning)
            }
            if services.settings.skipItemsInUse {
                Text("Items open in running apps are skipped automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    flow.cancelRequest()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(method == .moveToTrash ? "Move to Trash" : "Delete", role: .destructive) {
                    flow.request?.method = method
                    flow.confirm(services: services)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(method == .moveToTrash ? .accentColor : .red)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { method = request.method }
    }
}

struct CleanupReportSheet: View {
    @Bindable var flow: CleanupFlow
    let report: CleanupReport
    let services: AppServices
    @State private var isRestoring = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: report.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(report.failed.isEmpty ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.dryRun ? "Dry Run Complete" : "Cleanup Complete").font(.title3.weight(.semibold))
                    Text(report.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            if !report.skipped.isEmpty || !report.failed.isEmpty {
                List {
                    if !report.failed.isEmpty {
                        Section("Couldn't remove") {
                            ForEach(report.failed, id: \.self) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    PathText(path: item.path, font: .callout)
                                    Text(item.message).font(.caption).foregroundStyle(.red)
                                    if let suggestion = item.suggestion {
                                        Text(suggestion).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .contextMenu { FileContextMenu(path: item.path) }
                            }
                        }
                    }
                    if !report.skipped.isEmpty {
                        Section("Skipped") {
                            ForEach(report.skipped, id: \.self) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    PathText(path: item.path, font: .callout)
                                    Text(item.reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(height: 200)
            }

            if let message = flow.restoreMessage {
                InfoCallout(style: .success, message: message)
            }

            HStack {
                if report.method == .moveToTrash && !report.dryRun && !report.removed.isEmpty {
                    Button("Show Trash") { FinderActions.openTrash() }
                    Button {
                        isRestoring = true
                        Task {
                            await flow.restoreAll(services: services)
                            isRestoring = false
                        }
                    } label: {
                        if isRestoring { ProgressView().controlSize(.small) } else { Text("Undo (Restore All)") }
                    }
                    .disabled(isRestoring || flow.restoreMessage != nil)
                }
                Spacer()
                Button("Done") {
                    flow.report = nil
                    flow.restoreMessage = nil
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}
