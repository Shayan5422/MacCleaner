import SwiftUI

/// One guide: why it helps, what it saves or protects, the steps for this iOS version and a
/// "Mark as done" switch saved on this device.
struct GuideDetailView: View {
    var guide: Guide
    var context: GuideContext

    private var progress: GuideProgress { .shared }
    private var device: DeviceInfo { context.device }
    private var isDone: Bool { progress.isDone(guide.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let note = GuideLibrary.statusNote(for: guide, in: context) {
                    GuideStatusBanner(note: note)
                }
                aboutCard
                stepsCard
                if guide.opensAppSettings { appSettingsCard }
                if guide.key == .safariProtection && SafariExtensionsButton.isAvailable {
                    Card { SafariExtensionsButton() }
                }
                doneCard
            }
            .padding(16)
            .readableColumn()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(guide.title)
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: isDone) { _, done in done }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            IconTile(symbol: guide.symbol, tint: guide.tint, size: 60)
            Text(guide.title).font(.title2.weight(.bold)).fixedSize(horizontal: false, vertical: true)
            Text(guide.summary).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var aboutCard: some View {
        Card {
            sectionTitle("Why it helps", symbol: "lightbulb")
            Text(Guide.text(guide.why, for: device)).font(.body).fixedSize(horizontal: false, vertical: true)
            Divider()
            sectionTitle(guide.benefitTitle, symbol: guide.category == .space ? "internaldrive" : "lock.shield")
            Text(Guide.text(guide.benefit, for: device)).font(.body).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(guide.tint)
        }
        .font(.headline)
    }

    private var stepsCard: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text("Steps").font(.headline)
                Spacer()
                Text("For \(context.systemName) \(device.systemMajorVersion)").font(.footnote).foregroundStyle(.secondary)
            }
            let steps = guide.steps(forSystemMajorVersion: device.systemMajorVersion)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                GuideStepRow(number: index + 1, text: GuideMarkdown.render(step, for: device), tint: guide.tint)
            }
            if let note = guide.note {
                Divider()
                Label {
                    Text(GuideMarkdown.render(note, for: device)).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var appSettingsCard: some View {
        Card {
            Label("Mac Cleaner's own access", systemImage: "gearshape").font(.headline)
            Text("Mac Cleaner uses Photos and Contacts only for its cleanups, on this \(device.deviceWord). You can change its access on its page in Settings.")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button {
                openAppSettings()
            } label: {
                Text("Open Mac Cleaner Settings").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private var doneCard: some View {
        Card {
            Toggle(isOn: Binding(get: { isDone }, set: { progress.setDone($0, for: guide.id) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mark as done").font(.headline)
                    Text(isDone ? "Done guides get a check and leave your suggestions." : "Turn this on once you've followed the steps.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .tint(.green)
        }
    }
}

/// One numbered step.
struct GuideStepRow: View {
    var number: Int
    var text: AttributedString
    var tint: Color

    @ScaledMetric(relativeTo: .subheadline) private var badgeSize: CGFloat = 26

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: badgeSize, height: badgeSize)
                .background(Circle().fill(tint))
            Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(number): ") + Text(text))
    }
}

/// "iOS 27.0.2 is available for your iPhone.", in green when it's already done.
struct GuideStatusBanner: View {
    var note: GuideStatusNote

    var body: some View {
        let tint: Color = note.isGood ? .green : .orange
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: note.isGood ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(tint)
            Text(note.text).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Update iOS") {
    NavigationStack {
        GuideDetailView(guide: GuideLibrary.guide(.updateSystem),
                        context: GuideContext(storage: nil, device: DeviceInfo(modelIdentifier: "iPhone18,3", systemVersion: [27, 0, 1], isPad: false),
                                              deletedPhotos: false, deletedFiles: false, safariProtectionEnabled: true,
                                              systemUpToDate: false, passcodeSet: true, availableSystemVersion: "27.0.2"))
    }
}
#endif

/// Renders a guide's Markdown (**bold** for what to tap) with "{device}" and "{system}" filled in.
enum GuideMarkdown {
    static func render(_ template: String, for device: DeviceInfo) -> AttributedString {
        let text = Guide.text(template, for: device)
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
