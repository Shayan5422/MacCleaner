import Foundation

/// One reason an item was flagged.
struct SecurityAssessmentReason: Sendable, Hashable {
    var severity: FindingSeverity
    var code: String
    var text: String
}

/// Applies the security rules to startup items: known adware rules first, then
/// heuristics for signatures, locations, inline code and scripts.
enum SecurityPersistenceAnalyzer {
    /// Everything that is unusual about `item`, plus the adware rule it matches (if any).
    static func assess(
        _ item: StartupItem,
        scriptRisks: [SecurityShellRisk] = [],
        home: String = LaunchdLocations.home
    ) -> (reasons: [SecurityAssessmentReason], match: SecurityPUAMatch?) {
        var reasons: [SecurityAssessmentReason] = []
        let match = puaMatch(for: item, home: home)
        if let match {
            reasons.append(SecurityAssessmentReason(severity: match.severity, code: "pua", text: match.explanation))
        }

        if let error = item.parseError {
            reasons.append(SecurityAssessmentReason(severity: .info, code: "damaged", text: "The property list is damaged, so launchd ignores it (\(error))."))
            return (reasons, match)
        }
        if let definition = item.definition, definition.isEmpty {
            reasons.append(SecurityAssessmentReason(severity: .info, code: "empty", text: "The property list doesn't define a program, so launchd ignores it."))
            return (reasons, match)
        }
        if StartupHeuristics.isBroken(item) {
            let missing = item.targetPath ?? item.analysis?.executable ?? item.analysis?.openTarget ?? item.name
            reasons.append(SecurityAssessmentReason(severity: .info, code: "broken",
                                                    text: "The program it starts no longer exists (\(PathUtilities.abbreviate(missing)))."))
            return (reasons, match)
        }
        // Helpers inside app bundles are covered by the app's own signature check.
        guard item.kind != .appBackgroundItem else { return (reasons, match) }

        let category = item.code?.category
        if let label = item.label, item.kind != .loginItem, LaunchctlClient.isProtectedLabel(label),
           let category, category != .apple, category != .unknown, category != .missing {
            reasons.append(SecurityAssessmentReason(severity: .suspicious, code: "apple-name",
                                                    text: "Uses an Apple-style name (“\(label)”) but its program isn't signed by Apple."))
        }

        switch category {
        case .invalid?:
            reasons.append(SecurityAssessmentReason(severity: .suspicious, code: "signature-invalid",
                                                    text: "The program's code signature is invalid: it was modified after signing or is damaged."))
        case .revoked?:
            reasons.append(SecurityAssessmentReason(severity: .suspicious, code: "signature-revoked",
                                                    text: "Apple revoked the certificate used to sign the program. Apple does this when a developer distributed malware or misused their certificate."))
        case .untrustedCertificate?:
            let signer = item.code?.signature.authorities.first.map { " (“\($0)”)" } ?? ""
            reasons.append(SecurityAssessmentReason(severity: .suspicious, code: "signature-untrusted",
                                                    text: "The program is signed with a certificate that isn't issued by Apple\(signer). Gatekeeper doesn't trust it; modified or cracked software often looks like this."))
        case .unsigned?, .adHoc?:
            reasons.append(SecurityAssessmentReason(severity: .suspicious, code: "signature-missing",
                                                    text: "The program isn't signed by an identified developer (\(category == .adHoc ? "ad-hoc signature" : "no signature"))."))
        default:
            break
        }

        var locationTexts = Set<String>()
        let paths = [item.targetPath, item.analysis?.executable, item.analysis?.scriptPath].compactMap { $0 }
        for path in paths {
            for issue in SecurityLocationHeuristics.issues(for: path, home: home) where locationTexts.insert(issue.explanation).inserted {
                reasons.append(SecurityAssessmentReason(severity: .suspicious, code: "location", text: issue.explanation))
            }
        }

        if let analysis = item.analysis, let inline = analysis.inlineCode {
            let language = analysis.interpreter?.title ?? "script"
            if let risk = SecurityShellRiskDetector.risk(inInlineCode: inline) {
                reasons.append(SecurityAssessmentReason(severity: .suspicious, code: "inline-download",
                                                        text: "Runs inline \(language) code that \(lowercasedFirst(risk.explanation))"))
            } else {
                reasons.append(SecurityAssessmentReason(severity: .suspicious, code: "inline-code",
                                                        text: "Runs inline \(language) code instead of a program file. Developer tools do this, but so does malware that wants to hide what it runs."))
            }
        }

        for risk in scriptRisks.prefix(3) {
            let line = risk.lineNumber.map { " Line \($0): \(risk.line)" } ?? " \(risk.line)"
            reasons.append(SecurityAssessmentReason(severity: .suspicious, code: "script-risk",
                                                    text: "The script it runs \(lowercasedFirst(risk.kind.explanation))\(line)"))
        }

        if let definition = item.definition, definition.runAtLoad, definition.keepAlive == .always,
           let category, category.isUnknownDeveloper {
            reasons.append(SecurityAssessmentReason(severity: .suspicious, code: "keepalive-unknown",
                                                    text: "Starts at login and is restarted whenever it quits, but no identified developer signed it."))
        }
        return (reasons, match)
    }

