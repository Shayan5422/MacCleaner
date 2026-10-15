#if DEBUG
import AppKit
import SwiftUI

/// Debug-only helper that renders the main window of each section to PNG files
/// for the README: `Mac Cleaner --capture-screenshots <folder>`.
///
/// It drives the real app (real scans of this Mac) and renders the window's
/// own view hierarchy, so no screen-recording permission is needed.
@MainActor
enum ScreenshotAutomation {
    static var outputDirectory: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--capture-screenshots"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    struct Step {
        var name: String
        var section: AppSection
        /// Starts whatever the page needs (a scan) and returns once it's ready.
        var prepare: @MainActor (AppEnvironment) async -> Void = { _ in }
        var settle: Duration = .seconds(1.5)
    }

    /// Optional `--screenshot-steps a,b,c` limits the run to some pages.
    static var onlySteps: Set<String>? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--screenshot-steps"), index + 1 < arguments.count else { return nil }
        return Set(arguments[index + 1].split(separator: ",").map(String.init))
    }

    static func run(environment: AppEnvironment, steps allSteps: [Step], appearances: [NSAppearance.Name] = [.aqua, .darkAqua]) async {
        guard let directory = outputDirectory else { return }
        let steps = onlySteps.map { names in allSteps.filter { names.contains($0.name) } } ?? allSteps
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }) else {
            print("Screenshot automation: no window found")
            NSApp.terminate(nil)
            return
        }
        window.setContentSize(NSSize(width: 1320, height: 860))
        window.center()

        var prepared = Set<String>()
        for appearance in appearances {
            NSApp.appearance = NSAppearance(named: appearance)
            for step in steps {
                environment.navigation.open(step.section)
                try? await Task.sleep(for: .milliseconds(600))
                if prepared.insert(step.name).inserted {
                    await step.prepare(environment)
                }
                try? await Task.sleep(for: step.settle)
                let suffix = appearance == .darkAqua ? "-dark" : ""
                capture(window, to: directory.appendingPathComponent("\(step.name)\(suffix).png"))
            }
        }
        print("Screenshot automation: wrote \(steps.count * appearances.count) images to \(directory.path)")
        NSApp.terminate(nil)
    }

    /// Captures the window as the window server draws it (translucent sidebar,
    /// toolbar and shadow included). An app may always capture its own windows.
    /// Falls back to rendering the view hierarchy if that isn't available.
    static func capture(_ window: NSWindow, to url: URL) {
        if let image = windowServerImage(of: window) {
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

    /// `CGWindowListCreateImage`, looked up at run time because newer SDKs mark it
    /// unavailable in favor of ScreenCaptureKit (which needs a permission prompt even
    /// for an app's own windows). Debug-only tooling.
    private static func windowServerImage(of window: NSWindow) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        let includingWindow: UInt32 = 1 << 3   // kCGWindowListOptionIncludingWindow
        let bestResolution: UInt32 = 1 << 3    // kCGWindowImageBestResolution
        return createImage(.null, includingWindow, UInt32(window.windowNumber), bestResolution)?.takeRetainedValue()
    }

    /// Waits until `condition` is true or the timeout passes.
    static func wait(timeout: Duration = .seconds(180), until condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(300))
        }
    }
}
#endif
