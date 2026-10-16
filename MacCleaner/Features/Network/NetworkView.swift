import SwiftUI

/// The Ports & Network page. (Placeholder until the feature is implemented.)
struct NetworkView: View {
    @Bindable var model: NetworkViewModel

    var body: some View {
        PageScroll {
            PageHeader(section: .network, subtitle: "Open ports, the processes behind them and your network connections.")
        }
    }
}
