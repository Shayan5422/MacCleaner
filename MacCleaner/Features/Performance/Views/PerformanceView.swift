import SwiftUI

/// The Performance page: live monitoring and explained optimization suggestions.
/// Monitoring runs only while the page is visible.
struct PerformanceView: View {
    @Bindable var model: PerformanceViewModel

    var body: some View {
        PageScroll {
            PageHeader(section: .performance, subtitle: "Live CPU, memory, disk and network activity, and what's slowing your Mac down.") {
                PerformanceIntervalPicker(model: model)
            }

            Picker("View", selection: $model.tab) {
                ForEach(PerformanceViewModel.Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if let status = model.actionStatus {
                PerformanceActionBanner(status: status) {
                    model.actionStatus = nil
                } onForceQuit: { target in
                    model.actionStatus = nil
                    model.perform(.forceQuit, target: target)
                }
            }

            switch model.tab {
            case .monitor:
                PerformanceMonitorTab(model: model)
            case .optimize:
                PerformanceOptimizeTab(model: model)
            }
        }
        .onAppear { model.pageAppeared() }
        .onDisappear { model.pageDisappeared() }
        .performanceActionConfirmations(model: model)
    }
}

/// "Update every" menu bound to `settings.monitorRefreshInterval`.
struct PerformanceIntervalPicker: View {
    var model: PerformanceViewModel

    var body: some View {
        Picker(selection: Binding(get: { model.refreshInterval }, set: { model.refreshInterval = $0 })) {
            ForEach(PerformanceMonitor.supportedIntervals, id: \.self) { seconds in
                Text("Every \(Int(seconds)) s").tag(seconds)
            }
        } label: {
            Label("Update", systemImage: "arrow.clockwise")
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("How often Performance readings are updated. Shorter intervals use slightly more energy.")
    }
}

/// Result of the last action, with a Force Quit shortcut when an app didn't quit.
struct PerformanceActionBanner: View {
    var status: PerformanceActionStatus
    var onDismiss: () -> Void
    var onForceQuit: (PerformanceActionTarget) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            InfoCallout(style: status.style, message: status.message)
            if let target = status.forceQuitCandidate {
                Button("Force Quit…") { onForceQuit(target) }
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
    }
}

// MARK: - Confirmations

extension View {
    /// Quit / Stop confirmations and the two-step Force Quit sheet.
    func performanceActionConfirmations(model: PerformanceViewModel) -> some View {
        modifier(PerformanceConfirmationsModifier(model: model))
    }
}

private struct PerformanceConfirmationsModifier: ViewModifier {
    @Bindable var model: PerformanceViewModel

    func body(content: Content) -> some View {
        content
            .alert(
                title,
                isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } }),
                presenting: model.confirmation
            ) { confirmation in
                switch confirmation.kind {
                case .quit:
                    Button("Quit") { model.confirm(confirmation) }
                        .keyboardShortcut(.defaultAction)
                case .stopProcess:
                    Button("Stop Process", role: .destructive) { model.confirm(confirmation) }
                }
                Button("Cancel", role: .cancel) { model.confirmation = nil }
            } message: { confirmation in
                switch confirmation.kind {
                case .quit:
                    Text("\(confirmation.target.name) will be asked to quit normally. If it has unsaved changes, it will ask you what to do.")
                case .stopProcess:
                    Text("Mac Cleaner will ask “\(confirmation.target.name)” to stop (it receives a standard termination request). Unsaved work in it may be lost, and the app that installed it may start it again. Only continue if you know what this process does.")
                }
            }
            .sheet(item: $model.forceQuitTarget) { target in
                PerformanceForceQuitSheet(target: target) {
                    model.confirmForceQuit(target)
                } onCancel: {
                    model.forceQuitTarget = nil
                }
            }
    }

    private var title: String {
        guard let confirmation = model.confirmation else { return "" }
        switch confirmation.kind {
        case .quit: return "Quit \(confirmation.target.name)?"
        case .stopProcess: return "Stop \(confirmation.target.name)?"
        }
    }
}

/// Force Quit needs two explicit confirmations: one to explain, one to act.
struct PerformanceForceQuitSheet: View {
    var target: PerformanceActionTarget
    var onConfirm: () -> Void
    var onCancel: () -> Void

    @State private var acknowledged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                PerformanceProcessIcon(pid: target.pid, path: target.bundlePath, size: 44)
                VStack(alignment: .leading, spacing: 6) {
                    Text(acknowledged ? "Force quit \(target.name) now?" : "Force quit \(target.name)?")
                        .font(.title3.weight(.semibold))
                    Text(acknowledged
                        ? "This is the final confirmation. \(target.name) will close immediately, and any unsaved changes in it will be lost."
                        : "Force quitting closes \(target.name) immediately, without letting it save. Use it only when the app doesn't respond to a normal Quit — busy apps sometimes just need a minute.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if acknowledged {
                InfoCallout(style: .warning, message: "Unsaved documents in \(target.name) can't be recovered after a force quit.")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                if acknowledged {
                    Button("Force Quit", role: .destructive, action: onConfirm)
                        .tint(.red)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Continue…") { acknowledged = true }
                }
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}
