import SwiftUI

/// Settings › Protection: the antivirus and Guardian (Startup Guard, Web Shield, login analysis).
struct ProtectionSettingsTab: View {
    let environment: AppEnvironment
    @State private var part: Part = .antivirus

    enum Part: String, CaseIterable, Identifiable {
        case antivirus = "Antivirus"
        case guardian = "Startup & Web"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 10) {
            Picker("Show", selection: $part) {
                ForEach(Part.allCases) { part in
                    Text(part.rawValue).tag(part)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            switch part {
            case .antivirus: AntivirusSettingsTab(model: environment.antivirus)
            case .guardian: GuardianSettingsTab(settings: environment.guardian.settings)
            }
        }
    }
}
