import SwiftUI

/// Checks a pasted link or domain against the URLhaus and ThreatFox lists saved on this device.
struct LinkCheckView: View {
    var model: ProtectionModel

    @State private var input = ""
    @State private var outcome: ProtectionModel.LinkCheckOutcome?
    @State private var isChecking = false
    @FocusState private var isFieldFocused: Bool

    private var trimmedInput: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                inputCard
                if isChecking {
                    ProgressCard(title: "Checking…", message: model.updateMessage ?? "Looking it up in the lists on this \(model.device.deviceWord).",
                                 fraction: nil)
                } else if let outcome {
                    LinkCheckResultCard(outcome: outcome)
                }
                listsFooter
            }
            .padding(16)
            .readableColumn()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Link Check")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.prepareLinkCheck() }
    }

    private var inputCard: some View {
        Card {
            Text("Paste a link or a domain, for example from a message you didn't expect.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("example.com or https://…", text: $input)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($isFieldFocused)
                    .onSubmit(check)
                    .onChange(of: input) { outcome = nil }
                if !input.isEmpty {
                    Button {
                        input = ""
                        isFieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(12)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: 12) {
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first else { return }
                    Task { @MainActor in
                        input = text
                        check()
                    }
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)
                Spacer(minLength: 0)
                Button(action: check) {
                    Text("Check").frame(minWidth: 64)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(trimmedInput.isEmpty || isChecking)
            }
        }
    }

    private var listsFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("The check runs on your \(model.device.deviceWord), against lists downloaded from abuse.ch. The link isn't sent anywhere.",
                  systemImage: "lock.fill")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Text(listsStatus).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Update Now") {
                    Task { await model.updateListsNow() }
                }
                .font(.footnote.weight(.semibold))
                .disabled(model.isUpdatingLists)
            }
        }
        .font(.footnote)
        .padding(.horizontal, 4)
    }

    private var listsStatus: String {
        if model.isUpdatingLists { return model.updateMessage ?? "Updating the lists…" }
        guard let updated = model.feedState.allListsChecked else { return "The lists haven't been downloaded yet." }
        let entries = model.linkIndex.map { " · " + NumberFormatting.count($0.entryCount, "entry", plural: "entries") } ?? ""
        return "Lists updated \(DateFormatting.relative(updated))" + entries
    }

    private func check() {
        let text = trimmedInput
        guard !text.isEmpty, !isChecking else { return }
        isFieldFocused = false
        isChecking = true
        Task {
            let result = await model.checkLink(text)
            outcome = result
            isChecking = false
        }
    }
}

/// The link check's answer.
struct LinkCheckResultCard: View {
    var outcome: ProtectionModel.LinkCheckOutcome

    var body: some View {
        switch outcome {
        case .invalid:
            message(symbol: "questionmark.circle", tint: ProtectionPalette.gray, title: "That doesn't look like a link",
                    text: "Try a domain like example.com, or a full link that starts with https://.")
        case .listsUnavailable(let problem):
            message(symbol: "wifi.exclamationmark", tint: .orange, title: "The lists aren't available", text: problem)
        case .checked(let link, let verdict):
            verdictCard(link: link, verdict: verdict)
        }
    }

    private func message(symbol: String, tint: Color, title: String, text: String) -> some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: symbol, tint: tint, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func verdictCard(link: CheckedLink, verdict: LinkVerdict) -> some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: symbol(for: verdict), tint: tint(for: verdict), size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(for: verdict))
                        .font(.headline)
                        .foregroundStyle(verdictIsListed(verdict) ? Color.red : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle = subtitle(for: verdict) {
                        Text(subtitle).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text(link.display)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
            ForEach(details(for: verdict, link: link), id: \.self) { line in
                Text(line).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            if case .listed(let match) = verdict, let reference = match.referenceURL {
                Link(destination: reference) {
                    Label("View on ThreatFox", systemImage: "arrow.up.right.square")
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func verdictIsListed(_ verdict: LinkVerdict) -> Bool {
        if case .listed = verdict { return true }
        return false
    }

    private func symbol(for verdict: LinkVerdict) -> String {
        switch verdict {
        case .listed: return "xmark.shield.fill"
        case .notListed: return "shield"
        case .localAddress: return "house"
        }
    }

    private func tint(for verdict: LinkVerdict) -> Color {
        switch verdict {
        case .listed: return .red
        case .notListed: return ProtectionPalette.gray
        case .localAddress: return ProtectionPalette.blue
        }
    }

    private func title(for verdict: LinkVerdict) -> String {
        switch verdict {
        case .notListed: return "Not in the lists"
        case .listed, .localAddress: return verdict.headline
        }
    }

    private func subtitle(for verdict: LinkVerdict) -> String? {
        if case .notListed = verdict { return "That doesn't prove it's safe." }
        return nil
    }

    private func details(for verdict: LinkVerdict, link: CheckedLink) -> [String] {
        switch verdict {
        case .listed(let match):
            var lines: [String] = []
            switch match.scope {
            case .address: lines.append("This exact address is on the list.")
            case .host(let host):
                let isThisSite = host == link.originalHost || ThreatIntel.withoutWWW(host) == link.host
                lines.append(isThisSite ? "This site is on the list." : "Its domain, \(host), is on the list.")
            case .ipAddress(let ip): lines.append("Its server, \(ip), is on the list.")
            }
            lines.append(match.reason)
            if let firstSeen = match.listing.firstSeen { lines.append("First reported \(DateFormatting.day(firstSeen)).") }
            lines.append("Don't open it. If you already did, don't sign in, pay or download anything there.")
            return lines
        case .notListed:
            return ["URLhaus and ThreatFox track sites that spread or control malware. Scams and phishing pages are often missing, so stay careful with links you didn't expect."]
        case .localAddress:
            return ["Addresses like this only work inside a home or office network, so the lists don't cover them."]
        }
    }
}

#if DEBUG
#Preview("Link check") {
    NavigationStack { LinkCheckView(model: .preview()) }
}

#Preview("Verdicts") {
    let listing = ThreatIndex.Listing(sources: [.threatFox], threatType: "botnet_cc", malware: "Vidar", firstSeen: .now, threatFoxID: "1601001")
    ScrollView {
        VStack(spacing: 16) {
            LinkCheckResultCard(outcome: .checked(CheckedLink("c2.evil-domain.com")!,
                                                  .listed(LinkMatch(scope: .host("c2.evil-domain.com"), listing: listing))))
            LinkCheckResultCard(outcome: .checked(CheckedLink("example.com")!, .notListed))
            LinkCheckResultCard(outcome: .checked(CheckedLink("192.168.1.1")!, .localAddress))
        }
        .padding(16)
    }
    .background(Color(.systemGroupedBackground))
}
#endif
