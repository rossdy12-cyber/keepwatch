import SwiftUI

@main
struct KeepwatchApp: App {
    @StateObject private var settings = ServiceSettings()
    @StateObject private var truenas = TrueNASStore()
    @StateObject private var media = MediaStore()
    @StateObject private var router = AppRouter()

    init() {
        Theme.applyUIKitAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(truenas)
                .environmentObject(media)
                .environmentObject(router)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

enum AppTab: Hashable {
    case overview, files, downloads, media, settings
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var tab: AppTab = .overview
}

struct RootView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var settings: ServiceSettings

    var body: some View {
        TabView(selection: $router.tab) {
            OverviewView()
                .tabItem { Label("Overview", systemImage: "gauge.medium") }
                .tag(AppTab.overview)
            FilesView()
                .tabItem { Label("Files", systemImage: "folder") }
                .tag(AppTab.files)
            DownloadsView()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
                .tag(AppTab.downloads)
            MediaView()
                .tabItem { Label("Media", systemImage: "film.stack") }
                .tag(AppTab.media)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .onAppear {
            if !settings.anyConfigured { router.tab = .settings }
        }
    }
}
