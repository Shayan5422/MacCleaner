import Contacts
import Foundation
import Testing
@testable import MacCleanerMobile

/// In-memory contacts for the Contacts tests; nothing here touches the contact store.
enum ContactFixtures {
    static func contact(_ given: String = "", _ family: String = "", nickname: String = "", organization: String = "",
                        job: String = "", phones: [String] = [], emails: [String] = [], urls: [String] = [],
                        addresses: [CNPostalAddress] = [], birthday: DateComponents? = nil, photo: Data? = nil) -> CNMutableContact {
        let contact = CNMutableContact()
        contact.givenName = given
        contact.familyName = family
        contact.nickname = nickname
        contact.organizationName = organization
        contact.jobTitle = job
        contact.phoneNumbers = phones.map { CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: $0)) }
        contact.emailAddresses = emails.map { CNLabeledValue(label: CNLabelHome, value: $0 as NSString) }
        contact.urlAddresses = urls.map { CNLabeledValue(label: CNLabelURLAddressHomePage, value: $0 as NSString) }
        contact.postalAddresses = addresses.map { CNLabeledValue(label: CNLabelWork, value: $0) }
        contact.birthday = birthday
        contact.imageData = photo
        return contact
    }

    /// Snapshots in the given order, which stands for the order the contacts were added.
    static func snapshots(_ contacts: [CNContact]) -> [ContactSnapshot] {
        contacts.enumerated().map { ContactSnapshot($1, order: $0) }
    }

    static func address(_ street: String, _ city: String) -> CNPostalAddress {
        let address = CNMutablePostalAddress()
        address.street = street
        address.city = city
        return address
    }
}

struct ContactDuplicateFinderTests {
    private typealias F = ContactFixtures

    @Test func sameNameIgnoringCaseDiacriticsAndSpaces() {
        let contacts = F.snapshots([F.contact("José", "Álvarez", phones: ["555-0100"]), F.contact("jose", " alvarez", emails: ["j@example.com"]),
                                    F.contact("Kate", "Bell")])
        let groups = ContactDuplicateFinder.groups(in: contacts)
        #expect(groups.count == 1)
        #expect(Set(groups[0].contacts.map(\.id)) == Set(contacts.prefix(2).map(\.id)))
        #expect(groups[0].reasons == [.name])
        #expect(groups[0].reasonText == "Same name")
    }

    @Test func samePhoneNumberAcrossFormatsAndCountryPrefixes() {
        let contacts = F.snapshots([F.contact("Kate", "Bell", phones: ["(415) 555-3695"]), F.contact("K.", "Bell", phones: ["+1 415-555-3695"]),
                                    F.contact("Kim", "Bell", phones: ["(312) 555-3695"])])
        let groups = ContactDuplicateFinder.groups(in: contacts)
        #expect(groups.count == 1)
        #expect(groups[0].contacts.count == 2)
        #expect(!groups[0].contacts.contains { $0.name.given == "Kim" })
        #expect(groups[0].reasonText == "Same phone number")
    }

    @Test func sameEmailIgnoringCase() {
        let contacts = F.snapshots([F.contact("John", "Appleseed", emails: ["John-Appleseed@mac.com"]),
                                    F.contact("Johnny", emails: [" john-appleseed@MAC.com "])])
        let groups = ContactDuplicateFinder.groups(in: contacts)
        #expect(groups.count == 1)
        #expect(groups[0].reasons == [.email])
    }

    @Test func groupsJoinThroughSharedDetails() {
        // A and B share a phone number, B and C an email: one group of three.
        let contacts = F.snapshots([F.contact("Hank", "Zakroff", phones: ["707-555-1854"]),
                                    F.contact("H.", "Z.", phones: ["+1 707 555 1854"], emails: ["hank@example.com"]),
                                    F.contact("Henry", "Zakroff", emails: ["HANK@example.com"]),
                                    F.contact("Anna", "Haro", phones: ["555-522-8243"])])
        let groups = ContactDuplicateFinder.groups(in: contacts)
        #expect(groups.count == 1)
        #expect(groups[0].contacts.count == 3)
        #expect(groups[0].duplicateCount == 2)
        #expect(groups[0].reasons == [.phone, .email])
        #expect(groups[0].reasonText == "Same phone number and email")
    }

