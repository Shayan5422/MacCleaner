import SwiftUI

/// First launch: what Mac Cleaner can do on iPhone, what iOS doesn't allow, and how the app helps there.
/// Shown once, and later from the Overview's info button.
struct OnboardingView: View {
    var device: DeviceInfo
    var onFinish: () -> Void
    @State private var page = DebugLaunch.onboardingPage

    private var pages: [OnboardingPage] {
        [
            OnboardingPage(
                symbol: "sparkles", tint: .brand, artwork: "AppIconArtwork",
                title: "Welcome to Mac Cleaner",
                message: "The assistant that keeps your \(device.deviceWord) tidy and safe. Here's what it can do, and what it can't, in four short pages.",
                points: []),
            OnboardingPage(
                symbol: "photo.on.rectangle.angled", tint: MobileSection.photos.tint,
                title: "Clean what takes the most space",
                message: "With your permission, Mac Cleaner looks through:",
                points: [
                    OnboardingPoint(symbol: MobileSection.photos.symbol, text: "Photos: duplicates, similar shots, screenshots and bursts"),
                    OnboardingPoint(symbol: MobileSection.videos.symbol, text: "Videos: the largest ones and screen recordings"),
                    OnboardingPoint(symbol: MobileSection.contacts.symbol, text: "Contacts: duplicates to merge and empty cards"),
                    OnboardingPoint(symbol: MobileSection.files.symbol, text: "Files: large, old and duplicate files in folders you choose"),
                ]),
            OnboardingPage(
                symbol: "lightbulb", tint: MobileSection.guides.tint,
                title: "Guided where iOS keeps apps out",
                message: "iOS keeps every app in its own sandbox: no app can clear system data or other apps' caches. For those, the Guides tab walks you through the fastest way in Settings.",
                points: [
                    OnboardingPoint(symbol: "message", text: "Large attachments in Messages"),
                    OnboardingPoint(symbol: "safari", text: "Safari history and website data"),
                    OnboardingPoint(symbol: "icloud.and.arrow.up", text: "Apps you rarely use, offloaded automatically"),
                ]),
            OnboardingPage(
                symbol: "checkmark.shield", tint: MobileSection.protection.tint,
                title: "Safe by design",
                message: "Nothing is deleted until you've seen it and confirmed.",
                points: [
                    OnboardingPoint(symbol: "trash.slash", text: "Deleted photos and files wait in Recently Deleted for 30 days"),
                    OnboardingPoint(symbol: "person.crop.circle.badge.checkmark", text: "Contacts are backed up before every merge"),
                    OnboardingPoint(symbol: "lock", text: "No account and no tracking: everything stays on your \(device.deviceWord)"),
                    OnboardingPoint(symbol: "safari", text: "Safari protection blocks known malware sites"),
                ]),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    OnboardingPageView(page: page).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < pages.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    onFinish()
                }
            } label: {
                Text(page < pages.count - 1 ? "Continue" : "Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Button("Skip", action: onFinish)
                .font(.subheadline)
                .opacity(page < pages.count - 1 ? 1 : 0)
                .disabled(page == pages.count - 1)
                .padding(.bottom, 16)
        }
        .background(Color(.systemGroupedBackground))
    }
}

struct OnboardingPage: Hashable {
    var symbol: String
    var tint: Color
    /// An image from the asset catalog shown instead of the symbol (the app icon on the first page).
    var artwork: String? = nil
    var title: String
    var message: String
    var points: [OnboardingPoint]
}

struct OnboardingPoint: Hashable {
    var symbol: String
    var text: String
}

private struct OnboardingPageView: View {
    var page: OnboardingPage

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
    }

    private var content: some View {
        VStack(spacing: 20) {
            if let artwork = page.artwork {
                Image(artwork)
                    .resizable()
                    .frame(width: 104, height: 104)
                    .clipShape(RoundedRectangle(cornerRadius: 104 * 0.225, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                    .accessibilityHidden(true)
            } else {
                IconTile(symbol: page.symbol, tint: page.tint, size: 88)
            }
            Text(page.title)
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
            Text(page.message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !page.points.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(page.points, id: \.self) { point in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: point.symbol)
                                .font(.title3)
                                .foregroundStyle(page.tint)
                                .frame(width: 30)
                                .accessibilityHidden(true)
                            Text(point.text).font(.callout)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(18)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 40)
        .frame(maxWidth: 560)
    }
}
