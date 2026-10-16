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
        /// The menu bar popover, rendered in a panel of its own, and the menu bar item.
        case menuBarHub
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
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)

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
                        window.makeKeyAndOrderFront(nil)
                        capture(window, to: url)
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
                        await captureMenuBarHub(environment: environment, to: url, appearance: appearance)
                        if let item = statusItemWindow() {
                            capture(item, to: directory.appendingPathComponent("\(step.name)-item\(suffix).png"))
                        }
                    }
                    count += 1
                    await step.reset(environment)
                }
            }
        }
        print("Screenshot automation: wrote \(count) images to \(directory.path)")
        NSApp.terminate(nil)
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

    /// The menu bar item's window (an `NSStatusBarWindow`).
    static func statusItemWindow() -> NSWindow? {
        NSApp.windows.first { String(describing: type(of: $0)).contains("StatusBarWindow") && $0.isVisible && $0.frame.width < 200 }
    }

    /// Renders the menu bar popover in a temporary panel with the popover material, as
    /// it appears under the menu bar item, and captures it.
    static func captureMenuBarHub(environment: AppEnvironment, to url: URL, appearance: NSAppearance.Name) async {
        let hosting = NSHostingView(rootView: MenuBarHub(environment: environment))
        let size = hosting.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: appearance)
        let material = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        material.material = .popover
        material.state = .active
        material.blendingMode = .behindWindow
        material.wantsLayer = true
        material.layer?.cornerRadius = 12
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
#endif
