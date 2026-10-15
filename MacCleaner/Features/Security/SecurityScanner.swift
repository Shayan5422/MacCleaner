import Foundation

/// Headless security scan: persistence locations, code signatures, quarantined
/// downloads, known adware rules and macOS protections. It has no UI dependencies,
/// so the Security page, Smart Scan and scheduled automation can all use it.
///
/// This is not antivirus software: it reviews the places where unwanted software
/// usually hides and relies on macOS's XProtect for malware signatures.
struct SecurityScanner: Sendable {
    /// Where login items come from. Reading them needs Automation access to System Events.
    enum LoginItemsSource: Sendable {
        /// Read them only when access was already granted (never shows a prompt).
        case readIfAuthorized
        /// Use items read earlier on the main actor.
        case provided([StartupLoginItemRecord])
        case skip
    }

    var loginItems: LoginItemsSource
    var downloadsFolder: String
    /// Reviews quarantined items in Downloads. Reading Downloads is protected by macOS, so the
    /// first scan without Full Disk Access may show the system's folder-access prompt; scheduled
    /// scans can turn this off.
    var includesDownloads: Bool
    /// Saves a summary for the Dashboard when the scan completes.
    var recordsSummary: Bool
    /// Overrides the stored "ignored" findings (tests).
    var ignoredFindingIDs: Set<String>?

    init(
        loginItems: LoginItemsSource = .readIfAuthorized,
        downloadsFolder: String? = nil,
        includesDownloads: Bool = true,
        recordsSummary: Bool = true
    ) {
        self.loginItems = loginItems
        self.downloadsFolder = downloadsFolder ?? LaunchdLocations.home + "/Downloads"
        self.includesDownloads = includesDownloads
        self.recordsSummary = recordsSummary
    }

