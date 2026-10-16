import SwiftUI

/// The Antivirus page. (Placeholder until the feature is implemented.)
struct AntivirusView: View {
    @Bindable var model: AntivirusViewModel

    var body: some View {
        PageScroll {
            PageHeader(section: .antivirus, subtitle: "Scans files for malware with free, regularly updated virus definitions.")
        }
    }
}
