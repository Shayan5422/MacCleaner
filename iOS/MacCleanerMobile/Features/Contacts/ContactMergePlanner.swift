import Contacts
import Foundation

/// What merging a group of duplicates changes, worked out before anything is saved.
struct ContactMergePlan: Sendable, Hashable {
    /// The card that stays and receives the others' details.
    var primaryID: String
    /// The cards deleted once their details are copied, best first.
    var removedIDs: [String]
    var addedPhones: [ContactLabeledValue] = []
    var addedEmails: [ContactLabeledValue] = []
    var addedAddresses: [ContactAddress] = []
    var addedURLs: [ContactLabeledValue] = []
    /// Another card's name, when the kept card has none.
    var name: ContactName?
    var nickname: String?
    var organization: String?
    var jobTitle: String?
    var birthday: DateComponents?
    /// The card whose photo the kept card gets, when it has none.
    var photoSourceID: String?
    /// The kept card as it will look, for the preview.
    var merged: ContactSnapshot

    var contactCount: Int { removedIDs.count + 1 }
    var allIDs: [String] { [primaryID] + removedIDs }

    /// Whether the kept card changes; when it doesn't, merging only deletes the others.
    var changesPrimary: Bool {
        !addedPhones.isEmpty || !addedEmails.isEmpty || !addedAddresses.isEmpty || !addedURLs.isEmpty
            || name != nil || nickname != nil || organization != nil || jobTitle != nil || birthday != nil || photoSourceID != nil
    }
}

/// Plans and applies merges. Planning is a pure function of the snapshots, so the preview shows exactly what's saved.
enum ContactMergePlanner {
    /// Best first: the most filled-in fields, then the one with a photo, then the oldest.
    static func ranked(_ contacts: [ContactSnapshot]) -> [ContactSnapshot] {
        contacts.sorted { lhs, rhs in
            if lhs.filledFieldCount != rhs.filledFieldCount { return lhs.filledFieldCount > rhs.filledFieldCount }
            if lhs.hasPhoto != rhs.hasPhoto { return lhs.hasPhoto }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.id < rhs.id
        }
    }

    /// Keeps the best card and gives it every phone number, email, address and URL it doesn't have yet,
    /// plus the name, nickname, company, job title, birthday and photo when it has none. Nil for fewer than two contacts.
    static func plan(merging contacts: [ContactSnapshot]) -> ContactMergePlan? {
        guard contacts.count > 1 else { return nil }
        let ranked = ranked(contacts)
        let primary = ranked[0]
        let others = ranked.dropFirst()
        var merged = primary
        var plan = ContactMergePlan(primaryID: primary.id, removedIDs: others.map(\.id), merged: primary)

        for other in others {
            for phone in other.phones where !ContactNormalization.trimmed(phone.value).isEmpty {
                guard !merged.phones.contains(where: { ContactNormalization.samePhoneEntry($0.value, phone.value) }) else { continue }
                merged.phones.append(phone)
                plan.addedPhones.append(phone)
            }
            for email in other.emails {
                guard let key = ContactNormalization.email(email.value),
                      !merged.emails.contains(where: { ContactNormalization.email($0.value) == key }) else { continue }
                merged.emails.append(email)
                plan.addedEmails.append(email)
            }
            for address in other.addresses {
                guard let key = ContactNormalization.address(address),
                      !merged.addresses.contains(where: { ContactNormalization.address($0) == key }) else { continue }
                merged.addresses.append(address)
                plan.addedAddresses.append(address)
            }
            for url in other.urls {
                guard let key = ContactNormalization.url(url.value),
                      !merged.urls.contains(where: { ContactNormalization.url($0.value) == key }) else { continue }
                merged.urls.append(url)
                plan.addedURLs.append(url)
            }
        }

        if primary.personName.isEmpty, !primary.isOrganization, let named = others.first(where: { !$0.personName.isEmpty }) {
            plan.name = named.name
            merged.name = named.name
        }
        if let nickname = missing(primary.nickname, from: others.map(\.nickname)) {
            plan.nickname = nickname
            merged.nickname = nickname
        }
        if let organization = missing(primary.organization, from: others.map(\.organization)) {
            plan.organization = organization
            merged.organization = organization
        }
        if let jobTitle = missing(primary.jobTitle, from: others.map(\.jobTitle)) {
            plan.jobTitle = jobTitle
            merged.jobTitle = jobTitle
        }
        if primary.birthday == nil, let birthday = others.lazy.compactMap(\.birthday).first {
            plan.birthday = birthday
            merged.birthday = birthday
        }
        if !primary.hasPhoto, let source = others.first(where: \.hasPhoto) {
            plan.photoSourceID = source.id
            merged.hasPhoto = true
            merged.thumbnail = source.thumbnail
        }
        merged.formattedName = ContactSnapshot.format(merged.name, isOrganization: merged.isOrganization, organization: merged.organization)
        plan.merged = merged
        return plan
    }

    /// Copies the plan's additions into the kept card. `photo` is the full-size photo of `plan.photoSourceID`.
    static func apply(_ plan: ContactMergePlan, to contact: CNMutableContact, photo: Data?) {
        contact.phoneNumbers += plan.addedPhones.map { CNLabeledValue(label: $0.label, value: CNPhoneNumber(stringValue: $0.value)) }
        contact.emailAddresses += plan.addedEmails.map { CNLabeledValue(label: $0.label, value: $0.value as NSString) }
        contact.postalAddresses += plan.addedAddresses.map { CNLabeledValue(label: $0.label, value: $0.postalAddress) }
        contact.urlAddresses += plan.addedURLs.map { CNLabeledValue(label: $0.label, value: $0.value as NSString) }
        if let name = plan.name {
            contact.namePrefix = name.prefix
            contact.givenName = name.given
            contact.middleName = name.middle
            contact.familyName = name.family
            contact.nameSuffix = name.suffix
        }
        if let nickname = plan.nickname { contact.nickname = nickname }
        if let organization = plan.organization { contact.organizationName = organization }
        if let jobTitle = plan.jobTitle { contact.jobTitle = jobTitle }
        if let birthday = plan.birthday { contact.birthday = birthday }
        if plan.photoSourceID != nil, let photo { contact.imageData = photo }
    }

    /// The first non-empty value of the others, when the kept card's value is empty.
    private static func missing(_ value: String, from others: [String]) -> String? {
        guard ContactNormalization.trimmed(value).isEmpty else { return nil }
        return others.first { !ContactNormalization.trimmed($0).isEmpty }
    }
}
