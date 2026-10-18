import SwiftUI

/// One duplicate group: the merged card exactly as it will be saved, the cards it's made from, and the merge button.
struct ContactMergeView: View {
    var model: ContactCleanupModel
    var group: ContactDuplicateGroup
    @State private var excluded: Set<String> = []
    @State private var isConfirming = false
    @Environment(\.dismiss) private var dismiss

    private var tint: Color { MobileSection.contacts.tint }
    private var included: [ContactSnapshot] { group.contacts.filter { !excluded.contains($0.id) } }
    private var plan: ContactMergePlan? { ContactMergePlanner.plan(merging: included) }

    var body: some View {
        let plan = plan
        List {
            if let plan {
                Section {
                    MergedCardHeader(contact: plan.merged, reason: group.reasonText)
                        .listRowBackground(Color.clear)
                }
                Section {
                    MergedFieldsView(plan: plan, primary: group.contacts.first { $0.id == plan.primaryID } ?? plan.merged)
                } header: {
                    Text("Merged Contact")
                } footer: {
                    if plan.changesPrimary {
                        Text("Details marked Added come from the other cards.")
                    } else {
                        Text("The kept card already has every detail of the others.")
                    }
                }
            } else {
                Section {
                    EmptyStateView(symbol: "person.2.slash", title: "Choose at least two cards",
                                   message: "Check the cards that belong to the same person.")
                }
            }
            Section {
                ForEach(group.contacts) { contact in
                    MergeCandidateRow(contact: contact, isIncluded: !excluded.contains(contact.id), isKept: plan?.primaryID == contact.id) {
                        if excluded.contains(contact.id) { excluded.remove(contact.id) } else { excluded.insert(contact.id) }
                    }
                }
            } header: {
                Text("Cards")
            } footer: {
                Text("The kept card gets the other cards' details, then the others are deleted. Uncheck a card that belongs to someone else.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Review Merge")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if let plan {
                ContactActionBar(title: "Merge \(NumberFormatting.count(plan.contactCount, "Contact"))", role: nil, tint: tint,
                                 isBusy: model.isSaving) { isConfirming = true }
                    .confirmationDialog("Merge \(NumberFormatting.count(plan.contactCount, "contact"))?",
                                        isPresented: $isConfirming, titleVisibility: .visible, presenting: plan) { plan in
                        Button("Merge \(NumberFormatting.count(plan.contactCount, "Contact"))") {
                            let previewed = included
                            Task {
                                if await model.merge(plan, previewed: previewed) { dismiss() }
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: { plan in
                        Text("\(plan.merged.displayName) keeps every phone number, email and address, and the other \(NumberFormatting.count(plan.removedIDs.count, "card")) \(plan.removedIDs.count == 1 ? "is" : "are") deleted. A backup is saved first.")
                    }
            }
        }
        .animation(.default, value: excluded)
        .modifier(ContactErrorAlert(model: model))
    }
}

/// The merged card's photo, name and company, and why the cards matched.
private struct MergedCardHeader: View {
    var contact: ContactSnapshot
    var reason: String

    var body: some View {
        VStack(spacing: 8) {
            ContactAvatarView(contact: contact, size: 84)
            Text(contact.displayName)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            if !contact.workLine.isEmpty {
                Text(contact.workLine).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 5) {
                Image(systemName: "link")
                Text(reason)
            }
            .font(.footnote.weight(.medium))
                .foregroundStyle(MobileSection.contacts.tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(MobileSection.contacts.tint.opacity(0.12), in: Capsule())
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Every field of the merged card, with the ones that come from other cards marked.
private struct MergedFieldsView: View {
    var plan: ContactMergePlan
    var primary: ContactSnapshot

    var body: some View {
        let merged = plan.merged
        ForEach(Array(merged.phones.enumerated()), id: \.offset) { index, phone in
            MergeFieldRow(label: phone.localizedLabel ?? "phone", value: phone.value, isAdded: index >= primary.phones.count)
        }
        ForEach(Array(merged.emails.enumerated()), id: \.offset) { index, email in
            MergeFieldRow(label: email.localizedLabel ?? "email", value: email.value, isAdded: index >= primary.emails.count)
        }
        ForEach(Array(merged.addresses.enumerated()), id: \.offset) { index, address in
            MergeFieldRow(label: address.localizedLabel ?? "address", value: address.singleLine, isAdded: index >= primary.addresses.count)
        }
        ForEach(Array(merged.urls.enumerated()), id: \.offset) { index, url in
            MergeFieldRow(label: url.localizedLabel ?? "URL", value: url.value, isAdded: index >= primary.urls.count)
        }
        if !ContactNormalization.trimmed(merged.nickname).isEmpty {
            MergeFieldRow(label: "nickname", value: merged.nickname, isAdded: plan.nickname != nil)
        }
        if !ContactNormalization.trimmed(merged.organization).isEmpty {
            MergeFieldRow(label: "company", value: merged.organization, isAdded: plan.organization != nil)
        }
        if !ContactNormalization.trimmed(merged.jobTitle).isEmpty {
            MergeFieldRow(label: "job title", value: merged.jobTitle, isAdded: plan.jobTitle != nil)
        }
        if let birthday = merged.birthday, let text = ContactFormatting.birthday(birthday) {
            MergeFieldRow(label: "birthday", value: text, isAdded: plan.birthday != nil)
        }
        if plan.name != nil {
            MergeFieldRow(label: "name", value: merged.displayName, isAdded: true)
        }
        if plan.photoSourceID != nil {
            MergeFieldRow(label: "photo", value: "From another card", isAdded: true)
        }
        if merged.phones.isEmpty, merged.emails.isEmpty, merged.addresses.isEmpty, merged.urls.isEmpty {
            Text("No phone numbers, emails or addresses").font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

private struct MergeFieldRow: View {
    var label: String
    var value: String
    var isAdded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label).font(.subheadline).foregroundStyle(.secondary)
                if isAdded { ContactBadge(title: "Added") }
            }
            Text(value).font(.body).textSelection(.enabled)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isAdded ? "Added from another card" : "")
    }
}

/// A card in the group, with a check to include it in the merge.
private struct MergeCandidateRow: View {
    var contact: ContactSnapshot
    var isIncluded: Bool
    var isKept: Bool
    var toggle: () -> Void
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 40

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                ContactSelectionMark(isSelected: isIncluded)
                ContactAvatarView(contact: contact, size: min(avatarSize, 54))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(contact.displayName).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                        if isKept { ContactBadge(title: "Kept") }
                    }
                    ForEach(detailLines, id: \.self) { line in
                        Text(line).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if isIncluded, !isKept {
                        Text("Deleted after merging").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .opacity(isIncluded ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isIncluded ? .isSelected : [])
        .accessibilityHint(isIncluded ? "Leaves this card out of the merge" : "Includes this card in the merge")
    }

    private var detailLines: [String] {
        let phones = contact.phones.map(\.value).joined(separator: ", ")
        let emails = contact.emails.map(\.value).joined(separator: ", ")
        let lines = [phones, emails, contact.workLine].filter { !$0.isEmpty }
        return lines.isEmpty ? ["No phone number or email"] : Array(lines.prefix(2))
    }
}
