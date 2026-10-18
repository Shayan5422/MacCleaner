import Contacts
import Foundation

/// A phone number, email address or URL with its label, copied out of `CNLabeledValue`.
struct ContactLabeledValue: Sendable, Hashable {
    /// The raw label, such as `_$!<Mobile>!$_`, or nil when there's none.
    var label: String?
    var value: String

    /// "mobile", "work"; nil when there's no label.
    var localizedLabel: String? { ContactLabels.localized(label) }
}

/// A postal address with its label.
struct ContactAddress: Sendable, Hashable {
    var label: String?
    var street = ""
    var subLocality = ""
    var city = ""
    var subAdministrativeArea = ""
    var state = ""
    var postalCode = ""
    var country = ""
    var isoCountryCode = ""

    init(label: String? = nil, street: String = "", city: String = "", state: String = "", postalCode: String = "", country: String = "") {
        self.label = label
        self.street = street
        self.city = city
        self.state = state
        self.postalCode = postalCode
        self.country = country
    }

    init(label: String?, address: CNPostalAddress) {
        self.label = label
        street = address.street
        subLocality = address.subLocality
        city = address.city
        subAdministrativeArea = address.subAdministrativeArea
        state = address.state
        postalCode = address.postalCode
        country = address.country
        isoCountryCode = address.isoCountryCode
    }

    var postalAddress: CNPostalAddress {
        let address = CNMutablePostalAddress()
        address.street = street
        address.subLocality = subLocality
        address.city = city
        address.subAdministrativeArea = subAdministrativeArea
        address.state = state
        address.postalCode = postalCode
        address.country = country
        address.isoCountryCode = isoCountryCode
        return address
    }

    var localizedLabel: String? { ContactLabels.localized(label) }

