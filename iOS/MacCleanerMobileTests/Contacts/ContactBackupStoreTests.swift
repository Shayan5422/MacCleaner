import Contacts
import Foundation
import Testing
import UIKit
@testable import MacCleanerMobile

struct ContactBackupStoreTests {
    private typealias F = ContactFixtures

    private func temporaryStore(limit: Int = 20) throws -> ContactBackupStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ContactBackupTests-\(UUID().uuidString)", isDirectory: true)
        return ContactBackupStore(directory: directory, limit: limit)
    }

    private func removeStore(_ store: ContactBackupStore) {
        try? FileManager.default.removeItem(at: store.directory)
    }

    private func photo() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        return try #require(image.jpegData(compressionQuality: 0.8))
    }

    @Test func vCardRoundTripKeepsTheDetailsAndThePhoto() throws {
        let store = try temporaryStore()
        defer { removeStore(store) }
        let photo = try photo()
        let kate = F.contact("Kate", "Bell", organization: "Creative Consulting", job: "Producer",
                             phones: ["(555) 564-8583", "(415) 555-3695"], emails: ["kate-bell@mac.com"], urls: ["www.icloud.com"],
                             addresses: [F.address("165 Davis Street", "Hillsborough")],
                             birthday: DateComponents(year: 1978, month: 1, day: 20), photo: photo)
        let nameless = F.contact(phones: ["+1 (555) 610-6679"])

        let backup = try store.save([kate, nameless], kind: .merge)
        #expect(backup.contactCount == 2)
        #expect(backup.title == "Before merging 2 contacts")
        #expect(FileManager.default.fileExists(atPath: backup.url.path))

        let listed = store.backups()
        #expect(listed.map(\.url) == [backup.url])
        #expect(listed.first?.kind == .merge)
        #expect(listed.first?.contactCount == 2)

        let restored = try store.contacts(in: try #require(listed.first))
        #expect(restored.count == 2)
        let restoredKate = try #require(restored.first { $0.givenName == "Kate" })
        #expect(restoredKate.familyName == "Bell")
        #expect(restoredKate.organizationName == "Creative Consulting")
        #expect(restoredKate.jobTitle == "Producer")
        #expect(restoredKate.phoneNumbers.map(\.value.stringValue) == ["(555) 564-8583", "(415) 555-3695"])
        #expect(restoredKate.emailAddresses.map { $0.value as String } == ["kate-bell@mac.com"])
        #expect(restoredKate.urlAddresses.map { $0.value as String } == ["www.icloud.com"])
        #expect(restoredKate.postalAddresses.first?.value.street == "165 Davis Street")
        #expect(restoredKate.birthday?.year == 1978)
        #expect(restoredKate.birthday?.month == 1)
        #expect(restoredKate.imageData == photo)
        #expect(restored.contains { $0.phoneNumbers.first?.value.stringValue == "+1 (555) 610-6679" && $0.givenName.isEmpty })
    }

    @Test func photoLinesAreFoldedForVCard() throws {
        let lines = ContactBackupStore.photoLines(for: Data(repeating: 0xAB, count: 600)).components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines.count > 2)
        #expect(lines[0].hasPrefix("PHOTO;ENCODING=b;TYPE=JPEG:"))
        #expect(lines.allSatisfy { $0.utf8.count <= 75 })
        #expect(lines.dropFirst().allSatisfy { $0.hasPrefix(" ") })
        let base64 = lines[0].dropFirst("PHOTO;ENCODING=b;TYPE=JPEG:".count) + lines.dropFirst().map { $0.dropFirst() }.joined()
        #expect(Data(base64Encoded: String(base64)) == Data(repeating: 0xAB, count: 600))
    }

    @Test func fileNamesCarryTheDateAndKind() throws {
        let store = try temporaryStore()
        defer { removeStore(store) }
        let date = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 14, minute: 32, second: 5)))
        let first = try store.save([F.contact("Kate", "Bell")], kind: .delete, date: date)
        let second = try store.save([F.contact("Kate", "Bell")], kind: .delete, date: date)
        #expect(first.url.lastPathComponent == "Contacts Backup 2026-10-18 at 14.32.05 (Delete).vcf")
        #expect(second.url.lastPathComponent == "Contacts Backup 2026-10-18 at 14.32.05 (Delete) 2.vcf")
        #expect(first.title == "Before deleting 1 contact")
        #expect(store.backups().count == 2)
    }

    @Test func keepsOnlyTheNewestBackups() throws {
        let store = try temporaryStore()
        defer { removeStore(store) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let dates = (0..<25).map { start.addingTimeInterval(Double($0) * 60) }
        for date in dates {
            try store.save([F.contact("Kate", "Bell", phones: ["555-0100"])], kind: .merge, date: date)
        }
        let backups = store.backups()
        #expect(backups.count == 20)
        #expect(backups.map(\.date) == Array(dates.suffix(20).reversed()))
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory.path).filter { $0.hasSuffix(".vcf") }
        #expect(files.count == 20)
    }

    @Test func pruningHonorsTheLimit() throws {
        let store = try temporaryStore(limit: 3)
        defer { removeStore(store) }
        for minute in 0..<5 {
            try store.save([F.contact("Kate")], kind: .delete, date: Date(timeIntervalSince1970: 1_800_000_000 + Double(minute) * 60))
        }
        #expect(store.backups().count == 3)
        #expect(store.backups().first?.date == Date(timeIntervalSince1970: 1_800_000_000 + 240))
    }

    @Test func aMissingFolderHasNoBackups() throws {
        let store = try temporaryStore()
        #expect(store.backups().isEmpty)
        #expect(throws: Never.self) { try store.prune() }
    }
}
