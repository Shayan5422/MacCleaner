#if DEBUG
import AppKit
import SwiftUI

/// Debug-only helper that renders the windows of each section to PNG files
/// for the README and for design reviews:
///
///     Mac Cleaner --capture-screenshots <folder>
///                 [--screenshot-steps a,b,c]           only some steps
///                 [--screenshot-sizes default,min]     window sizes (default: default)
///                 [--screenshot-appearances light,dark] (default: both)
///
/// It drives the real app (real scans of this Mac) and captures the window as the
/// window server draws it, so no screen-recording permission is needed.
@MainActor
enum ScreenshotAutomation {
    static var outputDirectory: URL? {
        argument(after: "--capture-screenshots").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Which window a step captures.
    enum Target {
        /// The main window, with any sheet or popover attached to it.
        case main
        /// Another window, found by its title (About, the update window).
        case window(title: String)
        /// The Settings window.
        case settings
        /// The menu bar popover, rendered in a panel of its own, and the menu bar item's glyphs.
        case menuBarHub
        /// The first-launch introduction, rendered in a panel of its own.
        case onboarding
    }

    struct Step {
        var name: String
        var section: AppSection
        var target: Target = .main
        /// Starts whatever the page needs (a scan) and returns once it's ready. Runs once.
        var prepare: @MainActor (AppEnvironment) async -> Void = { _ in }
        /// Puts the page in the state to capture. Runs before every capture (each size and appearance).
        var apply: @MainActor (AppEnvironment) async -> Void = { _ in }
        /// Undoes `apply` (closes windows and sheets) after the capture.
        var reset: @MainActor (AppEnvironment) async -> Void = { _ in }
        var settle: Duration = .seconds(1.5)
    }

    /// A content size for the main window, with the suffix its files get.
    struct WindowSize: Equatable {
        var width: CGFloat
        var height: CGFloat
        var suffix: String

        /// The window's default size (`MacCleanerApp`'s `.defaultSize`).
        static let standard = WindowSize(width: 1260, height: 840, suffix: "")
        /// The smallest size the window allows.
        static let minimum = WindowSize(width: 1000, height: 660, suffix: "-min")
        /// The size the README screenshots use.
        static let readme = WindowSize(width: 1320, height: 860, suffix: "-readme")

        static func parse(_ text: String) -> WindowSize? {
            switch text.lowercased() {
            case "default", "standard": return .standard
            case "min", "minimum": return .minimum
            case "readme": return .readme
            default:
                let parts = text.lowercased().split(separator: "x").compactMap { Double($0) }
                guard parts.count == 2, parts[0] >= 1000, parts[1] >= 660 else { return nil }
                return WindowSize(width: parts[0], height: parts[1], suffix: "-\(Int(parts[0]))x\(Int(parts[1]))")
            }
        }
    }

    /// SwiftUI actions captured from the root view, so steps can open other windows.
    static var openWindow: OpenWindowAction?
    static var openSettings: OpenSettingsAction?

    /// Optional `--screenshot-steps a,b,c` limits the run to some pages.
    static var onlySteps: Set<String>? {
        argument(after: "--screenshot-steps").map { Set($0.split(separator: ",").map(String.init)) }
    }

    static var sizes: [WindowSize] {
        guard let list = argument(after: "--screenshot-sizes") else { return [.standard] }
        let parsed = list.split(separator: ",").compactMap { WindowSize.parse(String($0)) }
        return parsed.isEmpty ? [.standard] : parsed
    }

    static var appearances: [NSAppearance.Name] {
        guard let list = argument(after: "--screenshot-appearances") else { return [.aqua, .darkAqua] }
        let names = list.lowercased().split(separator: ",").compactMap { name -> NSAppearance.Name? in
            switch name {
            case "light": return .aqua
            case "dark": return .darkAqua
            default: return nil
            }
        }
        return names.isEmpty ? [.aqua, .darkAqua] : names
    }

    static func run(environment: AppEnvironment, steps allSteps: [Step]) async {
        guard let directory = outputDirectory else { return }
        let steps = onlySteps.map { names in allSteps.filter { names.contains($0.name) } } ?? allSteps
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(2))
        guard let window = mainWindow() else {
            print("Screenshot automation: no window found")
            NSApp.terminate(nil)
            return
        }
        // An active, key window draws prominent buttons and selections in their real colors.
        bringToFront(window)

        var prepared = Set<String>()
        var count = 0
        for size in sizes {
            window.setContentSize(NSSize(width: size.width, height: size.height))
            window.center()
            for appearance in appearances {
                NSApp.appearance = NSAppearance(named: appearance)
                for step in steps {
                    environment.navigation.open(step.section)
                    try? await Task.sleep(for: .milliseconds(600))
                    if prepared.insert(step.name).inserted {
                        await step.prepare(environment)
                    }
                    await step.apply(environment)
                    try? await Task.sleep(for: step.settle)
                    let suffix = size.suffix + (appearance == .darkAqua ? "-dark" : "")
                    let url = directory.appendingPathComponent("\(step.name)\(suffix).png")
                    switch step.target {
                    case .main:
                        bringToFront(window)
                        try? await Task.sleep(for: .milliseconds(200))
                        capture(window, to: url)
                        // A sheet on its own too, in case the window server leaves it out of
                        // the composite above.
                        if let sheet = window.attachedSheet, sheet.isVisible {
                            capture(sheet, to: directory.appendingPathComponent("\(step.name)-sheet\(suffix).png"))
                        }
                    case .window(let title):
                        if let other = NSApp.windows.first(where: { $0.title == title && $0.isVisible }) {
                            other.makeKeyAndOrderFront(nil)
                            try? await Task.sleep(for: .milliseconds(400))
                            capture(other, to: url)
                        } else {
                            print("Screenshot automation: window “\(title)” isn't open for \(step.name)")
                        }
                    case .settings:
                        if let settings = settingsWindow() {
                            settings.makeKeyAndOrderFront(nil)
                            try? await Task.sleep(for: .milliseconds(400))
                            capture(settings, to: url)
                        } else {
                            print("Screenshot automation: the Settings window isn't open for \(step.name)")
                        }
                    case .menuBarHub:
                        await captureHosted(AnyView(MenuBarHub(environment: environment)), material: .popover, cornerRadius: 12, to: url, appearance: appearance)
                        renderMenuBarGlyphs(to: directory.appendingPathComponent("\(step.name)-glyphs\(suffix).png"), appearance: appearance)
                    case .onboarding:
                        let onboarding = OnboardingView(services: environment.services).environment(environment.services.permissions)
                        await captureHosted(AnyView(onboarding), material: .windowBackground, cornerRadius: 10, to: url, appearance: appearance)
                    }
                    count += 1
                    await step.reset(environment)
                }
            }
        }
        print("Screenshot automation: wrote \(count) images to \(directory.path)")
        NSApp.terminate(nil)
    }