    /// The address on one line, such as "165 Davis Street, Hillsborough CA 94010".
    var singleLine: String {
        CNPostalAddressFormatter.string(from: postalAddress, style: .mailingAddress)
            .split(whereSeparator: \.isNewline)
            .map { ContactNormalization.trimmed(String($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

/// Name parts, copied together so a name is never assembled from two different people.
struct ContactName: Sendable, Hashable {
    var prefix = ""
    var given = ""
    var middle = ""
    var family = ""
    var suffix = ""
}

/// What the cleanup needs to know about one contact, copied out of `CNContact` so it can cross actors.
struct ContactSnapshot: Sendable, Identifiable, Hashable {
    var id: String
    /// Position in the store's own order (fetched unsorted), which follows the order contacts were added: lower is older.
    var order: Int
    var isOrganization = false
    var name = ContactName()
    var nickname = ""
    var organization = ""
    var jobTitle = ""
    var phones: [ContactLabeledValue] = []
    var emails: [ContactLabeledValue] = []
    var addresses: [ContactAddress] = []
    var urls: [ContactLabeledValue] = []
    var birthday: DateComponents?
    var thumbnail: Data?
    var hasPhoto = false
    /// The name as Contacts shows it, in the person's preferred order ("Kate Bell"); empty when there's none.
    var formattedName = ""

    init(id: String, order: Int) {
        self.id = id
        self.order = order
    }

    /// Copies the keys in `ContactSnapshot.keysToFetch`; keys the contact wasn't fetched with stay empty.
    init(_ contact: CNContact, order: Int) {
        id = contact.identifier
        self.order = order
        func available(_ key: String) -> Bool { contact.isKeyAvailable(key) }
        if available(CNContactTypeKey) { isOrganization = contact.contactType == .organization }
        if available(CNContactNamePrefixKey) { name.prefix = contact.namePrefix }
        if available(CNContactGivenNameKey) { name.given = contact.givenName }
        if available(CNContactMiddleNameKey) { name.middle = contact.middleName }
        if available(CNContactFamilyNameKey) { name.family = contact.familyName }
        if available(CNContactNameSuffixKey) { name.suffix = contact.nameSuffix }
        if available(CNContactNicknameKey) { nickname = contact.nickname }
        if available(CNContactOrganizationNameKey) { organization = contact.organizationName }
        if available(CNContactJobTitleKey) { jobTitle = contact.jobTitle }
        if available(CNContactPhoneNumbersKey) {
            phones = contact.phoneNumbers.map { ContactLabeledValue(label: $0.label, value: $0.value.stringValue) }
        }
        if available(CNContactEmailAddressesKey) {
            emails = contact.emailAddresses.map { ContactLabeledValue(label: $0.label, value: $0.value as String) }
        }
        if available(CNContactPostalAddressesKey) {
            addresses = contact.postalAddresses.map { ContactAddress(label: $0.label, address: $0.value) }
        }
        if available(CNContactUrlAddressesKey) {
            urls = contact.urlAddresses.map { ContactLabeledValue(label: $0.label, value: $0.value as String) }
        }
        if available(CNContactBirthdayKey) { birthday = contact.birthday }
        if available(CNContactThumbnailImageDataKey) { thumbnail = contact.thumbnailImageData }
        if available(CNContactImageDataAvailableKey) { hasPhoto = contact.imageDataAvailable }
        if !hasPhoto, available(CNContactImageDataKey) { hasPhoto = contact.imageData != nil }
        if !hasPhoto { hasPhoto = thumbnail != nil }
        formattedName = Self.format(name, isOrganization: isOrganization, organization: organization)
    }

    /// Everything the scan reads. Not the note: reading it needs a special entitlement.
    static var keysToFetch: [CNKeyDescriptor] {
        [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)] + ([
            CNContactTypeKey, CNContactNamePrefixKey, CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey,
            CNContactNameSuffixKey, CNContactNicknameKey, CNContactOrganizationNameKey, CNContactJobTitleKey,
            CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactPostalAddressesKey, CNContactUrlAddressesKey,
            CNContactBirthdayKey, CNContactThumbnailImageDataKey, CNContactImageDataAvailableKey,
        ] as [CNKeyDescriptor])
    }

    /// Formats a name the way Contacts does, honoring the person's name-order setting.
    static func format(_ name: ContactName, isOrganization: Bool = false, organization: String = "") -> String {
        let contact = CNMutableContact()
        contact.contactType = isOrganization ? .organization : .person
        contact.namePrefix = name.prefix
        contact.givenName = name.given
        contact.middleName = name.middle
        contact.familyName = name.family
        contact.nameSuffix = name.suffix
        contact.organizationName = organization
        return CNContactFormatter.string(from: contact, style: .fullName).map(ContactNormalization.trimmed) ?? ""
    }

    // MARK: Derived values

    /// The person's name without the prefix ("Kate Bell Jr."); empty for a company card.
    var personName: String {
        [name.given, name.middle, name.family, name.suffix].map(ContactNormalization.trimmed).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Compared to find duplicates: the person's name, or the company name on a card without one.
    var nameKey: String? {
        let person = personName
        return ContactNormalization.name(person.isEmpty || isOrganization ? organization : person)
    }

    /// Whether Contacts shows a name for this card rather than a number or "No Name".
    var hasName: Bool {
        !personName.isEmpty || !ContactNormalization.trimmed(nickname).isEmpty || !ContactNormalization.trimmed(organization).isEmpty
    }

    /// What Contacts shows as the title of this card.
    var displayName: String {
        let candidates = [formattedName, personName, organization, nickname] + emails.map(\.value) + phones.map(\.value)
        return candidates.lazy.map(ContactNormalization.trimmed).first { !$0.isEmpty } ?? "No Name"
    }

    /// The job and company on one line ("Producer, Creative Consulting"); empty when there's neither.
    var workLine: String {
        [jobTitle, organization].map(ContactNormalization.trimmed).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Initials for an avatar without a photo, such as "KB"; empty when there's no name.
    var initials: String {
        let personParts = [name.given, name.family].map(ContactNormalization.trimmed).filter { !$0.isEmpty }
        let parts = personParts.isEmpty
            ? Array([organization, nickname].map(ContactNormalization.trimmed).filter { !$0.isEmpty }.prefix(1))
            : personParts
        return parts.compactMap(\.first).prefix(2).map { String($0).uppercased() }.joined()
    }

    /// How complete the card is: one point per filled-in field and per phone number, email, address and URL.
    var filledFieldCount: Int {
        let fields = [name.prefix, name.given, name.middle, name.family, name.suffix, nickname, organization, jobTitle]
        return fields.filter { !ContactNormalization.trimmed($0).isEmpty }.count + (birthday == nil ? 0 : 1)
            + phones.count + emails.count + addresses.count + urls.count
    }

    /// The first phone number or email, for lists ("(415) 555-3695 +2").
    var contactLine: String? {
        let values = (phones.map(\.value) + emails.map(\.value)).map(ContactNormalization.trimmed).filter { !$0.isEmpty }
        guard let first = values.first else { return nil }
        return values.count > 1 ? "\(first) +\(values.count - 1)" : first
    }
}

enum ContactLabels {
    /// "mobile", "home", or the custom label; nil when there's no label.
    static func localized(_ label: String?) -> String? {
        guard let label, !label.isEmpty else { return nil }
        return CNLabeledValue<NSString>.localizedString(forLabel: label)
    }
}
