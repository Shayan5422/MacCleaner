import Foundation

/// Launch arguments for checking screens in the simulator without tapping through them
/// (`-debugTab clean`, `-onboardingPage 2`). They do nothing in release builds.
enum DebugLaunch {
    static var onboardingPage: Int {
        #if DEBUG
        return UserDefaults.standard.integer(forKey: "onboardingPage")
        #else
        return 0
        #endif
    }

    static var tab: AppModel.Tab? {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "debugTab") {
        case "overview": return .overview
        case "clean": return .clean
        case "protect": return .protect
        case "guides": return .guides
        default: return nil
        }
        #else
        return nil
        #endif
    }
}
