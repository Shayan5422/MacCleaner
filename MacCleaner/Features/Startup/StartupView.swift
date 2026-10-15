import SwiftUI

/// Startup & Background Activity Manager.
struct StartupView: View {
    @Bindable var model: StartupViewModel

    var body: some View {
        PageScroll {
            PageHeader(section: .startup, subtitle: "Apps and background services that start automatically. Turn off what you don't need.") {
                StartupHeaderActions(model: model)
            }
            if let message = model.statusMessage {
                StartupStatusBanner(message: message) { model.statusMessage = nil }
            }
            if model.inventory == nil {
                ScanProgressCard(title: "Reading startup items…", message: model.progressMessage,
                                 fraction: model.isLoading ? model.progress : nil, tint: AppSection.startup.tint)
            } else {
                StartupContent(model: model)
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search startup items")
        .task { await model.loadIfNeeded() }
        .sheet(item: $model.inspectedItem) { item in
            StartupItemDetailSheet(item: item, model: model)
        }
        .confirmationDialog(
            model.pendingAction?.title ?? "",
            isPresented: Binding(get: { model.pendingAction != nil && model.inspectedItem == nil },
                                 set: { if !$0 { model.pendingAction = nil } }),
            titleVisibility: .visible,
            presenting: model.pendingAction
        ) { action in
            Button(action.confirmTitle, role: action.isDestructive ? .destructive : nil) {
                Task { await model.perform(action) }
            }
            Button("Cancel", role: .cancel) { model.pendingAction = nil }
        } message: { action in
            Text(action.message)
        }
        .alert("Couldn't Change the Startup Item",
               isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } }),
               presenting: model.alertMessage) { _ in
            Button("OK", role: .cancel) { model.alertMessage = nil }
        } message: { message in
            Text(message)
        }
        .cleanupFlow(model.cleanupFlow, services: model.services)
    }
}

private struct StartupHeaderActions: View {
    @Bindable var model: StartupViewModel

    var body: some View {
        HStack(spacing: 8) {
            if model.isLoading && model.inventory != nil {
                ProgressView().controlSize(.small)
            } else if let date = model.inventory?.scannedAt {
                Text("Updated \(date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoading)
            .keyboardShortcut("r", modifiers: .command)
            .help("Read startup items again")

            Button {
                model.openLoginItemsSettings()
            } label: {
                Label("Login Items Settings", systemImage: "gearshape")
            }
            .help("Open System Settings › General › Login Items & Extensions")
        }
    }
}

private struct StartupContent: View {
    @Bindable var model: StartupViewModel

    var body: some View {
        StartupSummaryTiles(model: model)

        if model.needsReviewCount > 0 && model.filter != .needsReview {
            StartupAttentionBar(count: model.needsReviewCount) { model.filter = .needsReview }
        }

        Picker("Show", selection: $model.filter) {
            ForEach(StartupViewModel.Filter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 460)
        .accessibilityLabel("Filter startup items")

        let sections = model.sections
        let isFiltering = model.filter != .all || !model.searchText.isEmpty
        if isFiltering && sections.allSatisfy({ $0.items.isEmpty }) {
            EmptyStateView(
                title: "No Matching Items",
                symbol: "line.3.horizontal.decrease.circle",
                message: model.searchText.isEmpty ? "No startup items match this filter." : "No startup items match “\(model.searchText)”.",
                actionTitle: "Show All",
                action: {
                    model.filter = .all
                    model.searchText = ""
                }
            )
        } else {
            ForEach(sections) { section in
                if !isFiltering || !section.items.isEmpty {
                    StartupSectionCard(section: section, model: model)
                }
            }
        }

        if let notes = model.inventory?.notes.filter({ !$0.hasPrefix("Login items") }), !notes.isEmpty {
            ForEach(notes, id: \.self) { note in
                InfoCallout(style: .info, message: note)
            }
        }
    }
}

private struct StartupSummaryTiles: View {
    var model: StartupViewModel

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
            StatTile(
                title: "Open at Login",
                value: model.loginItemsAccess == .granted ? NumberFormatting.count(model.loginItemCount) : "—",
                caption: model.loginItemsAccess == .granted ? "apps" : "Access needed",
                symbol: StartupItemKind.loginItem.symbolName,
                tint: AppSection.startup.tint
            )
            StatTile(
                title: "Your Launch Agents",
                value: "\(model.runningUserAgentCount) running",
                caption: "\(model.userAgentCount) in your Library",
                symbol: StartupItemKind.userAgent.symbolName,
                tint: .blue
            )
            StatTile(
                title: "App Background Items",
                value: NumberFormatting.count(model.appItemCount),
                caption: "\(model.systemItemCount) system-wide items",
                symbol: StartupItemKind.appBackgroundItem.symbolName,
                tint: .purple
            )
            StatTile(
                title: "Needs Review",
                value: NumberFormatting.count(model.needsReviewCount),
                caption: model.needsReviewCount == 0 ? "Nothing looks unnecessary" : "may be unnecessary",
                symbol: model.needsReviewCount == 0 ? "checkmark.circle" : "exclamationmark.circle",
                tint: model.needsReviewCount == 0 ? .green : .orange
            )
        }
    }
}

private struct StartupAttentionBar: View {
    var count: Int
    var onShow: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(.orange)
            Text("\(count) item\(count == 1 ? " looks" : "s look") unnecessary — broken, unused or duplicated. Review them before changing anything.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Review", action: onShow)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.2)))
    }
}

