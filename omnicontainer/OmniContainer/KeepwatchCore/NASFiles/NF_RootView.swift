import SwiftUI

struct NFRootView: View {
    @EnvironmentObject private var settings: NFAppSettings

    var body: some View {
        TabView {
            NFBrowserView()
                .tabItem {
                    Label("Files", systemImage: "folder")
                }

            NFDownloadsView()
                .tabItem {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }

            NFSettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}
