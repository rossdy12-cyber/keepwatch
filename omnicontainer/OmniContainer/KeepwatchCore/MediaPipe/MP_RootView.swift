import SwiftUI

struct MPRootView: View {
    @EnvironmentObject private var settings: MPAppSettings
    @EnvironmentObject private var router: MPAppRouter

    var body: some View {
        TabView(selection: $router.selectedTab) {
            MPQueueView()
                .tabItem {
                    Label("Queue", systemImage: "arrow.down.circle")
                }
                .tag(0)

            MPAddDownloadView()
                .tabItem {
                    Label("Add", systemImage: "plus.circle")
                }
                .tag(1)

            MPSettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(2)
        }
    }
}
