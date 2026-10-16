import Foundation

/// Smart Scan contribution for startup items: findings only (nothing is removed automatically).
struct StartupSmartScanProvider: SmartScanProvider {
    let area: SmartScanArea = .startup
    /// Read "Open at Login" items when Automation access was already granted (never prompts).
    var includesLoginItems: Bool

    init(includesLoginItems: Bool = true) {
        self.includesLoginItems = includesLoginItems
    }

    func smartScan(context: SmartScanContext) async throws -> SmartScanContribution {
        context.reportProgress(0, "Reading startup items…")
        let records = includesLoginItems ? await StartupLoginItemsService.recordsIfAuthorized() : nil
        try Task.checkCancellation()
        let inventory = await StartupInventoryScanner().scan(loginItems: records) { fraction, message in
            context.reportProgress(min(0.98, fraction), message)
        }
        try Task.checkCancellation()
        let findings = Self.findings(for: inventory)
        context.reportProgress(1, "Startup items reviewed")
        return SmartScanContribution(area: area, findings: findings, summary: Self.summary(for: inventory, findings: findings))
    }

    /// Recommendations for broken, unused and duplicate items, plus "many login items".
    static func findings(for inventory: StartupInventory) -> [Finding] {
        var findings: [Finding] = []
        for item in inventory.items where item.isPotentiallyUnnecessary && !item.isProtected {
            guard let concern = item.concerns.first else { continue }
            let severity: FindingSeverity = item.kind.isUserManageable ? .recommendation : .info
            findings.append(Finding(
                id: "startup|\(item.id)|\(concern.kind.rawValue)",
                area: .startup,
                severity: severity,
                title: "\(concern.title): \(item.name)",
                detail: item.concerns.map(\.explanation).joined(separator: " "),
                path: item.plistPath ?? item.targetPath,
                recommendation: recommendation(for: item, concern: concern),
                destination: .startup
            ))
        }

        let loginItems = inventory.items(of: .loginItem)
        if loginItems.count > StartupHeuristics.manyLoginItemsThreshold {
            findings.append(Finding(
                id: "startup|many-login-items",
                area: .startup,
                severity: .recommendation,
                title: "\(loginItems.count) apps open at login",
                detail: "Every app that opens at login delays the moment your Mac is ready and uses memory in the background.",
                recommendation: "Review the list and remove apps you don't need right after logging in.",
                destination: .startup
            ))
        }
        return findings
    }

    private static func recommendation(for item: StartupItem, concern: StartupConcern) -> String {
        switch item.kind {
        case .userAgent:
            return concern.kind == .broken || concern.kind == .empty
                ? "Move its property list to the Trash on the Startup Items page."
                : "Turn it off on the Startup Items page if you don't need it."
        case .loginItem:
            return "Remove it from your login items on the Startup Items page."
        case .appBackgroundItem:
            return "Turn it off in the app or in System Settings › General › Login Items & Extensions."
        case .systemAgent, .systemDaemon:
            return "It's installed for all users; remove the app that installed it, or ask an administrator."
        }
    }

    private static func summary(for inventory: StartupInventory, findings: [Finding]) -> String {
        let flagged = inventory.potentiallyUnnecessary.filter { !$0.isProtected }.count
        if flagged == 0 { return "\(NumberFormatting.count(inventory.items.count, "startup item")), none look unnecessary" }
        return "\(flagged) of \(inventory.items.count) startup item\(inventory.items.count == 1 ? "" : "s") may be unnecessary"
    }
}
