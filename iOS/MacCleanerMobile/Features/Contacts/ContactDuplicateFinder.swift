import Foundation

/// Why contacts were grouped as duplicates.
enum ContactMatchReason: Int, Sendable, Hashable, CaseIterable, Comparable {
    case name, phone, email

    static func < (lhs: ContactMatchReason, rhs: ContactMatchReason) -> Bool { lhs.rawValue < rhs.rawValue }

    private var noun: String {
        switch self {
        case .name: return "name"
        case .phone: return "phone number"
        case .email: return "email"
        }
    }

    /// "Same phone number", "Same name and email", "Same name, phone number and email".
    static func sentence(for reasons: Set<ContactMatchReason>) -> String {
        let nouns = reasons.sorted().map(\.noun)
        switch nouns.count {
        case 0: return "Look alike"
        case 1: return "Same \(nouns[0])"
        default: return "Same \(nouns.dropLast().joined(separator: ", ")) and \(nouns[nouns.count - 1])"
        }
    }
}

/// Contacts that look like the same person.
struct ContactDuplicateGroup: Sendable, Identifiable, Hashable {
    /// Best first: the card a merge keeps (see `ContactMergePlanner.ranked`).
    var contacts: [ContactSnapshot]
    var reasons: Set<ContactMatchReason>

    var id: String { contacts.map(\.id).sorted().joined(separator: "|") }
    var primary: ContactSnapshot { contacts[0] }
    /// The cards a merge would remove.
    var duplicateCount: Int { contacts.count - 1 }
    var reasonText: String { ContactMatchReason.sentence(for: reasons) }
}

/// What's missing from an incomplete contact.
enum ContactIssue: Sendable, Hashable, CaseIterable {
    /// Only a number, an email, or nothing at all: Phone and Messages show the number instead of a name.
    case noName
    /// A name but no way to call or write.
    case noPhoneOrEmail
}

struct IncompleteContact: Sendable, Identifiable, Hashable {
    var contact: ContactSnapshot
    var issue: ContactIssue
    var id: String { contact.id }
}

/// Finds duplicate and incomplete contacts. Pure functions over snapshots: nothing here reads or changes the store.
enum ContactDuplicateFinder {
    /// Groups of two or more contacts that share a name, a phone number or an email, directly or through
    /// another contact in the group (union-find), sorted by name.
    static func groups(in contacts: [ContactSnapshot]) -> [ContactDuplicateGroup] {
        var sets = DisjointSets(count: contacts.count)
        var links: [(index: Int, reason: ContactMatchReason)] = []

        func linkAll(_ indices: [Int], _ reason: ContactMatchReason) {
            guard let first = indices.first else { return }
            for index in indices.dropFirst() where index != first {
                sets.union(first, index)
                links.append((first, reason))
            }
        }

        var byName: [String: [Int]] = [:]
        var byEmail: [String: [Int]] = [:]
        var byPhoneBucket: [String: [(index: Int, digits: String)]] = [:]
        for (index, contact) in contacts.enumerated() {
            if let key = contact.nameKey {
                byName[key, default: []].append(index)
            }
            for email in Set(contact.emails.compactMap { ContactNormalization.email($0.value) }) {
                byEmail[email, default: []].append(index)
            }
            for digits in Set(contact.phones.map { ContactNormalization.significantDigits($0.value) }) {
                if let bucket = ContactNormalization.phoneBucket(digits) {
                    byPhoneBucket[bucket, default: []].append((index, digits))
                }
            }
        }

        for indices in byName.values where indices.count > 1 { linkAll(indices, .name) }
        for indices in byEmail.values where indices.count > 1 { linkAll(indices, .email) }
        for entries in byPhoneBucket.values where entries.count > 1 {
            for first in entries.indices {
                for second in entries.indices[(first + 1)...] where entries[first].index != entries[second].index {
                    guard ContactNormalization.significantDigitsMatch(entries[first].digits, entries[second].digits) else { continue }
                    sets.union(entries[first].index, entries[second].index)
                    links.append((entries[first].index, .phone))
                }
            }
        }

        var members: [Int: [Int]] = [:]
        for index in contacts.indices {
            members[sets.find(index), default: []].append(index)
        }
        var reasons: [Int: Set<ContactMatchReason>] = [:]
        for link in links {
            reasons[sets.find(link.index), default: []].insert(link.reason)
        }

        return members.compactMap { root, indices -> ContactDuplicateGroup? in
            guard indices.count > 1 else { return nil }
            return ContactDuplicateGroup(contacts: ContactMergePlanner.ranked(indices.map { contacts[$0] }), reasons: reasons[root] ?? [])
        }
        .sorted { lhs, rhs in
            let order = lhs.primary.displayName.localizedStandardCompare(rhs.primary.displayName)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    /// Contacts without a name, and contacts with a name but no phone number or email, sorted by name.
    static func incomplete(in contacts: [ContactSnapshot]) -> [IncompleteContact] {
        contacts.compactMap { contact -> IncompleteContact? in
            if !contact.hasName { return IncompleteContact(contact: contact, issue: .noName) }
            if contact.phones.isEmpty && contact.emails.isEmpty { return IncompleteContact(contact: contact, issue: .noPhoneOrEmail) }
            return nil
        }
        .sorted { lhs, rhs in
            let order = lhs.contact.displayName.localizedStandardCompare(rhs.contact.displayName)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }
}

extension ContactDuplicateFinder {
    /// Union-find with path compression and union by rank.
    fileprivate struct DisjointSets {
        private var parent: [Int]
        private var rank: [UInt8]

        init(count: Int) {
            parent = Array(0..<count)
            rank = Array(repeating: 0, count: count)
        }

        mutating func find(_ element: Int) -> Int {
            var root = element
            while parent[root] != root { root = parent[root] }
            var node = element
            while parent[node] != root {
                let next = parent[node]
                parent[node] = root
                node = next
            }
            return root
        }

        mutating func union(_ first: Int, _ second: Int) {
            let firstRoot = find(first), secondRoot = find(second)
            guard firstRoot != secondRoot else { return }
            if rank[firstRoot] < rank[secondRoot] {
                parent[firstRoot] = secondRoot
            } else if rank[firstRoot] > rank[secondRoot] {
                parent[secondRoot] = firstRoot
            } else {
                parent[secondRoot] = firstRoot
                rank[firstRoot] += 1
            }
        }
    }
}
