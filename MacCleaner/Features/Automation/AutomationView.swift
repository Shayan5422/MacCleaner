import SwiftUI

struct AutomationView: View {
    @Bindable var model: AutomationViewModel

    var body: some View {
        PageScroll {
            PageHeader(section: .automation, subtitle: "Keep junk under control on a schedule or when storage runs low. Only regenerable data is ever cleaned automatically.") {
                Toggle("Automatic Cleaning", isOn: Binding(get: { model.configuration.isEnabled }, set: { model.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("Automatic cleaning")
            }
            statusCard
            if let error = model.errorMessage {
                InfoCallout(style: .warning, title: "Couldn't turn on automation", message: error)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 16) {
                    scheduleCard
                    triggersCard
                }
                VStack(spacing: 16) {
                    behaviorCard
                    categoriesCard
                }
            }
            historyCard
        }
        .onAppear { model.refresh() }
        .alert("Run the automatic cleanup now?", isPresented: $model.showRunNowConfirmation) {
            Button("Run Now") { model.runNow() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.configuration.dryRun
                 ? "This is a dry run: Mac Cleaner will only record what it would remove."
                 : "Mac Cleaner will remove items from the selected categories that are safe to remove. Personal files and items marked for review are never included.")
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        HStack(spacing: 16) {
            Image(systemName: statusSymbol)
                .font(.system(size: 28))
                .foregroundStyle(statusTint)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.configuration.isEnabled ? "Automation is \(model.agentStatus.title.lowercased())" : "Automation is off")
                    .font(.headline)
                if let next = model.nextRunDate {
                    Text(model.state.pendingCleanupSince != nil ? "Announced cleanup runs around \(DateFormatting.short(next))." : "Next scheduled run: \(DateFormatting.short(next))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if !model.configuration.isEnabled {
                    Text("Turn it on to clean on a schedule. The background agent wakes about once an hour and exits immediately unless something is due.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let message = model.lastRunMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.agentStatus == .requiresApproval {
                Button("Allow in System Settings") { model.openLoginItems() }
            }
            if model.state.pendingCleanupSince != nil && !model.state.skipPendingCleanup {
                Button("Skip This Cleanup") { model.skipPendingCleanup() }
            }
            Button {
                model.showRunNowConfirmation = true
            } label: {
                if model.isRunning { ProgressView().controlSize(.small) } else { Text("Run Now") }
            }
            .disabled(model.isRunning || model.configuration.categories.isEmpty)
        }
        .card()
    }

    private var statusSymbol: String {
        guard model.configuration.isEnabled else { return "pause.circle" }
        switch model.agentStatus {
        case .enabled: return "checkmark.circle.fill"
        case .requiresApproval: return "exclamationmark.circle.fill"
        default: return "xmark.circle.fill"
        }
    }

    private var statusTint: Color {
        guard model.configuration.isEnabled else { return .secondary }
        return model.agentStatus == .enabled ? .green : .orange
    }

    // MARK: - Cards

    private var scheduleCard: some View {
        Card("Schedule", symbol: "calendar") {
            Toggle("Run on a schedule", isOn: $model.configuration.scheduleEnabled)
            Picker("Frequency", selection: $model.configuration.frequency) {
                ForEach(AutomationConfiguration.Frequency.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!model.configuration.scheduleEnabled)
            if model.configuration.frequency == .weekly {
                Picker("Day", selection: $model.configuration.weekday) {
                    ForEach(1...7, id: \.self) { day in
                        Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                    }
                }
                .disabled(!model.configuration.scheduleEnabled)
            }
            if model.configuration.frequency == .monthly {
                Stepper("Day of month: \(model.configuration.dayOfMonth)", value: $model.configuration.dayOfMonth, in: 1...28)
                    .disabled(!model.configuration.scheduleEnabled)
            }
            DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                .disabled(!model.configuration.scheduleEnabled)
            Text("If your Mac is asleep at that time, the run happens the next time it's awake.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var timeBinding: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: model.configuration.hour, minute: model.configuration.minute, second: 0, of: Date()) ?? Date()
        } set: { date in
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            model.configuration.hour = components.hour ?? 10
            model.configuration.minute = components.minute ?? 0
        }
    }

    private var triggersCard: some View {
        Card("Triggers", symbol: "bolt") {
            Toggle(isOn: $model.configuration.storageTriggerEnabled) {
                VStack(alignment: .leading) {
                    Text("Clean when free space drops below")
                    Text("At most once every 12 hours.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Stepper("\(model.configuration.storageTriggerGB) GB", value: $model.configuration.storageTriggerGB, in: 5...500, step: 5)
                .disabled(!model.configuration.storageTriggerEnabled)
            Divider()
            Toggle(isOn: $model.configuration.junkAlertEnabled) {
                VStack(alignment: .leading) {
                    Text("Notify me when junk exceeds")
                    Text("Checked once a day.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Stepper("\(model.configuration.junkAlertGB) GB", value: $model.configuration.junkAlertGB, in: 1...200)
                .disabled(!model.configuration.junkAlertEnabled)
            Divider()
            Toggle("Include a security scan with each scheduled run", isOn: $model.configuration.securityScanEnabled)
        }
    }

    private var behaviorCard: some View {
        Card("Behavior", symbol: "slider.horizontal.3") {
            Picker("When something can be cleaned", selection: $model.configuration.mode) {
                ForEach(AutomationConfiguration.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Toggle("Notify me an hour before cleaning (so I can skip it)", isOn: $model.configuration.notifyBeforeCleaning)
                .disabled(model.configuration.mode != .clean)
            Toggle("Notify me after cleaning", isOn: $model.configuration.notifyAfterCleaning)
                .disabled(model.configuration.mode != .clean)
            Toggle("Dry run (record what would be removed, remove nothing)", isOn: $model.configuration.dryRun)
            Text("Removal method follows Settings › Cleaning (\(model.services.settings.junkCleanupMethod.title)). Automatic runs skip items that are open in running apps and pause in Low Power Mode.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !model.notificationsAuthorized {
                Button("Allow Notifications…") { model.requestNotifications() }
                    .buttonStyle(.link)
            }
        }
    }

    private var categoriesCard: some View {
        Card("What to clean", symbol: "checklist") {
            ForEach(model.availableCategories) { category in
                Toggle(isOn: Binding(get: { model.configuration.categories.contains(category.id) }, set: { model.toggleCategory(category.id, on: $0) })) {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(category.title)
                            Text(category.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: category.symbol).foregroundStyle(AppSection.automation.tint)
                    }
                }
                .toggleStyle(.checkbox)
            }
            InfoCallout(style: .info, message: "Personal files, downloads, app leftovers and anything marked “Review” are never removed automatically. Exclusions in Settings always apply.")
        }
    }

    private var historyCard: some View {
        Card("History", symbol: "clock.arrow.circlepath", accessory: {
            if !model.history.isEmpty {
                Button("Clear") { model.clearHistory() }.buttonStyle(.link)
            }
        }) {
            if model.history.isEmpty {
                Text("No automatic runs yet.").foregroundStyle(.secondary).font(.callout)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.history.prefix(30)) { record in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: symbol(for: record.outcome))
                                .foregroundStyle(tint(for: record.outcome))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.message).font(.callout)
                                Text("\(record.trigger.title) · \(DateFormatting.short(record.date))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if record.bytes > 0 {
                                SizeText(bytes: record.bytes, font: .callout).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
        }
    }

    private func symbol(for outcome: AutomationRunRecord.Outcome) -> String {
        switch outcome {
        case .cleaned: return "checkmark.circle.fill"
        case .dryRun: return "doc.text.magnifyingglass"
        case .notified, .announced: return "bell.fill"
        case .skipped, .deferred: return "forward.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .nothingToDo: return "minus.circle"
        }
    }

    private func tint(for outcome: AutomationRunRecord.Outcome) -> Color {
        switch outcome {
        case .cleaned: return .green
        case .failed: return .orange
        case .notified, .announced: return .blue
        default: return .secondary
        }
    }
}
