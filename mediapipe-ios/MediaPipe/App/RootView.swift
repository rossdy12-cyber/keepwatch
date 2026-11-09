import SwiftUI

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        TabView(selection: $router.selectedTab) {
            QueueView()
                .tabItem {
                    Label("Queue", systemImage: "arrow.down.circle")
                }
                .tag(0)

            AddDownloadView()
                .tabItem {
                    Label("Add", systemImage: "plus.circle")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(2)
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AppSettings())
        .environmentObject(AppRouter())
}
