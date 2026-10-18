import SwiftUI
import UIKit

/// A contact's photo, or their initials on gray like in Contacts.
struct ContactAvatarView: View {
    var contact: ContactSnapshot
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            if let image = ContactThumbnails.image(for: contact) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(white: 0.68), Color(white: 0.54)], startPoint: .top, endPoint: .bottom)
                if contact.initials.isEmpty {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.48))
                        .foregroundStyle(.white)
                        .offset(y: size * 0.06)
                } else {
                    Text(contact.initials)
                        .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.5)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// Decoded thumbnails, so scrolling a list doesn't decode the same photo again.
@MainActor
enum ContactThumbnails {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(for contact: ContactSnapshot) -> UIImage? {
        guard let data = contact.thumbnail else { return nil }
        let key = "\(contact.id)#\(data.count)#\(data.hashValue)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Two avatars of a duplicate group, one behind the other like a group in Messages.
struct ContactAvatarStack: View {
    var contacts: [ContactSnapshot]
    var size: CGFloat = 44

    var body: some View {
        let small = (size * 0.72).rounded()
        ZStack {
            if contacts.count > 1 {
                ContactAvatarView(contact: contacts[1], size: small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if let first = contacts.first {
                    ContactAvatarView(contact: first, size: small)
                        .background(Circle().fill(Color(.secondarySystemGroupedBackground)).padding(-2))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            } else if let first = contacts.first {
                ContactAvatarView(contact: first, size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A row for a duplicate group: the avatars, the name and why the cards match.
struct ContactGroupRow: View {
    var group: ContactDuplicateGroup
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 44

    var body: some View {
        HStack(spacing: 14) {
            ContactAvatarStack(contacts: group.contacts, size: min(avatarSize, 60))
            VStack(alignment: .leading, spacing: 2) {
                Text(group.primary.displayName).font(.body.weight(.medium)).lineLimit(2)
                Text("\(NumberFormatting.count(group.contacts.count, "card")) · \(group.reasonText)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A small capsule such as "Kept" or "Added".
struct ContactBadge: View {
    var title: String
    var tint: Color = MobileSection.contacts.tint

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// A selection circle like in Mail and Photos.
struct ContactSelectionMark: View {
    var isSelected: Bool
    var tint: Color = MobileSection.contacts.tint

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? tint : Color(.tertiaryLabel))
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }
}

/// A done message at the top of a list, with a button to dismiss it.
struct ContactNoticeView: View {
    var notice: ContactNotice
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title).font(.subheadline.weight(.semibold))
                Text(notice.message).font(.footnote).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(7)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(.vertical, 2)
    }
}

/// The button at the bottom of a screen that saves a change: "Merge 3 Contacts", "Delete 2 Contacts".
struct ContactActionBar: View {
    var title: String
    var role: ButtonRole?
    var tint: Color
    var isBusy: Bool
    var action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 8) {
                if isBusy { ProgressView().tint(.white) }
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(tint)
        .disabled(isBusy)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// A list row with a selection circle, an avatar, the name and one more line.
struct SelectableContactRow: View {
    var contact: ContactSnapshot
    var detail: String
    var isSelected: Bool
    var toggle: () -> Void
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 38

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                ContactSelectionMark(isSelected: isSelected, tint: .red)
                ContactAvatarView(contact: contact, size: min(avatarSize, 54))
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.displayName).font(.body).foregroundStyle(.primary).lineLimit(1)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Shows the model's error message from whichever Contacts page is on screen, so it's never hidden behind another page.
struct ContactErrorAlert: ViewModifier {
    var model: ContactCleanupModel
    @State private var isOnScreen = false

    func body(content: Content) -> some View {
        content
            .onAppear { isOnScreen = true }
            .onDisappear { isOnScreen = false }
            .alert("Couldn't Finish",
                   isPresented: Binding(get: { isOnScreen && model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
    }
}

enum ContactFormatting {
    /// "January 20, 1978", or "January 20" when the year isn't known.
    static func birthday(_ components: DateComponents) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        var parts = components
        let hasYear = parts.year != nil && parts.year != NSDateComponentUndefined
        if !hasYear { parts.year = 2000 }
        parts.calendar = calendar
        parts.timeZone = .gmt
        guard let date = calendar.date(from: parts) else { return nil }
        var style = Date.FormatStyle(timeZone: .gmt).month(.wide).day()
        if hasYear { style = style.year() }
        return date.formatted(style)
    }
}
