import SwiftUI

extension ContactIssue {
    var title: String {
        switch self {
        case .noName: return "No Name"
        case .noPhoneOrEmail: return "No Phone or Email"
        }
    }

    var explanation: String {
        switch self {
        case .noName: return "Only a phone number or an email, so Phone and Messages show the number instead of a name."
        case .noPhoneOrEmail: return "A name, but no phone number or email to reach them."
        }
    }
}

/// Incomplete contacts in two sections, to select and delete.
struct IncompleteContactsView: View {
    var model: ContactCleanupModel
    @State private var selection: Set<String> = []
    @State private var isConfirming = false

    private var selectedContacts: [ContactSnapshot] {
        model.incompleteContacts.map(\.contact).filter { selection.contains($0.id) }
    }

    private var allSelected: Bool {
        !model.incompleteContacts.isEmpty && model.incompleteContacts.allSatisfy { selection.contains($0.id) }
    }

    var body: some View {
        List {
            if let notice = model.notice {
                Section {
                    ContactNoticeView(notice: notice) { withAnimation { model.notice = nil } }
                }
            }
            ForEach(ContactIssue.allCases, id: \.self) { issue in
                let contacts = model.incomplete(issue)
                if !contacts.isEmpty {
                    Section {
                        ForEach(contacts) { item in
                            SelectableContactRow(contact: item.contact, detail: detail(for: item), isSelected: selection.contains(item.id)) {
                                if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
                            }
                        }
                    } header: {
                        Text(issue.title)
                    } footer: {
                        Text(issue.explanation)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if model.incompleteContacts.isEmpty {
                EmptyStateView(symbol: "person.crop.circle.badge.checkmark", title: "No incomplete contacts",
                               message: "Every card has a name and a way to reach them.")
            }
        }
        .navigationTitle("Incomplete")
        .toolbar {
            if !model.incompleteContacts.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(allSelected ? "Deselect All" : "Select All") {
                        selection = allSelected ? [] : Set(model.incompleteContacts.map(\.id))
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty {
                ContactActionBar(title: "Delete \(NumberFormatting.count(selection.count, "Contact"))", role: .destructive, tint: .red,
                                 isBusy: model.isSaving) { isConfirming = true }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .confirmationDialog("Delete \(NumberFormatting.count(selection.count, "contact"))?", isPresented: $isConfirming,
                                        titleVisibility: .visible) {
                        Button("Delete \(NumberFormatting.count(selection.count, "Contact"))", role: .destructive) {
                            let contacts = selectedContacts
                            Task {
                                if await model.delete(contacts) { selection.removeAll() }
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("A backup is saved first, so you can restore them from Backups.")
                    }
            }
        }
        .onAppear { model.notice = nil }
        .onChange(of: model.incompleteContacts) { _, contacts in
            selection.formIntersection(contacts.map(\.id))
        }
        .modifier(ContactErrorAlert(model: model))
        .animation(.default, value: selection.isEmpty)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func detail(for item: IncompleteContact) -> String {
        let contact = item.contact
        switch item.issue {
        case .noName:
            let values = (contact.phones.map(\.value) + contact.emails.map(\.value)).filter { !ContactNormalization.trimmed($0).isEmpty }
            if values.count > 1 { return "Also \(values.dropFirst().joined(separator: ", "))" }
            if let address = contact.addresses.first { return address.singleLine }
            return values.isEmpty ? "No details" : (contact.phones.isEmpty ? "Only an email" : "Only a phone number")
        case .noPhoneOrEmail:
            if !contact.workLine.isEmpty { return contact.workLine }
            if let address = contact.addresses.first { return address.singleLine }
            return "Only a name"
        }
    }
}

/// A backup with Share and Restore.
struct ContactBackupRow: View {
    var model: ContactCleanupModel
    var backup: ContactBackup
    @State private var isConfirmingRestore = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            HStack(spacing: 12) {
                IconTile(symbol: backup.kind == .delete ? "trash" : "arrow.triangle.merge", tint: Color(.systemGray), size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(backup.title).font(.subheadline.weight(.semibold))
                    Text(backup.date.formatted(date: .abbreviated, time: .shortened)).font(.footnote).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            HStack(spacing: 14) {
                ShareLink(item: backup.url) {
                    Image(systemName: "square.and.arrow.up").font(.body.weight(.medium))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Share")
                .accessibilityHint("Shares the vCard file of this backup")
                Button("Restore") { isConfirmingRestore = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isSaving || !model.access.canRead)
            }
        }
        .padding(.vertical, 2)
        .confirmationDialog("Restore \(NumberFormatting.count(backup.contactCount, "contact"))?", isPresented: $isConfirmingRestore, titleVisibility: .visible) {
            Button("Restore \(NumberFormatting.count(backup.contactCount, "Contact"))") {
                Task { await model.restore(backup) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They're added as new contacts. The contacts you have now aren't changed, so any that still exist will show up twice.")
        }
    }
}

/// Every backup.
struct ContactBackupsView: View {
    var model: ContactCleanupModel

    var body: some View {
        List {
            Section {
                ForEach(model.backups) { backup in
                    ContactBackupRow(model: model, backup: backup)
                }
            } footer: {
                Text("A backup is saved before every merge or delete. Restoring adds its contacts as new contacts. The last 20 backups are kept.")
            }
        }
        .overlay {
            if model.backups.isEmpty {
                EmptyStateView(symbol: "clock.arrow.circlepath", title: "No backups yet", message: "A backup is saved before every merge or delete.")
            }
        }
        .navigationTitle("Backups")
        .modifier(ContactErrorAlert(model: model))
    }
}
