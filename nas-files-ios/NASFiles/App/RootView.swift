import SwiftUI

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        TabView {
            BrowserView()
                .tabItem {
                    Label("Files", systemImage: "folder")
                }

            DownloadsView()
                .tabItem {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AppSettings())
        .environmentObject(OfflineStore())
        .environmentObject(DownloadQueueService(settings: AppSettings(), offlineStore: OfflineStore()))
}