    /// Converts an assessment to a finding; nil when nothing was flagged.
    static func finding(for item: StartupItem, reasons: [SecurityAssessmentReason], match: SecurityPUAMatch?) -> SecurityFinding? {
        guard let severity = reasons.map(\.severity).max() else { return nil }
        let kindTitle = SecurityPersistenceItem.Kind(item.kind).shortTitle
        let title: String
        let category: SecurityFindingCategory
        if let match, match.strength == .exact {
            title = match.ruleTitle
            category = .adware
        } else if severity >= .suspicious {
            title = "Suspicious \(kindTitle): \(item.name)"
            category = match != nil ? .adware : .persistence
        } else if reasons.contains(where: { $0.code == "broken" }) {
            title = "Broken \(kindTitle): \(item.name)"
            category = .persistence
        } else {
            title = "Invalid \(kindTitle): \(item.name)"
            category = .persistence
        }

        let fingerprint = item.analysis?.commandLine ?? item.targetPath ?? ""
        return SecurityFinding(
            id: "persistence|\(item.id)|\(fingerprint)",
            severity: severity,
            category: category,
            title: title,
            summary: reasons.first(where: { $0.severity == severity })?.text ?? reasons[0].text,
            reasons: reasons.map(\.text),
            path: item.plistPath ?? item.targetPath,
            evidence: evidence(for: item, match: match),
            recommendation: recommendation(for: item, severity: severity),
            remediation: remediation(for: item),
            ruleName: match?.ruleTitle
        )
    }

    /// The inventory entry for a startup item.
    static func inventoryItem(for item: StartupItem, finding: SecurityFinding?) -> SecurityPersistenceItem {
        SecurityPersistenceItem(
            id: "startup|" + item.id,
            kind: SecurityPersistenceItem.Kind(item.kind),
            name: item.name,
            location: item.plistPath ?? item.targetPath,
            target: item.targetPath,
            detail: item.triggerSummary + " · " + item.state.title,
            trust: item.code?.category,
            trustSummary: item.code?.summary,
            developer: item.developerDescription,
            isRunning: item.state.isRunning,
            severity: finding?.severity,
            findingID: finding?.id
        )
    }

    // MARK: - Helpers

