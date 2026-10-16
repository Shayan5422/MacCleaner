import SwiftUI

/// The "Ports & Network" tab of the Settings window. Uses the same `NetworkPreferences` instance as the page and
/// the menu bar section, so changes apply right away.
struct NetworkSettingsTab: View {
    @Bindable var preferences: NetworkPreferences
    let notifications: NotificationService

    @State private var notificationsAllowed: Bool?

    init(preferences: NetworkPreferences = .shared, notifications: NotificationService = .shared) {
        self.preferences = preferences
        self.notifications = notifications
    }

    var body: some View {
        Form {
            Section("Ports") {
                Picker("Refresh every", selection: $preferences.refreshInterval) {
                    ForEach(NetworkPreferences.refreshChoices, id: \.self) { seconds in
                        Text(seconds == 1 ? "1 second" : "\(Int(seconds)) seconds").tag(seconds)
                    }
                }
                Text("While the Ports list is on screen (the page or the menu bar). In the background Mac Cleaner checks about every 10 seconds, and only rebuilds the list when a port opened or closed.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Wait before force stopping") {
                    HStack(spacing: 6) {
                        Text(Int(preferences.gracefulTimeout) == 1 ? "1 second" : "\(Int(preferences.gracefulTimeout)) seconds")
                            .monospacedDigit()
                        Stepper("Wait before force stopping", value: $preferences.gracefulTimeout,
                                in: NetworkPreferences.gracefulTimeoutRange, step: 1)
                            .labelsHidden()
                    }
                }
                Text("Stop first asks a server to quit (SIGTERM) and force stops what's still running after this time. ⌥-click Stop to force stop right away.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Include other users' and system ports", isOn: $preferences.includeOtherUsers)
                Toggle("Show the Apps section", isOn: $preferences.showApps)
                Toggle("Show the System section", isOn: $preferences.showSystem)
                if preferences.hiddenItemCount > 0 {
                    LabeledContent("Hidden items") {
                        Button("Show \(preferences.hiddenItemCount) Hidden") { preferences.unhideAll() }
                    }
                }
            }

            Section("Notifications") {
                Toggle("Notify me when a project or service opens a new port", isOn: Binding(
                    get: { preferences.notifyNewPorts },
                    set: { enabled in
                        preferences.notifyNewPorts = enabled
                        if enabled { requestAuthorization() }
                    }))
                Text("Only while Mac Cleaner is running. Apps and macOS open and close ports all the time, so they don't notify.")
                    .font(.caption).foregroundStyle(.secondary)
                if notificationsAllowed == false && (preferences.notifyNewPorts || preferences.shieldEnabled) {
                    LabeledContent("Notifications are off for Mac Cleaner") {
                        Button("Notification Settings…") { NSWorkspace.shared.open(SystemSettingsPane.notifications.url) }
                    }
                }
            }

            Section("Connections") {
                Toggle("Network Shield", isOn: Binding(
                    get: { preferences.shieldEnabled },
                    set: { enabled in
                        preferences.shieldEnabled = enabled
                        if enabled { requestAuthorization() }
                    }))
                Text("While Mac Cleaner runs, checks every connection against the threat feeds downloaded on the Antivirus page about every 20 seconds, and notifies you the first time an app connects to a known malicious server. It works on this Mac only and can't block connections.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Look up host names", isOn: $preferences.reverseDNS)
                Text("Shows names like github.com instead of bare addresses, on the Connections tab and for devices on your network. Each lookup sends a DNS query to your DNS server.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button("Reset Ports & Network Settings") { preferences.resetToDefaults() }
            }
        }
        .formStyle(.grouped)
        .task { notificationsAllowed = await notifications.isAuthorized() }
    }

    private func requestAuthorization() {
        Task {
            _ = await notifications.requestAuthorization()
            notificationsAllowed = await notifications.isAuthorized()
        }
    }
}
