import AppKit

// The same executable serves two roles:
//  • normally it launches the SwiftUI app;
//  • when launchd starts it with `--run-automation` (the background agent registered
//    through SMAppService), it runs any due automatic cleanup headlessly and exits.
if AutomationHeadless.isRequested {
    let runner = AppEnvironment.makeAutomationRunner()
    Task.detached {
        let code = await AutomationHeadless.run(runner: runner)
        exit(code)
    }
    dispatchMain()
} else {
    MacCleanerApp.main()
}
