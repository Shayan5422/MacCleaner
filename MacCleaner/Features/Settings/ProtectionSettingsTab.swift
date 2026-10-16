import SwiftUI

/// Settings › Protection: the antivirus and Guardian (Startup Guard, Web Shield, login analysis).
struct ProtectionSettingsTab: View {
    let environment: AppEnvironment

    var body: some View {
        GuardianSettingsTab(settings: environment.guardian.settings)
    }
}
