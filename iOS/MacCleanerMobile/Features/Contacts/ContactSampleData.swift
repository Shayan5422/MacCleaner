#if DEBUG
import Contacts
import Foundation

/// Debug builds launched with `-seedSampleContacts` add a few look-alikes of the simulator's sample contacts once,
/// so duplicates and incomplete contacts can be checked by eye. Never compiled into release builds.
enum ContactSampleData {
    private static let seededKey = "ContactSampleDataSeeded"

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-seedSampleContacts") }

    @concurrent
    static func seedIfRequested() async {
        guard isRequested, !UserDefaults.standard.bool(forKey: seededKey) else { return }
        let request = CNSaveRequest()
        for contact in samples() {
            request.add(contact, toContainerWithIdentifier: nil)
        }
        do {
            try CNContactStore().execute(request)
            UserDefaults.standard.set(true, forKey: seededKey)
        } catch {
            print("Sample contacts weren't added: \(error)")
        }
    }

    private static func samples() -> [CNMutableContact] {
        func contact(given: String = "", family: String = "", organization: String = "", job: String = "",
                     phones: [(String, String)] = [], emails: [(String, String)] = [], urls: [String] = []) -> CNMutableContact {
            let contact = CNMutableContact()
            contact.givenName = given
            contact.familyName = family
            contact.organizationName = organization
            contact.jobTitle = job
            contact.phoneNumbers = phones.map { CNLabeledValue(label: $0.0, value: CNPhoneNumber(stringValue: $0.1)) }
            contact.emailAddresses = emails.map { CNLabeledValue(label: $0.0, value: $0.1 as NSString) }
            contact.urlAddresses = urls.map { CNLabeledValue(label: CNLabelURLAddressHomePage, value: $0 as NSString) }
            return contact
        }
        return [
            contact(given: "Kate", family: "Bell", phones: [(CNLabelPhoneNumberMobile, "+1 415-555-3695")],
                    emails: [(CNLabelHome, "kate.bell@example.com")]),
            contact(given: "Johnny", family: "Appleseed", organization: "Apple", job: "Engineer",
                    emails: [(CNLabelWork, "JOHN-APPLESEED@MAC.COM")]),
            contact(given: "Ánna", family: "Haro", phones: [(CNLabelPhoneNumberMobile, "555-522-8243")],
                    urls: ["https://annaharo.example.com"]),
            contact(given: "Hank", family: "Zakroff", emails: [(CNLabelWork, "hank-zakroff@mac.com")]),
            contact(given: "H.", family: "Zakroff", phones: [(CNLabelWork, "+1 707-555-1854"), (CNLabelPhoneNumberMobile, "+1 707-555-0199")]),
            contact(phones: [(CNLabelPhoneNumberMobile, "+1 (555) 610-6679")]),
            contact(emails: [(CNLabelHome, "pat@example.com")]),
            contact(given: "Sam", family: "Rivera", job: "Neighbor"),
        ]
    }
}
#endif
