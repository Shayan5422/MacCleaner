import SwiftUI

/// Capsule-shaped filter button with an optional count (used by Uninstaller and Updates).
struct UninstallerFilterChip: View {
    var title: String
    var symbol: String
    var count: Int?
    var isSelected: Bool
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).imageScale(.small)
                Text(title)
                if let count {
                    Text(NumberFormatting.count(count))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(Capsule().fill(isSelected ? tint : Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Checkbox showing "all", "none" or "some" for a group of items.
struct UninstallerTriStateCheckbox: View {
    var state: Bool?
    var label: String
    var isEnabled = true
    var onChange: @MainActor (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { state ?? false }, set: onChange)) { EmptyView() }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!isEnabled)
            .overlay {
                if state == nil {
                    Image(systemName: "minus").font(.system(size: 8, weight: .bold)).allowsHitTesting(false)
                }
            }
            .accessibilityLabel(label)
            .accessibilityValue(state == nil ? "Some selected" : (state == true ? "Selected" : "Not selected"))
    }
}

/// Badges shown next to an app's name.
struct UninstallerAppBadges: View {
    var app: UninstallerApp
    var isRunning: Bool

    var body: some View {
        HStack(spacing: 4) {
            if app.isWrappediOSApp {
                Badge(text: "iPhone & iPad", symbol: "ipad.and.iphone", tint: .blue)
                    .help("An iPhone and iPad app installed from the App Store.")
            } else if app.info.isAppStoreApp {
                Badge(text: "App Store", symbol: "bag.fill", tint: .blue)
                    .help("Installed from the Mac App Store.")
            }
            if isRunning {
                Badge(text: "Running", symbol: "circle.fill", tint: .green)
                    .help("The app is open. It's asked to quit before it's removed.")
            }
            if let protection = app.protection {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                    .help(protection.explanation)
                    .accessibilityLabel(protection.title)
            }
        }
    }
}

/// One related file in the uninstall preview or the details panel.
struct UninstallerLeftoverRow: View {
    var leftover: UninstallerLeftover
    @Binding var isSelected: Bool
    var showsCheckbox = true
    var onQuickLook: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showsCheckbox {
                Toggle("", isOn: $isSelected)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel("Select \(leftover.name)")
            }
            FileIcon(path: leftover.path, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(leftover.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if leftover.safety != .safe { SafetyBadge(safety: leftover.safety) }
                    if leftover.isSystemWide {
                        Badge(text: "Administrator", symbol: "lock.fill", tint: .purple)
                            .help("A system-wide item. macOS asks for an administrator to remove it.")
                    }
                }
                Text(leftover.reason.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let note = leftover.note {
                    Label(note, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PathText(path: leftover.path, font: .caption2)
            }
            Spacer(minLength: 8)
            UninstallerSizeLabel(usage: leftover.usage, font: .callout)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onTapGesture { if showsCheckbox { isSelected.toggle() } }
        .contextMenu {
            FileContextMenu(path: leftover.path, onQuickLook: onQuickLook)
        }
    }
}

/// Total size of related files: "≥" when some couldn't be measured, "—" when none could.
struct UninstallerTotalSize: View {
    var leftovers: [UninstallerLeftover]
    var font: Font = .callout

    var body: some View {
        let measured = leftovers.filter { $0.usage != nil }
        let total = measured.reduce(0) { $0 + $1.bytes }
        Group {
            if !leftovers.isEmpty && (measured.isEmpty || (total == 0 && measured.count < leftovers.count)) {
                Text("—")
                    .font(font)
                    .help("macOS protects this data. Grant Full Disk Access to measure it.")
            } else if measured.count < leftovers.count || leftovers.contains(where: { ($0.usage?.unreadableDirectoryCount ?? 0) > 0 }) {
                HStack(spacing: 3) {
                    Text("≥").font(font)
                    SizeText(bytes: total, font: font)
                }
                .help("Some items couldn't be measured, so the total may be larger.")
            } else {
                SizeText(bytes: total, font: font)
            }
        }
    }
}

/// Size with a hint when it's unknown or incomplete.
struct UninstallerSizeLabel: View {
    var usage: DiskUsage?
    var font: Font = .callout

    var body: some View {
        Group {
            if let usage {
                HStack(spacing: 3) {
                    if usage.unreadableDirectoryCount > 0 {
                        Text("≥").foregroundStyle(.secondary)
                    }
                    SizeText(bytes: usage.reclaimableBytes, font: font)
                }
                .help(usage.unreadableDirectoryCount > 0 ? "Some folders inside couldn't be read, so the real size may be larger." : "\(NumberFormatting.count(usage.fileCount, "file"))")
            } else {
                Text("—")
                    .font(font)
                    .foregroundStyle(.secondary)
                    .help("Size unavailable: macOS protects this data. Grant Full Disk Access to measure it.")
            }
        }
        .foregroundStyle(.secondary)
        .frame(minWidth: 70, alignment: .trailing)
    }
}
