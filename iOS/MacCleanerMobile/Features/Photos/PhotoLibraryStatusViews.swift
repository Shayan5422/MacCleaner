import SwiftUI

/// What the Photos and Videos screens show before there are results: access, the first scan, or why
/// the library can't be checked.
struct PhotoAccessCard: View {
    var model: PhotoCleanupModel
    var section: MobileSection

    var body: some View {
        let device = MediaDescription.deviceWord
        switch model.access {
        case .notDetermined:
            PermissionCard(section: section, title: "Allow access to your photos",
                           message: "To find duplicates, similar shots, screenshots and large videos, Mac Cleaner needs full access to your photo library. Everything is checked on this \(device) and never leaves it, and nothing is deleted until you choose.",
                           buttonTitle: "Allow Access") {
                Task { await model.requestAccess() }
            }
        case .full:
            PermissionCard(section: section, title: "Find what you don't need",
                           message: "Mac Cleaner looks through your library for duplicates, similar shots, screenshots, extra burst frames, large videos and screen recordings. Nothing is deleted until you choose.",
                           buttonTitle: "Scan Library") {
                model.startScan()
            }
        case .limited:
            PhotoLimitedAccessCard(section: section) { model.startScan() }
        case .denied:
            PermissionCard(section: section, title: "Photo access is off",
                           message: "Mac Cleaner can't see your photos, so it can't look for duplicates or large videos. In Settings, tap Photos and choose Full Access.",
                           buttonTitle: "Open Settings") {
                openAppSettings()
            }
        case .restricted:
            Card {
                HStack(spacing: 12) {
                    IconTile(section: section, size: 44)
                    Text("Photo access is restricted").font(.headline)
                }
                Text("Screen Time or a device management profile doesn't let apps use Photos on this \(device), so Mac Cleaner can't check your library. Whoever manages this \(device) can change that.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Limited access: explains what it means and offers both ways forward.
struct PhotoLimitedAccessCard: View {
    var section: MobileSection
    var onContinue: () -> Void

    var body: some View {
        Card {
            HStack(spacing: 12) {
                IconTile(section: section, size: 44)
                Text("Only selected photos").font(.headline)
            }
            Text("You've shared only some of your photos with Mac Cleaner, so only those can be checked, and copies of them elsewhere in your library won't be found. For the whole library, choose Full Access in Settings.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: openAppSettings) {
                Text("Allow Full Access").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(section.tint)
            Button(action: onContinue) {
                Text("Continue with Selected Photos").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(section.tint)
        }
    }
}

/// Above results from a limited scan.
struct PhotoLimitedNotice: View {
    var tint: Color

    var body: some View {
        Card(padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Only the photos you shared were checked").font(.subheadline.weight(.semibold))
                    Text("With limited access, copies elsewhere in your library can't be found.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Allow Full Access", action: openAppSettings)
                .buttonStyle(.bordered)
                .tint(tint)
                .font(.subheadline.weight(.semibold))
        }
    }
}

/// A scan in progress, with a way to stop it.
struct PhotoScanningCard: View {
    var progress: PhotoScanProgress
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ProgressCard(title: progress.title, message: progress.message, fraction: progress.fraction)
            Button("Cancel Scan", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
            Text("Photos are compared by the thumbnails on this \(MediaDescription.deviceWord). Nothing is downloaded from iCloud.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
    }
}

/// A problem the person should know about, inline rather than in an alert (two screens share the model).
struct PhotoErrorCard: View {
    var message: String
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message).font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 32, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
