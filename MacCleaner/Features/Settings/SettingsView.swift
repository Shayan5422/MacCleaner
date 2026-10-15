import SwiftUI

/// The app's Settings window (⌘,).
struct SettingsView: View {
    let services: AppServices

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: services.settings, notifications: services.notifications, permissions: services.permissions)
                .tabItem { Label("General", systemImage: "gearshape") }
            CleaningSettingsTab(settings: services.settings)
                .tabItem { Label("Cleaning", systemImage: "sparkles") }
            ExclusionsSettingsTab(settings: services.settings, permissions: services.permissions)
                .tabItem { Label("Exclusions", systemImage: "eye.slash") }
            PermissionsSettingsTab(permissions: services.permissions, notifications: services.notifications)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            MonitoringSettingsTab(settings: services.settings)
                .tabItem { Label("Monitoring", systemImage: "waveform.path.ecg") }
            ActivityLogSettingsTab(logger: services.logger)
                .tabItem { Label("Activity Log", systemImage: "list.bullet.rectangle") }
            AdvancedSettingsTab(services: services)
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 640, height: 500)
        .scenePadding()
    }
}

private struct GeneralSettingsTab: View {
    @Bindable var settings: SettingsManager
    let notifications: NotificationService
    let permissions: PermissionManager
    @State private var notificationsAllowed = false