    func scan(progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) async -> SecurityReport {
        let started = Date()
        var limitations: [String] = []
        var findings: [SecurityFinding] = []
        var inventory: [SecurityPersistenceItem] = []

        progress(0.01, "Checking macOS protections…")
        async let postureResult = SecurityPostureChecker.check()

        // Login items and launchd jobs.
        let records: [StartupLoginItemRecord]?
        switch loginItems {
        case .readIfAuthorized: records = await StartupLoginItemsService.recordsIfAuthorized()
        case .provided(let provided): records = provided
        case .skip: records = nil
        }
        if records == nil {
            limitations.append("Login items weren't checked: Mac Cleaner needs Automation access to System Events (System Settings › Privacy & Security › Automation). You can review them on the Startup Items page.")
        }

        progress(0.04, "Reviewing startup items…")
        let startup = await StartupInventoryScanner().scan(loginItems: records) { fraction, message in
            progress(0.04 + fraction * 0.36, message)
        }
        let scriptPaths = Array(Set(startup.items.compactMap(\.analysis?.scriptPath)))
        let scriptRisks = await BackgroundWork.run(qos: .userInitiated) { () -> [String: [SecurityShellRisk]] in
            var risks: [String: [SecurityShellRisk]] = [:]
            for path in scriptPaths {
                if let text = SecuritySystemInventory.readText(path) { risks[path] = SecurityShellRiskDetector.risks(in: text) }
            }
            return risks
        }
        for item in startup.items {
            let assessment = SecurityPersistenceAnalyzer.assess(item, scriptRisks: item.analysis?.scriptPath.flatMap { scriptRisks[$0] } ?? [])
            let finding = SecurityPersistenceAnalyzer.finding(for: item, reasons: assessment.reasons, match: assessment.match)
            if let finding { findings.append(finding) }
            inventory.append(SecurityPersistenceAnalyzer.inventoryItem(for: item, finding: finding))
        }
        limitations += startup.notes.filter { !$0.hasPrefix("Login items") }

        if Task.isCancelled {
            return await finish(started: started, posture: postureResult, findings: findings, inventory: inventory,
                                applications: [], downloads: [], extensions: [], limitations: limitations, cancelled: true, progress: progress)
        }

        // Shell startup files, cron, authorization plug-ins, system extensions, profiles.
        progress(0.42, "Checking shell startup files and scheduled tasks…")
        async let cronResult = SecuritySystemInventory.cronJobs()
        async let extensionsResult = SecuritySystemInventory.systemExtensions()
        async let profilesResult = SecuritySystemInventory.profiles()
        let local = await BackgroundWork.run(qos: .userInitiated) { Self.localChecks() }
        findings += local.findings
        inventory += local.inventory
        limitations += local.limitations

        let cron = await cronResult
        if let cron {
            let result = Self.cronFindings(cron)
            findings += result.findings
            inventory += result.inventory
        } else {
            limitations.append("Cron jobs couldn't be read.")
        }

        let extensions = await extensionsResult ?? []
        if await extensionsResult == nil { limitations.append("System extensions couldn't be listed.") }
        let extensionResult = Self.systemExtensionFindings(extensions)
        findings += extensionResult.findings
        inventory += extensionResult.inventory

        if let profiles = await profilesResult {
            let result = Self.profileFindings(profiles)
            findings += result.findings
            inventory += result.inventory
        } else {
            limitations.append("Configuration profiles couldn't be checked without administrator rights.")
        }

        if Task.isCancelled {
            return await finish(started: started, posture: postureResult, findings: findings, inventory: inventory,
                                applications: [], downloads: [], extensions: extensions, limitations: limitations, cancelled: true, progress: progress)
        }

        // Installed apps.
        progress(0.5, "Checking app signatures…")
        let apps = await BackgroundWork.run(qos: .userInitiated) { ApplicationCatalog.installedApplications(includeSystemApps: false) }
        let counter = StartupProgressCounter(total: apps.count)
        let applications = await StartupParallel.map(apps, limit: 6) { app in
            let evaluation = await BackgroundWork.run(qos: .userInitiated) { SecurityCodeTrust.evaluate(path: app.path) }
            progress(0.5 + 0.3 * counter.advance(), "Checking app signatures…")
            return SecurityAppRecord(path: app.path, name: app.name, bundleIdentifier: app.bundleIdentifier,
                                     version: app.displayVersion, evaluation: evaluation)
        }
        findings += Self.applicationFindings(applications)

        if Task.isCancelled {
            return await finish(started: started, posture: postureResult, findings: findings, inventory: inventory,
                                applications: applications, downloads: [], extensions: extensions, limitations: limitations, cancelled: true, progress: progress)
        }

        // Quarantined downloads.
        var downloads: (files: [SecurityQuarantinedFile], readable: Bool) = ([], true)
        if includesDownloads {
            progress(0.8, "Reviewing quarantined downloads…")
            downloads = await Self.scanDownloads(folder: downloadsFolder)
            if !downloads.readable {
                limitations.append("Your Downloads folder couldn't be read. Allow Mac Cleaner to access it (or grant Full Disk Access) to review downloaded installers.")
            }
            findings += Self.downloadFindings(downloads.files)
        } else {
            limitations.append("Downloads weren't reviewed in this scan.")
        }

        // Documented adware install locations that exist on this Mac.
        progress(0.95, "Checking known adware locations…")
        let known = await BackgroundWork.run(qos: .userInitiated) { SecurityPUARules.installedKnownPaths() }
        findings += Self.knownPathFindings(known, alreadyFlagged: findings.compactMap(\.path))

        return await finish(started: started, posture: postureResult, findings: findings, inventory: inventory,
                            applications: applications, downloads: downloads.files, extensions: extensions,
                            limitations: limitations, cancelled: false, progress: progress)
    }

    // MARK: - Assembly

