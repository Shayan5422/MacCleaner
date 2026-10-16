import SwiftUI

struct SidebarView: View {
    @Bindable var navigation: NavigationModel
    let badges: [AppSection: String]

    var body: some View {
        List(selection: Binding(get: { navigation.selection }, set: { if let value = $0 { navigation.selection = value } })) {
            ForEach(NavigationModel.groups) { group in
                Section(group.title) {
                    ForEach(group.sections) { section in
                        Label {
                            HStack {
                                Text(section.title)
                                Spacer()
                                if let badge = badges[section] {
                                    Text(badge)
                                        .font(.caption2.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                        } icon: {
                            Image(systemName: section.symbolName)
                                .foregroundStyle(section.tint)
                        }
                        .tag(section)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooter(updates: .shared)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
    }
}

/// Settings, and a notice when a new version of Mac Cleaner is available. It has its
/// own background, so the list never shows through when it scrolls under it.
private struct SidebarFooter: View {
    var updates: AppUpdateController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Settings (⌘,)")
                if let release = updates.availableUpdate {
                    Button {
                        AppPresence.shared.open(windowID: AppWindowID.update, using: openWindow)
                    } label: {
                        Label("\(release.version)", systemImage: "arrow.down.circle.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Mac Cleaner \(release.version) is available")
                    .accessibilityLabel("Mac Cleaner \(release.version) is available. Update")
                }
            }
            .padding(.horizontal, 16)
        }
        .background(.bar)
    }
}
