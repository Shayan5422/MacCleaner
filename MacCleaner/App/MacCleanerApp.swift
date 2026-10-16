import AppKit
import SwiftUI

struct MacCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment()

    var body: some Scene {
        Window("Mac Cleaner", id: AppWindowID.main) {
            RootView(environment: environment)
                .environment(environment.services.permissions)
                .frame(minWidth: 1000, minHeight: 660)
        }
        .defaultSize(width: 1260, height: 840)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands(environment: environment, updates: .shared) }

        Window("About Mac Cleaner", id: AppWindowID.about) {
            AboutView(updates: .shared)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Mac Cleaner Update", id: AppWindowID.update) {
            AppUpdateWindow(controller: .shared)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView(services: environment.services)
                .environment(environment.services.permissions)
        }

        MenuBarExtra(isInserted: menuBarBinding) {
            MenuBarHub(environment: environment)
        } label: {
            MenuBarHubLabel(environment: environment)
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
    func applicationWillFinishLaunching(_ notification: Notification) {
        // A login item starts in the menu bar without opening the main window.
        AppPresence.shared.noteLaunchEvent(NSAppleEventManager.shared().currentAppleEvent)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationService.shared.activate()
        ActivityLogger.shared.info("Mac Cleaner started", category: .app)
        AppPresence.shared.start()
        if !Self.isRunningTests && !Self.isCapturingScreenshots {
            AppUpdateController.shared.startAutomaticChecks()
        }
    }

    /// While the menu bar item is shown, closing the window keeps Mac Cleaner running there.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !MenuBarPreferences.isMenuBarItemShown
    }

    /// A Dock click or opening the app again shows the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        AppPresence.shared.showMainWindow()
        return false
    }

    /// The test runner hosts its tests in the app; it must stay offline and in the foreground.
    static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil || NSClassFromString("XCTestCase") != nil
    }

    static var isCapturingScreenshots: Bool {
        CommandLine.arguments.contains("--capture-screenshots")
    }
}

/// Root of the main window: sidebar navigation plus the selected page.
struct RootView: View {
    let environment: AppEnvironment
    @State private var showOnboarding = false
    @Environment(\.openWindow) private var openWindow
    #if DEBUG
    @Environment(\.openSettings) private var openSettings
    #endif

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
            AppPresence.shared.navigation = environment.navigation
            if AppPresence.shared.openWindowAction == nil { AppPresence.shared.openWindowAction = openWindow }
            showOnboarding = !environment.services.settings.hasCompletedOnboarding
            if AppPresence.shared.shouldHideMainWindowAtLaunch() {
                // Started at login: stay in the menu bar.
                DispatchQueue.main.async {
                    NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(AppWindowID.main) == true }?.close()
                }
            }
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
                ScreenshotAutomation.openWindow = openWindow
                ScreenshotAutomation.openSettings = openSettings
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
        case .antivirus: AntivirusView(model: environment.antivirus)
        case .network: NetworkView(model: environment.network)
        case .automation: AutomationView(model: environment.automation)
        case .history: HistoryView(model: environment.history)
        }
    }
}

/// Menu commands and keyboard shortcuts.
struct AppCommands: Commands {
    let environment: AppEnvironment
    let updates: AppUpdateController
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Mac Cleaner") {
                AppPresence.shared.open(windowID: AppWindowID.about, using: openWindow)
            }
            Button("Check for Updates…") {
                AppPresence.shared.open(windowID: AppWindowID.update, using: openWindow)
                updates.checkNow()
            }
        }
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
            Button("Mac Cleaner on GitHub") { AppInfo.open(AppInfo.repositoryURL) }
            Button("Permissions & Privacy Guide") {
                if let url = URL(string: "https://github.com/Shayan5422/MacCleaner/blob/main/docs/PERMISSIONS.md") { AppInfo.open(url) }
            }
            Button("Report an Issue…") { AppInfo.open(AppInfo.issuesURL) }
        }
    }
}