struct StartupStatusBanner: View {
    var message: String
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(message).font(.callout)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.green.opacity(0.2)))
        .task(id: message) {
            try? await Task.sleep(for: .seconds(6))
            onDismiss()
        }
    }
}

// MARK: - Sections

private struct StartupSectionCard: View {
    let section: StartupViewModel.Section
    @Bindable var model: StartupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: section.symbol)
                    .foregroundStyle(AppSection.startup.tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(section.title).font(.headline)
                        Text(countText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(section.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(14)

            if section.id == .loginItems {
                StartupLoginItemsAccessView(model: model)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }

            if section.items.isEmpty {
                if showsEmptyText {
                    Divider()
                    Text(emptyText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(14)
                }
            } else {
                Divider()
                LazyVStack(spacing: 0) {
                    ForEach(section.items) { item in
                        StartupItemRow(item: item, model: model)
                        if item.id != section.items.last?.id {
                            Divider().padding(.leading, 54)
                        }
                    }
                }
            }

            if section.id == .loginItems {
                Divider()
                HStack(spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text("Apps can also register background items that only appear in System Settings › General › Login Items & Extensions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Open Login Items & Extensions") { model.openLoginItemsSettings() }
                        .controlSize(.small)
                }
                .padding(12)
            }
        }
        .card(padding: 0)
    }

    private var countText: String {
        section.items.count == section.totalCount ? "\(section.totalCount)" : "\(section.items.count) of \(section.totalCount)"
    }

    private var showsEmptyText: Bool {
        section.id != .loginItems || model.loginItemsAccess == .granted
    }

    private var emptyText: String {
        switch section.id {
        case .loginItems: return "No apps open at login."
        case .userAgents: return "There are no launch agents in your Library folder."
        case .appItems: return "No installed app includes background helpers."
        case .systemItems: return "No system-wide launch agents or daemons are installed."
        }
    }
}

private struct StartupLoginItemsAccessView: View {
    @Bindable var model: StartupViewModel

    var body: some View {
        switch model.loginItemsAccess {
        case .granted?:
            if let error = model.loginItemsError {
                InfoCallout(style: .warning, title: "Login items couldn't be read", message: error)
            }
        case .notDetermined?:
            accessRow(
                style: .info,
                title: "Allow Mac Cleaner to read your login items",
                message: "Login items are read through System Events. macOS asks you once to allow this; Mac Cleaner only reads them and removes one when you ask.",
                primary: ("Allow Access…", { Task { await model.requestLoginItemsAccess() } })
            )
        case .denied?:
            accessRow(
                style: .warning,
                title: "Access to System Events is off",
                message: "Turn on Mac Cleaner › System Events in System Settings › Privacy & Security › Automation, then check again.",
                primary: ("Open Automation Settings", { model.openAutomationSettings() }),
                secondary: ("Check Again", { Task { await model.refresh() } })
            )
        case .unavailable(let reason)?:
            accessRow(
                style: .warning,
                title: "Login items couldn't be read",
                message: reason,
                primary: ("Try Again", { Task { await model.refresh() } })
            )
        case nil:
            EmptyView()
        }
    }

    private func accessRow(
        style: InfoCallout.Style,
        title: String,
        message: String,
        primary: (String, () -> Void),
        secondary: (String, () -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            InfoCallout(style: style, title: title, message: message)
            HStack {
                Spacer()
                if let secondary {
                    Button(secondary.0, action: secondary.1)
                }
                Button(primary.0, action: primary.1)
                    .buttonStyle(.borderedProminent)
                    .tint(AppSection.startup.tint)
                    .disabled(model.isRequestingAccess)
            }
        }
    }
}
