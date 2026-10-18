import Contacts
import Foundation
import Testing
@testable import MacCleanerMobile

struct ContactMergePlannerTests {
    private typealias F = ContactFixtures

    @Test func keepsTheCardWithTheMostDetails() throws {
        let contacts = F.snapshots([F.contact("Kate", "Bell", phones: ["555-0100"]),
                                    F.contact("Kate", "Bell", phones: ["555-0100", "555-0101"], emails: ["kate@example.com"])])
        let plan = try #require(ContactMergePlanner.plan(merging: contacts))
        #expect(plan.primaryID == contacts[1].id)
        #expect(plan.removedIDs == [contacts[0].id])
        #expect(plan.contactCount == 2)
    }

    @Test func tiesGoToThePhotoThenTheOldest() throws {
        let plain = F.snapshots([F.contact("Kate", "Bell", phones: ["555-0100"]), F.contact("Kate", "Bell", phones: ["555-0100"])])
        #expect(try #require(ContactMergePlanner.plan(merging: plain)).primaryID == plain[0].id)
        #expect(try #require(ContactMergePlanner.plan(merging: plain.reversed())).primaryID == plain[0].id)

        let withPhoto = F.snapshots([F.contact("Kate", "Bell", phones: ["555-0100"]),
                                     F.contact("Kate", "Bell", phones: ["555-0100"], photo: Data([0xFF, 0xD8, 0xFF, 0xE0]))])
        #expect(withPhoto[1].hasPhoto)
        #expect(try #require(ContactMergePlanner.plan(merging: withPhoto)).primaryID == withPhoto[1].id)
    }

    @Test func addsOnlyTheDetailsTheKeptCardLacks() throws {
        // 11 fields against the other card's 10, so this one is kept.
        let kept = F.contact("Kate", "Bell", nickname: "Katie", organization: "Creative Consulting", job: "Producer",
                             phones: ["(415) 555-3695", "555-0100"], emails: ["kate@example.com"],
                             urls: ["https://www.example.com/"], addresses: [F.address("165 Davis Street", "Hillsborough")],
                             birthday: DateComponents(year: 1978, month: 1, day: 20))
        let other = F.contact("Kate", "Bell", phones: ["+1 415 555 3695", "555-0199"], emails: ["KATE@example.com ", "k.bell@example.com"],
                              urls: ["example.com", "kate.example.com"],
                              addresses: [F.address("165 davis street", "HILLSBOROUGH"), F.address("1 Infinite Loop", "Cupertino")])
        let contacts = F.snapshots([kept, other])
        let plan = try #require(ContactMergePlanner.plan(merging: contacts))
        #expect(plan.primaryID == contacts[0].id)
        #expect(plan.addedPhones.map(\.value) == ["555-0199"])
        #expect(plan.addedEmails.map(\.value) == ["k.bell@example.com"])
        #expect(plan.addedURLs.map(\.value) == ["kate.example.com"])
        #expect(plan.addedAddresses.map(\.street) == ["1 Infinite Loop"])
        #expect(plan.merged.phones.count == 3)
        #expect(plan.merged.emails.count == 2)
        #expect(plan.addedPhones.first?.label == CNLabelPhoneNumberMobile)
    }

    @Test func fillsInTheMissingCompanyJobAndBirthdayOnly() throws {
        let birthday = DateComponents(year: 1978, month: 1, day: 20)
        let kept = F.contact("Kate", "Bell", organization: "Creative Consulting", phones: ["555-0100", "555-0101"])
        let other = F.contact("Kate", "Bell", organization: "Other Company", job: "Producer", birthday: birthday)
        let plan = try #require(ContactMergePlanner.plan(merging: F.snapshots([kept, other])))
        #expect(plan.organization == nil)
        #expect(plan.merged.organization == "Creative Consulting")
        #expect(plan.jobTitle == "Producer")
        #expect(plan.birthday == birthday)
        #expect(plan.merged.birthday == birthday)
        #expect(plan.changesPrimary)
    }

    @Test func aNamelessKeptCardGetsTheOtherName() throws {
        let nameless = F.contact(phones: ["555-0100", "555-0101", "555-0102"])
        let named = F.contact("David", "Taylor", phones: ["555-0100"])
        let contacts = F.snapshots([nameless, named])
        let plan = try #require(ContactMergePlanner.plan(merging: contacts))
        #expect(plan.primaryID == contacts[0].id)
        #expect(plan.name?.given == "David")
        #expect(plan.merged.displayName == "David Taylor")
    }

    @Test func aMergeThatOnlyDeletesDoesntTouchTheKeptCard() throws {
        let contacts = F.snapshots([F.contact("Kate", "Bell", phones: ["555-0100"], emails: ["kate@example.com"]),
                                    F.contact("Kate", "Bell", phones: ["555-0100"])])
        let plan = try #require(ContactMergePlanner.plan(merging: contacts))
        #expect(!plan.changesPrimary)
        #expect(plan.merged == contacts[0])
    }

    @Test func needsTwoContacts() {
        #expect(ContactMergePlanner.plan(merging: F.snapshots([F.contact("Kate")])) == nil)
        #expect(ContactMergePlanner.plan(merging: []) == nil)
    }

    /// A card with every kind of detail and a photo; 8 fields.
    private static func detailedKate(photo: Data) -> CNMutableContact {
        F.contact("Kate", "Bell", job: "Producer", phones: ["555-0199"], emails: ["kate@example.com"], urls: ["kate.example.com"],
                  addresses: [F.address("1 Infinite Loop", "Cupertino")], birthday: DateComponents(month: 1, day: 20), photo: photo)
    }

    @Test func applyingThePlanGivesThePreviewedCard() throws {
        let kept = Self.detailedKate(photo: Data([0xFF, 0xD8, 0xFF, 0xE0]))
        let other = F.contact("Kate", "Bell", phones: ["555-0100", "555-0101"])
        let contacts = F.snapshots([other, kept])
        let plan = try #require(ContactMergePlanner.plan(merging: contacts))
        #expect(plan.primaryID == contacts[1].id)

        let saved = try #require(kept.mutableCopy() as? CNMutableContact)
        ContactMergePlanner.apply(plan, to: saved, photo: nil)
        #expect(ContactSnapshot(saved, order: contacts[1].order) == plan.merged)
        #expect(saved.phoneNumbers.map(\.value.stringValue) == ["555-0199", "555-0100", "555-0101"])
    }

    @Test func aKeptCardWithoutAPhotoGetsTheOtherPhoto() throws {
        let photo = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01])
        let other = Self.detailedKate(photo: photo)
        // 9 fields, so it's kept even though it has no photo.
        let kept = F.contact("Kate", "Bell", phones: ["555-0100", "555-0101", "555-0102", "555-0103"],
                             emails: ["a@example.com", "b@example.com", "c@example.com"])
        let contacts = F.snapshots([kept, other])
        let plan = try #require(ContactMergePlanner.plan(merging: contacts))
        #expect(plan.primaryID == contacts[0].id)
        #expect(plan.photoSourceID == contacts[1].id)
        #expect(plan.merged.hasPhoto)

        let saved = try #require(kept.mutableCopy() as? CNMutableContact)
        ContactMergePlanner.apply(plan, to: saved, photo: photo)
        #expect(saved.imageData == photo)
        #expect(saved.jobTitle == "Producer")
        #expect(saved.birthday == DateComponents(month: 1, day: 20))
        #expect(saved.postalAddresses.map(\.value.street) == ["1 Infinite Loop"])
        #expect(saved.emailAddresses.count == 4)
    }
}
