import Contacts
import Foundation

/// Why a backup was saved.
enum ContactBackupKind: String, Sendable, Hashable {
    case merge = "Merge"
    case delete = "Delete"
}

/// A vCard file saved before contacts were merged or deleted.
struct ContactBackup: Sendable, Identifiable, Hashable {
    var url: URL
    var date: Date
    var kind: ContactBackupKind?
    var contactCount: Int

    var id: URL { url }

    /// "Before merging 3 contacts", "Before deleting 1 contact".
    var title: String {
        let contacts = NumberFormatting.count(contactCount, "contact")
        switch kind {
        case .merge: return "Before merging \(contacts)"
        case .delete: return "Before deleting \(contacts)"
        case nil: return "Backup of \(contacts)"
        }
    }
}

/// Saves the contacts a change affects as a vCard file in Application Support/ContactBackups, lists the backups,
/// keeps the last 20 and reads them back.
struct ContactBackupStore: Sendable {
    var directory: URL
    var limit = 20

    static var standard: ContactBackupStore {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return ContactBackupStore(directory: support.appendingPathComponent("ContactBackups", isDirectory: true))
    }

    /// The keys a contact must be fetched with to be backed up completely, photo included.
    static var keysToFetch: [CNKeyDescriptor] {
        [CNContactVCardSerialization.descriptorForRequiredKeys(), CNContactImageDataKey as CNKeyDescriptor]
    }

    /// Writes the contacts to a new vCard file named after the date, then removes the oldest backups beyond `limit`.
    @discardableResult
    func save(_ contacts: [CNContact], kind: ContactBackupKind, date: Date = Date()) throws -> ContactBackup {
        let data = try Self.vCardData(for: contacts)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = uniqueURL(for: date, kind: kind)
        try data.write(to: url, options: .atomic)
        // The list is sorted by this date, so a backup made in the same second as another still sorts in order.
        try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
        try? prune()
        return ContactBackup(url: url, date: date, kind: kind, contactCount: contacts.count)
    }

    /// The backups, newest first.
    func backups() -> [ContactBackup] {
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                                                                      options: .skipsHiddenFiles) else { return [] }
        return urls.filter { $0.pathExtension.lowercased() == "vcf" }
            .map { url in
                let values = try? url.resourceValues(forKeys: keys)
                return ContactBackup(url: url, date: values?.creationDate ?? values?.contentModificationDate ?? .distantPast,
                                     kind: Self.kind(fromFileName: url.lastPathComponent), contactCount: Self.cardCount(at: url))
            }
            .sorted { $0.date != $1.date ? $0.date > $1.date : $0.url.lastPathComponent > $1.url.lastPathComponent }
    }

    /// Removes the oldest backups beyond `limit`.
    func prune() throws {
        for backup in backups().dropFirst(limit) {
            try FileManager.default.removeItem(at: backup.url)
        }
    }

    /// The contacts in a backup. They're new contacts: they don't keep their old identifiers.
    func contacts(in backup: ContactBackup) throws -> [CNContact] {
        try CNContactVCardSerialization.contacts(with: Data(contentsOf: backup.url))
    }

    // MARK: vCard

    /// vCard 3.0 data for the contacts. `CNContactVCardSerialization` leaves photos out, so each card's photo is added
    /// as a PHOTO line, which it reads back.
    static func vCardData(for contacts: [CNContact]) throws -> Data {
        var data = Data()
        for contact in contacts {
            var card = try CNContactVCardSerialization.data(with: [contact])
            if contact.isKeyAvailable(CNContactImageDataKey), let photo = contact.imageData, !photo.isEmpty,
               var text = String(data: card, encoding: .utf8), let end = text.range(of: "END:VCARD", options: .backwards) {
                text.insert(contentsOf: photoLines(for: photo), at: end.lowerBound)
                card = Data(text.utf8)
            }
            data.append(card)
        }
        return data
    }

    /// "PHOTO;ENCODING=b;TYPE=JPEG:…", folded into lines of 75 characters as vCard requires.
    static func photoLines(for photo: Data) -> String {
        var remaining = Substring("PHOTO;ENCODING=b;TYPE=\(imageType(of: photo)):" + photo.base64EncodedString())
        var folded = ""
        var isFirstLine = true
        while !remaining.isEmpty {
            let length = isFirstLine ? 75 : 74
            folded += (isFirstLine ? "" : " ") + remaining.prefix(length) + "\r\n"
            remaining = remaining.dropFirst(length)
            isFirstLine = false
        }
        return folded
    }

    private static func imageType(of data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "PNG" }
        if data.count > 12, data.dropFirst(4).prefix(8).elementsEqual("ftypheic".utf8) { return "HEIC" }
        return "JPEG"
    }

    // MARK: File names

    /// "Contacts Backup 2026-10-18 at 14.32.05 (Merge).vcf", with a number added when the name is taken.
    private func uniqueURL(for date: Date, kind: ContactBackupKind) -> URL {
        let base = "Contacts Backup \(Self.fileStamp(for: date)) (\(kind.rawValue))"
        var url = directory.appendingPathComponent(base + ".vcf")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(number).vcf")
            number += 1
        }
        return url
    }

    /// "2026-10-18 at 14.32.05": no colons, which Files shows as slashes.
    static func fileStamp(for date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d at %02d.%02d.%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    static func kind(fromFileName name: String) -> ContactBackupKind? {
        if name.contains("(\(ContactBackupKind.merge.rawValue))") { return .merge }
        if name.contains("(\(ContactBackupKind.delete.rawValue))") { return .delete }
        return nil
    }

    /// The number of cards in a vCard file. Base64 photo data can't contain a colon, so this never miscounts.
    static func cardCount(at url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return text.components(separatedBy: "BEGIN:VCARD").count - 1
    }
}
