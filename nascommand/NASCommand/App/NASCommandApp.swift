import SwiftUI
import UserNotifications

@main
struct NASCommandApp: App {
    @StateObject private var settings = NASSettings.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task {
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                    BackgroundRefresh.schedule()
                }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            await BackgroundRefresh.run()
        }
    }
}

enum RootTab: Hashable { case dashboard, settings }

struct RootView: View {
    @EnvironmentObject private var settings: NASSettings
    @State private var tab: RootTab = .dashboard

    var body: some View {
        TabView(selection: $tab) {
            DashboardView(openSettings: { tab = .settings })
                .tabItem { Label("Dashboard", systemImage: "server.rack") }
                .tag(RootTab.dashboard)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(RootTab.settings)
        }
        .onAppear { if !settings.isConfigured { tab = .settings } }
    }
}
