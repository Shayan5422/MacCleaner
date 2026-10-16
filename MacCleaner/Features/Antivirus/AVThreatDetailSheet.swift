import SwiftUI

/// Everything known about one detection, with the actions.
struct AVThreatDetailSheet: View {
    let threat: AVThreat
    var model: AntivirusViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var signature: SecurityCodeEvaluation?
    @State private var dates: (created: Date?, modified: Date?)?

    var body: some View {
        VStack(spacing: 0) {
            header.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(threat.category.explanation)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Card("Detection", symbol: "ladybug") {
                        VStack(alignment: .leading, spacing: 6) {
                            if let detection = threat.detections.first {
                                AVInfoRow(label: "Signature", value: detection.signatureName)
                                AVInfoRow(label: "Database", value: threat.sourceTitle)
                                if threat.detections.count > 1 {
                                    AVInfoRow(label: "Also matched", value: threat.detections.dropFirst().map(\.signatureName).joined(separator: ", "))
                                }
                            }
                            if threat.detections.isEmpty, let match = threat.origin?.intelMatch {
                                AVInfoRow(label: "Reason", value: "The download address is listed by \(match.source)", valueColor: .red)
                            }
                            if let rule = threat.ruleMatch {
                                AVInfoRow(label: "Rule", value: rule.title)
                                AVInfoRow(label: "Family", value: rule.family)
                            }
                            if let member = threat.memberPath { AVInfoRow(label: "Inside archive", value: member) }
                            if threat.limitsReached {
                                AVInfoRow(label: "Note", value: "Parts of an archive inside this file were too large or too deeply nested to scan.")
                            }
                            AVInfoRow(label: "Found by", value: "\(threat.foundBy.title), \(DateFormatting.short(threat.detectedAt))")
                        }
                    }
                    Card("File", symbol: "doc") {
                        VStack(alignment: .leading, spacing: 6) {
                            AVPathRow(label: "Location", path: threat.path)
                            if let app = threat.enclosingApp { AVPathRow(label: "Inside app", path: app) }
                            AVInfoRow(label: "Size", value: ByteFormatting.string(threat.size))
                            if let dates {
                                if let created = dates.created { AVInfoRow(label: "Created", value: DateFormatting.short(created)) }
                                if let modified = dates.modified { AVInfoRow(label: "Modified", value: DateFormatting.short(modified)) }
                            }
                            if let sha256 = threat.sha256 {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("SHA-256").foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                                    Text(sha256.prefix(32) + "\n" + sha256.dropFirst(32))
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 4)
                                    Button { FinderActions.copyPath(sha256) } label: { Image(systemName: "doc.on.doc") }
                                        .buttonStyle(.borderless)
                                        .help("Copy the SHA-256")
                                }
                                .font(.callout)
                            }
                        }
                    }
                    Card("Code signature", symbol: "signature") {
                        if let signature {
                            VStack(alignment: .leading, spacing: 6) {
                                AVInfoRow(label: "Status", value: signature.summary,
                                          valueColor: signature.category.isSignatureProblem ? .red : (signature.category.isIdentifiedDeveloper ? .green : .primary))
                                if let developer = signature.developer { AVInfoRow(label: "Developer", value: developer) }
                                if let team = signature.signature.teamIdentifier { AVInfoRow(label: "Team ID", value: team) }
                                if let identifier = signature.signature.identifier { AVInfoRow(label: "Identifier", value: identifier) }
                                AVInfoRow(label: "Notarization", value: signature.notarization)
                            }
                        } else {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Checking the signature…").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let origin = threat.origin {
                        Card("Where it came from", symbol: "arrow.down.circle") {
                            VStack(alignment: .leading, spacing: 6) {
                                if let url = origin.downloadURL { AVInfoRow(label: "Downloaded from", value: url) }
                                if origin.urls.count > 1 { AVInfoRow(label: "Page", value: origin.urls[1]) }
                                if let agent = origin.agent { AVInfoRow(label: "Downloaded by", value: agent) }
                                if let date = origin.downloadedAt { AVInfoRow(label: "Downloaded", value: DateFormatting.short(date)) }
                                if let match = origin.intelMatch {
                                    AVInfoRow(label: "Listed by", value: match.source, valueColor: .red)
                                    AVInfoRow(label: "Listed as", value: [match.threatType.replacingOccurrences(of: "_", with: " "), match.malware].compactMap { $0 }.joined(separator: " · "))
                                    if let reference = match.reference {
                                        Link("View the listing on abuse.ch", destination: reference).font(.callout)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            Divider()
            footer.padding(16)
        }
        .frame(width: 640, height: 600)
        .task {
            let path = threat.path
            async let evaluation = BackgroundWork.run(qos: .userInitiated) { SecurityCodeTrust.evaluate(path: path) }
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            dates = (attributes?[.creationDate] as? Date, attributes?[.modificationDate] as? Date)
            signature = await evaluation
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            FileIcon(path: threat.enclosingApp ?? threat.path, size: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text(threat.name)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    AVCategoryBadge(category: threat.category)
                    Text(threat.fileName).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let sha256 = threat.sha256 {
                Button("Search VirusTotal for This Hash") { model.openVirusTotal(sha256: sha256) }
                    .help("Opens virustotal.com in your browser to look up the SHA-256. The file isn't uploaded.")
            }
            Button("Reveal in Finder") { FinderActions.reveal(threat.path) }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if threat.enclosingApp != nil {
                Button("Move App to Virus Chest") {
                    dismiss()
                    model.moveToChest(threat, wholeApp: true)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button("Move to Virus Chest") {
                    dismiss()
                    model.moveToChest(threat)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
