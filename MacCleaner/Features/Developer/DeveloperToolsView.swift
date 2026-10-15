import QuickLook
import SwiftUI

/// Advanced developer cleanup: Xcode, simulators, package managers, Docker and build tools.
struct DeveloperToolsView: View {
    @Bindable var model: DeveloperToolsViewModel
    @State private var quickLookURL: URL?

    var body: some View {
        PageScroll {
            PageHeader(
                section: .developer,
                subtitle: "Reclaim space from build products, package caches and simulators. Projects, running containers and environments are never touched."
            ) {
                headerAccessory
            }
            content
        }
        .safeAreaInset(edge: .bottom) {
            if model.phase == .ready {
                actionBar
            }
        }
        .searchable(text: $model.searchText, prompt: "Search developer data")
        .cleanupFlow(model.cleanupFlow, services: model.services)
        .sheet(isPresented: Binding(
            get: { model.pendingCommand != nil || model.commandRun != nil },
            set: { isPresented in
                if !isPresented {
                    model.pendingCommand = nil
                    model.dismissCommandRun()
                }
            }
        )) {
            // One sheet that turns from confirmation into progress and output,
            // so a second sheet never has to appear while the first is closing.
            DeveloperCommandSheet(model: model)
        }
        .quickLookPreview($quickLookURL)
    }

    // MARK: - Header

    @ViewBuilder
    private var headerAccessory: some View {
        if model.phase == .ready {
            HStack(spacing: 14) {
                VStack(alignment: .trailing, spacing: 1) {
                    SizeText(bytes: model.totalRecoverable, font: .title3.weight(.semibold))
                    Text("can be recovered")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Button {
                    model.scan()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isBusy)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            ScanLaunchView(
                section: .developer,
                headline: "Clean up developer tools",
                message: "Mac Cleaner checks Xcode, simulators, Homebrew, package managers, Docker and build tools you have installed, and shows how much space each can give back.",
                buttonTitle: "Scan",
                bullets: [
                    "Only caches that rebuild automatically are selected",
                    "Official cleanup commands run only after you confirm them",
                    "Projects, running containers and environments are never touched",
                ],
                action: model.scan
            )
        case .scanning:
            ScanProgressCard(
                title: "Checking developer tools…",
                message: model.progressMessage,
                fraction: model.progressFraction,
                tint: AppSection.developer.tint,
                onCancel: model.cancelScan
            )
        case .ready:
            results
        }
    }

    @ViewBuilder
    private var results: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
            StatTile(title: "Recoverable", value: ByteFormatting.string(model.totalRecoverable), caption: "Across \(model.reports.count) tool\(model.reports.count == 1 ? "" : "s")", symbol: "externaldrive", tint: AppSection.developer.tint)
            StatTile(title: "Rebuilds automatically", value: ByteFormatting.string(model.safeRecoverable), caption: "Caches and build products", symbol: "checkmark.shield", tint: .green)
            StatTile(title: "Selected", value: ByteFormatting.string(model.selectedBytes), caption: "\(model.selectedItems.count) item\(model.selectedItems.count == 1 ? "" : "s") to remove", symbol: "checklist", tint: .blue)
        }

        let visible = model.visibleReports
        if visible.isEmpty {
            if model.searchText.isEmpty {
                EmptyStateView(
                    title: "No Developer Tools Found",
                    symbol: "hammer",
                    message: "Mac Cleaner didn’t find Xcode, package managers, Docker or other supported tools on this Mac."
                )
            } else {
                EmptyStateView(title: "No Results", symbol: "magnifyingglass", message: "Nothing matches “\(model.searchText)”.")
            }
        } else {
            ForEach(visible) { report in
                DeveloperToolCard(
                    report: report,
                    model: model,
                    onQuickLook: { path in quickLookURL = URL(fileURLWithPath: path) }
                )
            }
        }

        if !model.missingTools.isEmpty && model.searchText.isEmpty {
            DisclosureGroup {
                Text(model.missingTools.map(\.title).joined(separator: ", "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            } label: {
                Text("Not installed (\(model.missingTools.count))")
                    .font(.callout.weight(.medium))
            }
            .padding(.horizontal, 4)
        }
    }

    private var actionBar: some View {
        SelectionActionBar(selectedCount: model.selectedItems.count, selectedBytes: model.selectedBytes) {
            Button {
                model.cleanSelected()
            } label: {
                Text("Clean…").frame(minWidth: 80)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(AppSection.developer.tint)
            .disabled(model.selectedItems.isEmpty || model.isBusy)
            .help("Review and remove the selected caches and build products")
        }
    }
}
