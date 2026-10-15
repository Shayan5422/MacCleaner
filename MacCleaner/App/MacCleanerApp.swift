import AppKit
import SwiftUI

struct MacCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment()

    var body: some Scene {
        Window("Mac Cleaner", id: "main") {
            RootView(environment: environment)
                .environment(environment.services.permissions)
                .frame(minWidth: 1000, minHeight: 660)
        }
        .defaultSize(width: 1260, height: 840)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands(environment: environment) }

        Settings {
            SettingsView(services: environment.services)
                .environment(environment.services.permissions)
        }

        MenuBarExtra(isInserted: menuBarBinding) {
            MenuBarMonitorView(monitor: environment.monitor)
        } label: {
            MenuBarMonitorLabel(monitor: environment.monitor)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { environment.services.settings.showMenuBarExtra },
            set: { environment.services.settings.showMenuBarExtra = $0 }
        )
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationService.shared.activate()
        ActivityLogger.shared.info("Mac Cleaner started", category: .app)
    }

    /// Keep running in the menu bar when the monitor is shown there.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: SettingsManager.Key.showMenuBarExtra)
    }
}

/// Root of the main window: sidebar navigation plus the selected page.
struct RootView: View {
    let environment: AppEnvironment
    @State private var showOnboarding = false

    var body: some View {
        @Bindable var navigation = environment.navigation
        NavigationSplitView {
            SidebarView(navigation: navigation, badges: environment.sidebarBadges)
        } detail: {
            detail(for: navigation.selection)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            navigation.goBack()
                        } label: {
                            Label("Back", systemImage: "chevron.backward")
                        }
                        .disabled(!navigation.canGoBack)
                        .help("Back (⌘[)")
                    }
                }
        }
        .onAppear {
            environment.connectNavigation()
            showOnboarding = !environment.services.settings.hasCompletedOnboarding
        }
        .onChange(of: environment.services.settings.hasCompletedOnboarding) { _, completed in
            showOnboarding = !completed
        }
        .sheet(isPresented: $showOnboarding, onDismiss: {
            environment.services.settings.hasCompletedOnboarding = true
        }) {
            OnboardingView(services: environment.services)
        }
        #if DEBUG
        .task {
            if ScreenshotAutomation.outputDirectory != nil {
                showOnboarding = false
                await ScreenshotAutomation.run(environment: environment, steps: ScreenshotPlan.steps)
            }
        }
        #endif
    }

    @ViewBuilder
    private func detail(for section: AppSection) -> some View {
        switch section {
        case .dashboard: DashboardView(model: environment.dashboard)
        case .smartScan: SmartScanView(model: environment.smartScan)
        case .systemJunk: SystemJunkView(model: environment.systemJunk)
        case .privacy: PrivacyView(model: environment.privacy)
        case .developer: DeveloperToolsView(model: environment.developer)
        case .storage: StorageAnalyzerView(model: environment.storage)
        case .duplicates: DuplicatesView(model: environment.duplicates)
        case .cloud: CloudStorageView(model: environment.cloud)
        case .uninstaller: UninstallerView(model: environment.uninstaller)
        case .updates: UpdatesView(model: environment.updates)
        case .startup: StartupView(model: environment.startup)
        case .performance: PerformanceView(model: environment.performance)
        case .security: SecurityView(model: environment.security)
        case .automation: AutomationView(model: environment.automation)
        case .history: HistoryView(model: environment.history)
        }
    }
}

/// Menu commands and keyboard shortcuts.
struct AppCommands: Commands {
    let environment: AppEnvironment

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Start Smart Scan") {
                environment.navigation.open(.smartScan)
                environment.smartScan.start()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
        CommandMenu("Go") {
            ForEach(NavigationModel.groups) { group in
                Section(group.title) {
                    ForEach(group.sections) { section in
                        if let key = NavigationModel.shortcuts[section] {
                            Button(section.title) { environment.navigation.open(section) }
                                .keyboardShortcut(key, modifiers: .command)
                        } else {
                            Button(section.title) { environment.navigation.open(section) }
                        }
                    }
                }
            }
            Divider()
            Button("Back") { environment.navigation.goBack() }
                .keyboardShortcut("[", modifiers: .command)
        }
        CommandGroup(replacing: .help) {
            Button("Mac Cleaner on GitHub") {
                if let url = URL(string: "https://github.com/Shayan5422/MacCleaner") { NSWorkspace.shared.open(url) }
            }
            Button("Permissions & Privacy Guide") {
                if let url = URL(string: "https://github.com/Shayan5422/MacCleaner/blob/main/docs/PERMISSIONS.md") { NSWorkspace.shared.open(url) }
            }
        }
    }
}
