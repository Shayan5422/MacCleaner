import SwiftUI

/// The "Antivirus" tab of the Settings window.
struct AntivirusSettingsTab: View {
    @Bindable var model: AntivirusViewModel
    @State private var exclusionSelection: Set<String> = []
    @State private var newHash = ""
    @State private var hashError: String?

    private var settings: AntivirusSettings { model.settings }

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Real-time protection", isOn: Binding(get: { model.isRealTimeProtectionOn }, set: { model.setRealTimeProtection($0) }))
                Toggle("Check where new downloads came from (Download Shield)", isOn: Binding(get: { settings.downloadShield }, set: { model.setDownloadShield($0) }))
                Toggle("Move malware to the Virus Chest automatically", isOn: $settings.autoQuarantineMalware)
                Picker("When unwanted software is found", selection: $settings.puaAction) {
                    ForEach(AVPUAAction.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Open Mac Cleaner at login", isOn: Binding(get: { model.openAtLoginStatus == .enabled || model.openAtLoginStatus == .requiresApproval },
                                                               set: { model.setOpenAtLogin($0) }))
                    .disabled(model.openAtLoginStatus == .notFound)
            } header: {
                Text("Protection")
            } footer: {
                Text("Real-time protection works while Mac Cleaner is running; it keeps running in the menu bar when you close the window. Apps and files inside apps are never moved automatically. Login item: \(model.openAtLoginStatus.title).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Detection") {
                Toggle("Detect potentially unwanted apps (adware, bundled installers, hacking tools)", isOn: $settings.detectPUA)
                Text("Unwanted apps made for Windows or Linux aren't reported: they can't affect a Mac, and they cause most false alarms.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Detect Windows and Linux threats", isOn: $settings.detectNonMacThreats)
                Text("They can't run on a Mac, but you could pass them on to other computers. Full, custom and drive scans include them; Quick Scan sticks to threats that can run on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Scan inside archives (zip, gzip, tar) and universal apps", isOn: $settings.scanArchives)
                Picker("Skip files larger than", selection: $settings.maxFileSizeMB) {
                    ForEach(AntivirusSettings.maxFileSizeChoices, id: \.self) { megabytes in
                        Text(megabytes >= 1000 ? "\(megabytes / 1000) GB" : "\(megabytes) MB").tag(megabytes)
                    }
                }
                Toggle("Include external drives in Full Scan", isOn: $settings.includeExternalVolumesInFullScan)
            }

            Section {
                Toggle("Update virus definitions automatically", isOn: $settings.automaticUpdates)
                Toggle("Use freshclam when it's installed", isOn: $settings.useFreshclam)
                LabeledContent("Updater") {
                    Text(model.activeUpdater.title).foregroundStyle(.secondary)
                }
                Toggle("MalwareBazaar recent samples", isOn: Binding(get: { settings.sources.malwareBazaarRecent }, set: { model.setSource(\.malwareBazaarRecent, enabled: $0) }))
                Toggle("MalwareBazaar full archive (about 43 MB, weekly)", isOn: Binding(get: { settings.sources.malwareBazaarFull }, set: { model.setSource(\.malwareBazaarFull, enabled: $0) }))
                Toggle("URLhaus malware sites", isOn: Binding(get: { settings.sources.urlhaus }, set: { model.setSource(\.urlhaus, enabled: $0) }))
                Toggle("ThreatFox indicators", isOn: Binding(get: { settings.sources.threatFox }, set: { model.setSource(\.threatFox, enabled: $0) }))
            } header: {
                Text("Updates")
            } footer: {
                Text("While Mac Cleaner runs, it checks for new definitions at most every 4 hours. ClamAV signatures come from database.clamav.net; the other sources from abuse.ch. ClamAV recommends its own updater, freshclam; when it's installed, Mac Cleaner uses it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if settings.exclusions.paths.isEmpty {
                    Text("No antivirus exclusions. Exclusions in the Exclusions tab apply too.").foregroundStyle(.secondary)
                }
                ForEach(settings.exclusions.paths, id: \.self) { path in
                    HStack {
                        FileIcon(path: path, size: 16)
                        Text(PathUtilities.abbreviate(path)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { settings.removeExclusion(path); model.refreshShields() }.buttonStyle(.link)
                    }
                }
                Button("Add Folder or File…") {
                    for url in model.services.permissions.chooseItems(message: "Choose items the antivirus should never scan.") {
                        settings.addExclusion(url.path)
                    }
                    model.refreshShields()
                }
            } header: {
                Text("Not scanned")
            } footer: {
                Text("Excluded items are skipped by scans and the File Shield. Exclude only folders you trust, such as malware research or developer test data.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if settings.allowedHashes.isEmpty {
                    Text("No files are on the allow list.").foregroundStyle(.secondary)
                }
                ForEach(settings.allowedHashes) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name ?? "File").lineLimit(1)
                            Text(entry.sha256).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Remove") { settings.removeAllowed(sha256: entry.sha256); model.refreshShields() }.buttonStyle(.link)
                    }
                }
                HStack {
                    TextField("SHA-256", text: $newHash, prompt: Text("Paste a SHA-256 to allow"))
                        .font(.callout.monospaced())
                    Button("Add") {
                        if settings.allow(sha256: newHash) {
                            newHash = ""
                            hashError = nil
                            model.refreshShields()
                        } else {
                            hashError = "That isn't a SHA-256 (64 hexadecimal characters)."
                        }
                    }
                    .disabled(newHash.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let hashError { Text(hashError).font(.caption).foregroundStyle(.red) }
                Button("Allow a File…") { allowFile() }
            } header: {
                Text("Always allowed")
            } footer: {
                Text("Allowed files aren't reported again. The allow list matches the exact file contents, so a changed copy is checked again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.snapshot) { _, _ in model.refreshShields() }
        .onChange(of: settings.automaticUpdates) { _, _ in model.scheduleAutomaticUpdates() }
        .task {
            model.refreshOpenAtLoginStatus()
            await model.refreshTools()
        }
    }

    private func allowFile() {
        let urls = model.services.permissions.chooseItems(message: "Choose a file to always allow.", allowFiles: true, allowMultiple: false)
        guard let url = urls.first else { return }
        Task {
            let path = url.path
            let hash = await BackgroundWork.run(qos: .userInitiated) { AVFileHasher.sha256(path: path) }
            if let hash, settings.allow(sha256: hash, name: url.lastPathComponent, path: path) {
                hashError = nil
                model.refreshShields()
            } else {
                hashError = "That file couldn't be read."
            }
        }
    }
}
