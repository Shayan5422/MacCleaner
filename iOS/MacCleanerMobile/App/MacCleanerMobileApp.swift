import SwiftUI

@main
struct MacCleanerMobileApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .tint(.brand)
                .onChange(of: scenePhase) { _, phase in
                    // Coming back from Settings or another app: storage and permissions may have changed.
                    if phase == .active {
                        model.refreshStorage()
                        Task { await model.protection.refresh() }
                    }
                }
        }
    }
}

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            NavigationStack { OverviewView(model: model) }
                .tabItem { Label("Overview", systemImage: MobileSection.overview.symbol) }
                .tag(AppModel.Tab.overview)
            NavigationStack { CleanHomeView(model: model) }
                .tabItem { Label("Clean", systemImage: "sparkles") }
                .tag(AppModel.Tab.clean)
            NavigationStack { ProtectionHomeView(model: model.protection) }
                .tabItem { Label("Protect", systemImage: MobileSection.protection.symbol) }
                .tag(AppModel.Tab.protect)
            NavigationStack { GuidesHomeView(context: model.guideContext) }
                .tabItem { Label("Guides", systemImage: MobileSection.guides.symbol) }
                .tag(AppModel.Tab.guides)
        }
    }
}
