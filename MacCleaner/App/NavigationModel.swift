import Observation
import SwiftUI

/// Which section is showing, plus simple back navigation.
@MainActor
@Observable
final class NavigationModel {
    var selection: AppSection = .dashboard {
        didSet {
            if oldValue != selection { backStack.append(oldValue) }
            if backStack.count > 30 { backStack.removeFirst() }
        }
    }
    private var backStack: [AppSection] = []

    var canGoBack: Bool { !backStack.isEmpty }

    func open(_ section: AppSection) {
        selection = section
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        selection = previous
        backStack.removeLast() // `selection`'s didSet pushed the section we left
    }

    /// Sidebar layout.
    struct Group: Identifiable {
        var title: String
        var sections: [AppSection]
        var id: String { title }
    }

    static let groups: [Group] = [
        Group(title: "Overview", sections: [.dashboard, .smartScan]),
        Group(title: "Cleanup", sections: [.systemJunk, .privacy, .developer]),
        Group(title: "Storage", sections: [.storage, .duplicates, .cloud]),
        Group(title: "Applications", sections: [.uninstaller, .updates, .startup]),
        Group(title: "System", sections: [.performance, .security]),
        Group(title: "Automation", sections: [.automation, .history]),
    ]

    /// ⌘-number shortcuts for the most used sections.
    static let shortcuts: [AppSection: KeyEquivalent] = [
        .dashboard: "1", .smartScan: "2", .systemJunk: "3", .storage: "4", .duplicates: "5",
        .uninstaller: "6", .performance: "7", .security: "8", .privacy: "9", .developer: "0",
    ]
}
