import SwiftUI

/// The Contacts page: access, the scan, and three sections — duplicates, incomplete contacts and backups.
struct ContactsHomeView: View {
    var model: ContactCleanupModel
    @Environment(\.scenePhase) private var scenePhase

    /// Up to this many groups and backups are listed here; more go behind "Show All".
    private static let previewLimit = 5
    private static let backupPreviewLimit = 3

    var body: some View {
        ScrollViewReader { proxy in
            list
                .onChange(of: model.notice) { _, notice in
                    if notice != nil { withAnimation { proxy.scrollTo(Self.noticeID, anchor: .top) } }
                }
        }
    }

    private static let noticeID = "notice"

    private var list: some View {
        List {
            if let notice = model.notice {
                Section {
                    ContactNoticeView(notice: notice) { withAnimation { model.notice = nil } }
                        .id(Self.noticeID)
                }
            }
            switch model.access {
            case .notDetermined:
                cardSection(PermissionCard(
                    section: .contacts, title: "Allow access to Contacts",
                    message: "Mac Cleaner finds duplicate and incomplete contacts on your \(model.deviceWord). Nothing changes until you confirm, a backup is saved before every change, and your contacts never leave your \(model.deviceWord).",
                    buttonTitle: "Allow Access"
                ) { Task { await model.requestAccess() } })
            case .denied:
                cardSection(PermissionCard(
                    section: .contacts, title: "Contacts access is off",
                    message: "To find duplicates, turn on Contacts for Mac Cleaner in Settings.",
                    buttonTitle: "Open Settings", action: openAppSettings
                ))
            case .restricted:
                cardSection(restrictedCard)
            case .limited:
                cardSection(PermissionCard(
                    section: .contacts, title: "Mac Cleaner sees only some contacts",
                    message: "You shared only some of your contacts, so duplicates among the others can't be found. Allow full access in Settings to check all of them.",
                    buttonTitle: "Allow Full Access", action: openAppSettings
                ))
                results
            case .full:
                results
            }
            // Backups can be shared without access to Contacts; restoring one needs it.
            if model.access.canRead || !model.backups.isEmpty {
                backupsSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Contacts")
        .toolbar {
            if model.access.canRead, model.lastScanDate != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await model.scan() } } label: {
                        Label("Scan Again", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isScanning || model.isSaving)
                }
            }
        }
        .refreshable {
            if model.access.canRead { await model.scan() }
        }
        .task {
            model.refreshAccess()
            await model.loadBackups()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshAccess() }
        }
        .modifier(ContactErrorAlert(model: model))
        .animation(.default, value: model.phase)
        .animation(.default, value: model.notice)
    }

    // MARK: Access

    private func cardSection(_ card: some View) -> some View {
        Section {
            card
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
    }

    private var restrictedCard: some View {
        Card {
            HStack(spacing: 12) {
                IconTile(symbol: "lock.fill", tint: Color(.systemGray), size: 44)
                Text("Contacts access is restricted").font(.headline)
            }
            Text("Screen Time or a profile on this \(model.deviceWord) doesn't let apps use Contacts, and Mac Cleaner can't change that. The person who manages this \(model.deviceWord) can.")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        switch model.phase {
        case .idle:
            cardSection(PermissionCard(
                section: .contacts, title: "Find duplicate contacts",
                message: "Mac Cleaner looks for cards with the same name, phone number or email, and for cards without a name or a way to reach them. Nothing changes until you confirm.",
                buttonTitle: "Scan Contacts"
            ) { Task { await model.scan() } })
        case .scanning(let read):
            cardSection(ProgressCard(title: "Scanning contacts",
                                     message: read > 0 ? "\(NumberFormatting.count(read, "contact")) read" : "Reading your contacts…",
                                     fraction: nil))
        case .scanned:
            summarySection
            duplicatesSection
            incompleteSection
        }
    }

    private var summarySection: some View {
        Section {
            HStack(spacing: 12) {
                StatTile(title: "Duplicates", value: NumberFormatting.count(model.duplicateCount),
                         caption: model.duplicateGroups.isEmpty ? "None found" : "In \(NumberFormatting.count(model.duplicateGroups.count, "group"))",
                         symbol: "person.2.circle.fill", tint: MobileSection.contacts.tint)
                StatTile(title: "Incomplete", value: NumberFormatting.count(model.incompleteContacts.count),
                         caption: model.incompleteContacts.isEmpty ? "None found" : "Missing details",
                         symbol: "person.crop.circle.badge.questionmark.fill", tint: .orange)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } footer: {
            if let date = model.lastScanDate {
                Text("\(NumberFormatting.count(model.contacts.count, "contact")) checked \(DateFormatting.relative(date)).")
            }
        }
    }

    private var duplicatesSection: some View {
        Section {
            if model.duplicateGroups.isEmpty {
                allClear("No duplicates found")
            } else {
                ForEach(model.duplicateGroups.prefix(Self.previewLimit)) { group in
                    NavigationLink { ContactMergeView(model: model, group: group) } label: { ContactGroupRow(group: group) }
                }
                if model.duplicateGroups.count > Self.previewLimit {
                    NavigationLink { ContactDuplicatesView(model: model) } label: {
                        Text("Show All \(NumberFormatting.count(model.duplicateGroups.count, "Group"))").foregroundStyle(Color.accentColor)
                    }
                }
            }
        } header: {
            Text("Duplicates")
        } footer: {
            if !model.duplicateGroups.isEmpty {
                Text("Merging keeps one card with every phone number, email and address of the others. A backup is saved first.")
            }
        }
    }

    private var incompleteSection: some View {
        Section {
            if model.incompleteContacts.isEmpty {
                allClear("No incomplete contacts")
            } else {
                NavigationLink { IncompleteContactsView(model: model) } label: {
                    HStack(spacing: 12) {
                        IconTile(symbol: "person.crop.circle.badge.questionmark", tint: .orange, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NumberFormatting.count(model.incompleteContacts.count, "incomplete contact")).font(.body.weight(.medium))
                            Text(incompleteDetail).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            Text("Incomplete")
        } footer: {
            if !model.incompleteContacts.isEmpty {
                Text("Cards without a name, or with a name but no phone number or email.")
            }
        }
    }

    private var incompleteDetail: String {
        let noName = model.incomplete(.noName).count, noReach = model.incomplete(.noPhoneOrEmail).count
        return [noName > 0 ? "\(NumberFormatting.count(noName)) without a name" : nil,
                noReach > 0 ? "\(NumberFormatting.count(noReach)) without a phone or email" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func allClear(_ title: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    // MARK: Backups

    private var backupsSection: some View {
        Section {
            if model.backups.isEmpty {
                Text("A backup is saved here before every merge or delete.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(model.backups.prefix(Self.backupPreviewLimit)) { backup in
                    ContactBackupRow(model: model, backup: backup)
                }
                if model.backups.count > Self.backupPreviewLimit {
                    NavigationLink { ContactBackupsView(model: model) } label: {
                        Text("Show All \(NumberFormatting.count(model.backups.count, "Backup"))").foregroundStyle(Color.accentColor)
                    }
                }
            }
        } header: {
            Text("Backups")
        } footer: {
            if !model.access.canRead {
                Text("To restore a backup, allow access to Contacts. You can still share it as a vCard file.")
            } else if !model.backups.isEmpty {
                Text("Restoring adds a backup's contacts as new contacts and doesn't change the ones you have. The last 20 backups are kept.")
            }
        }
    }
}

/// Every duplicate group.
struct ContactDuplicatesView: View {
    var model: ContactCleanupModel

    var body: some View {
        List {
            ForEach(model.duplicateGroups) { group in
                NavigationLink { ContactMergeView(model: model, group: group) } label: { ContactGroupRow(group: group) }
            }
        }
        .overlay {
            if model.duplicateGroups.isEmpty {
                EmptyStateView(symbol: "person.2", title: "No duplicates", message: "Every contact has its own card.")
            }
        }
        .navigationTitle("Duplicates")
        .modifier(ContactErrorAlert(model: model))
    }
}