    /// Debug tooling only: asks to become the active app the way older SDKs did, since
    /// cooperative activation may leave a launched-from-Terminal app in the background.
    static func bringToFront(_ window: NSWindow) {
        if !NSApp.isActive {
            NSApp.perform(NSSelectorFromString("activateIgnoringOtherApps:"), with: NSNumber(value: true))
            NSApp.activate()
        }
        window.makeKeyAndOrderFront(nil)
    }

    static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) && $0.title == "Mac Cleaner" }
            ?? NSApp.windows.first { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }
    }

    /// Closes a window opened by a step.
    static func closeWindow(titled title: String) {
        NSApp.windows.first { $0.title == title && $0.isVisible }?.close()
    }

    static func settingsWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && ($0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") ?? false) }
    }

    static func closeSettings() {
        settingsWindow()?.close()
    }

    /// Renders a view in a temporary panel with the given material (the menu bar popover,
    /// the onboarding sheet) and captures it.
    static func captureHosted(_ view: AnyView, material kind: NSVisualEffectView.Material, cornerRadius: CGFloat, to url: URL, appearance: NSAppearance.Name) async {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: appearance)
        let material = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        material.material = kind
        material.state = .active
        material.blendingMode = .behindWindow
        material.wantsLayer = true
        material.layer?.cornerRadius = cornerRadius
        material.layer?.masksToBounds = true
        hosting.frame = material.bounds
        hosting.autoresizingMask = [.width, .height]
        material.addSubview(hosting)
        panel.contentView = material
        if let screen = NSScreen.main {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - size.width - 40, y: screen.visibleFrame.maxY - 8))
        }
        panel.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(3))
        panel.setContentSize(hosting.fittingSize)
        try? await Task.sleep(for: .milliseconds(500))
        capture(panel, to: url)
        panel.orderOut(nil)
    }

    /// Captures the window as the window server draws it (translucent sidebar,
    /// toolbar and shadow included), together with its sheets and popovers.
    /// An app may always capture its own windows. Falls back to rendering the view
    /// hierarchy if that isn't available.
    static func capture(_ window: NSWindow, to url: URL) {
        var windows = [window]
        if let sheet = window.attachedSheet { windows.append(sheet) }
        windows += (window.childWindows ?? []).filter(\.isVisible)
        // Sheets and popovers SwiftUI presents as separate windows over this one.
        windows += NSApp.windows.filter { other in
            other !== window && !windows.contains(other) && other.isVisible && other.windowNumber > 0
                && other.frame.intersects(window.frame) && other.level.rawValue >= window.level.rawValue
                && (other.isSheet || other is NSPanel || other.parent === window)
        }
        if let image = windowServerImage(of: windows) {
            let rep = NSBitmapImageRep(cgImage: image)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: url)
                return
            }
        }
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    /// `CGWindowListCreateImage(FromArray)`, looked up at run time because newer SDKs
    /// mark them unavailable in favor of ScreenCaptureKit (which needs a permission
    /// prompt even for an app's own windows). Debug-only tooling.
    private static func windowServerImage(of windows: [NSWindow]) -> CGImage? {
        guard let handle = dlopen(nil, RTLD_NOW) else { return nil }
        let bestResolution: UInt32 = 1 << 3 // kCGWindowImageBestResolution
        if windows.count > 1, let symbol = dlsym(handle, "CGWindowListCreateImageFromArray") {
            typealias CreateFromArray = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
            let createImage = unsafeBitCast(symbol, to: CreateFromArray.self)
            // The array holds CGWindowIDs as raw pointer-sized values, like CGWindowListCreate returns.
            var callbacks = kCFTypeArrayCallBacks
            callbacks.retain = nil
            callbacks.release = nil
            callbacks.copyDescription = nil
            callbacks.equal = nil
            let ids = windows.map { UnsafeRawPointer(bitPattern: UInt(UInt32(truncatingIfNeeded: $0.windowNumber))) }
            var values = ids
            if let array = CFArrayCreate(nil, &values, values.count, &callbacks) {
                return createImage(.null, array, bestResolution)?.takeRetainedValue()
            }
        }
        guard let window = windows.first, window.windowNumber > 0, let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        let includingWindow: UInt32 = 1 << 3 // kCGWindowListOptionIncludingWindow
        return createImage(.null, includingWindow, UInt32(truncatingIfNeeded: window.windowNumber), bestResolution)?.takeRetainedValue()
    }

    /// Draws the menu bar item's variants (icon, ports, CPU, free space, attention and
    /// threat dots) on a menu bar–like strip, tinted the way the menu bar tints them.
    static func renderMenuBarGlyphs(to url: URL, appearance: NSAppearance.Name) {
        let variants: [(String?, MenuBarGlyph.Alert?)] = [(nil, nil), ("3", nil), ("\u{2007}12%", nil), ("362 GB", nil), ("3", .attention), (nil, .threat)]
        let images = variants.map { MenuBarGlyph.image(text: $0.0, alert: $0.1) }
        let gap: CGFloat = 18
        let width = images.reduce(gap) { $0 + $1.size.width + gap }
        let height: CGFloat = 26
        let scale: CGFloat = 4
        guard let look = NSAppearance(named: appearance),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        look.performAsCurrentDrawingAppearance {
            (appearance == .darkAqua ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            var x = gap
            for image in images {
                let rect = NSRect(x: x, y: (height - image.size.height) / 2, width: image.size.width, height: image.size.height)
                if image.isTemplate {
                    let tinted = NSImage(size: image.size, flipped: false) { bounds in
                        image.draw(in: bounds)
                        NSColor.labelColor.set()
                        bounds.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: rect)
                } else {
                    image.draw(in: rect)
                }
                x += image.size.width + gap
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Waits until `condition` is true or the timeout passes.
    static func wait(timeout: Duration = .seconds(180), until condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    private static func argument(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
/// Debug-only self-test of the menu bar mode, for checking a build without clicking:
///
///     Mac Cleaner --exercise-windows <cycles>
///
/// Each cycle shows a page (the Uninstaller with an app selected, so its details panel is
/// open), closes the main window the way its close button does, and reopens it from the
/// menu bar's "Open Mac Cleaner" or a Dock click. With no window open it also opens About
/// and Settings. After every step it checks the windows and the Dock icon policy, prints
/// one line per check to standard error, and quits when it's done.
///
/// The app stays open without windows only while the menu bar item is on. To try that
/// while the saved setting is off, add `-showMenuBarExtra YES`; the menu bar item then
/// saves the setting as on, so turn it off again afterwards.
@MainActor
enum WindowCycleExercise {
    private static var started = false
    private static var checks = 0
    private static var failures = 0

    static var isRequested: Bool { cycles != nil }

    private static var cycles: Int? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--exercise-windows"), index + 1 < arguments.count else { return nil }
        return Int(arguments[index + 1]).map { max(1, $0) }
    }

    /// Starts once, in a task of its own: closing the main window cancels its view's tasks.
    static func startIfRequested(environment: AppEnvironment, openSettings: OpenSettingsAction) {
        guard let cycles, !started else { return }
        started = true
        Task { @MainActor in
            await run(cycles: cycles, environment: environment, openSettings: openSettings)
        }
    }

    private static func run(cycles: Int, environment: AppEnvironment, openSettings: OpenSettingsAction) async {
        await settle(2)
        log("start: \(cycles) cycles; menu bar item \(MenuBarPreferences.isMenuBarItemShown ? "shown" : "hidden"), hide the Dock icon without windows: \(MenuBarPreferences.shared.hidesDockIconWhenWindowClosed)")
        expectWindow("launch", mainWindow())
        let pages: [AppSection] = [.uninstaller, .updates, .dashboard, .duplicates, .storage]
        for cycle in 1...cycles {
            let page = pages[(cycle - 1) % pages.count]
            environment.navigation.open(page)
            if page == .uninstaller {
                environment.uninstaller.loadIfNeeded()
                await ScreenshotAutomation.wait(timeout: .seconds(60)) { environment.uninstaller.hasLoaded }
                if let app = environment.uninstaller.visibleApps.first { environment.uninstaller.selection = [app.id] }
            }
            await settle()
            mainWindow()?.performClose(nil)
            await settle()
            expectNoWindows("cycle \(cycle): closed the main window on \(page)")
            if cycle.isMultiple(of: 2) {
                // A Dock click (or opening the app again) while no window is open.
                let handled = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
                if handled == nil { AppPresence.shared.showMainWindow() }
                await settle()
                expectWindow("cycle \(cycle): reopened from the Dock", mainWindow())
            } else {
                // The menu bar hub's "Open Mac Cleaner".
                AppPresence.shared.open(windowID: AppWindowID.main)
                await settle()
                expectWindow("cycle \(cycle): reopened from the menu bar", mainWindow())
            }
        }

        mainWindow()?.performClose(nil)
        await settle()
        expectNoWindows("closed the main window before About")
        await exerciseMenuBarPopover()
        AppPresence.shared.open(windowID: AppWindowID.about)
        await settle()
        let about = NSApp.windows.first { $0.title == "About Mac Cleaner" && $0.isVisible }
        expectWindow("About opened from the menu bar", about)
        about?.performClose(nil)
        await settle()
        expectNoWindows("closed About")

        AppPresence.shared.bringToFront()
        openSettings()
        await settle()
        let settings = ScreenshotAutomation.settingsWindow()
        expectWindow("Settings opened from the menu bar", settings)
        settings?.performClose(nil)
        await settle()
        expectNoWindows("closed Settings")

        AppPresence.shared.open(windowID: AppWindowID.main)
        await settle()
        expectWindow("reopened the main window at the end", mainWindow())
        environment.uninstaller.selection = []
        environment.navigation.open(.dashboard)
        await settle()
        log("done: \(checks) checks, \(failures) failed")
        NSApp.terminate(nil)
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(AppWindowID.main) == true && $0.isVisible }
    }

    /// Opens and closes the menu bar popover by clicking the status item, when the status
    /// item's button lives in this process.
    private static func exerciseMenuBarPopover() async {
        guard MenuBarPreferences.isMenuBarItemShown else { return }
        func buttons(in view: NSView) -> [NSStatusBarButton] {
            ((view as? NSStatusBarButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons(in:))
        }
        let button = NSApp.windows.compactMap(\.contentView).flatMap(buttons(in:)).first
        guard let button else {
            log("     the status item's button isn't in this process; the popover wasn't clicked")
            return
        }
        let before = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        button.performClick(nil)
        await settle(2)
        guard let popover = NSApp.windows.first(where: { $0.isVisible && !before.contains(ObjectIdentifier($0)) && !String(describing: type(of: $0)).hasPrefix("NSStatusBar") }) else {
            // SwiftUI opens the popover from real mouse events; a programmatic click doesn't.
            log("     clicking the status item from inside the app didn't open the popover; not checked")
            return
        }
        log("     menu bar popover opened: \(type(of: popover)) \(popover.frame.size)")
        button.performClick(nil)
        await settle()
        check(!popover.isVisible, "menu bar popover closed")
        expectNoWindows("menu bar popover closed")
    }

    /// The Dock icon hides only while the menu bar item is shown and the person wants that.
    private static var expectedPolicyWithoutWindows: NSApplication.ActivationPolicy {
        MenuBarPreferences.isMenuBarItemShown && MenuBarPreferences.shared.hidesDockIconWhenWindowClosed ? .accessory : .regular
    }

    private static func expectNoWindows(_ step: String) {
        let open = NSApp.windows.filter(AppPresence.isAppWindow).map(\.title)
        check(open.isEmpty, "\(step): no app windows open \(open)")
        let expected = expectedPolicyWithoutWindows
        check(NSApp.activationPolicy() == expected, "\(step): Dock icon policy \(name(NSApp.activationPolicy())), expected \(name(expected))")
    }

    private static func expectWindow(_ step: String, _ window: NSWindow?) {
        check(window?.isVisible == true, "\(step): window '\(window?.title ?? "none")' visible")
        check(NSApp.activationPolicy() == .regular, "\(step): Dock icon policy \(name(NSApp.activationPolicy())), expected regular")
        log("     \(step): app active \(NSApp.isActive), key window '\(NSApp.keyWindow?.title ?? "-")'")
    }

    private static func name(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular: return "regular"
        case .accessory: return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "unknown"
        }
    }

    private static func check(_ condition: Bool, _ text: String) {
        checks += 1
        if !condition { failures += 1 }
        log("\(condition ? "ok  " : "FAIL") \(text)")
    }

    private static func log(_ text: String) {
        FileHandle.standardError.write(Data("EXERCISE \(text)\n".utf8))
    }

    private static func settle(_ seconds: Double = 1.2) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

#endif
