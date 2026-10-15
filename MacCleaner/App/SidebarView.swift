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
        .safeAreaInset(edge: .bottom) {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings (⌘,)")
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
    }
}
