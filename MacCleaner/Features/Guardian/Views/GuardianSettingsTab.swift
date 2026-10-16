import SwiftUI

/// The Guardian tab of the Settings window: Startup Guard, Web Shield (with per-browser
/// switches) and the login analysis.
///
/// Add it to `SettingsView`'s `TabView`:
/// `GuardianSettingsTab(settings: guardian.settings).tabItem { Label("Guardian", systemImage: "shield.lefthalf.filled") }`
struct GuardianSettingsTab: View {
    @Bindable var settings: GuardianSettings
    @State private var installedBrowsers: [String: String] = PrivacyBrowserApps.applicationPaths()

    var body: some View {
        Form {
            Section {
                Toggle("Watch startup items for changes", isOn: $settings.watchStartupItems)
                Toggle("Notify me when something new will start automatically", isOn: $settings.notifyNewStartupItems)
                    .disabled(!settings.watchStartupItems)
                Toggle("Also notify when items are removed or turned on or off", isOn: $settings.notifyOtherStartupChanges)
                    .disabled(!settings.watchStartupItems)
                Toggle("Scan new startup items with the antivirus", isOn: $settings.scanNewStartupItems)
                    .disabled(!settings.watchStartupItems)
                Text("Startup Guard compares everything that starts automatically at launch, every 10 minutes and right away when a launch agent folder changes. Changes are listed on the Startup Items page and in Activity.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Startup Guard")
            }

            Section {
                Toggle("Show what opened automatically at login", isOn: $settings.analyzeLogin)
                Text("A couple of minutes after you log in, Mac Cleaner looks at which apps and background programs opened by themselves, and why: a login item, a launch agent, an app's own setting, or macOS reopening the apps that were open when you logged out.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Login")
            }

            Section {
                Toggle("Warn me when a browser opens a known malware site", isOn: $settings.webShieldEnabled)
                Toggle("Show a notification", isOn: $settings.webShieldNotifications)
                    .disabled(!settings.webShieldEnabled)
                let installed = PrivacyBrowser.all.filter { installedBrowsers[$0.id] != nil }
                ForEach(installed) { browser in
                    Toggle(isOn: Binding(get: { settings.isBrowserWatched(browser.id) }, set: { settings.setBrowser(browser.id, watched: $0) })) {
                        HStack(spacing: 8) {
                            if let path = installedBrowsers[browser.id] { FileIcon(path: path, size: 16) }
                            Text("Watch \(browser.name)")
                        }
                    }
                    .disabled(!settings.webShieldEnabled)
                }
                if installed.isEmpty {
                    Text("No supported browser is installed.").foregroundStyle(.secondary)
                }
                Text("While a browser is open, Mac Cleaner reads the visits added to its history since the last check (about every 25 seconds) and compares them with the URLhaus and ThreatFox feeds from the Antivirus page. It keeps only matches and never stores or sends the sites you visit. It works once the feeds are loaded, can't see private windows, and can't block sites. Safari's history, and on recent macOS versions other browsers' too, needs Full Disk Access.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Web Shield")
            }
        }
        .formStyle(.grouped)
        .onAppear { installedBrowsers = PrivacyBrowserApps.applicationPaths() }
    }
}