    var body: some View {
        Form {
            Section {
                Toggle("Show performance monitor in the menu bar", isOn: $settings.showMenuBarExtra)
                Toggle("Ask for confirmation before cleaning", isOn: $settings.confirmBeforeCleaning)
                Text("Personal files, apps and anything that needs review always ask for confirmation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Network") {
                Toggle("Check for app updates online when I ask", isOn: $settings.checkUpdatesOnline)
                Text("Scanning and cleaning work completely offline. Update checks contact the update feeds of your apps and the App Store, only when you click “Check for Updates”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Notifications") {
                LabeledContent("Status") {
                    Text(notificationsAllowed ? "Allowed" : "Not allowed")
                        .foregroundStyle(notificationsAllowed ? .green : .secondary)
                }
                Button(notificationsAllowed ? "Notification Settings…" : "Allow Notifications…") {
                    Task {
                        if notificationsAllowed {
                            permissions.open(.notifications)
                        } else {
                            _ = await notifications.requestAuthorization()
                            notificationsAllowed = await notifications.isAuthorized()
                            if !notificationsAllowed { permissions.open(.notifications) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { notificationsAllowed = await notifications.isAuthorized() }
    }
}

private struct CleaningSettingsTab: View {
    @Bindable var settings: SettingsManager

    var body: some View {
        Form {
            Section("Removing junk") {
                Picker("Caches, logs and temporary files", selection: $settings.junkCleanupMethod) {
                    Text("Move to Trash (recoverable)").tag(CleanupMethod.moveToTrash)
                    Text("Delete immediately (frees space now)").tag(CleanupMethod.deletePermanently)
                }
                Text("Personal files, apps and app settings always go to the Trash, whatever you choose here.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Skip items that are open in running apps", isOn: $settings.skipItemsInUse)
            }
            Section("Thresholds") {
                Picker("Large files are at least", selection: $settings.largeFileThresholdMB) {
                    ForEach([50, 100, 250, 500, 1000, 2000, 5000], id: \.self) { megabytes in
                        Text(megabytes >= 1000 ? "\(megabytes / 1000) GB" : "\(megabytes) MB").tag(megabytes)
                    }
                }
                Picker("Old files haven't been used for", selection: $settings.oldFileAgeDays) {
                    ForEach([30, 90, 180, 365, 730], id: \.self) { Text(ageLabel($0)).tag($0) }
                }
                Picker("Old downloads haven't been used for", selection: $settings.oldDownloadAgeDays) {
                    ForEach([14, 30, 60, 90, 180, 365], id: \.self) { Text(ageLabel($0)).tag($0) }
                }
                Picker("Logs are old after", selection: $settings.logAgeDays) {
                    ForEach([1, 3, 7, 14, 30], id: \.self) { Text(ageLabel($0)).tag($0) }
                }
            }
            Section("Storage") {
                Toggle("Include hidden files in storage scans", isOn: $settings.includeHiddenFiles)
            }
        }
        .formStyle(.grouped)
    }

    private func ageLabel(_ days: Int) -> String {
        switch days {
        case 1: return "1 day"
        case 365: return "1 year"
        case 730: return "2 years"
        default: return days % 30 == 0 && days >= 60 ? "\(days / 30) months" : "\(days) days"
        }
    }
}

private struct ExclusionsSettingsTab: View {
    @Bindable var settings: SettingsManager
    let permissions: PermissionManager
    @State private var selection: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mac Cleaner never scans or removes these items or anything inside them.")
                .foregroundStyle(.secondary)
            List(selection: $selection) {
                ForEach(settings.exclusions.paths, id: \.self) { path in
                    HStack {
                        FileIcon(path: path, size: 18)
                        Text(PathUtilities.abbreviate(path)).lineLimit(1).truncationMode(.middle)
                    }
                    .tag(path)
                }
            }
            .overlay {
                if settings.exclusions.isEmpty {
                    Text("No exclusions. Add folders or files, or choose “Always Exclude” in any result list.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            HStack {
                Button {
                    for url in permissions.chooseItems(message: "Choose items Mac Cleaner should never scan or remove.") {
                        settings.addExclusion(url.path)
                    }
                } label: {
                    Label("Add…", systemImage: "plus")
                }
                Button {
                    for path in selection { settings.removeExclusion(path) }
                    selection.removeAll()
                } label: {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(selection.isEmpty)
            }
        }
        .padding()
    }
}

private struct PermissionsSettingsTab: View {
    let permissions: PermissionManager
    let notifications: NotificationService

    var body: some View {
        Form {
            Section {
                permissionRow(
                    title: "Full Disk Access",
                    detail: "Lets Mac Cleaner measure and clean protected locations such as app containers, Safari data, Mail downloads and the Trash. Without it, those items are skipped and marked as unreadable.",
                    status: permissions.fullDiskAccess,
                    pane: .fullDiskAccess
                )
                permissionRow(
                    title: "App Management",
                    detail: "Needed to move other apps to the Trash when uninstalling. macOS asks the first time; you can also allow it here.",
                    status: .unknown,
                    pane: .appManagement
                )
                permissionRow(
                    title: "Automation (System Events)",
                    detail: "Used only to list and remove your login items when you ask.",
                    status: .unknown,
                    pane: .automation
                )
            } footer: {
                Text("Mac Cleaner never works around macOS privacy protections. If a permission is missing, the affected items are skipped and shown as such.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Remembered locations") {
                if permissions.authorizedLocations.isEmpty {
                    Text("Folders and drives you choose for scanning appear here.").foregroundStyle(.secondary)
                }
                ForEach(permissions.authorizedLocations) { location in
                    HStack {
                        FileIcon(path: location.path, size: 18)
                        Text(PathUtilities.abbreviate(location.path)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Forget") { permissions.forget(location) }.buttonStyle(.link)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.refresh() }
    }

    private func permissionRow(title: String, detail: String, status: PermissionStatus, pane: SystemSettingsPane) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status == .granted ? "checkmark.circle.fill" : status == .notGranted ? "exclamationmark.circle.fill" : "questionmark.circle")
                .foregroundStyle(status == .granted ? .green : status == .notGranted ? .orange : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Button("Open Settings") { permissions.open(pane) }
                if pane == .fullDiskAccess {
                    Button("Check Again") { permissions.refresh() }.buttonStyle(.link)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MonitoringSettingsTab: View {
    @Bindable var settings: SettingsManager

    var body: some View {
        Form {
            Section("Sampling") {
                Picker("Refresh every", selection: $settings.monitorRefreshInterval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                }
                Text("Monitoring runs only while the Performance page or the menu bar monitor is visible.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Alerts") {
                Toggle("Notify me about performance problems", isOn: $settings.performanceAlertsEnabled)
                LabeledContent("Sustained CPU above") {
                    HStack {
                        Slider(value: $settings.cpuAlertThreshold, in: 0.5...1.0, step: 0.05)
                            .frame(width: 180)
                        Text(NumberFormatting.percent(settings.cpuAlertThreshold)).monospacedDigit().frame(width: 44)
                    }
                }
                .disabled(!settings.performanceAlertsEnabled)
                Toggle("Critical memory pressure", isOn: $settings.memoryPressureAlerts)
                    .disabled(!settings.performanceAlertsEnabled)
                Stepper("Free space below \(settings.lowDiskAlertGB) GB", value: $settings.lowDiskAlertGB, in: 1...500)
                    .disabled(!settings.performanceAlertsEnabled)
                Text("Alerts are checked while monitoring is active — turn on the menu bar monitor to get them in the background.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ActivityLogSettingsTab: View {
    let logger: ActivityLogger
    @State private var events: [ActivityEvent] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A record of what Mac Cleaner did: scans, cleanups, permissions and errors. It never contains file contents.")
                .foregroundStyle(.secondary)
            Table(events) {
                TableColumn("Time") { event in
                    Text(DateFormatting.short(event.date)).foregroundStyle(.secondary)
                }
                .width(130)
                TableColumn("Area") { event in
                    Text(event.category.title)
                }
                .width(90)
                TableColumn("Event") { event in
                    HStack(spacing: 4) {
                        if event.level != .info {
                            Image(systemName: event.level == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(event.level == .error ? .red : .orange)
                        }
                        Text(event.message).lineLimit(2)
                    }
                    .help(event.message)
                }
            }
            HStack {
                Button("Refresh") { Task { events = await logger.recentEvents() } }
                Button("Show Log File") { FinderActions.reveal(logger.logFileURL.path) }
                Spacer()
                Button("Clear Log", role: .destructive) {
                    Task {
                        await logger.clear()
                        events = []
                    }
                }
            }
        }
        .padding()
        .task { events = await logger.recentEvents() }
    }
}

private struct AdvancedSettingsTab: View {
    let services: AppServices
    @State private var confirmReset = false
    @State private var confirmClearHistory = false

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section("About") {
                LabeledContent("Version", value: version)
                LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                Text("Mac Cleaner has no accounts, subscriptions or analytics. Everything it finds stays on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Reset") {
                Button("Reset All Settings…") { confirmReset = true }
                Button("Clear Cleanup History…") { confirmClearHistory = true }
                Button("Show Onboarding Again") { services.settings.hasCompletedOnboarding = false }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmReset) {
            Button("Reset Settings", role: .destructive) { services.settings.resetToDefaults() }
        } message: {
            Text("Exclusions and remembered folders are kept.")
        }
        .confirmationDialog("Clear the cleanup history?", isPresented: $confirmClearHistory) {
            Button("Clear History", role: .destructive) { Task { await services.history.clear() } }
        } message: {
            Text("Items already in the Trash stay there, but can no longer be restored from Mac Cleaner.")
        }
    }
}
