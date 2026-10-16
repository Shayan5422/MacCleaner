import SwiftUI

/// The About window: who made Mac Cleaner, its links, the update status,
/// acknowledgements and the license.
struct AboutView: View {
    var updates: AppUpdateController

    var body: some View {
        VStack(spacing: 0) {
            AboutHero()
            VStack(alignment: .leading, spacing: 14) {
                AboutSection(title: "Made by \(AppInfo.author)") {
                    HStack(spacing: 8) {
                        AboutLinkPill(title: "Website", symbol: "globe", url: AppInfo.websiteURL)
                        AboutLinkPill(title: "GitHub", symbol: "chevron.left.forwardslash.chevron.right", url: AppInfo.githubURL)
                        AboutLinkPill(title: "LinkedIn", symbol: "person.crop.square", url: AppInfo.linkedInURL)
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                }

                AboutSection(title: "Project") {
                    VStack(spacing: 0) {
                        AboutLinkRow(title: "Source code", symbol: "curlybraces", url: AppInfo.repositoryURL)
                        Divider().padding(.leading, 42)
                        AboutLinkRow(title: "Report an issue", symbol: "exclamationmark.bubble", url: AppInfo.issuesURL)
                        Divider().padding(.leading, 42)
                        AboutLinkRow(title: "Release notes", symbol: "doc.text", url: AppInfo.releasesURL)
                    }
                }

                AboutSection(title: "Updates") {
                    AppUpdateStatusRow(controller: updates)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }

                AboutSection(title: "Acknowledgements") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(AppInfo.acknowledgements.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().padding(.leading, 12) }
                            AboutAcknowledgementRow(item: item)
                        }
                    }
                }

                HStack(spacing: 5) {
                    Spacer()
                    Button(AppInfo.license) { AppInfo.open(AppInfo.licenseURL) }
                        .buttonStyle(.link)
                        .help(AppInfo.licenseURL.absoluteString)
                    Text(verbatim: "·").accessibilityHidden(true)
                    Text(AppInfo.copyright)
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .padding(.bottom, 18)
        }
        .frame(width: 460)
        .background(Color.windowBackground)
    }
}

/// Icon, name, version and tagline on a soft brand gradient.
private struct AboutHero: View {
    var body: some View {
        VStack(spacing: 6) {
            AppIconImage(size: 88)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .padding(.bottom, 4)
            Text(AppInfo.name)
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text(AppInfo.versionLine())
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(AppInfo.tagline)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
        .padding(.bottom, 20)
        .padding(.horizontal, 24)
        .background(
            LinearGradient(
                colors: [AppSection.smartScan.tint.opacity(0.16), AppSection.dashboard.tint.opacity(0.10), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .accessibilityElement(children: .combine)
    }
}

/// A titled group with a card surface, like a grouped form section.
private struct AboutSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Metrics.tileRadius, style: .continuous).fill(Color.cardBackground))
                .overlay(RoundedRectangle(cornerRadius: Metrics.tileRadius, style: .continuous).strokeBorder(Color.subtleBorder))
        }
    }
}

/// Capsule link (Website / GitHub / LinkedIn).
private struct AboutLinkPill: View {
    var title: String
    var symbol: String
    var url: URL
    @State private var isHovering = false

    var body: some View {
        Button {
            AppInfo.open(url)
        } label: {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(isHovering ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(url.absoluteString)
        .accessibilityLabel(title)
        .accessibilityHint("Opens \(url.host ?? "the link") in your browser")
    }
}

/// A full-width row that opens a link: icon, title, ↗.
private struct AboutLinkRow: View {
    var title: String
    var symbol: String
    var url: URL
    @State private var isHovering = false

    var body: some View {
        Button {
            AppInfo.open(url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(title)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(isHovering ? Color.hoverFill : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(url.absoluteString)
        .accessibilityLabel(title)
        .accessibilityHint("Opens \(url.host ?? "the link") in your browser")
    }
}

private struct AboutAcknowledgementRow: View {
    var item: AppInfo.Acknowledgement
    @State private var isHovering = false

    var body: some View {
        Button {
            if let url = item.url { AppInfo.open(url) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(item.detail)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if item.url != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isHovering && item.url != nil ? Color.hoverFill : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .disabled(item.url == nil)
        .help(item.url?.absoluteString ?? "")
        .accessibilityLabel("\(item.title): \(item.detail)")
    }
}
