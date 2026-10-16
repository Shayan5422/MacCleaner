import SwiftUI

/// First-launch introduction: what Mac Cleaner does, what it never does, and
/// which permissions help (all optional).
struct OnboardingView: View {
    let services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if page == 0 { welcome } else { permissions }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)

            Divider()
            HStack {
                if page == 1 {
                    Button("Back") { withAnimation { page = 0 } }
                }
                Spacer()
                if page == 0 {
                    Button("Continue") { withAnimation { page = 1 } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Start Using Mac Cleaner") {
                        services.settings.hasCompletedOnboarding = true
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
        }
        .frame(width: 620, height: 520)
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            AppIconImage(size: 84)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
            VStack(spacing: 6) {
                Text("Welcome to Mac Cleaner")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(AppInfo.tagline)
                    .font(.title3.weight(.medium))
            }
            Text("Free up space, remove apps completely and keep an eye on your Mac — without subscriptions, accounts or tracking.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            VStack(alignment: .leading, spacing: 12) {
                promise("eye", "You review everything before it's removed. Nothing is deleted without your confirmation.")
                promise("arrow.uturn.backward", "Your files go to the Trash and can be restored from History.")
                promise("lock.shield", "Your documents, photos, passwords and macOS itself are protected by built-in rules.")
                promise("wifi.slash", "Everything runs on your Mac. No data leaves it.")
            }
            .frame(maxWidth: 480)
        }
    }

    private func promise(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(AppSection.smartScan.tint)
                .frame(width: 26)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Optional permissions")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("Mac Cleaner works without them, but some locations are protected by macOS and will be skipped. You can change these any time in System Settings.")
                .foregroundStyle(.secondary)
            permissionCard(
                symbol: "externaldrive.badge.checkmark",
                title: "Full Disk Access",
                detail: "Lets scans include app containers, Safari data, Mail downloads and the Trash. In System Settings, turn on Mac Cleaner in the list (you may need to add it with +).",
                status: services.permissions.fullDiskAccess == .granted ? "Granted" : "Not granted",
                granted: services.permissions.fullDiskAccess == .granted
            ) {
                services.permissions.open(.fullDiskAccess)
            }
            permissionCard(
                symbol: "bell.badge",
                title: "Notifications",
                detail: "For automatic cleaning results, security scan alerts and performance warnings you turn on.",
                status: nil,
                granted: false
            ) {
                Task { await services.notifications.requestAuthorization() }
            }
            Button("Check Full Disk Access Again") { services.permissions.refresh() }
                .buttonStyle(.link)
        }
    }

    private func permissionCard(symbol: String, title: String, detail: String, status: String?, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(granted ? .green : AppSection.smartScan.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.headline)
                    if let status {
                        Badge(text: status, symbol: granted ? "checkmark" : nil, tint: granted ? .green : .orange)
                    }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(granted ? "Open Settings" : "Allow…", action: action)
        }
        .card()
    }
}