    private func finish(
        started: Date,
        posture: SecurityPosture,
        findings scanned: [SecurityFinding],
        inventory: [SecurityPersistenceItem],
        applications: [SecurityAppRecord],
        downloads: [SecurityQuarantinedFile],
        extensions: [SecuritySystemExtension],
        limitations: [String],
        cancelled: Bool,
        progress: @Sendable (Double, String) -> Void
    ) async -> SecurityReport {
        var findings = posture.recommendations() + scanned
        var seen = Set<String>()
        findings = findings.filter { seen.insert($0.id).inserted }
        let ignored = ignoredFindingIDs ?? SecurityStore.ignoredFindingIDs()
        for index in findings.indices { findings[index].isIgnored = ignored.contains(findings[index].id) }
        findings.sort { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }

        var updatedInventory = inventory
        let findingsByID = Dictionary(findings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in updatedInventory.indices {
            if let id = updatedInventory[index].findingID, findingsByID[id]?.isIgnored == true {
                updatedInventory[index].severity = nil
            }
        }

        let report = SecurityReport(
            startedAt: started,
            finishedAt: Date(),
            posture: posture,
            findings: findings,
            persistenceItems: updatedInventory.sorted { lhs, rhs in
                let left = lhs.severity?.rawValue ?? -1
                let right = rhs.severity?.rawValue ?? -1
                if left != right { return left > right }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            },
            applications: applications.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            quarantinedFiles: downloads.sorted { ($0.downloadedDate ?? .distantPast) > ($1.downloadedDate ?? .distantPast) },
            systemExtensions: extensions,
            limitations: limitations,
            wasCancelled: cancelled
        )
        if recordsSummary && !cancelled { SecurityStore.saveLastScanSummary(report.scanSummary) }
        progress(1, cancelled ? "Stopped" : "Done")
        return report
    }

    // MARK: - Local checks (blocking)

    private struct LocalChecks: Sendable {
        var findings: [SecurityFinding] = []
        var inventory: [SecurityPersistenceItem] = []
        var limitations: [String] = []
    }

    private static func localChecks() -> LocalChecks {
        var result = LocalChecks()

        for file in SecuritySystemInventory.existingShellStartupFiles() {
            let name = (file as NSString).lastPathComponent
            guard let text = SecuritySystemInventory.readText(file) else {
                result.inventory.append(SecurityPersistenceItem(id: "shell|" + file, kind: .shellStartupFile, name: name, location: file,
                                                                detail: "Couldn't be read"))
                continue
            }
            let risks = SecurityShellRiskDetector.risks(in: text)
            var firstFindingID: String?
            for risk in risks {
                let id = "shell|\(file)|\(SecurityHash.fnv1a(risk.line))"
                firstFindingID = firstFindingID ?? id
                result.findings.append(SecurityFinding(
                    id: id,
                    severity: .suspicious,
                    category: .shellStartup,
                    title: "\(name) runs downloaded code",
                    summary: risk.kind.explanation + " It runs every time you open a Terminal window.",
                    reasons: [risk.kind.explanation],
                    path: file,
                    evidence: [
                        SecurityEvidence(label: "File", value: file, isPath: true),
                        SecurityEvidence(label: "Line", value: risk.lineNumber.map(String.init) ?? "—"),
                        SecurityEvidence(label: "Command", value: risk.line),
                    ],
                    recommendation: "If you didn't add this line yourself, open \(name) in a text editor and delete it, then open a new Terminal window.",
                    remediation: .shellStartupFile(path: file)
                ))
            }
            result.inventory.append(SecurityPersistenceItem(
                id: "shell|" + file, kind: .shellStartupFile, name: name, location: file,
                detail: risks.isEmpty ? "No risky commands found" : "\(risks.count) risky command\(risks.count == 1 ? "" : "s")",
                severity: risks.isEmpty ? nil : .suspicious, findingID: firstFindingID
            ))
        }

        if let plugins = SecuritySystemInventory.authorizationPlugins() {
            for plugin in plugins {
                let evaluation = SecurityCodeTrust.evaluate(path: plugin)
                let name = ((plugin as NSString).lastPathComponent as NSString).deletingPathExtension
                let problem = evaluation.category.isSignatureProblem || evaluation.category.lacksIdentity
                let id = "authplugin|\(plugin)|\(evaluation.category.rawValue)"
                let finding = SecurityFinding(
                    id: id,
                    severity: problem ? .suspicious : .info,
                    category: .authorizationPlugin,
                    title: problem ? "Unsigned login plug-in: \(name)" : "Third-party login plug-in: \(name)",
                    summary: problem
                        ? "An authorization plug-in runs inside the macOS login window and can see passwords. This one isn't signed by an identified developer."
                        : "An authorization plug-in from \(evaluation.developer ?? "a third-party developer") runs inside the macOS login window. Keep it only if you rely on its software (for example a company sign-in tool).",
                    reasons: [evaluation.summary],
                    path: plugin,
                    evidence: [
                        SecurityEvidence(label: "Plug-in", value: plugin, isPath: true),
                        SecurityEvidence(label: "Signature", value: evaluation.summary),
                        SecurityEvidence(label: "Developer", value: evaluation.developer ?? "Unknown"),
                    ],
                    recommendation: "Removing it requires an administrator: uninstall the software that installed it, or reveal it in Finder and move it to the Trash there.",
                    remediation: .authorizationPlugin(path: plugin)
                )
                result.findings.append(finding)
                result.inventory.append(SecurityPersistenceItem(
                    id: "authplugin|" + plugin, kind: .authorizationPlugin, name: name, location: plugin, target: plugin,
                    detail: "Runs in the login window", trust: evaluation.category, trustSummary: evaluation.summary,
                    developer: evaluation.developer, severity: finding.severity, findingID: id
                ))
            }
        } else {
            result.limitations.append("Authorization plug-ins couldn't be listed.")
        }
        return result
    }

    // MARK: - Cron, extensions, profiles

    static func cronFindings(_ jobs: [SecurityCronJob]) -> (findings: [SecurityFinding], inventory: [SecurityPersistenceItem]) {
        var findings: [SecurityFinding] = []
        var inventory: [SecurityPersistenceItem] = []
        for job in jobs {
            var reasons: [String] = []
            if let risk = SecurityShellRiskDetector.risk(inLine: job.command) { reasons.append(risk.explanation) }
            if let program = job.command.split(separator: " ").first.map(String.init), program.hasPrefix("/") {
                reasons += SecurityLocationHeuristics.issues(for: program).map(\.explanation)
            }
            let id = "cron|\(SecurityHash.fnv1a(job.schedule + " " + job.command))"
            if !reasons.isEmpty {
                findings.append(SecurityFinding(
                    id: id,
                    severity: .suspicious,
                    category: .scheduledTask,
                    title: "Suspicious cron job",
                    summary: reasons[0],
                    reasons: reasons,
                    evidence: [
                        SecurityEvidence(label: "Schedule", value: job.schedule),
                        SecurityEvidence(label: "Command", value: SecurityShellRiskDetector.displayLine(job.command)),
                        SecurityEvidence(label: "Crontab line", value: String(job.lineNumber)),
                    ],
                    recommendation: "If you don't recognize it, remove it: run `crontab -e` in Terminal and delete the line.",
                    remediation: .cronJobs
                ))
            }
            inventory.append(SecurityPersistenceItem(
                id: "cronitem|" + id, kind: .cronJob, name: SecurityShellRiskDetector.displayLine(job.command),
                detail: "Schedule: \(job.schedule)", severity: reasons.isEmpty ? nil : .suspicious, findingID: reasons.isEmpty ? nil : id
            ))
        }
        if !jobs.isEmpty {
            findings.append(SecurityFinding(
                id: "cron|summary|\(jobs.count)",
                severity: .info,
                category: .scheduledTask,
                title: "\(jobs.count) cron job\(jobs.count == 1 ? " is" : "s are") scheduled for your account",
                summary: "Few apps use cron today. Make sure you recognize every scheduled command.",
                evidence: jobs.prefix(10).map { SecurityEvidence(label: $0.schedule, value: SecurityShellRiskDetector.displayLine($0.command)) },
                recommendation: "Review them with `crontab -l` in Terminal and remove unknown ones with `crontab -e`.",
                remediation: .cronJobs
            ))
        }
        return (findings, inventory)
    }

    static func systemExtensionFindings(_ extensions: [SecuritySystemExtension]) -> (findings: [SecurityFinding], inventory: [SecurityPersistenceItem]) {
        var findings: [SecurityFinding] = []
        var inventory: [SecurityPersistenceItem] = []
        for item in extensions {
            var findingID: String?
            var severity: FindingSeverity?
            if let match = SecurityPUARules.match(identifier: item.bundleIdentifier) {
                let id = "sysext|\(item.bundleIdentifier)"
                findingID = id
                severity = match.severity
                findings.append(SecurityFinding(
                    id: id, severity: match.severity, category: .adware, title: match.ruleTitle, summary: match.explanation,
                    reasons: [match.explanation],
                    evidence: [
                        SecurityEvidence(label: "Extension", value: item.name),
                        SecurityEvidence(label: "Bundle identifier", value: item.bundleIdentifier),
                        SecurityEvidence(label: "Team ID", value: item.teamIdentifier),
                        SecurityEvidence(label: "State", value: item.state),
                    ],
                    recommendation: "Turn it off in System Settings › General › Login Items & Extensions, then uninstall the app that installed it.",
                    remediation: .settings(.loginItems), ruleName: match.ruleTitle
                ))
            }
            inventory.append(SecurityPersistenceItem(
                id: "sysext|" + item.id, kind: .systemExtension, name: item.name,
                detail: "\(item.categoryTitle) · \(item.state)\(item.version.isEmpty ? "" : " · " + item.version)",
                developer: item.teamIdentifier.isEmpty ? nil : "Team \(item.teamIdentifier)",
                isRunning: item.isActive && item.isEnabled, severity: severity, findingID: findingID
            ))
        }
        return (findings, inventory)
    }

    static func profileFindings(_ profiles: SecurityProfilesStatus) -> (findings: [SecurityFinding], inventory: [SecurityPersistenceItem]) {
        var inventory: [SecurityPersistenceItem] = profiles.userProfileIdentifiers.map {
            SecurityPersistenceItem(id: "profile|" + $0, kind: .configurationProfile, name: $0, detail: "Installed for your account")
        }
        let systemCount = profiles.systemProfileCount ?? 0
        if systemCount > 0 {
            inventory.append(SecurityPersistenceItem(id: "profile|system", kind: .configurationProfile,
                                                     name: "\(systemCount) profile\(systemCount == 1 ? "" : "s") for this Mac",
                                                     detail: "Details require an administrator"))
        }
        let total = systemCount + profiles.userProfileIdentifiers.count
        guard total > 0 else { return ([], inventory) }
        let managed = profiles.isMDMEnrolled == true
        let finding = SecurityFinding(
            id: "profiles|\(SecurityHash.fnv1a("\(systemCount)|" + profiles.userProfileIdentifiers.joined(separator: ",")))",
            severity: .info,
            category: .configurationProfile,
            title: "\(total) configuration profile\(total == 1 ? " is" : "s are") installed",
            summary: managed
                ? "This Mac is enrolled in device management, so your organization may install profiles."
                : "Profiles can change system and browser settings. Adware sometimes installs one to lock the browser's home page or search engine.",
            evidence: profiles.userProfileIdentifiers.map { SecurityEvidence(label: "Profile", value: $0) }
                + (systemCount > 0 ? [SecurityEvidence(label: "For this Mac", value: "\(systemCount)")] : [])
                + [SecurityEvidence(label: "Device management", value: profiles.isMDMEnrolled.map { $0 ? "Enrolled" : "Not enrolled" } ?? "Unknown")],
            recommendation: "Review them in System Settings › General › Device Management and remove any you don't recognize.",
            remediation: .deviceManagement
        )
        for index in inventory.indices { inventory[index].findingID = finding.id }
        return ([finding], inventory)
    }

    // MARK: - Applications

    static func applicationFindings(_ applications: [SecurityAppRecord]) -> [SecurityFinding] {
        var findings: [SecurityFinding] = []
        for app in applications {
            let match = app.bundleIdentifier.flatMap { SecurityPUARules.match(identifier: $0) }
                .map { candidate -> SecurityPUAMatch in
                    if candidate.strength == .prefix, let pathMatch = SecurityPUARules.match(path: app.path) { return pathMatch }
                    return candidate
                } ?? SecurityPUARules.match(path: app.path)
            if let match {
                findings.append(SecurityFinding(
                    id: "app-pua|\(app.path)",
                    severity: match.severity,
                    category: .adware,
                    title: match.strength == .exact ? match.ruleTitle : "\(app.name) matches \(match.rule.family)",
                    summary: match.explanation,
                    reasons: [match.explanation],
                    path: app.path,
                    evidence: appEvidence(app) + [SecurityEvidence(label: "Rule", value: match.ruleTitle)],
                    recommendation: "Quit the app and remove it with the Uninstaller, which also removes its background items and support files.",
                    remediation: .application(path: app.path),
                    ruleName: match.ruleTitle
                ))
                continue
            }
            let category = app.evaluation.category
            guard category.isSignatureProblem else { continue }
            let reason: String
            switch category {
            case .invalid: reason = "The app's code signature is invalid: files were modified after signing or are damaged."
            case .revoked: reason = "Apple revoked the certificate used to sign this app. Apple does this when a developer distributed malware or misused their certificate."
            default:
                let signer = app.evaluation.signature.authorities.first.map { "“\($0)”" } ?? "an unknown authority"
                reason = "The app is signed with a certificate from \(signer) that isn't issued by Apple. Modified or cracked apps often look like this."
            }
            findings.append(SecurityFinding(
                id: "app-signature|\(app.path)|\(category.rawValue)",
                severity: .suspicious,
                category: .codeSignature,
                title: "\(app.name): \(category.title.lowercased())",
                summary: reason,
                reasons: [reason],
                path: app.path,
                evidence: appEvidence(app),
                recommendation: "Reinstall the app from its developer's website or the App Store. If you don't know where it came from, remove it.",
                remediation: .application(path: app.path)
            ))
        }

        let unidentified = applications.filter { $0.evaluation.category.lacksIdentity }
        if !unidentified.isEmpty {
            let names = unidentified.map(\.name).sorted()
            findings.append(SecurityFinding(
                id: "apps-unidentified|\(SecurityHash.fnv1a(names.joined(separator: "|")))",
                severity: .info,
                category: .codeSignature,
                title: "\(unidentified.count) app\(unidentified.count == 1 ? " isn't" : "s aren't") signed by an identified developer",
                summary: "Apps without a developer identity (unsigned or ad-hoc signed) can't be traced to their maker. Open-source builds and apps you built yourself often look like this.",
                evidence: unidentified.prefix(15).map { SecurityEvidence(label: $0.name, value: $0.evaluation.summary) },
                recommendation: "Keep only apps from sources you trust. Use Deep Verify on an app for a full signature check.",
                remediation: .reviewApplications
            ))
        }
        return findings
    }

    static func appEvidence(_ app: SecurityAppRecord) -> [SecurityEvidence] {
        var evidence = [
            SecurityEvidence(label: "App", value: app.path, isPath: true),
            SecurityEvidence(label: "Version", value: app.version),
            SecurityEvidence(label: "Signature", value: app.evaluation.summary),
            SecurityEvidence(label: "Notarization", value: app.evaluation.notarization),
        ]
        if let identifier = app.bundleIdentifier { evidence.insert(SecurityEvidence(label: "Bundle identifier", value: identifier), at: 1) }
        if let developer = app.evaluation.developer { evidence.append(SecurityEvidence(label: "Developer", value: developer)) }
        if let team = app.evaluation.signature.teamIdentifier { evidence.append(SecurityEvidence(label: "Team ID", value: team)) }
        return evidence
    }

    // MARK: - Downloads

    static func scanDownloads(folder: String) async -> (files: [SecurityQuarantinedFile], readable: Bool) {
        let base = await BackgroundWork.run(qos: .userInitiated) { () -> ([SecurityQuarantinedFile], Bool) in
            guard (try? FileManager.default.contentsOfDirectory(atPath: folder)) != nil else { return ([], false) }
            var files = SecurityQuarantineScanner.scan(folder: folder)
            for index in files.indices where files[index].kind.canRunCode {
                files[index].lastOpened = ApplicationCatalog.lastUsedDate(path: files[index].path)
                if files[index].kind == .application {
                    files[index].bundleIdentifier = ApplicationCatalog.read(path: files[index].path)?.bundleIdentifier
                }
                if files[index].kind == .application || files[index].kind == .executable {
                    files[index].evaluation = SecurityCodeTrust.evaluate(path: files[index].path)
                }
            }
            return (files, true)
        }
        var files = base.0
        for index in files.indices where files[index].kind == .installerPackage {
            if let result = try? await ProcessRunner.run("/usr/sbin/pkgutil", arguments: ["--check-signature", files[index].path], timeout: 30),
               !result.timedOut {
                files[index].packageSignature = SecurityPackageSignature.parse(result.combinedOutput)
            }
        }
        return (files, base.1)
    }

    static func downloadFindings(_ files: [SecurityQuarantinedFile], now: Date = Date()) -> [SecurityFinding] {
        var findings: [SecurityFinding] = []
        for file in files {
            let evidence = downloadEvidence(file)
            if let match = file.bundleIdentifier.flatMap({ SecurityPUARules.match(identifier: $0) }) {
                findings.append(SecurityFinding(
                    id: "download-pua|\(file.path)",
                    severity: match.severity,
                    category: .adware,
                    title: match.strength == .exact ? match.ruleTitle : "Download matches \(match.rule.family)",
                    summary: match.explanation,
                    reasons: [match.explanation],
                    path: file.path,
                    evidence: evidence + [SecurityEvidence(label: "Rule", value: match.ruleTitle)],
                    recommendation: "Don't open it. Move it to the Trash.",
                    remediation: .quarantinedFiles(paths: [file.path]),
                    ruleName: match.ruleTitle
                ))
                continue
            }
            guard file.kind == .application || file.kind == .executable, let evaluation = file.evaluation else { continue }
            let category = evaluation.category
            if category.isSignatureProblem || category.lacksIdentity {
                let approved = file.quarantine.isUserApproved
                let severity: FindingSeverity = category.isSignatureProblem || !approved ? .suspicious : .info
                findings.append(SecurityFinding(
                    id: "download-signature|\(file.path)|\(category.rawValue)",
                    severity: severity,
                    category: .download,
                    title: "Downloaded \(file.kind == .application ? "app" : "program") “\(file.name)”: \(category.title.lowercased())",
                    summary: file.gatekeeperNote,
                    reasons: [file.gatekeeperNote] + (approved ? ["You already allowed it to open."] : []),
                    path: file.path,
                    evidence: evidence,
                    recommendation: approved
                        ? "If you no longer trust where it came from, move it to the Trash."
                        : "Only open it if you trust where it came from. Otherwise move it to the Trash.",
                    remediation: .quarantinedFiles(paths: [file.path])
                ))
            }
        }

        let oldInstallers = files.filter { $0.kind.isInstaller && $0.neverOpened && ($0.ageDays(now: now) ?? 0) > 30 }
        if !oldInstallers.isEmpty {
            let total = oldInstallers.reduce(Int64(0)) { $0 + $1.sizeBytes }
            findings.append(SecurityFinding(
                id: "downloads-old-installers|\(SecurityHash.fnv1a(oldInstallers.map(\.path).sorted().joined(separator: "|")))",
                severity: .info,
                category: .download,
                title: "\(oldInstallers.count) old installer\(oldInstallers.count == 1 ? "" : "s") in Downloads were never opened",
                summary: "These apps, packages and disk images were downloaded more than 30 days ago and never opened (\(ByteFormatting.string(total))).",
                evidence: oldInstallers.prefix(12).map {
                    SecurityEvidence(label: $0.name, value: $0.downloadedDate.map { "Downloaded " + DateFormatting.day($0) } ?? $0.kind.title)
                },
                recommendation: "If you don't need them any more, move them to the Trash.",
                remediation: .quarantinedFiles(paths: oldInstallers.map(\.path))
            ))
        }
        return findings
    }

    static func downloadEvidence(_ file: SecurityQuarantinedFile) -> [SecurityEvidence] {
        var evidence = [
            SecurityEvidence(label: "File", value: file.path, isPath: true),
            SecurityEvidence(label: "Type", value: file.kind.title),
            SecurityEvidence(label: "Downloaded by", value: file.quarantine.agent ?? "Unknown app"),
        ]
        if let date = file.downloadedDate { evidence.append(SecurityEvidence(label: "Downloaded", value: DateFormatting.short(date))) }
        evidence.append(SecurityEvidence(label: "Opened", value: file.quarantine.isUserApproved ? "Approved by you" : (file.lastOpened.map { DateFormatting.short($0) } ?? "Never")))
        evidence.append(SecurityEvidence(label: "Gatekeeper", value: file.gatekeeperNote))
        if let evaluation = file.evaluation {
            evidence.append(SecurityEvidence(label: "Signature", value: evaluation.summary))
            if let developer = evaluation.developer { evidence.append(SecurityEvidence(label: "Developer", value: developer)) }
        }
        if let identifier = file.bundleIdentifier { evidence.append(SecurityEvidence(label: "Bundle identifier", value: identifier)) }
        evidence.append(SecurityEvidence(label: "Quarantine flags", value: file.quarantine.flagsDescription))
        return evidence
    }

    // MARK: - Known adware locations

    static func knownPathFindings(_ matches: [SecurityPUAMatch], alreadyFlagged: [String], home: String = LaunchdLocations.home) -> [SecurityFinding] {
        matches.compactMap { match in
            let path = match.matchedValue
            if alreadyFlagged.contains(where: { PathUtilities.isSameOrDescendant($0, of: path) || PathUtilities.isSameOrDescendant(path, of: $0) }) {
                return nil
            }
            let remediation: SecurityRemediation
            if path.hasSuffix(".app") && (path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")) {
                remediation = .application(path: path)
            } else if path.hasPrefix(home + "/Library/") {
                remediation = .libraryItem(path: path)
            } else {
                remediation = .systemLaunchItem(plistPath: path)
            }
            return SecurityFinding(
                id: "known-path|\(path)",
                severity: .threat,
                category: .adware,
                title: match.ruleTitle,
                summary: "A documented component of \(match.rule.family) is installed. \(match.rule.summary)",
                reasons: [match.explanation],
                path: path,
                evidence: [
                    SecurityEvidence(label: "Location", value: path, isPath: true),
                    SecurityEvidence(label: "Family", value: "\(match.rule.family) (\(match.rule.classification.title.lowercased()))"),
                    SecurityEvidence(label: "Rule", value: match.ruleTitle),
                ],
                recommendation: path.hasPrefix(home + "/")
                    ? "Move it to the Trash, then restart your Mac."
                    : "Removing it requires an administrator: reveal it in Finder and move it to the Trash there (Finder asks for your password), then restart.",
                remediation: remediation,
                ruleName: match.ruleTitle
            )
        }
    }
}