    @Test func differentPeopleStayApart() {
        let contacts = F.snapshots([F.contact(phones: ["555-0100"]), F.contact(phones: ["555-0199"]),
                                    F.contact("Ann", "Lee", phones: ["212-555-0123"]), F.contact("Bob", "Lee", phones: ["312-555-0123"]),
                                    F.contact(emails: ["a@example.com"]), F.contact(emails: ["b@example.com"])])
        #expect(ContactDuplicateFinder.groups(in: contacts).isEmpty)
    }

    @Test func oneCardWithTheSameNumberTwiceIsNotADuplicate() {
        let contacts = F.snapshots([F.contact("Kate", "Bell", phones: ["(415) 555-3695", "+1 415 555 3695"])])
        #expect(ContactDuplicateFinder.groups(in: contacts).isEmpty)
    }

    @Test func companyCardsMatchByCompanyName() {
        let first = F.contact(organization: "Creative Consulting", phones: ["555-0100"])
        first.contactType = .organization
        let contacts = F.snapshots([first, F.contact(organization: "creative consulting")])
        #expect(ContactDuplicateFinder.groups(in: contacts).count == 1)
    }

    @Test func theCardWithTheMostDetailsComesFirst() {
        let contacts = F.snapshots([F.contact("Kate", "Bell"), F.contact("Kate", "Bell", phones: ["555-0100"], emails: ["kate@example.com"])])
        let group = ContactDuplicateFinder.groups(in: contacts)[0]
        #expect(group.primary.id == contacts[1].id)
    }

    @Test func incompleteContacts() {
        let contacts = F.snapshots([
            F.contact(phones: ["555-0100"]),
            F.contact(emails: ["pat@example.com"]),
            F.contact(),
            F.contact("Sam", "Rivera", job: "Neighbor"),
            F.contact("Kate", "Bell", phones: ["555-0101"]),
            F.contact(nickname: "Mom", phones: ["555-0102"]),
            F.contact(organization: "Pizza Place", phones: ["555-0103"]),
        ])
        let incomplete = ContactDuplicateFinder.incomplete(in: contacts)
        #expect(Set(incomplete.filter { $0.issue == .noName }.map(\.id)) == Set([contacts[0].id, contacts[1].id, contacts[2].id]))
        #expect(incomplete.filter { $0.issue == .noPhoneOrEmail }.map(\.id) == [contacts[3].id])
    }

    @Test func matchReasonsReadAsSentences() {
        #expect(ContactMatchReason.sentence(for: [.email, .name]) == "Same name and email")
        #expect(ContactMatchReason.sentence(for: [.phone, .email, .name]) == "Same name, phone number and email")
    }

    @MainActor
    @Test func summaryCountsDuplicatesAndIncompleteContacts() {
        let model = ContactCleanupModel()
        #expect(model.issueCount == nil)
        #expect(model.summary == nil)
        model.apply(scan: F.snapshots([F.contact("Kate", "Bell", phones: ["555-0100"]), F.contact("Kate", "Bell", phones: ["555-0100"]),
                                       F.contact("Kate", "Bell"), F.contact(phones: ["555-0199"])]), at: Date())
        // Three Kate Bells (one without a phone or email, so also incomplete) and a card with only a number.
        #expect(model.duplicateCount == 2)
        #expect(model.incompleteContacts.count == 2)
        #expect(model.summary == "2 duplicates and 2 incomplete contacts")
        #expect(model.issueCount == 3)
        model.apply(scan: F.snapshots([F.contact(phones: ["555-0100"])]), at: Date())
        #expect(model.summary == "1 incomplete contact")
        model.apply(scan: F.snapshots([F.contact("Kate", "Bell", phones: ["555-0100"])]), at: Date())
        #expect(model.summary == "No duplicate or incomplete contacts")
        #expect(model.issueCount == 0)
    }
}