    private static func puaMatch(for item: StartupItem, home: String) -> SecurityPUAMatch? {
        var best: SecurityPUAMatch?
        func consider(_ candidate: SecurityPUAMatch?) {
            guard let candidate else { return }
            if best == nil || (best?.strength == .prefix && candidate.strength == .exact) { best = candidate }
        }
        if let label = item.label { consider(SecurityPUARules.match(identifier: label)) }
        for path in [item.plistPath, item.plistLinkDestination, item.targetPath, item.analysis?.executable].compactMap({ $0 }) {
            consider(SecurityPUARules.match(path: path, home: home))
        }
        if item.kind == .loginItem || item.kind == .appBackgroundItem, let identifier = item.owner?.bundleIdentifier {
            consider(SecurityPUARules.match(identifier: identifier))
        }
        return best
    }

    static func evidence(for item: StartupItem, match: SecurityPUAMatch?) -> [SecurityEvidence] {
        var evidence: [SecurityEvidence] = [SecurityEvidence(label: "Type", value: item.kind.title)]
        if let label = item.label { evidence.append(SecurityEvidence(label: "Label", value: label)) }
        if let plist = item.plistPath { evidence.append(SecurityEvidence(label: "Property list", value: plist, isPath: true)) }
        if let link = item.plistLinkDestination { evidence.append(SecurityEvidence(label: "Links to", value: link, isPath: true)) }
        if let target = item.targetPath { evidence.append(SecurityEvidence(label: "Runs", value: target, isPath: true)) }
        if let analysis = item.analysis, analysis.arguments.count > 1 {
            let line = analysis.commandLine
            evidence.append(SecurityEvidence(label: "Command", value: line.count > 400 ? String(line.prefix(399)) + "…" : line))
        }
        if let code = item.code {
            evidence.append(SecurityEvidence(label: "Signature", value: code.summary))
            if let developer = code.developer { evidence.append(SecurityEvidence(label: "Developer", value: developer)) }
            if let team = code.signature.teamIdentifier { evidence.append(SecurityEvidence(label: "Team ID", value: team)) }
        }
        evidence.append(SecurityEvidence(label: "Starts", value: item.triggerSummary))
        evidence.append(SecurityEvidence(label: "Status", value: item.state.title))
        if let owner = item.owner { evidence.append(SecurityEvidence(label: "Belongs to", value: owner.name)) }
        if let match { evidence.append(SecurityEvidence(label: "Rule", value: match.ruleTitle)) }
        return evidence
    }

    private static func recommendation(for item: StartupItem, severity: FindingSeverity) -> String {
        if severity == .info {
            switch item.kind {
            case .userAgent: return "It does nothing. Move its property list to the Trash to tidy up."
            case .loginItem: return "Remove it from your login items."
            case .systemAgent, .systemDaemon: return "Reveal it in Finder and move it to the Trash there (Finder asks for an administrator password)."
            case .appBackgroundItem: return "Reinstall or remove the app it belongs to."
            }
        }
        switch item.kind {
        case .userAgent:
            return "If you don't recognize it, turn it off (reversible) or move its property list to the Trash, then remove the app that installed it."
        case .loginItem:
            return "If you don't recognize it, remove it from your login items and check where the app came from."
        case .systemAgent, .systemDaemon:
            return "Changing system-wide items requires an administrator. If you don't recognize it, reveal it in Finder and move it to the Trash there (Finder asks for your password), or uninstall the app that installed it."
        case .appBackgroundItem:
            return "Turn it off in the app or in System Settings › General › Login Items & Extensions, or uninstall the app."
        }
    }

    private static func remediation(for item: StartupItem) -> SecurityRemediation {
        switch item.kind {
        case .userAgent:
            guard let plist = item.plistPath else { return .none }
            return item.isProtected ? .systemLaunchItem(plistPath: plist) : .userLaunchAgent(label: item.label, plistPath: plist)
        case .systemAgent, .systemDaemon:
            return item.plistPath.map { .systemLaunchItem(plistPath: $0) } ?? .none
        case .loginItem:
            return .loginItem(name: item.name, path: item.targetPath)
        case .appBackgroundItem:
            return item.containingAppPath.map { .appBackgroundItem(appPath: $0) } ?? .settings(.loginItems)
        }
    }

    private static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}
