import AppKit
import SwiftUI

/// Scene identifiers of Mac Cleaner's own windows.
enum AppWindowID {
    static let main = "main"
    static let about = "about"
    static let update = "app-update"
    static let activity = "activity"
}

/// The application icon as SwiftUI image.
struct AppIconImage: View {
    var size: CGFloat = 64

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Update window

/// "Mac Cleaner Update": the result of "Check for Updates…", release notes and the
/// verified "Download & Install".
struct AppUpdateWindow: View {
    @Bindable var controller: AppUpdateController
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 16)
            if showsContent {
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            footer
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
        }
        .frame(width: 540, height: showsContent ? 520 : nil)
        .background(Color.windowBackground)
    }

    private var release: AppRelease? { controller.availableUpdate ?? controller.latestRelease }

    /// Release notes, progress and results need room; "you're up to date" doesn't.
    private var showsContent: Bool {
        if case .idle = controller.installPhase { return release != nil }
        return true
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            AppIconImage(size: 64)
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                Text(subheadline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }

    private var headline: String {
        switch controller.installPhase {
        case .working: return "Updating Mac Cleaner…"
        case .relaunching(let version): return "Mac Cleaner \(version) is installed"
        case .failed: return "The update wasn't installed"
        case .savedDiskImage: return "Install Mac Cleaner from the disk image"
        case .idle: break
        }
        if let release { return "Mac Cleaner \(release.version) is available" }
        switch controller.phase {
        case .checking: return "Checking for updates…"
        case .finished(.failed): return "Couldn't check for updates"
        default: return controller.lastCheckDate == nil ? "Mac Cleaner Updates" : "Mac Cleaner is up to date"
        }
    }

    private var subheadline: String {
        if case .relaunching = controller.installPhase { return "Mac Cleaner restarts in a moment." }
        if case .working = controller.installPhase, let release { return "Installing version \(release.version). You have \(controller.currentVersion)." }
        if let release {
            var parts = ["You have \(controller.currentVersion)"]
            if let date = release.publishedAt { parts.append("released \(DateFormatting.day(date))") }
            if controller.isSkipped(release) { parts.append("skipped") }
            return parts.joined(separator: " · ") + "."
        }
        switch controller.phase {
        case .checking: return "Asking GitHub for the newest release of Mac Cleaner."
        case .finished(.failed(let reason)): return reason + " Releases are also listed on GitHub."
        default:
            var text = "Version \(controller.currentVersion) is the newest version."
            if let date = controller.lastCheckDate { text += " Checked \(DateFormatting.relative(date))." }
            text += controller.automaticChecksEnabled
                ? " Mac Cleaner checks for a new version once a day."
                : " Automatic checks are off (Settings › General)."
            return text
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch controller.installPhase {
        case .working(let stage):
            AppUpdateProgressView(stage: stage, release: release)
                .padding(22)
        case .relaunching:
            statusMessage(symbol: "checkmark.circle.fill", tint: .green, title: "Restarting Mac Cleaner…",
                          message: "The previous version was moved to the Trash.")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                InfoCallout(style: .warning, title: "Nothing was changed", message: message)
                Text("You can try again, or download the update from GitHub and install it yourself.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(22)
        case .savedDiskImage(let image, let reason):
            VStack(alignment: .leading, spacing: 12) {
                if !reason.isEmpty {
                    InfoCallout(style: .info, message: reason)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label("The disk image was verified and saved to \(PathUtilities.abbreviate(image.deletingLastPathComponent().path)).", systemImage: "checkmark.shield.fill")
                        .symbolRenderingMode(.multicolor)
                    Label("Quit Mac Cleaner, then drag Mac Cleaner from the disk image to the Applications folder and choose Replace.", systemImage: "1.circle")
                    Label("Open Mac Cleaner again from the Applications folder.", systemImage: "2.circle")
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
        case .idle:
            if let release {
                releaseNotes(release)
            } else {
                switch controller.phase {
                case .checking:
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text("Checking for updates…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .finished(.failed):
                    statusMessage(symbol: "wifi.exclamationmark", tint: .orange, title: "GitHub couldn't be reached",
                                  message: "Check your internet connection and try again. Releases are also listed on GitHub.")
                default:
                    statusMessage(symbol: "checkmark.seal.fill", tint: .green, title: "You're up to date",
                                  message: controller.automaticChecksEnabled
                                      ? "Mac Cleaner checks for a new version once a day and lets you know."
                                      : "Automatic checks are off. Turn them on in Settings › General.")
                }
            }
        }
    }

    private func statusMessage(symbol: String, tint: Color, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(22)
    }

    private func releaseNotes(_ release: AppRelease) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("What's New").font(.headline)
                    Spacer()
                    Button("View on GitHub") { controller.openReleasePage(release) }
                        .buttonStyle(.link)
                        .font(.callout)
                        .help(release.pageURL.absoluteString)
                }
                let document = ReleaseNotesDocument.markdown(release.notes ?? "")
                if document.isEmpty {
                    Text("This release has no release notes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ReleaseNotesView(document: document)
                }
            }
            .padding(22)
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        switch controller.installPhase {
        case .working(let stage):
            HStack {
                Text("Mac Cleaner restarts when the update is installed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { controller.cancelInstall() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(stage == .installing)
            }
        case .relaunching:
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
            }
        case .failed:
            HStack {
                if let release {
                    Button("Download from GitHub") { controller.openReleasePage(release) }
                }
                Spacer()
                Button("Close") {
                    controller.resetInstall()
                    dismissWindow(id: AppWindowID.update)
                }
                if let release, release.canInstall {
                    Button("Try Again") {
                        controller.resetInstall()
                        controller.downloadAndInstall(release)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        case .savedDiskImage(let image, _):
            HStack {
                Button("Show in Finder") { FinderActions.reveal(image.path) }
                Spacer()
                Button("Done") {
                    controller.resetInstall()
                    dismissWindow(id: AppWindowID.update)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        case .idle:
            if let release {
                updateFooter(release)
            } else {
                HStack {
                    Button("Release Notes on GitHub") { AppInfo.open(AppInfo.releasesURL) }
                        .buttonStyle(.link)
                    Spacer()
                    Button("Check Again") { controller.checkNow() }
                        .disabled(controller.isChecking)
                    Button("Done") { dismissWindow(id: AppWindowID.update) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func updateFooter(_ release: AppRelease) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if release.canInstall {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(.green)
                    Text("Before anything is replaced, the download is checked: its SHA-256 checksum, the Developer ID signature and Apple's notarization.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                InfoCallout(style: .info, message: "This release can't be installed from Mac Cleaner because it doesn't include a verifiable disk image. Download it from GitHub.")
            }
            HStack(spacing: 8) {
                if !controller.isSkipped(release) {
                    Button("Skip This Version") {
                        controller.skip(release)
                        dismissWindow(id: AppWindowID.update)
                    }
                    .help("Don't remind me about \(release.version). Newer versions are still announced.")
                }
                if release.canInstall {
                    Button("Download Disk Image") { controller.downloadDiskImage(release) }
                        .buttonStyle(.link)
                        .help("Download and verify the disk image, save it to Downloads and open it, so you can install it yourself.")
                }
                Spacer()
                Button("Remind Me Later") { dismissWindow(id: AppWindowID.update) }
                    .keyboardShortcut(.cancelAction)
                if release.canInstall {
                    Button("Download & Install") { controller.downloadAndInstall(release) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Open GitHub") { controller.openReleasePage(release) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

/// Download and verification progress.
struct AppUpdateProgressView: View {
    var stage: AppUpdateInstaller.Stage
    var release: AppRelease?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Step.allCases, id: \.self) { step in
                HStack(spacing: 10) {
                    Group {
                        if step.rawValue < current.rawValue {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if step == current {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 18)
                    Text(step.title)
                        .foregroundStyle(step.rawValue <= current.rawValue ? .primary : .secondary)
                    Spacer()
                    if step == .download, case .downloading(let received, let expected) = stage {
                        Text(downloadText(received: received, expected: expected))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                if step == .download, case .downloading(let received, let expected) = stage {
                    if let expected, expected > 0 {
                        ProgressView(value: min(1, Double(received) / Double(expected)))
                            .padding(.leading, 28)
                    } else {
                        ProgressView().progressViewStyle(.linear).padding(.leading, 28)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    enum Step: Int, CaseIterable {
        case download, checksum, signature, install

        var title: String {
            switch self {
            case .download: return "Downloading the disk image"
            case .checksum: return "Checking the SHA-256 checksum"
            case .signature: return "Checking the signature and notarization"
            case .install: return "Replacing this copy of Mac Cleaner"
            }
        }
    }

    private var current: Step {
        switch stage {
        case .downloading: return .download
        case .verifyingChecksum: return .checksum
        case .openingDiskImage, .verifyingApp: return .signature
        case .installing: return .install
        }
    }

    private func downloadText(received: Int64, expected: Int64?) -> String {
        guard let expected, expected > 0 else { return ByteFormatting.string(received) }
        return "\(ByteFormatting.string(received)) of \(ByteFormatting.string(expected))"
    }
}

// MARK: - Notices

/// A calm notice that a new Mac Cleaner version is available (Dashboard).
struct AppUpdateBanner: View {
    var controller: AppUpdateController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let release = controller.availableUpdate {
            HStack(spacing: 12) {
                AppIconImage(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mac Cleaner \(release.version) is available")
                        .font(.callout.weight(.semibold))
                    Text(detail(release))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button("Skip This Version") { controller.skip(release) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                Button("What's New") { show() }
                Button("Update…") { show() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.2)))
            .accessibilityElement(children: .contain)
        }
    }

    private func detail(_ release: AppRelease) -> String {
        var parts = ["You have \(controller.currentVersion)"]
        if let date = release.publishedAt { parts.append("released \(DateFormatting.day(date))") }
        return parts.joined(separator: " · ") + ". The download is verified before it's installed."
    }

    private func show() {
        NSApp.activate()
        openWindow(id: AppWindowID.update)
    }
}

/// "Mac Cleaner 1.0.0 · You're up to date" with "Check for Updates…" (About and Settings).
struct AppUpdateStatusRow: View {
    var controller: AppUpdateController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.statusTitle)
                    .font(.callout.weight(.medium))
                Text(controller.statusDetail)
                    .font(.caption)
                    .foregroundStyle(controller.lastCheckFailed ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if controller.availableUpdate != nil {
                Button("Update…") {
                    NSApp.activate()
                    openWindow(id: AppWindowID.update)
                }
                .buttonStyle(.borderedProminent)
            } else {
                if controller.isChecking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Checking for updates")
                }
                Button("Check for Updates…") { controller.checkNow() }
                    .disabled(controller.isChecking)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        if controller.availableUpdate != nil { return "arrow.down.circle.fill" }
        if controller.lastCheckFailed { return "exclamationmark.triangle.fill" }
        if controller.lastCheckDate != nil { return "checkmark.circle.fill" }
        return "arrow.triangle.2.circlepath"
    }

    private var tint: Color {
        if controller.availableUpdate != nil { return .accentColor }
        if controller.lastCheckFailed { return .orange }
        if controller.lastCheckDate != nil { return .green }
        return .secondary
    }
}
